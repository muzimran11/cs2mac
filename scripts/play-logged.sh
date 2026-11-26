#!/usr/bin/env bash
# Like ./cs2mac play, but samples cl_showfps 2 overlay every 5 seconds and writes a CSV
# plus a summary when the game exits. Output under build/sessions/<timestamp>/.
# Usage: play-logged.sh [backend] [WxH] [cs2 args...]
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/env.sh"

backend="${1:-d3dmetal}"; res="${2:-1920x1080}"; shift $(( $# > 2 ? 2 : $# ))
ts=$(date +%Y%m%d-%H%M%S)
sess="$ROOT/build/sessions/$backend-$res-$ts"
mkdir -p "$sess"
csv="$sess/fps.csv"
play_log="$sess/play.log"

echo "[play-logged] session dir: $sess"
echo "t,now,f60,f240,f1000,min_ms,max_ms" > "$csv"

# Launch the game with Wine stderr captured. CS2MAC_DIRECT=1 keeps cs2.exe in the foreground
# of this shell so we can see its PID and clean up when it exits.
export CS2MAC_DIRECT=1 CS2MAC_BACKEND="$backend"
export CS2MAC_WIDTH="${res%x*}" CS2MAC_HEIGHT="${res#*x}"
export WINEDEBUG="${WINEDEBUG:-+seh,+dbghelp}"

"$ROOT/scripts/run-cs2.sh" +cl_showfps 2 +fps_max 0 "$@" > "$play_log" 2>&1 &
game_pid=$!
echo "[play-logged] cs2 pid=$game_pid, logging fps to $csv (Ctrl+C to stop logger; game keeps running)"

# Background OCR sampler. Dies when the game exits.
(
    while kill -0 $game_pid 2>/dev/null; do
        shot="$sess/frame.png"
        WINSHOT_NAME="Counter" "$ROOT/scripts/winshot" "$shot" > /dev/null 2>&1 || break
        r=$("$ROOT/scripts/fpsread" "$shot" 2>/dev/null || echo "")
        g() { echo "$r" | tr ' ' '\n' | grep "^$1=" | cut -d= -f2; }
        echo "$SECONDS,$(g now),$(g f60),$(g f240),$(g f1000),$(g min),$(g max)" >> "$csv"
        sleep 5
    done
) &
sampler_pid=$!

trap 'kill $sampler_pid 2>/dev/null; echo; echo "[play-logged] stopping logger"' INT TERM
wait $game_pid
kill $sampler_pid 2>/dev/null
wait $sampler_pid 2>/dev/null || true

# Summary
python3 - "$csv" "$backend" "$res" <<'PY' | tee "$sess/summary.txt"
import csv, statistics, sys
rows = list(csv.DictReader(open(sys.argv[1])))
def col(k): return [float(r[k]) for r in rows if r.get(k)]
f60, mx = col("f60"), col("max_ms")
print(f"session backend={sys.argv[2]} res={sys.argv[3]} samples={len(rows)} duration={5*len(rows)}s")
if f60:
    s = sorted(f60)
    p = lambda x: s[max(0, int(len(s)*x)-1)]
    print(f"fps(60-frame window): median={statistics.median(s):.1f} mean={statistics.fmean(s):.1f} p5={p(0.05):.1f} p1={p(0.01):.1f} min={s[0]:.1f} max={s[-1]:.1f}")
else:
    print("no fps samples captured (game window may have been minimized or on a different Space)")
if mx: print(f"worst frame (ms) over session: {max(mx):.1f}")
PY
echo "[play-logged] done: $sess/summary.txt"
