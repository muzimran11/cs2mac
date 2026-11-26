#!/usr/bin/env bash
# Launch CS2 via Steam -applaunch (so VAC-secure servers work) and sample cl_showfps 2 every 5 s
# until cs2.exe exits. Writes CSV + summary under build/sessions/<timestamp>/.
# Usage: play-logged.sh [backend] [WxH] [cs2 args...]
#
# Wine stderr isn't captured here: Steam owns the process tree and swallows it. For a crash
# investigation run CS2MAC_DIRECT=1 ./cs2mac play ... instead; that loses VAC but keeps stderr.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/env.sh"

backend="${1:-d3dmetal}"; res="${2:-1920x1080}"; shift $(( $# > 2 ? 2 : $# ))
ts=$(date +%Y%m%d-%H%M%S)
sess="$ROOT/build/sessions/$backend-$res-$ts"
mkdir -p "$sess"
csv="$sess/fps.csv"
echo "[play-logged] session dir: $sess (VAC enabled, via Steam -applaunch)"
echo "t,now,f60,f240,f1000,min_ms,max_ms" > "$csv"

# Make sure no stale cs2.exe is running, so pgrep matches the one we launch.
pkill -f "^cs2.exe" 2>/dev/null; sleep 1

export CS2MAC_BACKEND="$backend" CS2MAC_WIDTH="${res%x*}" CS2MAC_HEIGHT="${res#*x}"
# Fire the Steam launch and return immediately; Steam spawns cs2.exe as its own child.
CS2MAC_DIRECT=0 "$ROOT/scripts/run-cs2.sh" +cl_showfps 2 +fps_max 0 "$@" > "$sess/launch.log" 2>&1 &
# Wait up to 60 s for Steam to actually spawn cs2.exe.
for i in $(seq 1 60); do
    pid=$(pgrep -f "^cs2.exe" | head -1)
    [ -n "$pid" ] && break
    sleep 1
done
[ -z "${pid:-}" ] && { echo "[play-logged] cs2.exe never started; see $sess/launch.log"; exit 1; }
echo "[play-logged] cs2 pid=$pid; sampling to $csv until the game exits (Ctrl+C stops the logger)"

(
    while kill -0 $pid 2>/dev/null; do
        shot="$sess/frame.png"
        WINSHOT_NAME="Counter" "$ROOT/scripts/winshot" "$shot" > /dev/null 2>&1 || break
        r=$("$ROOT/scripts/fpsread" "$shot" 2>/dev/null || echo "")
        g() { echo "$r" | tr ' ' '\n' | grep "^$1=" | cut -d= -f2; }
        echo "$SECONDS,$(g now),$(g f60),$(g f240),$(g f1000),$(g min),$(g max)" >> "$csv"
        sleep 5
    done
) &
sampler_pid=$!

trap 'kill $sampler_pid 2>/dev/null; echo; echo "[play-logged] logger stopped (game still running)"' INT TERM
# Wait on cs2.exe directly via a polling loop (we don't own the PID, so wait doesn't work).
while kill -0 $pid 2>/dev/null; do sleep 2; done
kill $sampler_pid 2>/dev/null
wait $sampler_pid 2>/dev/null || true

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
