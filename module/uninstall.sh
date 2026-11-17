#!/system/bin/sh
# 卸载时停止拉起的服务、清理运行时数据、临时文件

MODDIR=${0%/*}
STATE_DIR=/data/adb/fbo_plus

# 运行中若被强行中断，重置为关闭状态
[ "$(getprop persist.sys.fboservice.ctrl)" = "true" ] && \
    setprop persist.sys.fboservice.ctrl false 2>/dev/null

rm -rf "$STATE_DIR"
rm -f /data/local/tmp/fbo_webui.log
rm -f /data/local/tmp/fbo_new.* /data/local/tmp/fbo_apps.*

true
