# Low-end machine simulator (Windows)

Runs the built app (`build\src\Mahfin Desktop.exe`) as if it were on a cheap
laptop, and records what it costs once a second.

```powershell
.\run.ps1 -Machine lowend -Duration 60
```

| `-Machine` | Pretends to be | How |
|---|---|---|
| `host` | this machine | no limits — the baseline |
| `budget` | Core i3, 2C/4T, 8 GB, working iGPU | 4 logical CPUs, each shared with 1 busy thread |
| `lowend` | Celeron N4020, 2C/2T, 4 GB, working iGPU | 2 CPUs, each shared with 2 busy threads |
| `nodriver` | `lowend` with no vendor GPU driver | as above, plus `QT_OPENGL=software` |
| `tieronly` | `lowend`'s settings at full speed | separates what the tier does from the slowness |
| `hardcap` | `lowend` under a hard CPU-rate cap | comparison only — see below |

The app and every Chromium process it starts run inside a Windows Job Object
pinned to those CPUs, and the harness runs busy threads pinned to the same
ones. The scheduler shares each core between them in ordinary short slices, so
the app sees a slower core. `MAHFIN_SIMULATE_MACHINE` (see
`GraphicsCapability.cpp`) makes the app's own hardware probe see the pretend
RAM, core count and adapter, so it picks the same graphics tier it would on the
real thing. Treat the numbers as comparisons between builds, not absolutes.

**Do not judge playback with `hardcap`.** A hard CPU-rate cap does not make a
CPU slower: it runs the process at full speed, then freezes all of it until the
next quota period. Under that, video frames reach the screen late and out of
order — stale window contents (the previous page, the opening mark) over the
film while the sound plays normally. mpv reports no dropped frames throughout,
and the same build plays correctly under `lowend`. It was mistaken for a Mahfin
bug once; it is an artefact of the cap.

`out\<machine>.csv` has, per second: CPU used (in host cores and as a share of
the budget), process count, private and working-set memory, peak commit, how
long the window took to answer a hung-window ping (what Windows uses to decide
"Not Responding"), and page faults.

The app is started with `--remote-debugging-port=9222`, and `cdp.mjs` reads
the page through it while it runs:

```sh
node cdp.mjs perf 10          # style/layout/script work per second while idle
node cdp.mjs scroll           # wheel-scroll; frame rate and worst frame gap
node cdp.mjs eval "document.getAnimations().length"
node cdp.mjs shot out/page.png
```

Only one instance can run at a time — a second launch hands over to the first
and exits — so `run.ps1` waits for any earlier one to close. A run killed
inside its first 20 seconds leaves the start-up guard behind; pass
`-ExtraArgs '--reset-graphics'` on the next one.

For frame-by-frame timing, set `QT_LOGGING_RULES=qt.scenegraph.time.renderloop=true`
before `run.ps1`; every frame Qt draws is then written to the profile's log.
