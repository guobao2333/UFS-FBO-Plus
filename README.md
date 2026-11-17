<h1 align="center"><b>FBO+</b></h1>

<p align="center">
  更强大的「焕新存储」
</p>

<p align="center">
<a href="https://github.com/guobao2333/UFS-FBO-Plus"><img alt="Github" src="https://img.shields.io/badge/Github-Repo-blue?labelColor=black&logo=Github&logoColor=white"></a>
<a href="https://github.com/guobao2333/UFS-FBO-Plus/blob/main/LICENSE"><img alt="License" src="https://img.shields.io/github/license/guobao2333/UFS-FBO-Plus?logo=apache&label=License&labelColor=black&color=blue"></a>
</p>

<p align="center"><a href="README.md">English</a></p>

FBO（File-Based Optimization）是 JEDEC 的 UFS 扩展，澎湃OS里它叫「焕新存储」。本模块增强了该功能的自定义能力，使其可以随时随地、按您心意、立即运行！

***目前本模块处于测试预览阶段，正在稳定基础功能，可能会对您的设备产生一定影响，请评估风险接受程度后再决定使用本模块与否！***

## 特性

- [x] **一键触发**：走系统自己的链路（`MiuiFboService` → `FboNativeService` → f2fs GC），模块不介入整理算法
- [x] **选择应用**：不必整理整个设备，您可以按需选择需要整理的应用，以便减少等待时间
- [x] **结果可见**：逐应用对比整理前后的碎片数，柱状图 + 总量统计
- [x] **前置检查**：手机管家缺失、挂起或被禁用时直接拦下并说明原因，而不是花几分钟换回一个 0

## 计划

- [ ] 界面风格优化
- [ ] Cron 定时任务
- [ ] 条件表达式

## 安装

1. 从 [Releases](https://github.com/guobao2333/UFS-FBO-Plus/releases) 下载 zip
2. 在 KernelSU / Magisk / ... 中刷入并重启
3. 点模块的「操作」按钮打开 WebUI

> [!WARNING]
> HyperOS请确保手机管家（`com.miui.securitycenter`）已安装，否则系统将无法启动FBO！

## 使用

1. 勾选要整理的应用（默认勾选 3 个）
2. 点「立即焕新」
3. 等进度走完，柱状图显示每个应用整理前后的碎片数

## 构建

```sh
sh build.sh
```
输出位于`build/`
> 请勿将其他重要文件放入该目录以免丢失

WebUI 就是普通的 HTML/CSS/JS，`build.sh` 原样打包。`su://` 下经典外部脚本可以正常加载
（只有 `type="module"` 会被 CORS 拦），WebView 每次都会重新读取文件。

`.github/workflows/release.yml` 会在 `version` 还没有同名 tag 时自动发版。

## 兼容性

- 目前只支持带 `miui.fbo.service` 的澎湃OS，其他设备在探测阶段会给出原因
- 已在 HyperOS 3 上测试

## 技术文档
> [!important]
> 当前文档已过时，请查看`docs/TODO`中包含的最新完整设计文档及PoC验证程序。

- [架构说明](docs/architecture.md)：分层、数据流、文件归属、不变量
- [技术细节](docs/technical.md)：调用链、组件、结果解析、已知问题
- [耗时预估](docs/eta.md)：预估表、没做拟合、内部超时

## 开源协议
[Apache-2.0](LICENSE)，Copyright (c) 2026 shiguobaona

## 引用致谢
**项目地基：**
- [KOWX712/ksu-webui-demo](https://github.com/KOWX712/ksu-webui-demo)（MIT）

**借鉴：**
- [Raffxzr/modulize](https://github.com/Raffxzr/modulize)
- [barsikus007/ksu-webui-module-template](https://github.com/barsikus007/ksu-webui-module-template)
