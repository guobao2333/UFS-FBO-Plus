<h1 align="center"><b>FBO+</b></h1>

<p align="center">
  澎湃OS「焕新存储」的手动触发与结果可视化
</p>

<p align="center">
<a href="https://github.com/guobao2333/UFS-FBO-Plus"><img alt="Github" src="https://img.shields.io/badge/Github-Repo-blue?labelColor=black&logo=Github&logoColor=white"></a>
<a href="https://github.com/guobao2333/UFS-FBO-Plus/blob/main/LICENSE"><img alt="License" src="https://img.shields.io/github/license/guobao2333/UFS-FBO-Plus?logo=apache&label=License&labelColor=black&color=blue"></a>
</p>

<p align="center"><a href="README.md">English</a></p>

FBO（File-Based Optimization）是 JEDEC 的 UFS 扩展，澎湃OS里它叫「焕新存储」。本模块让你不用翻设置菜单，直接在 KernelSU / Magisk / MMRL 的 WebUI 里触发一次整理，并把每个应用的整理效果画成柱状图。

## 特性

- **一键触发**：走系统自己的链路（`MiuiFboService` → `FboNativeService` → f2fs GC），模块不实现整理算法
- **结果可见**：逐应用对比整理前后的碎片数，横向柱状图 + 总量统计
- **自愈**：每轮结束系统会让 `fbo-installd` 退出，模块在触发前自动重启它
- **不空跑**：手机管家缺失、挂起或被禁用时直接拦下并说明原因，而不是花几分钟换回一个 0
- **留了位置**：Cron 定时任务、条件表达式

## 安装

1. 从 [Releases](https://github.com/guobao2333/UFS-FBO-Plus/releases) 下载 zip
2. 在 KernelSU / Magisk / ... 中刷入并重启
3. 点模块的「操作」按钮打开 WebUI

> [!WARNING]
> 手机管家（`com.miui.securitycenter`）必须安装，否则系统将无法启动FBO！

## 使用

1. 勾选要整理的应用（默认按数据体积选最大的 6 个）
2. 点「立即焕新」
3. 等进度走完，柱状图显示每个应用整理前后的碎片数

> [!NOTE]
> 耗时是保守估算，只会提前完成，不会卡在临界点。模型见 [docs/eta.md](docs/eta.md)。

## 构建
> [!important]
> 需要安装 `zip`

```sh
sh build.sh
```
输出位于`build/FBOPlus.zip`

`.github/workflows/release.yml` 会在 `version` 还没有同名 tag 时自动发版。

## 兼容性

- 只支持带 `miui.fbo.service` 的澎湃OS，其他设备在探测阶段就会给出原因
- 已在 Redmi M332BF / HyperOS 3.0.305（Android 16）上实测

## 文档

- [技术细节](docs/technical.md)：调用链、组件、结果解析、已知问题
- [耗时预估](docs/eta.md)：预估表、为什么不做拟合、内部超时

## 路线图

- [ ] Cron 定时任务
- [ ] 条件表达式

## 开源协议
[Apache-2.0](LICENSE)，Copyright (c) 2026 shiguobaona。

## 引用致谢
**项目地基：**
- [KOWX712/ksu-webui-demo](https://github.com/KOWX712/ksu-webui-demo)（MIT）

**借鉴：**
- [Raffxzr/modulize](https://github.com/Raffxzr/modulize)
- [barsikus007/ksu-webui-module-template](https://github.com/barsikus007/ksu-webui-module-template)
