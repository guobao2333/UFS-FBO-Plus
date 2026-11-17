#!/system/bin/sh
# 把当前状态写进模块描述，管理器里一眼能看到（参考 hma_oss_zygisk/update_desc.sh）
# 原始描述保存在 module.prop.orig，重复执行只会替换前缀

MODDIR=${0%/*}
BAK="$MODDIR/module.prop.orig"

[ -f "$BAK" ] || cp "$MODDIR/module.prop" "$BAK" 2>/dev/null

orig=$(sed -n 's/^description=//p' "$BAK" 2>/dev/null | head -n1)
[ -n "$orig" ] || orig="手动触发澎湃OS焕新存储(FBO)"
# 只保留原始描述，去掉之前写过前缀的可能
orig=$(printf '%s' "$orig" | sed 's/^[^ ]* \[[^]]*\] //')

if ! pm path com.miui.securitycenter >/dev/null 2>&1; then
    status="❌手机管家缺失"
elif ! service list 2>/dev/null | grep -q miui.fbo.service; then
    status="❌无FBO服务"
else
    last=$(tail -n1 /data/adb/fbo_plus/history.jsonl 2>/dev/null)
    case "$last" in
        "")            status="✅可用" ;;
        *'"ok":true'*) status="✅可用" ;;
        *)             status="⚠️上次失败" ;;
    esac
fi

safe=$(printf '%s' "$orig" | sed 's/[&|]/\\&/g')
sed -i "s|^description=.*|description=$status $safe|" "$MODDIR/module.prop" 2>/dev/null

printf '%s %s\n' "$status" "$orig"
