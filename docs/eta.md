# Time estimate

> [!NOTE]
> The estimate is intentionally pessimistic: a run should finish early, never late. A real single-app
> pass takes 40–65 seconds, while the UI promises minutes.

## The table

| Apps | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9+ |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Estimate | 2 min | 5 | 8 | 12 | 15 | 20 | 25 | 30 | “may take 30 minutes or more” |

Only whole minutes are shown. Past eight apps the UI stops quoting numbers: a selection large enough to
reach 128 GB / 256 GB / 512 GB of data makes any figure a guess, and “or more” cannot be wrong at the
edge.

## Why not a formula

The numbers are hand-picked, not fitted. A logarithmic fit anchored at 1 → 2 min and 8 → 30 min yields
11 minutes for two apps — far off the intended 5. Hardware generation and wear differ too much for a
fitted curve to mean anything across devices, so the baseline is only labelled as a like-new
Snapdragon 8 Elite reference.

## Internally nothing is capped

The UI caps at 30 minutes, the hard timeout does not:

```
timeout = apps <= 8 ? table[apps] : 30 + (apps - 8) * 3   // minutes, plus 2 minutes of slack
```

A 50-app run therefore gets ~3 hours of headroom even though the user is only told “30 minutes or more”.

## Where it lives

- `module/fbo.sh` — `ETA_MINUTES`, `ETA_CAP`, `ETA_TIMEOUT_STEP`; `eta_minutes()` / `eta_total()`;
  the parameters are emitted by `probe` so there is a single source of truth.
- `module/webroot/js/app.js` — `estimateMinutes()`, `isOpenEnded()`, `timeoutFor()`; the live counter
  shows `elapsed · estimate` while a run is in progress.
