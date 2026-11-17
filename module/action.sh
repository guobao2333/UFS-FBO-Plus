#!/system/bin/sh
# 打开模块 WebUI；没有 WebUI 容器时打印状态报告（KernelSU 的「执行」按钮）

MODDIR=${0%/*}
MODID=$(sed -n 's/^id=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1)
[ -n "$MODID" ] || MODID=fbo_plus

# 刷新模块描述里的状态（参考 hma_oss_zygisk）
[ -f "$MODDIR/update_desc.sh" ] && sh "$MODDIR/update_desc.sh" >/dev/null 2>&1

open_webui() {
    if pm path io.github.a13e300.ksuwebui >/dev/null 2>&1; then
        am start -n "io.github.a13e300.ksuwebui/.WebUIActivity" -e id "$MODID" >/dev/null 2>&1
        echo "- 已在 KSUWebUIStandalone 中打开"
        return 0
    fi
    if pm path com.dergoogler.mmrl >/dev/null 2>&1; then
        am start -n "com.dergoogler.mmrl/.ui.activity.webui.WebUIActivity" -e MOD_ID "$MODID" >/dev/null 2>&1
        echo "- 已在 MMRL 中打开"
        return 0
    fi
    if pm path com.dergoogler.mmrl.webuix >/dev/null 2>&1; then
        am start -n "com.dergoogler.mmrl.webuix/.ui.activity.webui.WebUIActivity" -e MOD_ID "$MODID" >/dev/null 2>&1
        echo "- 已在 WebUI X 中打开"
        return 0
    fi
    return 1
}

report() {
    echo "FBO+ 状态"
    echo "----------"
    pm path com.miui.securitycenter >/dev/null 2>&1 \
        && echo "手机管家：已安装" || echo "手机管家：缺失（焕新存储不可用）"
    service list 2>/dev/null | grep -q miui.fbo.service \
        && echo "系统服务：miui.fbo.service 正常" || echo "系统服务：缺失"
    echo "fbo-installd：$(getprop init.svc.fbo-installd)"
    echo "开关：ctrl=$(getprop persist.sys.fboservice.ctrl) enable=$(getprop persist.sys.stability.miui_fbo_enable)"
    if [ -f /data/adb/fbo_plus/history.jsonl ]; then
        echo
        echo "最近记录：$(tail -n 1 /data/adb/fbo_plus/history.jsonl)"
    fi
    echo
    echo "整理请在模块卡片点 <> 打开 WebUI 选择应用。"
}

if open_webui; then
    exit 0
fi

echo "! 没有独立的 WebUI 容器（KSUWebUIStandalone / MMRL / WebUI X）"
echo
report
