#!/usr/bin/env bash
# Shader cache warmup. Loads a map with bots disabled, fires every weapon and scope, triggers
# post-process and decal pipelines, then exits. On a cold D3DMetal cache the first real session
# on a map hits 100+ ms frame stalls while pipelines compile; this script pays those costs once
# so matches start warm. Stamps a mark so './cs2mac play' can skip warmup after.
#
# Usage: warmup.sh [map] [backend] [WxH]   (defaults: de_dust2, d3dmetal, 1920x1080)
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/env.sh"

map="${1:-de_dust2}"; backend="${2:-d3dmetal}"; res="${3:-1920x1080}"
cfg_src="$ROOT/scripts/warmup/warmup.cfg"
cfg_dst="$CS2_DIR/game/csgo/cfg/warmup.cfg"
mark_dir="$CS2MAC_HOME/warmup"; mkdir -p "$mark_dir"
# Cache invalidates on D3DMetal shim or MoltenVK changes; hash both into the mark name.
hash="$(shasum -a 1 "$ROOT/build/d3dmetal/gptk.dll" "$WINE_ROOT/lib/libMoltenVK.dylib" 2>/dev/null | shasum -a 1 | cut -c1-12)"
mark="$mark_dir/$backend-$map-$hash"
if [ "${CS2MAC_FORCE_WARMUP:-0}" != 1 ] && [ -f "$mark" ]; then
    echo "[warmup] $backend/$map already warm (mark: $mark). CS2MAC_FORCE_WARMUP=1 to redo."
    exit 0
fi

[ -f "$CS2_DIR/game/bin/win64/cs2.exe" ] || { echo "CS2 not installed" >&2; exit 1; }
mkdir -p "$(dirname "$cfg_dst")"
cp -f "$cfg_src" "$cfg_dst"

# Append a firing sweep as a cfg alias chain: use each weapon, fire a burst at a few angles so
# bullets hit different world materials (compiling decal shaders per surface type).
cat >> "$cfg_dst" <<'INNER'
alias _burst "+attack; wait 120; -attack; wait 20"
alias _look_a "setang 0 0 0; wait 5; _burst"
alias _look_b "setang -5 45 0; wait 5; _burst"
alias _look_c "setang 10 -60 0; wait 5; _burst"
alias _look_d "setang -20 160 0; wait 5; _burst"
alias _fire_all "_look_a; _look_b; _look_c; _look_d"
alias _sweep "use weapon_glock; _fire_all; use weapon_ak47; _fire_all; use weapon_m4a1; _fire_all; use weapon_awp; _fire_all; use weapon_deagle; _fire_all; use weapon_mp9; _fire_all; use weapon_p90; _fire_all; use weapon_m249; _fire_all; use weapon_nova; _fire_all"
_sweep
echo CS2MAC_WARMUP_SWEEP_DONE
INNER

: > "$CS2_DIR/game/csgo/console.log"
echo "[warmup] backend=$backend map=$map res=$res (compiling pipelines)"
export CS2MAC_DIRECT=1 CS2MAC_BACKEND="$backend"
export CS2MAC_WIDTH="${res%x*}" CS2MAC_HEIGHT="${res#*x}"
"$ROOT/scripts/run-cs2.sh" -insecure +sv_cheats 1 +map "$map" +exec warmup.cfg +cl_showfps 2 +fps_max 0 \
    > "$mark_dir/last-$backend-$map.log" 2>&1 &
launcher=$!

# Wait for map load.
for i in $(seq 1 180); do
    grep -q "Sending full update to client" "$CS2_DIR/game/csgo/console.log" 2>/dev/null && break
    kill -0 $launcher 2>/dev/null || { echo "[warmup] cs2 exited before map load"; exit 1; }
    sleep 1
done
grep -q "Sending full update to client" "$CS2_DIR/game/csgo/console.log" 2>/dev/null \
    || { echo "[warmup] map load timeout" >&2; pkill -f "^cs2.exe"; exit 1; }
echo "[warmup] map loaded after ${i}s; firing sweep (up to 90 s)"

for i in $(seq 1 90); do
    grep -q "CS2MAC_WARMUP_SWEEP_DONE" "$CS2_DIR/game/csgo/console.log" 2>/dev/null && { echo "[warmup] sweep complete"; break; }
    kill -0 $launcher 2>/dev/null || break
    sleep 1
done

echo "[warmup] stopping cs2"
pkill -f "^cs2.exe" 2>/dev/null
wait $launcher 2>/dev/null || true
touch "$mark"
echo "[warmup] done (mark: $mark)"
