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

MODDIR=${0%/*}
STATE_DIR=/data/adb/fbo_plus
STATE="$STATE_DIR/state.json"
HISTORY="$STATE_DIR/history.jsonl"
APPS_CACHE="$STATE_DIR/apps.json"
RUNLOG="$STATE_DIR/run.log"
STATPREF=/data/data/com.miui.securitycenter/shared_prefs/remote_provider_preferences.xml
CTRL_PROP=persist.sys.fboservice.ctrl
ENABLE_PROP=persist.sys.stability.miui_fbo_enable
SVC_NAME=miui.fbo.service
TRIGGER_ACTION=miui.intent.action.transferActiveFboTrigger
PATTERN='Receive data from native|fbo event report data|sendBroadcast and resultNumber|All stop,exit|PackageNamePlaceholder|policy disables|appList is empty|SIGABRT|Fatal signal|died; reconnecting'
LOCK="$STATE_DIR/run.lock"
# 耗时预估（分钟，整数，故意只报整分钟）：
#   1个 2 分钟起，按 2 5 8 12 15 20 25 30 爬升；超过 8 个只报“30 分钟以上”。
ETA_MINUTES="2 5 8 12 15 20 25 30"
ETA_MINUTES_LIST="2,5,8,12,15,20,25,30"
ETA_CAP=30
# 超过 8 个应用内部超时仍按每个 +3 分钟放宽，另加 2 分钟余量
ETA_TIMEOUT_STEP=3
mkdir -p "$STATE_DIR" 2>/dev/null

# ---------- 输出 ----------
esc() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr -d '\n\r'; }
emit() { printf '%s\n' "$1"; }
emit_log() { emit "{\"ev\":\"log\",\"msg\":\"$(esc "$1")\"}"; }
emit_error() { emit "{\"ev\":\"error\",\"msg\":\"$(esc "$1")\"}"; }
now() { date +%s; }

# 供 WebUI 轮询的进度文件
RESULTS=""
REMOVED=0
RUNID=0
LOCKED=0
# 原子写 state.json；参数：running phase total done ok reason
# ok: null / true / false；reason: null / "timeout" 等
write_state() {
    tmp="$STATE.tmp.$$"
    printf '{"runId":%s,"running":%s,"phase":"%s","started":%s,"updated":%s,"total":%s,"done":%s,"etaMinutes":%s,"openEnded":%s,"ok":%s,"reason":%s,"apps":[%s]}\n' \
        "$RUNID" "$1" "$2" "${STARTED:-0}" "$(now)" "$3" "$4" "${ETA_MIN:-0}" "${OPENED:-false}" "$5" "$6" "${RESULTS%,}" \
        > "$tmp" 2>/dev/null && mv "$tmp" "$STATE"
}

# 同一个时间只允许一轮整理；锁目录里记 pid，进程没了就自动清掉
acquire_lock() {
    if mkdir "$LOCK" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null
        LOCKED=1
        return 0
    fi
    holder=$(cat "$LOCK/pid" 2>/dev/null)
    # 刚 mkdir、还没写 pid 的窗口：等一下再判断，别把正在启动的一轮顶掉
    if [ -z "$holder" ]; then
        sleep 1
        holder=$(cat "$LOCK/pid" 2>/dev/null)
    fi
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
        return 1
    fi
    # 上一轮被强杀留下的锁：pid 已经不在了，直接接管
    rm -rf "$LOCK" 2>/dev/null
    if mkdir "$LOCK" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK/pid" 2>/dev/null
        LOCKED=1
        return 0
    fi
    return 1
}

# 运行前记录现场：ctrl / enable 会被本轮改动，结束时必须还原
ORIG_CTRL=""; ORIG_ENABLE=""; PROPS_TOUCHED=0
restore_props() {
    [ "$PROPS_TOUCHED" = 1 ] || return 0
    PROPS_TOUCHED=0
    [ -n "$ORIG_CTRL" ] && setprop "$CTRL_PROP" "$ORIG_CTRL" 2>/dev/null
    [ -n "$ORIG_ENABLE" ] && setprop "$ENABLE_PROP" "$ORIG_ENABLE" 2>/dev/null
}

cleanup() {
    restore_props
    if [ "${IN_RUN:-0}" = 1 ] && [ -f "$MODDIR/update_desc.sh" ]; then
        sh "$MODDIR/update_desc.sh" >/dev/null 2>&1
    fi
    [ "${LOCKED:-0}" = 1 ] || return 0
    LOCKED=0
    rm -rf "$LOCK" 2>/dev/null
}
trap 'cleanup' EXIT
trap 'exit 143' HUP INT TERM

# 统一收尾：先发 done（WebUI 读 NDJSON），最后落 state（轮询看到 running:false）
finish_run() {
    # $1 ok(false/true) $2 count $3 done $4 reason [$5 elapsed]
    okj=$1
    count_n=${2:-0}
    done_k=${3:-0}
    why=$4
    el=${5:-$(( $(now) - STARTED ))}
    [ "$okj" = true ] || okj=false
    emit "{\"ev\":\"done\",\"runId\":$RUNID,\"ok\":$okj,\"count\":$count_n,\"done\":$done_k,\"elapsed\":$el,\"reason\":\"$why\"}"
    write_state false done "$count_n" "$done_k" "$okj" "\"$why\""
}

# 心跳：没有新日志也刷新 updated；已判定的失败原因不要被心跳重置
heartbeat() {
    if [ "$ok" = 1 ]; then
        write_state true processing "$count" "$done_n" null null
    else
        write_state true processing "$count" "$done_n" false "\"$reason\""
    fi
}

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
        printf '%s' $(( $(eta_minutes "$n") * 60 + 120 ))
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
    # 按数据体积降序；体积统计较慢，缓存 6 小时
    CACHE="$APPS_CACHE"
    now=$(date +%s)
    if [ -f "$CACHE" ]; then
        born=$(stat -c %Y "$CACHE" 2>/dev/null || date -r "$CACHE" +%s 2>/dev/null || echo 0)
        [ $(( now - born )) -lt 21600 ] && { cat "$CACHE"; return 0; }
    fi
    tmp=/data/local/tmp/fbo_apps.$$
    : > "$tmp"
    for p in $(pm list packages -3 2>/dev/null | sed 's/^package://'); do
        kb=$(du -sk "/data/data/$p" 2>/dev/null | cut -f1)
        printf '%s %s\n' "${kb:-0}" "$p" >> "$tmp"
    done
    body=$(sort -rn "$tmp" 2>/dev/null | head -60 | while read -r kb pkg; do
        printf '{"pkg":"%s","mb":%s},' "$pkg" $(( ${kb:-0} / 1024 ))
    done | sed 's/,$//')
    rm -f "$tmp"
    out="{\"ev\":\"apps\",\"data\":[$body]}"
    # pm 偶发失败时不要用空列表覆盖缓存
    [ -n "$body" ] && printf '%s\n' "$out" > "$CACHE" 2>/dev/null
    printf '%s\n' "$out"
}

# 系统自己的按天累计：shared_prefs 里 key_fbo_result_number 是 {天零点毫秒,累计数}
cmd_stats() {
    if [ ! -f "$STATPREF" ]; then
        emit '{"ev":"stats","data":[]}'
        return 0
    fi
    body=$(sed -n '/<set name="key_fbo_result_number">/,/<\/set>/p' "$STATPREF" 2>/dev/null \
        | sed -n 's/.*<string>\([0-9]*\),\([0-9]*\)<\/string>.*/{"ts":\1,"count":\2},/p' \
        | tr -d '\n' | sed 's/,$//')
    emit "{\"ev\":\"stats\",\"data\":[$body]}"
}

cmd_state() { cat "$STATE" 2>/dev/null || printf '{"runId":0,"running":false}\n'; }

# ---------- run ----------
parse_apps() {
    # "a,b,c" -> 每行一个
    printf '%s' "$1" | tr ',' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$'
}

# 从 logcat 行提取 resultPkg 列表。
# 兼容 resultPkg[a, b] / resultPkg: [a, b] / resultPkg=a,b 三种写法；
# 没有这行就返回空，调用方跳过交叉校验。
result_pkgs_from() {
    inner=$(printf '%s' "$1" | sed -n 's/.*resultPkg[^[]*\[\([^]]*\)\].*/\1/p')
    [ -n "$inner" ] || inner=$(printf '%s' "$1" | sed -n 's/.*resultPkg[[:space:]]*[:=][[:space:]]*\(.*\)$/\1/p')
    printf '%s' "$inner" | tr ',' '\n' | tr -d "[]{}'\"" | sed 's/[[:space:]]//g; /^$/d'
}

cmd_run() {
    apps=""; timeout=""; RUNID=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --apps) apps=$2; shift 2 ;;
            --timeout) timeout=$2; shift 2 ;;
            --runid) RUNID=$2; shift 2 ;;
            *) shift ;;
        esac
    done
    [ "$RUNID" = 0 ] && RUNID=$(now)
    STARTED=$(now)
    RESULTS=""; done_n=0; REMOVED=0; ETA_MIN=0; OPENED=false

    if ! acquire_lock; then
        holder=$(cat "$LOCK/pid" 2>/dev/null)
        emit_error "已有一次整理在进行中（pid ${holder:-?}），本次未执行"
        emit "{\"ev\":\"done\",\"runId\":$RUNID,\"ok\":false,\"count\":0,\"done\":0,\"elapsed\":0,\"reason\":\"busy\"}"
        return 1
    fi
    IN_RUN=1
    ORIG_CTRL=$(prop "$CTRL_PROP")
    ORIG_ENABLE=$(prop "$ENABLE_PROP")
    PROPS_TOUCHED=1

    # 先落 running 状态：页面不用等 probe / 应用扫描就能认领本次 runId
    write_state true starting 0 0 null null

    printf '\n===== %s =====\n' "$(date '+%m-%d %H:%M:%S')" >> "$RUNLOG" 2>/dev/null
    emit "{\"ev\":\"log\",\"msg\":\"run start runid=$RUNID apps=${apps:-auto}\"}"
    cmd_probe

    if ! svc_listed; then
        emit_error "系统里没有 miui.fbo.service，这台设备不支持焕新存储"
        finish_run false 0 0 no-service 0
        return 1
    fi
    center=$(center_state)
    if [ "$center" != "ok" ]; then
        case "$center" in
            missing)   emit_error "手机管家已被卸载或未安装，焕新存储会直接中止（Placeholder，结果恒为 0）" ;;
            suspended) emit_error "手机管家处于挂起状态，焕新存储不可用" ;;
            disabled)  emit_error "手机管家被禁用，焕新存储不可用" ;;
            *)         emit_error "手机管家状态异常：$center" ;;
        esac
        finish_run false 0 0 center 0
        return 1
    fi
    if [ "$(svc_support)" != "1" ]; then
        emit_error "系统报告 ActiveFBO_isSupport=0，当前策略禁用了焕新存储"
        finish_run false 0 0 disabled 0
        return 1
    fi

    # 应用列表：自动选择只取 pkg 字段。用 tr + sed 代替 grep -o，兼容旧 toybox
    if [ -z "$apps" ]; then
        apps=$(cmd_apps | tr '{' '\n' | sed -n 's/.*"pkg":"\([^"]*\)".*/\1/p')
    else
        apps=$(parse_apps "$apps")
    fi
    count=$(printf '%s\n' "$apps" | grep -c .)
    if [ "$count" -eq 0 ]; then
        emit_error "应用列表为空"
        finish_run false 0 0 empty 0
        return 1
    fi

    join=$(printf '%s' "$apps" | tr '\n' ',' | sed 's/,$//')
    ETA_MIN=$(eta_minutes "$count")
    OPENED=$(eta_opened "$count")
    [ -n "$timeout" ] || timeout=$(eta_total "$count")
    write_state true triggering "$count" 0 null null
    emit "{\"ev\":\"trigger\",\"count\":$count,\"etaMinutes\":$ETA_MIN,\"openEnded\":$OPENED,\"apps\":\"$(esc "$join")\"}"

    [ "$(prop $ENABLE_PROP)" = "true" ] || setprop "$ENABLE_PROP" true 2>/dev/null
    restart_service || {
        finish_run false "$count" 0 service 0
        return 1
    }

    attempt_run() {
        ok=1; reason=""; complete=0; broadcast_seen=0; grace=0; result_pkgs=""; seen=0; dump_fail=0
    logcat -c 2>/dev/null
    am broadcast -a "$TRIGGER_ACTION" --es appList "$join" >/dev/null 2>&1
    emit_log "已发送触发广播"
    write_state true processing "$count" 0 null null

    deadline=$(( $(now) + timeout ))
    seen=0; ok=1; reason=""; complete=0; broadcast_seen=0; grace=0; result_pkgs=""
    while :; do
        out=$(logcat -d 2>/dev/null | grep -E "$PATTERN")
        n=$(printf '%s' "$out" | grep -c .)
        # logcat 环形缓冲回绕时重新计数，避免永远追不上 seen
        [ "$n" -lt "$seen" ] && seen=0
        if [ "$n" -gt "$seen" ]; then
            NEWF=/data/local/tmp/fbo_new.$$
            printf '%s\n' "$out" | tail -n +$((seen + 1)) > "$NEWF"
            while IFS= read -r line; do
                case "$line" in
                    # 这几个必须先判：占位符行同时包含 sendBroadcast，会被后面的分支抢走
                    *"PackageNamePlaceholder"*)
                        ok=0; reason=placeholder; complete=1; dump_fail=1
                        emit_error "系统回退成 PackageNamePlaceholder：本轮触发被吞"
                        continue
                        ;;
                    *"policy disables"*)
                        ok=0; reason=policy; complete=1
                        emit_error "系统策略拒绝执行焕新存储"
                        continue
                        ;;
                    *"appList is empty"*)
                        ok=0; reason=empty; complete=1
                        emit_error "应用列表被系统判为空"
                        continue
                        ;;
                    *"Receive data from native"*)
                        pkg=$(printf '%s' "$line" | sed -n 's/.*native:pkg:\([^:]*\):.*/\1/p')
                        before=$(printf '%s' "$line" | sed -n 's/.*F2FS:\([0-9]*\):.*/\1/p')
                        after=$(printf '%s' "$line" | sed -n 's/.*F2FS:[0-9]*:\([0-9]*\).*/\1/p')
                        [ -n "$before" ] || before=0
                        [ -n "$after" ] || after=0
                        if [ -n "$pkg" ]; then
                            done_n=$(( done_n + 1 ))
                            RESULTS="$RESULTS{\"pkg\":\"$pkg\",\"before\":$before,\"after\":$after},"
                            REMOVED=$(( REMOVED + before - after ))
                            heartbeat
                            emit "{\"ev\":\"app\",\"pkg\":\"$(esc "$pkg")\",\"before\":$before,\"after\":$after,\"t\":$(( $(now) - STARTED ))}"
                        fi
                        ;;
                    *"sendBroadcast and resultNumber"*)
                        # 结束回执。部分机型没有 All stop,exit，给 15 秒收尾窗口
                        broadcast_seen=1
                        [ "$grace" -eq 0 ] && grace=$(( $(now) + 15 ))
                        res=$(result_pkgs_from "$line")
                        if [ -n "$res" ]; then
                            result_pkgs="$result_pkgs
$res"
                        fi
                        ;;
                    *"All stop,exit"*)
                        complete=1
                        ;;
                    *"fbo event report data"*)
                        total=$(printf '%s' "$line" | sed -n 's/.*fragment_count:\([0-9]*\).*/\1/p')
                        [ -n "$total" ] || total=0
                        emit "{\"ev\":\"report\",\"total\":$total}"
                        ;;
                    *"SIGABRT"*|*"Fatal signal"*)
                        ok=0; reason=crash; dump_fail=1
                        emit_error "FboNativeService 崩溃（SIGABRT），本轮终止"
                        complete=1
                        ;;
                    *"died; reconnecting"*)
                        # 正常收尾也会打印这句（在 All stop,exit 之后），
                        # 只有既没结束、也没收到广播回执时才按崩溃处理
                        if [ "$complete" = 0 ] && [ "$broadcast_seen" = 0 ]; then
                            ok=0; reason=crash; dump_fail=1
                            emit_error "FboNativeService 提前退出，本轮终止"
                            complete=1
                        fi
                        ;;
                esac
            done < "$NEWF"
            rm -f "$NEWF"
            seen=$n
        fi
        # 心跳：没有新日志也刷新 updated，页面据此区分“还在跑”和“进程没了”
        heartbeat
        [ "$complete" = 1 ] && break
        [ "$broadcast_seen" = 1 ] && [ "$(now)" -ge "$grace" ] && break
        [ "$(now)" -ge "$deadline" ] && { ok=0; reason=timeout; emit_error "等待超时（${timeout}s）"; break; }
        sleep 2
    done
    }

    attempt_run
    # 上一次崩溃后系统可能还停在旧状态，会把下一轮触发吞成 Placeholder——重试一次
    if [ "$done_n" -eq 0 ] && [ "$reason" = placeholder ]; then
        emit_log "系统回退成占位符，重启服务后重试一次"
        restart_service && { sleep 2; attempt_run; }
    fi

    # 用 resultPkg 交叉校验：请求的每个包都必须出现在系统回执里。
    # 没有 resultPkg 行时 result_pkgs 为空，跳过校验（安全降级）。
    if [ "$ok" = 1 ] && [ -n "$result_pkgs" ]; then
        missing=""
        while IFS= read -r want; do
            [ -n "$want" ] || continue
            case "
$result_pkgs
" in
                *"
$want
"*) ;;
                *) missing="$missing $want" ;;
            esac
        done <<EOF
$apps
EOF
        if [ -n "$missing" ]; then
            ok=0
            # 一个都没处理 → 系统直接放弃了这次触发，不是「部分完成」
            if [ "$done_n" -eq 0 ]; then reason=aborted; else reason=partial; fi
            emit_error "系统未处理：$missing（回执：$(printf '%s' "$result_pkgs" | tr '\n' ' ')）"
        fi
    fi

    # 崩溃时把现场日志留在 run.log 里，便于事后定位
    [ "${dump_fail:-0}" = 1 ] && logcat -d -s FboNativeService:V MiuiFboService:V 2>/dev/null \
        | tail -15 >> "$RUNLOG"

    [ "$ok" = 1 ] && okj=true || okj=false
    elapsed=$(( $(now) - STARTED ))
    printf '{"ts":%s,"runId":%s,"ok":%s,"count":%s,"done":%s,"removed":%s,"elapsed":%s,"reason":%s,"apps":[%s]}\n' \
        "$(now)" "$RUNID" "$okj" "$count" "$done_n" "$REMOVED" "$elapsed" "\"$reason\"" "${RESULTS%,}" \
        >> "$HISTORY" 2>/dev/null
    tail -n 50 "$HISTORY" > "$HISTORY.tmp" 2>/dev/null && mv "$HISTORY.tmp" "$HISTORY"
    printf '%s 本次%s，处理 %s/%s，碎片 %s\n' "$(date '+%H:%M:%S')" \
        "$([ "$ok" = 1 ] && echo 完成 || echo "失败($reason)")" "$done_n" "$count" "$REMOVED" >> "$RUNLOG" 2>/dev/null
    tail -n 600 "$RUNLOG" > "$RUNLOG.tmp" 2>/dev/null && mv "$RUNLOG.tmp" "$RUNLOG"
    finish_run "$okj" "$count" "$done_n" "$reason" "$elapsed"
}

cmd_log() {
    tail -n "${1:-20}" "$HISTORY" 2>/dev/null || true
}

case "${1:-probe}" in
    probe) cmd_probe ;;
    apps) cmd_apps ;;
    stats) cmd_stats ;;
    state) cmd_state ;;
    run) shift; cmd_run "$@" ;;
    log) shift; cmd_log "$@" ;;
    *) emit_error "unknown command: $1"; exit 2 ;;
esac