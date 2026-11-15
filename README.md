<h1 align="center"><b>FBO+</b></h1>

<p align="center">
  Manual trigger and result visualisation for HyperOS storage refresh (FBO)
</p>

<p align="center">
<a href="https://github.com/guobao2333/UFS-FBO-Plus"><img alt="Github" src="https://img.shields.io/badge/Github-Repo-blue?labelColor=black&logo=Github&logoColor=white"></a>
<a href="https://github.com/guobao2333/UFS-FBO-Plus/blob/main/LICENSE"><img alt="License" src="https://img.shields.io/github/license/guobao2333/UFS-FBO-Plus?logo=apache&label=License&labelColor=black&color=blue"></a>
</p>

<p align="center"><a href="README_ZH.md">简体中文</a></p>

FBO (File-Based Optimization) is a JEDEC UFS extension that HyperOS implements under the name “Storage refresh” (焕新存储). This module triggers it from a KernelSU / Magisk / MMRL WebUI and charts how each app was defragmented — no menu hunting, no waiting for the nightly window.

## Features

- **One tap** — drives the system's own chain (`MiuiFboService` → `FboNativeService` → f2fs GC); no
  defragmentation algorithm lives in this module
- **Visible result** — horizontal bars comparing fragmentation before and after, per app, plus totals
- **Self-healing** — the system lets `fbo-installd` exit after each pass; the module restarts it
  before every trigger
- **No wasted runs** — if MIUI Security Center is missing, suspended or disabled the run is refused
  with a reason instead of burning minutes on a meaningless zero
- **Room to grow** — placeholders for cron jobs and condition expressions

## Install

1. Grab the zip from [Releases](https://github.com/guobao2333/UFS-FBO-Plus/releases)
2. Flash it in KernelSU / Magisk / MMRL and reboot
3. Tap "Action" on the module to open the WebUI

> [!WARNING]
> MIUI Security Center (`com.miui.securitycenter`) must stay installed.  
> After uninstalling, this function will become unavailable!

## Usage

1. Pick the apps to refresh (the six largest by data size are preselected)
2. Tap "Refresh now"
3. Wait for the progress to finish; the chart shows fragmentation before and after per app

> [!NOTE]
> Estimates are pessimistic on purpose: a run finishes early, never late.
> See [docs/eta.md](docs/eta.md).

## Build
```sh
sh build.sh
```
Output: `build/FBOPlus.zip`

`.github/workflows/release.yml` publishes automatically when `version` has no matching tag yet.

## Compatibility

- HyperOS builds that expose `miui.fbo.service`; anything else is reported at probe time
- Verified on a Redmi M332BF running HyperOS 3.0.305 (Android 16)

## Documentation

- [Technical details](docs/technical.md) — call chain, components, result parsing, known issues
- [Time estimate](docs/eta.md) — the table, why it is not fitted, the internal timeout

## Roadmap

- [ ] Cron jobs
- [ ] Condition expressions

## License

[Apache-2.0](LICENSE), Copyright (c) 2026 shiguobaona.

## Credits

- Built on [KOWX712/ksu-webui-demo](https://github.com/KOWX712/ksu-webui-demo) (MIT)
- Inspired by [Raffxzr/modulize](https://github.com/Raffxzr/modulize) and
  [barsikus007/ksu-webui-module-template](https://github.com/barsikus007/ksu-webui-module-template)
