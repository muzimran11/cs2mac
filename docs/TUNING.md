# Tuning

What was tried, what mattered, and what did not. Numbers are in `docs/RESULTS.md`.

## Things that matter

| knob | where | effect |
|------|-------|--------|
| backend `d3dmetal` | `./cs2mac play d3dmetal` | best median, best p5 and shortest load stalls, see RESULTS |
| `RetinaMode = n` | prefix registry, set by setup | `y` renders at full Retina pixels but breaks CS2's mouse mapping |
| MoltenVK 1.4.3 + null descriptor patch | `vendor/MoltenVK`, installed into Wine | vulkan/dxvk run at all (present_wait2, no crash on map load) |
| `WINEESYNC=1 WINEMSYNC=1` | `scripts/env.sh` | fewer wineserver round trips for synchronisation; msync is the macOS native one and is used when available |
| `-windowed -w 1280 -h 720` | `run-cs2.sh` | fullscreen on Wine's Mac driver changes the display mode and is slower to alt-tab; the window can be resized in the game's settings |
| `fps_max 0` | benchmark only | uncapped so the numbers are comparable; for play, cap at the display's refresh rate to keep frame pacing even |
| `-nojoy -novid` | `run-cs2.sh` | skip the joystick scan (slow under Wine) and the intro |

## D3DMetal environment knobs

`libd3dshared` reads these from the environment (found by string search in the binary, not
documented by Apple). Set them before `./cs2mac play d3dmetal`:

| variable | what it does |
|----------|--------------|
| `D3DM_SHOW_HUD_STATS=1` | Metal performance HUD in the corner of the window |
| `D3DM_ENABLE_METALFX=1` | let D3DMetal use MetalFX upscaling where it can |
| `D3DM_ENABLE_ASYNC_COMMIT=1` | commit command buffers from a worker thread |
| `D3DM_MULTITHREADED_INTERFACE_ENABLE=1` | run the D3D11 immediate context on its own thread |
| `D3DM_WAIT_ON_RESET=1` | synchronous device reset (debugging only) |
| `D3DM_NO_WINDOW=1` | headless (no CAMetalLayer), useful for tracing |

In the runs so far none of these moved the median by more than noise at 1280x720; the game is
CPU/translation bound there, not GPU bound.

## Things that did not help

- **`r_wait_on_present 0`** on the vulkan backend: hides the present-wait error but the game still
  exits; the real fix was the MoltenVK upgrade.
- **DXVK async shader compilation**: the "async" build is already used; the stalls are pipeline
  creation inside MoltenVK, not DXVK's state cache.
- **Retina on with d3dmetal**: sharp since the finished shim (was quarter resolution in early builds).
- **wined3d** (stock Wine, OpenGL): loads the menu, single-digit fps in a map. Kept as the
  fallback backend because it needs nothing extra.

## Where the time goes

At 1280x720 on an M2 Max all backends are far from the GPU limit. The remaining cost is
Rosetta (CS2 is x86_64 and so is Wine's PE side) and the D3D11 to Metal translation. The
d3dmetal backend wins because it translates D3D11 to Metal in one step; dxvk and vulkan go through
Vulkan first and MoltenVK then re-translates. Running Wine's Unix side native arm64 (Wine's
`--enable-archs` with an arm64 host build) would remove Rosetta from the Unix half but not from
the game itself; it is the next thing worth trying.

## Frame drops while shooting (2026-09-12)

Measured with `scripts/shoot-test.sh` (Aim Botz, AK-47 bursts, M2 Max, 1280x720, one run per row).

| run | idle f60 median | shooting f60 median / min | worst frame ms while shooting |
|---|---|---|---|
| d3dmetal | 120 | 118 / 86 | 94 |
| dxvk | 118 | 117 / 112 | 1552 |
| d3dmetal -nosound | 114 | 115 / 105 | 344 |
| d3dmetal D3DM_ENABLE_ASYNC_COMMIT=1 | 120 | 119 / 93 | 99 |
| d3dmetal D3DM_MULTITHREADED_INTERFACE_ENABLE=1 | 113 | 109 / 84 | 71 |
| de_dust2 with bots, d3dmetal | 111 | 113 / 88 | 57 |
| de_dust2 without bots, d3dmetal | 114 | 116 / 61 | 175 |

Findings:

- The big drops (30 to 45 fps for several seconds) only showed on the very first shooting session
  on a fresh shader cache. Later sessions on the same map stayed within about 10% of idle. That
  matches D3DMetal compiling pipelines the first time muzzle flash, tracer and impact effects
  appear; the result is cached on disk, so it gets better after one session.
- None of sound, bots, async commit or the multithreaded interface changed the steady-state
  numbers beyond run-to-run noise. Async commit had the best single run but did not hold up on
  repeats, so it stays off by default.
- DXVK keeps a similar median but has second-long hitches (worst frame 0.8 to 1.5 s), so d3dmetal
  stays the default.
- Background load matters more than any knob: a busy Chrome GPU helper and a dev server pulled
  repeat runs down to 80 to 100 fps with 250+ ms spikes, idle included. Close them before playing
  or benchmarking.

To warm the shader cache before a real match, load Aim Botz once and fire every weapon you plan to
use: `./cs2mac play d3dmetal 1280x720 +map_workshop 3070244462 aim_botz`.

## Retina (2026-09-12)

d3dmetal, `RetinaMode=y`, 2x external display, Dust2 benchmark map, 90 s each. The window is
clamped to the screen in points, so the pixel size is what the GPU renders.

| Rendered pixels | median fps | 5th percentile fps | worst frame ms |
|---|---|---|---|
| 2304x1296 | 86.4 | 59.7 | 234.6 |
| 2304x1296 with FSR | 83.0 | 58.7 | 74.7 |
| 1920x1080 | 109.8 | 80.0 | 54.9 |
| 1280x720 | 116.8 | 113.3 | 1031.6 |

The GPU is the limit above 1080p; at 720p the CPU (Rosetta) is. For competitive play pick 1920x1080.

## M4 Air experiments (2026-11-25)

Four changes landed together on branch WebhelperFIX targeting a 1080p 85+ fps median on an
M4 Air (10-core GPU, 16 GB unified, 4P/6E CPU). Measure each in isolation with
`./cs2mac bench d3dmetal 120 1920x1080`.

### MetalFX spatial upscaling (default on at 1920+)

`D3DM_ENABLE_METALFX=1` is now auto-set at CS2MAC_WIDTH >= 1920. On smaller Apple GPUs the
regime at 1080p flips from CPU-bound (as on M2 Max at 720p, where MetalFX moved nothing)
to GPU-bound, and a spatial upscale from ~900p should give roughly a 20-40% median uplift.
Opt-out with CS2MAC_METALFX=0. Watch for ghosting on muzzle flash edges and scope reticle;
if it is unacceptable, fall back to CS2 internal FSR via the game's video settings.

### P-core QoS

Wine is launched under `taskpolicy -c user-interactive` so macOS biases scheduling onto
the P-cores. On an M4 Air with only 4 P-cores and 6 E-cores the default (user-initiated,
inherited from Steam) can land hot threads on E-cores under contention, which hurts p5
more than median. Opt-out with CS2MAC_QOS=0.

### mimalloc

`CS2MAC_MIMALLOC=1` inserts Microsoft's mimalloc as the Wine host process allocator via
DYLD_INSERT_LIBRARIES. Source 2 is allocator-heavy on map load and particle creation;
mimalloc typically beats the system allocator by 5-10% on alloc-heavy workloads. Off by
default because DYLD_INSERT_LIBRARIES interacts with code signing on some setups;
if the game refuses to launch with it on, that is why.

### Shader warmup

`./cs2mac warmup [map]` precompiles every D3DMetal pipeline the map is likely to hit
(every weapon fired at multiple surface materials, every scope, every post-process path)
and stamps a mark file. D3DMetal persists compiled pipelines to its on-disk cache, so
this pays forward across sessions until a binary changes. Expect the first warmup on a
map to take 60-120 seconds; subsequent `./cs2mac play` sessions on that map should show
flat p5 from the start instead of the 100+ ms first-session stalls documented in the
shoot-test section above.

### Hybrid arm64 Wine (experimental, build it yourself)

`./cs2mac setup wine_arm64` builds a second Wine configure with an aarch64 Unix side
alongside the x86_64 PE side. The win is making the Wine loader, ntdll.so, winemac.so
and wineserver native arm64 so syscalls and wineserver round trips do not pay Rosetta.
The game loop and D3DMetal stay x86_64. CS2MAC_WINE_ARM64=1 switches to the new
binaries for the next launch. Flagged experimental because the local patches may need
light adjustment against aarch64 paths; iterate against the build log.
