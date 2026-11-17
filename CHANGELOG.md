# Changelog
## v0.1.1

***大量重构及 bug 修复***

- 新增 `uninstall.sh`：卸载时停服务、清理 `/data/adb/fbo_plus` 与临时文件
- 新增 `update_desc.sh`：把状态写进模块描述，卡片上一眼可见

- 崩溃后系统会把下一轮触发吞成 `PackageNamePlaceholder`：识别后自动重启服务并重试一次
- 占位符判定提前，避免被 `sendBroadcast` 分支抢走导致误判成 partial/aborted

- 运行状态收敛到 `state.json` 单一事实源，页面不再从 NDJSON 猜完成状态
- 事件输出改写入 `run.log`，去掉 `run.ndjson`
- 新增 `docs/architecture.md`：分层、数据流、文件归属与已知脆弱点

- WebUI 脚本拆到 `webroot/assets/app.js`；后台启动改用 `setsid` 并断开 stdio，避免 `ksu.exec` 等到整轮结束
- 状态文件加 runId 与心跳；页面重载后能接着跟踪同一轮，进程被杀也能在界面显示中断
- 日志解析兼容 `resultPkg[...]`、`resultPkg: [...]`、`resultPkg=...`，缺失时跳过交叉校验
- 结束判定以 `All stop,exit` 为准；只有广播回执时等 15 秒收尾，都没有则回退到超时
- 去掉旧版 toybox 可能缺失的 `grep -o` / `grep -qx`；应用缓存移出模块目录
- 修复 ETA 常量在重构中丢失导致 `set -u` 直接退出；同一时间只允许一轮整理；恢复 action.sh 打开 WebUI

## v0.1.0

* ***首发开源版本！***

- 每次触发前自动重置系统属性（每轮结束后会自行退出）
- 应用多选（按数据体积排序，默认选最大的 6 个）、预计耗时、横向柱状图对比前后
- 运行中显示「已用 / 预计」
- 探测手机管家状态（缺失/挂起/禁用时直接拦截并说明原因）
- 内置回退，避免把失效结果当成 0 碎片
- 移除不适用的 UFS sysfs 后端
