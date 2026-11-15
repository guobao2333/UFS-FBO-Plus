#!/system/bin/sh
# FBO+ 引擎（澎湃OS / MIUI HAL 后端）
#
# 调用链（已在 Redmi M332BF / HyperOS 3.0.305 上实测）：
#   am broadcast miui.intent.action.transferActiveFboTrigger --es appList "pkg1,pkg2"
#     → system_server: com.miui.server.MiuiFboService (ACTIVE_START_FBO)
#     → /system_ext/bin/FboNativeService (init 服务名 fbo-installd, root)
#         FBO_trigger() → FBO_F2FS_Trigger() → f2fs GC
#     → 日志回传 "Receive data from native:pkg:<pkg>:F2FS:<before>:<after>"
#
# 注意：fbo-installd 在 init 里是 disabled，且每轮跑完会自行退出，
# 所以每次触发前都要用 persist.sys.fboservice.ctrl 重新拉起。
#
# 用法：
#   fbo.sh probe              能力探测
#   fbo.sh apps               列出第三方应用
#   fbo.sh run [--apps a,b] [--timeout N]
#   fbo.sh log [N]
# 输出：NDJSON，每行一个 JSON 对象

set -u

STATE_DIR=/data/adb/fbo_plus
HISTORY="$STATE_DIR/history.jsonl"
CTRL_PROP=persist.sys.fboservice.ctrl
ENABLE_PROP=persist.sys.stability.miui_fbo_enable
SVC_NAME=miui.fbo.service
TRIGGER_ACTION=miui.intent.action.transferActiveFboTrigger
# 耗时预估（分钟，整数，故意只报整分钟）：
#   1个 2 分钟起，按 2 5 8 12 15 20 25 30 爬升，超过 8 个每个 +5 分钟。
# 这不是拟合出来的曲线，是手挑的一串整数——实测单应用只要 40~65 秒，
# 这里整体报大 2~4 倍，保证"只会提前跑完"，且数字整齐不零碎。
ETA_MINUTES="2 5 8 12 15 20 25 30"
ETA_MINUTES_LIST="2,5,8,12,15,20,25,30"
ETA_CAP=30
# 超过 8 个应用不再报数字（只说"30 分钟以上"），但内部超时仍按每个 +3 分钟放宽
ETA_TIMEOUT_STEP=3
SVC_NAME=miui.fbo.service
TRIGGER_ACTION=miui.intent.action.transferActiveFboTrigger
# 耗时预估：单应用基础 3 分钟（2 分 45 秒 + 余量），多应用线性叠加，
# 并按数量梯度加 2~5 分钟，抵消并行处理带来的降速。
# 这是"只早不晚"的保守估算，基准参考 9.9 成新的骁龙 8 Elite 机型。
ETA_BASE=165
ETA_PAD=15
mkdir -p "$STATE_DIR" 2>/dev/null

# ---------- 输出 ----------
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r'; }
emit() { printf '%s\n' "$1"; }
emit_log() { emit "{\"ev\":\"log\",\"msg\":\"$(esc "$1")\"}"; }
emit_error() { emit "{\"ev\":\"error\",\"msg\":\"$(esc "$1")\"}"; }
now() { date +%s; }

# ---------- 基础探测 ----------
svc_listed() {
    service list 2>/dev/null | grep -q "$SVC_NAME"
}

# ActiveFBO_isSupport：只读调用，返回 "00000001" 表示支持
svc_support() {
    out=$(service call "$SVC_NAME" 1 2>/dev/null)
    case "$out" in
        *00000001*) printf '1' ;;
        *) printf '0' ;;
    esac
}

prop() { getprop "$1" 2>/dev/null; }

# 对外展示的预估分钟数，封顶 ETA_CAP
eta_minutes() {
    n=$1
    if [ "$n" -le 0 ]; then printf '0'
    elif [ "$n" -le 8 ]; then
        printf '%s' "$(printf '%s' "$ETA_MINUTES" | cut -d' ' -f"$n")"
    else
        printf '%s' "$ETA_CAP"
    fi
}

# 是否超出可量化区间（只报"X 分钟以上"）
eta_opened() {
    [ "$1" -gt 8 ] && printf 'true' || printf 'false'
}

# 内部硬超时（秒）：超过 8 个时不再封顶，按每个 +3 分钟放宽，再加 2 分钟余量
eta_total() {
    n=$1
    if [ "$n" -le 8 ]; then
        printf '%s' $(( $(eta_minutes "$n") * 60 ))
    else
        printf '%s' $(( (ETA_CAP + (n - 8) * ETA_TIMEOUT_STEP) * 60 + 120 ))
    fi
}

svc_running() { [ "$(prop init.svc.fbo-installd)" = "running" ]; }

# 手机管家状态：卸载 / 冻结 / 正常
# 实测：卸载后 MiuiFboService 会立刻中止并回退成 PackageNamePlaceholder，结果恒为 0
center_state() {
    pm path com.miui.securitycenter >/dev/null 2>&1 || { printf 'missing'; return; }
    line=$(dumpsys package com.miui.securitycenter 2>/dev/null | grep -m1 'User 0:')
    case "$line" in
        *suspended=true*) printf 'suspended' ;;
        *enabled=2* | *enabled=4* | *enabled=5*) printf 'disabled' ;;
        *) printf 'ok' ;;
    esac
}

# 重启 fbo-installd（每轮结束后它会自己退出）
restart_service() {
    emit_log "重启 fbo-installd"
    setprop "$CTRL_PROP" false 2>/dev/null
    sleep 1
    setprop "$CTRL_PROP" true 2>/dev/null
    i=0
    while [ $i -lt 15 ]; do
        svc_running && { emit_log "fbo-installd 已启动"; return 0; }
        sleep 1
        i=$((i + 1))
    done
    emit_error "fbo-installd 没能启动（init.svc.fbo-installd=$(prop init.svc.fbo-installd)）"
    return 1
}

# ---------- probe ----------
cmd_probe() {
    model=$(prop ro.product.model)
    sdk=$(prop ro.build.version.sdk)
    osname=$(prop ro.mi.os.version.name)
    [ -n "$osname" ] || osname=$(prop ro.build.version.release)

    if svc_listed; then svc=true; else svc=false; fi
    center=$(center_state)
    support=0
    [ "$svc" = true ] && support=$(svc_support)
    if svc_running; then running=true; else running=false; fi

    emit "{\"ev\":\"probe\",\"data\":{\"device\":{\"model\":\"$(esc "$model")\",\"sdk\":\"$(esc "$sdk")\",\"os\":\"$(esc "$osname")\"},\"miui\":{\"service\":$svc,\"center\":\"$center\",\"support\":$support,\"running\":$running,\"eta\":{\"minutes\":[$ETA_MINUTES_LIST],\"cap\":$ETA_CAP,\"timeoutStep\":$ETA_TIMEOUT_STEP}},\"props\":{\"ctrl\":\"$(esc "$(prop $CTRL_PROP)")\",\"enable\":\"$(esc "$(prop $ENABLE_PROP)")\"}}}"
}

# ---------- apps ----------
cmd_apps() {
    # 列出第三方应用，带数据目录大小（MB），按大小降序 —— 大应用更值得整理
    tmp=/data/local/tmp/fbo_apps.$$
    : > "$tmp"
    for p in $(pm list packages -3 2>/dev/null | sed 's/^package://'); do
        kb=$(du -sk "/data/data/$p" 2>/dev/null | cut -f1)
        printf '%s %s\n' "${kb:-0}" "$p" >> "$tmp"
    done
    body=$(sort -rn "$tmp" 2>/dev/null | head -80 | while read -r kb pkg; do
        printf '{"pkg":"%s","mb":%s},' "$pkg" $(( ${kb:-0} / 1024 ))
    done | sed 's/,$//')
    rm -f "$tmp"
    emit "{\"ev\":\"apps\",\"data\":[$body]}"
}

# ---------- run ----------
parse_apps() {
    # "a,b,c" -> 行分隔
    printf '%s' "$1" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$'
}

cmd_run() {
    apps=""
    timeout=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --apps) apps=$2; shift 2 ;;
            --timeout) timeout=$2; shift 2 ;;
            *) shift ;;
        esac
    done

    t0=$(now)
    cmd_probe

    if ! svc_listed; then
        emit_error "系统里没有 miui.fbo.service，这台设备不支持焕新存储"
        emit "{\"ev\":\"done\",\"ok\":false,\"reason\":\"no-service\",\"elapsed\":0}"
        return 1
    fi
    center=$(center_state)
    if [ "$center" != "ok" ]; then
        case "$center" in
            missing) emit_error "手机管家（com.miui.securitycenter）已被卸载或未安装，焕新存储会直接中止，结果恒为 0" ;;
            suspended) emit_error "手机管家处于挂起状态，焕新存储不可用" ;;
            disabled) emit_error "手机管家被禁用，焕新存储不可用" ;;
            *) emit_error "手机管家状态异常：$center" ;;
        esac
        emit "{\"ev\":\"done\",\"ok\":false,\"reason\":\"center\",\"elapsed\":$(( $(now) - t0 ))}"
        return 1
    fi
    if [ "$(svc_support)" != "1" ]; then
        emit_error "系统报告 ActiveFBO_isSupport=0，当前策略禁用了焕新存储"
        emit "{\"ev\":\"done\",\"ok\":false,\"reason\":\"disabled\",\"elapsed\":0}"
        return 1
    fi

    if [ -z "$apps" ]; then
        apps=$(cmd_apps | sed 's/^{"ev":"apps","data":\[//; s/\]}$//; s/"//g')
        apps=$(printf '%s' "$apps" | tr ',' '\n')
    else
        apps=$(parse_apps "$apps")
    fi

    count=$(printf '%s\n' "$apps" | grep -c .)
    if [ "$count" -eq 0 ]; then
        emit_error "应用列表为空"
        emit "{\"ev\":\"done\",\"ok\":false,\"reason\":\"empty\",\"elapsed\":0}"
        return 1
    fi

    join=$(printf '%s' "$apps" | tr '\n' ',' | sed 's/,$//')
    eta_min=$(eta_minutes "$count")
    opened=$(eta_opened "$count")
    [ -n "$timeout" ] || timeout=$(eta_total "$count")
    emit "{\"ev\":\"trigger\",\"count\":$count,\"etaMinutes\":$eta_min,\"openEnded\":$opened,\"apps\":\"$(esc "$join")\"}"

    [ "$(prop $ENABLE_PROP)" = "true" ] || setprop "$ENABLE_PROP" true 2>/dev/null
    restart_service || { emit "{\"ev\":\"done\",\"ok\":false,\"reason\":\"service\",\"elapsed\":$(( $(now) - t0 ))}"; return 1; }

    logcat -c 2>/dev/null
    am broadcast -a "$TRIGGER_ACTION" --es appList "$join" >/dev/null 2>&1
    emit_log "已发送触发广播"

    # 轮询日志直到出现 All stop,exit 或超时
    deadline=$(( $(now) + timeout ))
    seen=0
    while :; do
        out=$(logcat -d 2>/dev/null | grep -E 'Receive data from native|fbo event report data|All stop,exit|policy disables|appList is empty')
        n=$(printf '%s' "$out" | grep -c .)
        if [ "$n" -gt "$seen" ]; then
            printf '%s\n' "$out" | tail -n +$((seen + 1)) | while IFS= read -r line; do
                case "$line" in
                    *"Receive data from native"*)
                        pkg=$(printf '%s' "$line" | sed -n 's/.*native:pkg:\([^:]*\):.*/\1/p')
                        before=$(printf '%s' "$line" | sed -n 's/.*F2FS:\([0-9]*\):.*/\1/p')
                        after=$(printf '%s' "$line" | sed -n 's/.*F2FS:[0-9]*:\([0-9]*\).*/\1/p')
                        [ -n "$pkg" ] && emit "{\"ev\":\"app\",\"pkg\":\"$(esc "$pkg")\",\"before\":${before:-0},\"after\":${after:-0},\"t\":$(( $(now) - t0 ))}"
                        ;;
                    *"fbo event report data"*)
                        total=$(printf '%s' "$line" | sed -n 's/.*fragment_count:\([0-9]*\).*/\1/p')
                        emit "{\"ev\":\"report\",\"total\":${total:-0}}"
                        ;;
                    *"All stop,exit"*)
                        emit_log "本轮结束"
                        ;;
                    *"policy disables"*)
                        emit_error "系统策略拒绝执行焕新存储"
                        ;;
                    *"PackageNamePlaceholder"*)
                        emit_error "系统回退成 PackageNamePlaceholder：手机管家未被识别，本轮结果无效"
                        ;;
                    *"appList is empty"*)
                        emit_error "应用列表被系统判为空"
                        ;;
                esac
            done
            seen=$n
        fi
        case "$out" in
            *"All stop,exit"*) break ;;
        esac
        [ "$(now)" -ge "$deadline" ] && { emit_error "等待超时（${timeout}s）"; break; }
        sleep 2
    done

    elapsed=$(( $(now) - t0 ))
    emit "{\"ev\":\"done\",\"ok\":true,\"count\":$count,\"elapsed\":$elapsed}"
    printf '{"ts":%s,"apps":%s,"elapsed":%s}\n' "$(now)" "$count" "$elapsed" >> "$HISTORY" 2>/dev/null
}

cmd_log() {
    tail -n "${1:-20}" "$HISTORY" 2>/dev/null || true
}

case "${1:-probe}" in
    probe) cmd_probe ;;
    apps) cmd_apps ;;
    run) shift; cmd_run "$@" ;;
    log) shift; cmd_log "$@" ;;
    *) emit_error "unknown command: $1"; exit 2 ;;
esac
