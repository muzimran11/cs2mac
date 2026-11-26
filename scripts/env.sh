#!/usr/bin/env bash
# Shared environment for cs2mac. Source this, don't execute it.
# Everything here is tunable; see docs/TUNING.md for what each knob does.

CS2MAC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")/.." && pwd)"
CS2MAC_HOME="${CS2MAC_HOME:-$HOME/Library/Application Support/cs2mac}"
export WINEPREFIX="${WINEPREFIX:-$CS2MAC_HOME/prefix}"

# Wine 11.17 (gcenx build, wow64, bundles MoltenVK) unpacked by scripts/setup.sh
export WINE_ROOT="${WINE_ROOT:-$CS2MAC_ROOT/vendor/wine-11.17/Wine Devel.app/Contents/Resources/wine}"
# vendor/CS2.app wraps the Wine loader in a bundle that declares the games category, so macOS
# turns on Game Mode for fullscreen CS2 (setup.sh step "gamemode"). Falls back to the stock loader.
if [ -x "$CS2MAC_ROOT/vendor/CS2.app/Contents/MacOS/wine" ]; then
    export WINE="${WINE:-$CS2MAC_ROOT/vendor/CS2.app/Contents/MacOS/wine}"
else
    export WINE="${WINE:-$WINE_ROOT/bin/wine}"
fi
export WINESERVER="${WINESERVER:-$WINE_ROOT/bin/wineserver}"

# Apple Game Porting Toolkit (only needed for the d3dmetal backend)
GPTK_APP="/Applications/Game Porting Toolkit.app/Contents/Resources/wine"
export GPTK_LIB="$GPTK_APP/lib"

export WINEDEBUG="${WINEDEBUG:--all}"
export WINEESYNC="${WINEESYNC:-1}"
export WINEMSYNC="${WINEMSYNC:-1}"

# Backend selection: vulkan (CS2 -vulkan -> MoltenVK), dxvk, d3dmetal
export CS2MAC_BACKEND="${CS2MAC_BACKEND:-vulkan}"

STEAM_DIR="$WINEPREFIX/drive_c/Program Files (x86)/Steam"
CS2_DIR="$STEAM_DIR/steamapps/common/Counter-Strike Global Offensive"

# D3DMetal knobs (see docs/TUNING.md). MetalFX pays off when the GPU is the bottleneck, i.e. above
# about 1080p on the smaller Apple GPUs; default it on at >= 1920 pixels wide if the user did not
# set it. Async commit and the multithreaded interface are noisy on M2 Max and off by default; try
# them on an M4 Air with CS2MAC_ASYNC_COMMIT=1 or CS2MAC_MULTITHREADED=1.
if [ -z "${D3DM_ENABLE_METALFX:-}" ] && [ "${CS2MAC_METALFX:-auto}" != "0" ]; then
    _w="${CS2MAC_WIDTH:-0}"
    if [ "${CS2MAC_METALFX:-auto}" = "1" ] || [ "${_w:-0}" -ge 1920 ] 2>/dev/null; then
        export D3DM_ENABLE_METALFX=1
    fi
fi
[ "${CS2MAC_ASYNC_COMMIT:-0}" = 1 ] && export D3DM_ENABLE_ASYNC_COMMIT=1
[ "${CS2MAC_MULTITHREADED:-0}" = 1 ] && export D3DM_MULTITHREADED_INTERFACE_ENABLE=1

# mimalloc replaces the system allocator in the Wine host process; CS2 and Wine both do a lot of
# small allocations and the system allocator is a hot spot. Opt-in via CS2MAC_MIMALLOC=1 after
# scripts/setup.sh installs it; see docs/TUNING.md.
if [ "${CS2MAC_MIMALLOC:-0}" = 1 ]; then
    for _mi in /opt/homebrew/lib/libmimalloc.dylib /usr/local/lib/libmimalloc.dylib; do
        [ -f "$_mi" ] && export DYLD_INSERT_LIBRARIES="${DYLD_INSERT_LIBRARIES:+$DYLD_INSERT_LIBRARIES:}$_mi" && break
    done
fi

# Raise the Wine process tree to user-interactive QoS so macOS schedules it on the P-cores. On an
# M4 Air with 4 P-cores and 6 E-cores the default (user-initiated via Steam) can land threads on
# E-cores under contention. Opt-out with CS2MAC_QOS=0.
if [ "${CS2MAC_QOS:-1}" = 1 ] && command -v taskpolicy >/dev/null 2>&1; then
    CS2MAC_QOS_WRAPPER=(taskpolicy -c user-interactive)
else
    CS2MAC_QOS_WRAPPER=()
fi

# Hybrid arm64 Wine (experimental). Built by './cs2mac setup wine_arm64'; opt in per-launch with
# CS2MAC_WINE_ARM64=1. The PE side (CS2.exe, D3DMetal) stays x86_64 under Rosetta; the Unix side
# (ntdll.so, winemac.drv.so, wineserver, the Wine loader itself) becomes native aarch64. The win
# is on syscalls, wineserver round trips, and scheduling: no Rosetta tax on that half.
if [ "${CS2MAC_WINE_ARM64:-0}" = 1 ] && [ -x "$CS2MAC_ROOT/vendor/wine-arm64/bin/wine" ]; then
    export WINE="$CS2MAC_ROOT/vendor/wine-arm64/bin/wine"
    export WINESERVER="$CS2MAC_ROOT/vendor/wine-arm64/bin/wineserver"
    echo "[cs2mac] using hybrid arm64 Wine (experimental)" >&2
fi
