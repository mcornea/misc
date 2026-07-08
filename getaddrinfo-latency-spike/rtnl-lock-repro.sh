#!/bin/bash
# RTNL mutex contention capture
#
# Deploys a privileged pod that records rtnl_lock/rtnl_unlock
# via perf probe while measuring getaddrinfo("localhost") latency.
# Run this BEFORE starting the kube-burner workload, then Ctrl-C
# when the workload is done.
#
# Usage:
#   export KUBECONFIG=/tmp/kubeconfig
#   ./rtnl-lock-repro.sh            # start recording
#   # ... run kube-burner in another terminal ...
#   # Ctrl-C when done — analysis runs automatically

set -euo pipefail

if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "ERROR: KUBECONFIG is not set"
  exit 1
fi

DURATION=${DURATION:-600}
POD_NAME="rtnl-repro"
NS="default"
NODE=$(oc get nodes --no-headers -o jsonpath='{.items[0].metadata.name}')
COLLECT_DIR="$HOME/test/rtnl-repro-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$COLLECT_DIR"
GAI_PID=""
PERF_PID=""

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

analyze() {
    log ""
    log "=== Stopping recordings ==="

    kill "$GAI_PID" 2>/dev/null || true
    wait "$GAI_PID" 2>/dev/null || true

    # Stop stack capture and its getaddrinfo loop
    kill "$STACK_PID" 2>/dev/null || true
    wait "$STACK_PID" 2>/dev/null || true
    oc -n "$NS" exec "$POD_NAME" -- bash -c 'pkill -f "import socket" 2>/dev/null' || true

    # Stop perf gracefully
    oc -n "$NS" exec "$POD_NAME" -- bash -c 'pkill -INT perf 2>/dev/null' || true
    sleep 5
    kill "$PERF_PID" 2>/dev/null || true
    wait "$PERF_PID" 2>/dev/null || true

    # Collect stack captures
    cp /tmp/rtnl-stack-captures.txt "$COLLECT_DIR/stack-captures.txt" 2>/dev/null || true
    STACK_COUNT=$(wc -l < /tmp/rtnl-stack-captures.txt 2>/dev/null || echo 0)

    log ""
    log "=== getaddrinfo kernel stack captures ==="
    log ""
    if [ "$STACK_COUNT" -gt 0 ]; then
        echo "Caught getaddrinfo in rtnl_dumpit $STACK_COUNT times:"
        echo "  (D = sleeping/blocked on lock, R = running/dumping)"
        echo ""
        head -20 /tmp/rtnl-stack-captures.txt
        [ "$STACK_COUNT" -gt 20 ] && echo "  ... ($STACK_COUNT total, see $COLLECT_DIR/stack-captures.txt)"
    else
        echo "No kernel stack captures (getaddrinfo was never caught in rtnl_dumpit)"
    fi

    log ""
    log "=== Analyzing rtnl_lock hold times ==="
    log ""

    oc -n "$NS" exec "$POD_NAME" -- perf script -i /tmp/perf-rtnl.data 2>/dev/null \
      > "$COLLECT_DIR/perf-rtnl-script.txt"

    BOOT_EPOCH=$(oc -n "$NS" exec "$POD_NAME" -- python3 -c "
import time
with open('/proc/uptime') as f:
    uptime = float(f.read().split()[0])
print(f'{time.time() - uptime:.6f}')
" 2>/dev/null)

    python3 - "$COLLECT_DIR/perf-rtnl-script.txt" "$COLLECT_DIR/analysis.txt" "$BOOT_EPOCH" <<'PYEOF'
import sys, re
from collections import defaultdict
import time as _time

infile, outfile = sys.argv[1], sys.argv[2]
boot_epoch = float(sys.argv[3]) if len(sys.argv) > 3 else 0

def fmt_ts(kernel_ts):
    if boot_epoch:
        return _time.strftime('%H:%M:%S', _time.gmtime(boot_epoch + kernel_ts))
    return f'{kernel_ts:.3f}'

holds = []
pending_lock = None  # (ts, cpu, comm, caller) of the last unpaired lock

# Parse perf script output with stacks:
#   process  PID [CPU] timestamp: probe:rtnl_lock: (addr)
#                 addr func+off (module)
#                 addr func+off (module)
#                 ...
# Blank line separates events.

SKIP_FUNCS = {'rtnl_lock', 'rtnl_unlock', 'mutex_lock', '__mutex_lock',
              '__mutex_lock.constprop.0', 'refcount_dec_and_rtnl_lock'}

current_event = None  # (comm, cpu, ts, action)
current_stack = []

def process_event(comm, cpu, ts, action, stack):
    global pending_lock, holds
    # Find the first meaningful kernel function (skip lock internals)
    caller = comm
    for func in stack:
        name = func.split('+')[0]
        if name not in SKIP_FUNCS:
            caller = f'{comm} -> {name}'
            break
    if action == 'lock':
        pending_lock = (ts, cpu, comm, caller)
    elif action == 'unlock' and pending_lock is not None:
        lock_ts, lock_cpu, lock_comm, lock_caller = pending_lock
        hold_ms = (ts - lock_ts) * 1000
        if hold_ms >= 0:
            holds.append((lock_ts, lock_cpu, hold_ms, lock_caller))
        pending_lock = None

with open(infile) as f:
    for line in f:
        m = re.match(r'\s*(\S+)\s+\d+\s+\[(\d+)\]\s+(\d+\.\d+):\s+probe:rtnl_(lock|unlock)', line)
        if m:
            # Process previous event if any
            if current_event:
                process_event(*current_event, current_stack)
            current_event = (m.group(1), int(m.group(2)), float(m.group(3)), m.group(4))
            current_stack = []
        elif current_event:
            # Stack frame line: whitespace + addr + func+off (module)
            sm = re.match(r'\s+[0-9a-f]+\s+(\S+)', line)
            if sm:
                current_stack.append(sm.group(1))
    # Process last event
    if current_event:
        process_event(*current_event, current_stack)

with open(outfile, 'w') as out:
    def p(msg):
        print(msg)
        out.write(msg + '\n')

    p("=" * 64)
    p("  RTNL Mutex Hold Time Analysis")
    p("=" * 64)
    p("")

    if not holds:
        p("No rtnl_lock/unlock pairs found.")
        sys.exit(0)

    holds.sort(key=lambda x: x[0])

    p(f"Total rtnl_lock acquisitions: {len(holds)}")
    p("")
    long_holds = [h for h in holds if h[2] > 100]
    p(f"Holds >100ms (chronological): {len(long_holds)}")
    p(f"  {'Time':>10}  {'CPU':>4}  {'Hold':>12}  Caller")
    for ts, cpu, hold_ms, caller in long_holds:
        marker = " <<<" if hold_ms > 10 else ""
        if hold_ms >= 1000:
            hold_str = f"{hold_ms/1000:.1f} s"
        else:
            hold_str = f"{hold_ms:.1f} ms"
        p(f"  {fmt_ts(ts):>10}  {cpu:>4}  {hold_str:>12}  {caller}{marker}")

    p("")
    p("Hold time distribution:")
    buckets = defaultdict(int)
    for _, _, ms, _ in holds:
        if ms < 0.1: buckets['<0.1ms'] += 1
        elif ms < 1: buckets['0.1-1ms'] += 1
        elif ms < 10: buckets['1-10ms'] += 1
        elif ms < 100: buckets['10-100ms'] += 1
        elif ms < 1000: buckets['100ms-1s'] += 1
        else: buckets['>1s'] += 1
    for b in ['<0.1ms', '0.1-1ms', '1-10ms', '10-100ms', '100ms-1s', '>1s']:
        c = buckets.get(b, 0)
        bar = '#' * min(c, 50)
        p(f"  {b:>10}: {c:5d}  {bar}")

    p("")
    p("By caller (sorted by total hold time):")
    caller_stats = defaultdict(lambda: [0, 0.0, 0.0])
    for _, _, ms, comm in holds:
        s = caller_stats[comm]
        s[0] += 1
        s[1] += ms
        s[2] = max(s[2], ms)
    for comm, (cnt, total, mx) in sorted(caller_stats.items(), key=lambda x: -x[1][1]):
        if mx >= 1000:
            mx_str = f"{mx/1000:.1f}s"
        else:
            mx_str = f"{mx:.0f}ms"
        p(f"  {comm:>20}: {cnt:5d} calls, total {total/1000:.1f}s, max {mx_str}")

    over_1s = sum(1 for _, _, ms, _ in holds if ms >= 1000)
    if over_1s:
        p(f"\n  *** {over_1s} lock holds exceeded 1 second ***")
PYEOF

    log ""
    log "Results saved to: $COLLECT_DIR/"
    log "  analysis.txt           — hold time analysis"
    log "  perf-rtnl-script.txt   — raw perf script output"

    # Clean up perf probes
    oc -n "$NS" exec "$POD_NAME" -- bash -c '
      perf probe --del rtnl_lock 2>/dev/null
      perf probe --del rtnl_unlock 2>/dev/null
    ' 2>/dev/null || true
}

cleanup() {
    analyze
    log ""
    log "Pod $POD_NAME left running for further investigation."
    log "  Delete: oc delete pod $POD_NAME -n $NS"
}
trap cleanup EXIT INT TERM

cat <<BANNER
================================================================
  RTNL Mutex Contention Capture
================================================================

  Node:        $NODE
  Duration:    ${DURATION}s (or Ctrl-C to stop early)
  Collect dir: $COLLECT_DIR

  Recording:
    - perf probe on rtnl_lock / rtnl_unlock (mutex hold times)
    - getaddrinfo("localhost") latency (impact on probes)

  Start the kube-burner workload in another terminal.
  Ctrl-C when the workload is done.
================================================================

BANNER

### Step 1: Deploy profiler pod
log "Deploying profiler pod..."
oc -n "$NS" delete pod "$POD_NAME" --ignore-not-found 2>/dev/null
sleep 2

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NS}
spec:
  nodeName: ${NODE}
  hostPID: true
  hostNetwork: true
  containers:
  - name: profiler
    image: registry.redhat.io/rhel10/support-tools
    imagePullPolicy: IfNotPresent
    command: ["sleep", "86400"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: modules
      mountPath: /lib/modules
      readOnly: true
    - name: tmp
      mountPath: /tmp
  volumes:
  - name: modules
    hostPath:
      path: /lib/modules
  - name: tmp
    emptyDir:
      sizeLimit: 4Gi
  tolerations:
  - operator: Exists
  restartPolicy: Never
EOF

oc -n "$NS" wait "pod/${POD_NAME}" --for=condition=Ready --timeout=120s

### Step 2: Install perf
log "Installing perf..."
oc -n "$NS" exec "$POD_NAME" -- bash -c '
  KERNEL_VER=$(uname -r)
  if echo "$KERNEL_VER" | grep -q "el9"; then
    STREAM_VER="9-stream"
  else
    STREAM_VER="10-stream"
  fi
  cat > /etc/yum.repos.d/centos-stream.repo << REPO
[centos-stream-baseos]
name=CentOS Stream BaseOS
baseurl=https://mirror.stream.centos.org/${STREAM_VER}/BaseOS/x86_64/os/
gpgcheck=0
enabled=1
[centos-stream-appstream]
name=CentOS Stream AppStream
baseurl=https://mirror.stream.centos.org/${STREAM_VER}/AppStream/x86_64/os/
gpgcheck=0
enabled=1
REPO
  dnf install -y perf 2>&1 | tail -3
  perf --version
'

### Step 3: Set up perf probes + start recording
log "Setting up perf probes..."
oc -n "$NS" exec "$POD_NAME" -- bash -c '
  perf probe --del rtnl_lock 2>/dev/null || true
  perf probe --del rtnl_unlock 2>/dev/null || true
  perf probe --add rtnl_lock
  perf probe --add rtnl_unlock
'

log "Detecting reserved CPUs..."
RESERVED_CPUS=$(oc -n "$NS" exec "$POD_NAME" -- bash -c \
  'grep Cpus_allowed_list /proc/$(pgrep -x kubelet | head -1)/status | awk "{print \$2}"' 2>/dev/null)
log "Reserved CPUs: ${RESERVED_CPUS}"

log "Starting perf record (${DURATION}s)..."
oc -n "$NS" exec "$POD_NAME" -- bash -c \
  "perf record -g -e probe:rtnl_lock -e probe:rtnl_unlock -C ${RESERVED_CPUS} -R -o /tmp/perf-rtnl.data -- sleep $DURATION" &
PERF_PID=$!

### Step 4: Start getaddrinfo latency monitor
log "Starting getaddrinfo latency monitor..."
log ""

oc -n "$NS" exec "$POD_NAME" -- python3 -c '
import socket, time

INTERVAL = 0.05
count = 0
spikes = 0
max_ms = 0

while True:
    start = time.monotonic()
    try:
        socket.getaddrinfo("localhost", 80)
    except Exception:
        time.sleep(INTERVAL)
        continue
    elapsed_ms = (time.monotonic() - start) * 1000
    count += 1
    if elapsed_ms > max_ms:
        max_ms = elapsed_ms
    ts = time.strftime("%H:%M:%S", time.gmtime())
    if elapsed_ms > 10:
        spikes += 1
        marker = " ***" if elapsed_ms > 1000 else ""
        print(f"  {ts}  {elapsed_ms:9.1f} ms  [spike {spikes}]{marker}", flush=True)
    elif count % 100 == 0:
        print(f"  {ts}  {elapsed_ms:9.1f} ms  [ok - {count} calls, max {max_ms:.0f} ms]", flush=True)
    time.sleep(INTERVAL)
' &
GAI_PID=$!

### Step 5: Start kernel stack capture for getaddrinfo
log "Starting kernel stack capture for getaddrinfo..."
oc -n "$NS" exec "$POD_NAME" -- bash -c '
# getaddrinfo loop
python3 -c "
import socket
while True:
    socket.getaddrinfo(\"localhost\", 80)
" &
GAI_PID=$!

# Poll its kernel stack + process state
while kill -0 $GAI_PID 2>/dev/null; do
    stack=$(cat /proc/$GAI_PID/stack 2>/dev/null)
    if echo "$stack" | grep -q "rtnl_dumpit\|rtnl_lock"; then
        ts=$(date -u +%H:%M:%S)
        state=$(awk "/^State:/{print \$2}" /proc/$GAI_PID/status 2>/dev/null)
        funcs=$(echo "$stack" | sed -n "s/.*] \([^ ]*\).*/\1/p" | paste -sd "," -)
        echo "  $ts  state=$state  $funcs"
    fi
    sleep 0.01
done
' > /tmp/rtnl-stack-captures.txt 2>&1 &
STACK_PID=$!

log "Recording. Start kube-burner now. Ctrl-C when done."
log ""

# Wait for perf to finish or Ctrl-C
wait "$PERF_PID" 2>/dev/null || true
