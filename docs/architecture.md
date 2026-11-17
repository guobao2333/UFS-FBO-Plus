# Architecture

How the pieces fit together, what each one owns, and which file is authoritative for what.

> [!NOTE]
> The WebUI runs inside KernelSU's WebView over a `su://` document: there is no HTTP server and no
> module bundler. Classic external scripts load fine (verified on device), but `<script type="module">`
> is blocked by CORS — so `assets/app.js` is a classic script, not an ES module.

## Layers

| Layer | File | Owns |
| --- | --- | --- |
| View | `module/webroot/index.html` + `app.css` | Markup and styling only |
| Controller | `module/webroot/assets/app.js` | Probing, app selection, launching a run, polling state, rendering |
| Engine | `module/fbo.sh` | Everything privileged: service restart, broadcast, logcat parsing, state/history files |
| Pack | `build.sh` | Adds `META-INF`, writes `update.json`; leaves the WebUI untouched |
| Entry | `module/action.sh` | Refreshes the module description, then opens a WebUI host (or prints a status report) |
| Status | `module/update_desc.sh` | Prefixes `module.prop`'s description with the current state (`✅可用` / `❌手机管家缺失` / `⚠️上次失败`) |
| Teardown | `module/uninstall.sh` | Stops the service we started and removes `/data/adb/fbo_plus` plus temp files |

`index.html` loads `assets/app.js` with a classic `<script src="assets/app.js">`. Verified on device: the
WebView reads the file from disk on every load, so no cache-buster is needed. `build.sh` only packs
files — it does not process the WebUI at all.

## Data flow

```
button click
  └─ app.js  launchRun(runid, apps)
       └─ ksu.exec: setsid sh fbo.sh run --apps … --runid … >> run.log 2>&1 &
            └─ fbo.sh: lock → probe → restart fbo-installd → broadcast → parse logcat
                 ├─ writes state.json   (running → processing → done, with apps[])
                 ├─ append history.jsonl (one line per finished run)
                 └─ append run.log       (human-readable trace)
  └─ app.js  pollState()  every 2 s: cat state.json
       └─ running:false ⇒ finished; ok/reason decide the outcome
```

## The contract

`fbo.sh` subcommands, all emitting one JSON object per line:

| Command | Emits | Notes |
| --- | --- | --- |
| `probe` | `{"ev":"probe","data":{miui,props,eta}}` | Gate for the whole UI |
| `apps` | `{"ev":"apps","data":[{pkg,mb}]}` | Sorted by data-dir size, cached 6 h |
| `stats` | `{"ev":"stats","data":[{ts,count}]}` | Read from MIUI Security Center's `key_fbo_result_number` |
| `state` | raw `state.json` | Used when the page needs the current run |
| `run` | `log` / `trigger` / `app` / `report` / `error` / `done` | Only `done` matters to the page |

Files under `/data/adb/fbo_plus/`:

| File | Writer | Reader | Authoritative for |
| --- | --- | --- | --- |
| `state.json` | `fbo.sh` (atomic rename) | `app.js` | The current/last run — **single source of truth** |
| `history.jsonl` | `fbo.sh` | `app.js` (fallback) | Completed runs, 50 entries |
| `run.log` | `fbo.sh` + stdout redirect | `app.js` (diagnostics) | Human-readable trace |
| `apps.json` | `fbo.sh` | `fbo.sh` | Cached app sizes, 6 h TTL |
| `run.lock/` | `fbo.sh` | `fbo.sh` | One run at a time; stale pid is taken over |

The daily chart does **not** come from `history.jsonl`. It comes from MIUI Security Center's own
`remote_provider_preferences.xml` (`key_fbo_result_number`, format `<dayStartMillis>,<count>`), which
survives reboots and also counts the nightly automatic passes. `history.jsonl` is only a fallback for
when that file is gone (e.g. the manager app was uninstalled).

## Invariants

1. **One run at a time.** `run.lock/` holds a pid; a lock whose pid is gone is taken over.
2. **`state.json` is the only completion signal.** The page never decides "done" from logcat text.
3. **The system's counters win.** Charts render `stats`; per-run numbers only appear while a run is
   in flight or in the log.
4. **`ksu.exec` returns stdout as a string.** `normalize()` also accepts `{errno,stdout,stderr}` for
   other managers.

## Known fragile points

| Point | Why | Mitigation |
| --- | --- | --- |
| Completion detection | Some builds emit only `sendBroadcast and resultNumber`, others also `All stop,exit` | `All stop,exit` finishes immediately, otherwise a 15 s grace after the broadcast, then the hard timeout |
| `resultPkg` cross-check | Format varies (`[a, b]`, `: [a, b]`, `=a,b`) and may be absent | Three-way parser; absent list skips the check instead of failing |
| WebView cache | `su://` pages can be restored from a snapshot without re-running the script | State lives in files, so the page re-reads everything on load |
| `fbo-installd` lifecycle | `disabled` in init and exits after every batch | `persist.sys.fboservice.ctrl` toggled before each run |
| MIUI Security Center | Must stay installed; uninstalling yields `PackageNamePlaceholder` and 0 | `probe` refuses to run and explains why |
