# cs2mac

Run Counter-Strike 2 (the Windows build) on Apple Silicon Macs through a small, custom
translation shim: Wine 11 for the Win32 layer, Metal for the GPU, and a launcher that picks and
tunes the graphics backend, benchmarks it, and precompiles shaders so the first real round
doesn't stutter.

This fork extends the original [PierreAndreis/cs2mac](https://github.com/PierreAndreis/cs2mac)
with M4 Air optimizations: MetalFX spatial upscaling at 1080p+, mimalloc, a shader warmup
command, an experimental hybrid arm64 Wine build, per-session fps logging, and a handful of
launch-flow fixes (the webhelper two-pass setup, the Steam `-silent` hide, and bash wrapper
regressions).

Educational project. Valve does not ship CS2 for macOS; this is a study of how far modern
translation layers (MoltenVK, DXVK, Apple's D3DMetal) get on an M-series GPU, what breaks, and
what tuning matters. Nothing proprietary is redistributed: the scripts download Wine, MoltenVK,
DXVK and Steam from upstream, and D3DMetal comes from Apple's Game Porting Toolkit which you
install yourself.

## What works

Three backends, all playable, all benchmarked on the same map (details in `docs/RESULTS.md`):

| backend  | path                                              | 1280x720 median fps | 5th percentile |
|----------|---------------------------------------------------|--------------------:|---------------:|
| d3dmetal | D3D11 -> Apple D3DMetal -> Metal (custom shim)    | 113 | 82 |
| dxvk     | D3D11 -> DXVK 1.10 -> Vulkan -> MoltenVK -> Metal | 108 | 79 |
| vulkan   | CS2 `-vulkan` -> MoltenVK -> Metal                | 76 to 91 | 27 to 46 |

Apple M2 Max, macOS 26, everything under Rosetta 2. `d3dmetal` is the default: highest median and,
what you actually feel, the best worst-case frame times.

### M4 Air baseline (this fork)

Apple M4 base MacBook Air, 10 GPU cores, 16 GB unified memory, macOS 26, Dust2, `d3dmetal`
backend with MetalFX enabled (default at 1920 pixels wide and up):

| resolution | median fps | notes |
|------------|-----------:|-------|
| 1920x1080  | ~120 stable | beats M2 Max at same resolution (109.8); MetalFX spatial upscale is doing real work on the smaller GPU |

Stutters on new map regions and crowded fights are shader-compile stalls on the cold D3DMetal
cache; `./cs2mac warmup <map>` precompiles the pipelines and flattens them. See
`docs/SESSION-2026-11-25.md` and `docs/TUNING.md` "M4 Air experiments" section for what each
knob does and how to measure.

The custom part is getting Apple's D3DMetal (built for Apple's Wine 7/9 fork) to run inside stock
Wine 11: an import trampoline DLL, a two-file patch to Wine's ntdll (single thread-state base),
and a new `macdrv_functions` export in Wine's Mac display driver plus a one-line fix for the
black window D3DMetal otherwise gets. `docs/ARCHITECTURE.md` walks through it.

## Requirements

- Apple Silicon Mac (tested: M2 Max 38-core GPU, M4 base 10-core GPU), macOS 26 (Tahoe) or newer
- ~45 GB free disk (CS2 is ~35 GB, the Wine prefix and toolchain ~5 GB)
- Xcode command line tools (`xcode-select --install`), Rosetta 2 (`softwareupdate --install-rosetta --agree-to-license`)
- Homebrew
- A Steam account that owns CS2 (it is free to play)
- For the `d3dmetal` backend: `brew install --cask gcenx/wine/game-porting-toolkit` (needs Apple's
  Game Porting Toolkit download from developer.apple.com, free Apple ID)
- For fps logging via `./cs2mac play-logged` and `./cs2mac bench`: Screen Recording permission for
  your terminal. System Settings -> Privacy & Security -> Screen Recording -> add Terminal/iTerm,
  then fully quit and reopen the terminal. Without it the OCR screenshot path returns nothing.

## Quick start

```sh
git clone https://github.com/muzimran11/cs2mac && cd cs2mac
./cs2mac setup                      # downloads Wine, MoltenVK, DXVK, Steam; builds the patched bits; creates the prefix
./cs2mac steam                      # first launch: log in, let Steam finish updating itself, then quit it
./scripts/setup.sh webhelper        # swaps in the CEF webhelper wrapper now that Steam downloaded the real one
./cs2mac steam                      # install Counter-Strike 2 from the library
./cs2mac warmup de_dust2            # precompile every pipeline the map needs (~90 s, once per map)
./cs2mac play                       # launches CS2 on the d3dmetal backend
```

The extra `setup.sh webhelper` step is only needed on a fresh prefix: Steam ships
`steamwebhelper.exe` on first login, and the wrapper that fixes black Steam windows can only be
installed once that file exists. After that it is a no-op and `./cs2mac steam` keeps the wrapper
in place across Steam auto-updates.

### Warm every Premier map at once

```sh
for map in de_ancient de_anubis de_dust2 de_inferno de_mirage de_nuke de_overpass de_train; do
    ./cs2mac warmup "$map"
done
```

~12 minutes on a cold cache, near-instant on reruns (each map's completion is recorded as a mark
file under `~/Library/Application Support/cs2mac/warmup/`).

## Subcommands

```
./cs2mac setup                         fetch and build everything
./cs2mac steam                         start Steam inside the prefix
./cs2mac play [backend] [WxH]          launch CS2 via Steam (VAC enabled); default d3dmetal, native res
./cs2mac play-logged [backend] [WxH]   same as play, plus per-session fps.csv + summary.txt
./cs2mac warmup [map] [backend] [WxH]  precompile pipelines for a map (idempotent)
./cs2mac bench [backend|all] [secs] [WxH]   benchmark on the de_dust2 workshop map
./cs2mac backend [name]                show or switch the D3D11 backend
./cs2mac status                        what is installed, running and selected
./cs2mac stop                          kill CS2, Steam and the wineserver
```

See `docs/USAGE.md` for every subcommand's arguments, `docs/TUNING.md` for the knobs and what
they did.

## Tunable environment variables

Set these before `./cs2mac play` / `./cs2mac play-logged` to change behavior:

| variable               | default | effect |
|------------------------|---------|--------|
| `CS2MAC_METALFX`       | auto    | `1` forces MetalFX on at any resolution; `0` disables it; auto enables when width >= 1920 |
| `CS2MAC_ASYNC_COMMIT`  | 0       | `1` sets `D3DM_ENABLE_ASYNC_COMMIT=1` |
| `CS2MAC_MULTITHREADED` | 0       | `1` sets `D3DM_MULTITHREADED_INTERFACE_ENABLE=1` |
| `CS2MAC_MIMALLOC`      | 0       | `1` injects mimalloc into the Wine host via `DYLD_INSERT_LIBRARIES` (install with `./cs2mac setup deps`) |
| `CS2MAC_NICE`          | 0       | `1` wraps launch in `nice -n -5`. See *Work in progress* below: P-core pinning is not functional yet. |
| `CS2MAC_WINE_ARM64`    | 0       | `1` uses the experimental hybrid arm64 Wine built by `./cs2mac setup wine_arm64` (Unix side native arm64, PE side stays x86_64) |
| `CS2MAC_DIRECT`        | 0       | `1` launches `cs2.exe` directly instead of through Steam. Keeps Wine stderr visible (crash debugging). Disables VAC. |
| `CS2MAC_FORCE_WARMUP`  | 0       | `1` re-runs warmup even if the map's mark file exists |
| `WINEDEBUG`            | `-all`  | e.g. `+seh,+dbghelp` to print Wine exception stacks (pair with `CS2MAC_DIRECT=1`) |

## Logging fps per session

```sh
./cs2mac play-logged d3dmetal 1920x1080
```

Writes to `build/sessions/d3dmetal-1920x1080-<timestamp>/`:
- `fps.csv` one row every 5 seconds (`t, now, f60, f240, f1000, min_ms, max_ms`)
- `summary.txt` median, mean, p5, p1, min, max, worst frame over the session
- `launch.log` Steam launch output

Quick comparisons across sessions:

```sh
for d in build/sessions/*/; do echo "=== $d"; cat "$d/summary.txt" 2>/dev/null; done
```

VAC-secure matchmaking works because the launch still goes through `steam.exe -applaunch 730`.
The OCR sampler needs Screen Recording permission for the terminal (see Requirements).

## Work in progress

**P-core pinning is not functional yet.** The intent was to bias Wine's hot threads onto the M4
Air's 4 P-cores (vs its 6 E-cores) under contention. First attempt used `taskpolicy -c
user-interactive`, which macOS rejects (only `utility` and `background` are valid `-c` clamps,
and both DEMOTE). `CS2MAC_NICE=1` wrapping in `nice -n -5` is in as a placeholder but Darwin
mostly ignores `nice` for scheduling decisions. There is no supported CLI knob on macOS that
raises QoS above the inherited default; the right fix likely needs the game threads themselves
to call `pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)`, which means either a
dylib injected via `DYLD_INSERT_LIBRARIES` or a small patch in Wine's thread start hooks.
Contributions welcome.

## Experimental: hybrid arm64 Wine

```sh
./cs2mac setup wine_arm64           # ~20 minutes, may need patch iteration
CS2MAC_WINE_ARM64=1 ./cs2mac play
```

Builds a second Wine configure at `vendor/wine-build-arm64/` with
`--enable-archs=aarch64,x86_64,i386`. The PE side (CS2.exe, D3DMetal) stays x86_64 under Rosetta;
what becomes native arm64 is the Wine loader, `ntdll.so`, `winemac.drv.so`, and `wineserver`.
The expected win is on syscall-heavy paths and wineserver round trips. Build failures print the
log to open; the three local patches were written against the x86_64 tree and may need light
adjustment for the aarch64 code paths.

## Layout

```
cs2mac                      launcher (setup | steam | play | play-logged | warmup | bench | backend | status | stop)
scripts/
  setup.sh                  idempotent setup (deps wine dxvk moltenvk ntdll winemac gptk gamemode tools prefix steam webhelper steamcfg wine_arm64)
  backend.sh                switch D3D11 implementation in the prefix
  env.sh                    paths and tunables; sourced by every other script
  run-cs2.sh                low-level CS2 launcher (reads CS2MAC_* vars)
  bench.sh                  OCR-based benchmark on the de_dust2 workshop map
  play-logged.sh            like play, plus fps.csv + summary.txt
  warmup.sh                 precompile every D3DMetal pipeline for a map
  warmup/warmup.cfg         in-game script the warmup drives
  shoot-test.sh             combat stress with the overlay
  winshot / fpsread         Swift helpers: window screenshot + red-overlay OCR
shim/                       gptk.c + gptk.def (trampoline DLL), patch_imports.py, d3d11probe.c
patches/                    wine-macos-single-gsbase.patch, wine-macos-gptk-d3dmetal.patch,
                            moltenvk-null-descriptor-sets.patch, wine-fast-udp-sockets.patch
tools/webhelper/            steamwebhelper.c wrapper source and its compiled .exe
docs/                       ARCHITECTURE.md, USAGE.md, TUNING.md, RESULTS.md, SESSION-2026-11-25.md
vendor/ downloads/ build/   created by setup, gitignored
```

## Changes in this fork (branch `WebhelperFIX`)

Full detail in `docs/SESSION-2026-11-25.md`:

- **Webhelper two-pass setup** so a fresh prefix doesn't fail on the first `./cs2mac steam`
- **MetalFX default at 1080p+** via `D3DM_ENABLE_METALFX`
- **mimalloc opt-in** via `CS2MAC_MIMALLOC=1`
- **`./cs2mac warmup [map]`** precompiles every pipeline the map needs, idempotent
- **`./cs2mac play-logged`** records fps every 5 s per session
- **Hybrid arm64 Wine scaffold** at `./cs2mac setup wine_arm64`
- **Bug fixes**: broken `taskpolicy -c user-interactive` dropped; empty bash array under `set -u`
  fixed; Steam `-silent` removed so the main window shows on macOS

## Legal

Wine is LGPL, MoltenVK and DXVK are Apache 2 / zlib; their sources are fetched, not vendored. The
Game Porting Toolkit is covered by Apple's license and is never copied into this repository.
Counter-Strike 2 and Steam are Valve's. Use your own account and follow Valve's terms.
