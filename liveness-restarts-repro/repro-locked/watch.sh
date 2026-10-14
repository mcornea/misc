#!/usr/bin/env bash
# Kill-watch: tails liveness-kill events for the reproducer namespace and
# flags cascades (>= 3 kills landing within one poll window). Prints UTC
# timestamps so the cascades can be correlated with the client scenario
# cycle (edge phase every ~6 min) and the 15-min restart triggers.
#
# Optional env:
#   NS        namespace (default haproxy-repro)
#   INTERVAL  poll seconds (default 10)
#
# Usage:
#   NS=haproxy-repro KUBECONFIG=/tmp/kubeconfig ./watch.sh
set -u
NS=${NS:-haproxy-repro}
INTERVAL=${INTERVAL:-10}
TMPDIR_W=${TMPDIR:-/tmp}
BASE="$TMPDIR_W/watch-baseline-$$.json"
NOW="$TMPDIR_W/watch-now-$$.json"
trap 'rm -f "$BASE" "$NOW"' EXIT

oc -n "$NS" get events --field-selector reason=Killing -o json > "$BASE" 2>/dev/null
echo "watching namespace '$NS' for liveness kills (poll ${INTERVAL}s, ctrl-c to stop)..."

while true; do
  sleep "$INTERVAL"
  oc -n "$NS" get events --field-selector reason=Killing -o json > "$NOW" 2>/dev/null || continue
  python3 - "$BASE" "$NOW" <<'PY'
import json, sys, os

def kills(path):
    out = {}
    with open(path) as f:
        ev = json.load(f)
    for e in ev.get("items", []):
        msg = e.get("message", "")
        if "failed liveness" not in msg:
            continue
        t = e.get("lastTimestamp") or e.get("firstTimestamp")
        if t:
            out[t + "|" + msg] = t
    return out

base, now = kills(sys.argv[1]), kills(sys.argv[2])
new = sorted(set(now) - set(base))
if new:
    flag = "  *** CASCADE ***" if len(new) >= 3 else ""
    for m in new:
        ts, msg = m.split("|", 1)
        print(f"{ts}  {msg}{flag}", flush=True)
os.replace(sys.argv[2], sys.argv[1])
PY
done
