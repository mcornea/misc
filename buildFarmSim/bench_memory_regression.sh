#!/usr/bin/env bash
#
# bench_memory_regression.sh — Reproduce the etcd v3.6 kvsToEvents memory
# regression (etcd#21355) by running the watch-latency benchmark against
# v3.5 and v3.6, capturing RSS + heap profiles, then comparing results.
#
# Usage:
#   ./bench_memory_regression.sh              # full run (both versions)
#   ./bench_memory_regression.sh v3.5         # run only v3.5
#   ./bench_memory_regression.sh v3.6         # run only v3.6
#   ./bench_memory_regression.sh compare      # skip benchmarks, just compare existing results
#
# Output goes to $OUTDIR (default /tmp/bench-profiles).
#
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────

ETCD_V35=/tmp/etcd-v3.5.27-linux-amd64/etcd
ETCD_V36=/tmp/etcd-v3.6.8-linux-amd64/etcd
ETCD_V36_REVERTED=/tmp/etcd-v36-reverted
BENCHMARK_SRC=/root/buildFarmSim/etcd
BENCHMARK_BIN=/tmp/benchmark
OUTDIR=/tmp/bench-profiles

# Benchmark parameters (tuned to maximize kvsToEvents regression visibility)
# Key insight: moderate watchers let v3.6's regression stand out vs v3.5;
# too many watchers makes both versions equally stressed.
BG_KEY_COUNT=3000          # background keys (more data for kvsToEvents to process)
BG_KEY_SIZE=102400         # 100KiB per background key (total: ~300MiB)
PUT_TOTAL=3000             # total puts during benchmark
PUT_RATE=20                # puts/sec (150s runtime — more reconnect cycles)
VAL_SIZE=21504             # ~21KiB per watched value
STREAMS=3
WATCHERS_PER_STREAM=6
RECONNECT_INTERVAL=10s     # time between reconnects
RECONNECT_SLEEP=3s         # sleep before reconnect (watch-from-rev=1 replays full range anyway)
WATCH_FROM_REV=1           # force full sync from rev 1

# Profile capture interval (1s to catch transient reconnect spikes)
CAPTURE_INTERVAL=1

# ── Helpers ──────────────────────────────────────────────────────────────────

log()  { echo ">>> $*"; }
die()  { echo "ERROR: $*" >&2; exit 1; }

check_prereqs() {
    command -v go    >/dev/null || die "go not found in PATH"
    command -v curl  >/dev/null || die "curl not found in PATH"
    case "${1:-all}" in
        v3.5)     [ -x "$ETCD_V35" ] || die "etcd v3.5 binary not found at $ETCD_V35" ;;
        v3.6)     [ -x "$ETCD_V36" ] || die "etcd v3.6 binary not found at $ETCD_V36" ;;
        v3.6-reverted) [ -x "$ETCD_V36_REVERTED" ] || die "etcd v3.6-reverted binary not found at $ETCD_V36_REVERTED" ;;
        compare)  ;; # no etcd binary needed
        all)
            [ -x "$ETCD_V35" ] || die "etcd v3.5 binary not found at $ETCD_V35"
            [ -x "$ETCD_V36" ] || die "etcd v3.6 binary not found at $ETCD_V36"
            [ -x "$ETCD_V36_REVERTED" ] || die "etcd v3.6-reverted binary not found at $ETCD_V36_REVERTED"
            ;;
    esac
}

build_benchmark() {
    if [ -x "$BENCHMARK_BIN" ]; then
        log "Benchmark binary already exists at $BENCHMARK_BIN"
        return
    fi
    log "Building benchmark binary..."
    cd "$BENCHMARK_SRC"
    GOTOOLCHAIN=auto go build -buildvcs=false -o "$BENCHMARK_BIN" ./tools/benchmark
    log "Built $BENCHMARK_BIN"
}

kill_etcd() {
    pkill -f "etcd --data-dir" 2>/dev/null || true
    sleep 2
}

# ── Profile capture (runs in background until BENCH_PID exits) ───────────────

capture_profiles() {
    local BENCH_PID=$1
    local PROFILE_DIR=$2
    local ADDR="127.0.0.1:2379"
    local LABEL="127-0-0-1-2379"

    # Wait for pprof endpoint to be ready
    for _ in $(seq 1 30); do
        curl -s "http://${ADDR}/debug/pprof/heap" -o /dev/null 2>&1 && break
        sleep 1
    done

    local SEQ=0
    while kill -0 "$BENCH_PID" 2>/dev/null; do
        SEQ=$((SEQ + 1))
        PADDED=$(printf "%04d" $SEQ)

        # Binary profile (for pprof / SVG)
        if curl -s "http://${ADDR}/debug/pprof/heap" \
             -o "$PROFILE_DIR/heap_${LABEL}_${PADDED}.pb.gz" 2>/dev/null; then
            SIZE=$(wc -c < "$PROFILE_DIR/heap_${LABEL}_${PADDED}.pb.gz")
            [ "$SIZE" -lt 100 ] && rm -f "$PROFILE_DIR/heap_${LABEL}_${PADDED}.pb.gz"
        fi

        # Text profile (for memstats)
        if curl -s "http://${ADDR}/debug/pprof/heap?debug=1" \
             -o "$PROFILE_DIR/heap_${LABEL}_${PADDED}.txt" 2>/dev/null; then
            SIZE=$(wc -c < "$PROFILE_DIR/heap_${LABEL}_${PADDED}.txt")
            [ "$SIZE" -lt 100 ] && rm -f "$PROFILE_DIR/heap_${LABEL}_${PADDED}.txt"
        fi

        sleep "$CAPTURE_INTERVAL"
    done
    echo "  Captured $SEQ profile snapshots -> $PROFILE_DIR"
}

# ── Run one version ─────────────────────────────────────────────────────────

run_version() {
    local VERSION=$1
    local ETCD_BIN=$2
    local DATA_DIR="/tmp/etcd-data-${VERSION}"
    local PROFILE_DIR="$OUTDIR/${VERSION}/profiles"
    local MEM_CSV="$OUTDIR/${VERSION}/mem.csv"

    echo ""
    echo "========================================="
    echo "  Running etcd $VERSION"
    echo "========================================="

    mkdir -p "$PROFILE_DIR"
    kill_etcd
    rm -rf "$DATA_DIR"

    # Start etcd with pprof enabled
    $ETCD_BIN --data-dir "$DATA_DIR" --enable-pprof --log-level error \
        &>"/tmp/etcd-${VERSION}.log" &
    local ETCD_PID=$!
    sleep 3

    if ! kill -0 $ETCD_PID 2>/dev/null; then
        die "etcd $VERSION failed to start (see /tmp/etcd-${VERSION}.log)"
    fi

    log "etcd PID=$ETCD_PID"
    echo "  Baseline: $(grep VmRSS /proc/$ETCD_PID/status)"

    # RSS memory monitor (every 0.5s)
    echo "timestamp_ms,rss_kb" > "$MEM_CSV"
    local START_NS=$(date +%s%N)
    (
        while kill -0 $ETCD_PID 2>/dev/null; do
            local_now=$(date +%s%N)
            local_elapsed=$(( (local_now - START_NS) / 1000000 ))
            local_rss=$(awk '/VmRSS/{print $2}' /proc/$ETCD_PID/status 2>/dev/null)
            [ -n "$local_rss" ] && echo "$local_elapsed,$local_rss" >> "$MEM_CSV"
            sleep 0.5
        done
    ) &
    local MON_PID=$!

    # Run benchmark in background so we can capture profiles concurrently
    $BENCHMARK_BIN watch-latency \
      --endpoints=http://127.0.0.1:2379 \
      --streams=$STREAMS --watchers-per-stream=$WATCHERS_PER_STREAM \
      --put-total=$PUT_TOTAL --put-rate=$PUT_RATE \
      --val-size=$VAL_SIZE \
      --bg-key-count=$BG_KEY_COUNT --bg-key-size=$BG_KEY_SIZE \
      --reconnect-interval=$RECONNECT_INTERVAL --reconnect-sleep=$RECONNECT_SLEEP \
      --watch-from-rev=$WATCH_FROM_REV --prevkv \
      > "$OUTDIR/${VERSION}/bench.log" 2>&1 &
    local BENCH_PID=$!

    # Capture heap profiles while benchmark runs
    capture_profiles "$BENCH_PID" "$PROFILE_DIR"

    wait $BENCH_PID 2>/dev/null || true

    # Stop RSS monitor
    kill $MON_PID 2>/dev/null || true
    wait $MON_PID 2>/dev/null || true

    # Report
    local PEAK=$(awk -F, 'NR>1 && $2+0>0{if($2+0>max)max=$2+0}END{print max+0}' "$MEM_CSV")
    local SAMPLES=$(awk 'END{print NR-1}' "$MEM_CSV")
    local PROFILE_COUNT=$(find "$PROFILE_DIR" -name 'heap_*.pb.gz' 2>/dev/null | wc -l)

    echo ""
    echo "  Results:"
    echo "  Peak RSS: $((PEAK/1024)) MiB ($SAMPLES RSS samples)"
    echo "  Heap profiles captured: $PROFILE_COUNT"
    echo ""
    echo "  Benchmark output:"
    cat "$OUTDIR/${VERSION}/bench.log"
    echo ""

    # Stop etcd
    kill $ETCD_PID 2>/dev/null || true
    wait $ETCD_PID 2>/dev/null || true
    sleep 2
}

# ── Compare results ──────────────────────────────────────────────────────────

find_peak_profile() {
    # Find the profile with the highest total inuse_space (best captures reconnect spike)
    local DIR=$1
    local BEST="" BEST_SIZE=0
    for F in "$DIR"/heap_*.pb.gz; do
        [ -f "$F" ] || continue
        # Extract total inuse from pprof top output (e.g. "492.39MB total")
        local TOTAL=$(GOTOOLCHAIN=auto go tool pprof -top -nodecount=1 -inuse_space "$F" 2>&1 \
            | grep -oP '[\d.]+MB total' | head -1 | grep -oP '[\d.]+')
        if [ -n "$TOTAL" ]; then
            # Compare as integers (multiply by 100 to preserve 2 decimal places)
            local INT=$(echo "$TOTAL" | awk '{printf "%d", $1*100}')
            if [ "$INT" -gt "$BEST_SIZE" ]; then
                BEST_SIZE=$INT
                BEST=$F
            fi
        fi
    done
    echo "$BEST"
}

generate_svgs() {
    echo ""
    echo "========================================="
    echo "  Generating heap profile SVGs"
    echo "========================================="

    for DIR in "$OUTDIR"/v3.5 "$OUTDIR"/v3.6 "$OUTDIR"/v3.6-reverted; do
        [ -d "$DIR/profiles" ] || continue
        echo "  Scanning profiles for peak inuse snapshot..."
        PEAK=$(find_peak_profile "$DIR/profiles")
        [ -z "$PEAK" ] && continue
        VER=$(basename "$DIR")
        echo "  $VER: peak inuse profile = $PEAK"

        # inuse_space — what's live at snapshot time
        GOTOOLCHAIN=auto go tool pprof -svg -inuse_space \
            -nodefraction=0 -edgefraction=0 -nodecount=0 "$PEAK" \
            | sed 's/style="dashed"/style="solid"/g' > "$DIR/heap-inuse.svg"

        # inuse_space focused on kvsToEvents / syncWatchers
        GOTOOLCHAIN=auto go tool pprof -svg -inuse_space \
            -focus="kvsToEvents|syncWatchers" -nodefraction=0 -edgefraction=0 "$PEAK" \
            | sed 's/style="dashed"/style="solid"/g' > "$DIR/heap-kvsToEvents.svg"

        # alloc_space — cumulative allocations
        GOTOOLCHAIN=auto go tool pprof -svg -alloc_space \
            -nodefraction=0 -edgefraction=0 -nodecount=0 "$PEAK" \
            | sed 's/style="dashed"/style="solid"/g' > "$DIR/heap-alloc.svg"

        # alloc_space focused on kvsToEvents / syncWatchers
        GOTOOLCHAIN=auto go tool pprof -svg -alloc_space \
            -focus="kvsToEvents|syncWatchers" -nodefraction=0 -edgefraction=0 "$PEAK" \
            | sed 's/style="dashed"/style="solid"/g' > "$DIR/heap-alloc-kvsToEvents.svg"

        echo "    -> heap-inuse.svg, heap-kvsToEvents.svg, heap-alloc.svg, heap-alloc-kvsToEvents.svg"
    done
}

print_pprof_comparison() {
    echo ""
    echo "========================================="
    echo "  Peak profile comparison (inuse_space top 20)"
    echo "========================================="
    for DIR in "$OUTDIR"/v3.5 "$OUTDIR"/v3.6 "$OUTDIR"/v3.6-reverted; do
        [ -d "$DIR/profiles" ] || continue
        PEAK=$(find_peak_profile "$DIR/profiles")
        [ -z "$PEAK" ] && continue
        VER=$(basename "$DIR")
        echo ""
        echo "=== $VER peak ($PEAK) ==="
        GOTOOLCHAIN=auto go tool pprof -top -nodecount=20 -inuse_space "$PEAK" 2>&1
    done

    echo ""
    echo "========================================="
    echo "  syncWatchers / kvsToEvents comparison (alloc_space)"
    echo "========================================="
    # Use largest file for alloc_space (cumulative, grows over time)
    for DIR in "$OUTDIR"/v3.5 "$OUTDIR"/v3.6 "$OUTDIR"/v3.6-reverted; do
        [ -d "$DIR/profiles" ] || continue
        PEAK=$(find "$DIR/profiles" -name 'heap_*.pb.gz' -printf '%s %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2)
        [ -z "$PEAK" ] && continue
        VER=$(basename "$DIR")
        echo ""
        echo "=== $VER ==="
        GOTOOLCHAIN=auto go tool pprof -top -nodecount=50 -alloc_space "$PEAK" 2>&1 \
            | grep -iE "kvsToEvents|rangeEvents|syncWatch|KeyValue.*Unmarshal|Total" || true
    done

    # Print kvsToEvents inuse comparison table (matches issue #21355 format)
    echo ""
    echo "========================================="
    echo "  kvsToEvents regression summary (inuse_space during reconnect)"
    echo "========================================="
    for DIR in "$OUTDIR"/v3.5 "$OUTDIR"/v3.6 "$OUTDIR"/v3.6-reverted; do
        [ -d "$DIR/profiles" ] || continue
        PEAK=$(find_peak_profile "$DIR/profiles")
        [ -z "$PEAK" ] && continue
        VER=$(basename "$DIR")
        local PPROF_OUT
        PPROF_OUT=$(GOTOOLCHAIN=auto go tool pprof -top -nodecount=50 -inuse_space "$PEAK" 2>&1)
        # cum column (col 5) for functions that only appear via cum (kvsToEvents, syncWatchersLoop)
        # flat column (col 1) for KeyValue.Unmarshal
        # pprof format: "  flat flat% sum%  cum cum%  name"
        #               "283.04MB 37.40% 37.40%   283.04MB 37.40%  go.etcd.io/..."
        # col 4 = cum value
        KVS_INUSE=$(echo "$PPROF_OUT" | grep "\.kvsToEvents" | head -1 | awk '{print $4}' || true)
        # If kvsToEvents is inlined (v3.6.8+), fall back to syncWatchers cum
        if [ -z "$KVS_INUSE" ]; then
            KVS_INUSE=$(echo "$PPROF_OUT" | grep '\.syncWatchers$' | head -1 | awk '{print $4}' || true)
        fi
        UNMARSHAL=$(echo "$PPROF_OUT" | grep "KeyValue.*Unmarshal" | head -1 | awk '{print $1}' || true)
        SYNC=$(echo "$PPROF_OUT" | grep "syncWatchersLoop" | head -1 | awk '{print $4}' || true)
        TOTAL=$(echo "$PPROF_OUT" | grep -oP '[\d.]+MB total' | head -1 | grep -oP '[\d.]+MB' || true)
        echo "  $VER: total=${TOTAL:-n/a}  syncWatchersLoop(cum)=${SYNC:-0}  kvsToEvents(cum)=${KVS_INUSE:-0}  KeyValue.Unmarshal(flat)=${UNMARSHAL:-0}"
    done
}

generate_memory_chart() {
    local CSV_35="$OUTDIR/v3.5/mem.csv"
    local CSV_36="$OUTDIR/v3.6/mem.csv"
    local CSV_36R="$OUTDIR/v3.6-reverted/mem.csv"
    local CHART="$OUTDIR/memory_comparison.png"

    # Need at least v3.5 and v3.6
    if [ ! -f "$CSV_35" ] || [ ! -f "$CSV_36" ]; then
        echo "  (skipping chart — need both v3.5 and v3.6 mem.csv)"
        return
    fi

    # Pass v3.6-reverted CSV as optional 4th arg
    local EXTRA_ARGS=""
    [ -f "$CSV_36R" ] && EXTRA_ARGS="$CSV_36R"

    python3 - "$CSV_35" "$CSV_36" "$CHART" $EXTRA_ARGS <<'PYEOF'
import csv, sys, os
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker

def load_csv(path):
    times, rss = [], []
    with open(path) as f:
        reader = csv.reader(f)
        next(reader)
        for row in reader:
            times.append(int(row[0]) / 1000.0)
            rss.append(int(row[1]) / 1024.0)
    return times, rss

csv_35, csv_36, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
csv_36r = sys.argv[4] if len(sys.argv) > 4 else None

t35, m35 = load_csv(csv_35)
t36, m36 = load_csv(csv_36)

fig, ax = plt.subplots(figsize=(14, 6))
label_35 = os.environ.get('ETCD_V35_LABEL', 'v3.5')
label_36 = os.environ.get('ETCD_V36_LABEL', 'v3.6')
ax.plot(t35, m35, color='#2196F3', linewidth=1.5, label=f'etcd {label_35}', alpha=0.9)
ax.plot(t36, m36, color='#F44336', linewidth=1.5, label=f'etcd {label_36}', alpha=0.9)
ax.fill_between(t35, 0, m35, color='#2196F3', alpha=0.08)
ax.fill_between(t36, 0, m36, color='#F44336', alpha=0.08)

if csv_36r:
    t36r, m36r = load_csv(csv_36r)
    ax.plot(t36r, m36r, color='#4CAF50', linewidth=1.5, label='etcd v3.6 (PR#17563 reverted)', alpha=0.9)
    ax.fill_between(t36r, 0, m36r, color='#4CAF50', alpha=0.08)

peak35 = max(m35)
peak35_t = t35[m35.index(peak35)]
peak36 = max(m36)
peak36_t = t36[m36.index(peak36)]

ax.annotate(f'v3.5 peak: {peak35:.0f} MiB',
    xy=(peak35_t, peak35), xytext=(peak35_t + 5, peak35 - 80),
    arrowprops=dict(arrowstyle='->', color='#1565C0', lw=1.2),
    fontsize=9, color='#1565C0', fontweight='bold')
ax.annotate(f'v3.6 peak: {peak36:.0f} MiB',
    xy=(peak36_t, peak36), xytext=(peak36_t + 5, peak36 + 30),
    arrowprops=dict(arrowstyle='->', color='#C62828', lw=1.2),
    fontsize=9, color='#C62828', fontweight='bold')

if csv_36r:
    peak36r = max(m36r)
    peak36r_t = t36r[m36r.index(peak36r)]
    ax.annotate(f'v3.6-reverted peak: {peak36r:.0f} MiB',
        xy=(peak36r_t, peak36r), xytext=(peak36r_t + 5, peak36r - 120),
        arrowprops=dict(arrowstyle='->', color='#2E7D32', lw=1.2),
        fontsize=9, color='#2E7D32', fontweight='bold')

delta = peak36 - peak35
pct = (peak36 / peak35 - 1) * 100 if peak35 > 0 else 0
ax.annotate(f'+{delta:.0f} MiB ({pct:.0f}% more)',
    xy=((peak35_t + peak36_t) / 2, (peak35 + peak36) / 2),
    fontsize=10, color='#E65100', fontweight='bold',
    bbox=dict(boxstyle='round,pad=0.4', facecolor='#FFF3E0', edgecolor='#E65100', alpha=0.9),
    ha='center')

ax.set_xlabel('Time (seconds)', fontsize=11)
ax.set_ylabel('RSS Memory (MiB)', fontsize=11)
bg_count = os.environ.get('BG_KEY_COUNT', '2000')
bg_size_kb = int(os.environ.get('BG_KEY_SIZE', '102400')) // 1024
rc_sleep = os.environ.get('RECONNECT_SLEEP', '20s')
ax.set_title(f'etcd Memory: Watch Reconnect Benchmark (kvsToEvents regression)\n'
             f'{bg_count} bg keys x {bg_size_kb}KiB, '
             f'reconnect-sleep={rc_sleep}',
             fontsize=12, fontweight='bold')
ax.legend(fontsize=11, loc='upper left')
ax.set_ylim(bottom=0)
ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, p: f'{x:.0f}'))
ax.grid(True, alpha=0.3)
plt.tight_layout()
plt.savefig(out_path, dpi=150)
print(f'  Chart saved to {out_path}')
summary = f'  v3.5 peak: {peak35:.0f} MiB   v3.6 peak: {peak36:.0f} MiB   delta: +{delta:.0f} MiB ({pct:.0f}%)'
if csv_36r:
    delta_r = peak36r - peak35
    pct_r = (peak36r / peak35 - 1) * 100 if peak35 > 0 else 0
    summary += f'\n  v3.6-reverted peak: {peak36r:.0f} MiB   delta vs v3.5: +{delta_r:.0f} MiB ({pct_r:.0f}%)'
print(summary)
PYEOF
}

print_summary() {
    echo ""
    echo "========================================="
    echo "  Summary"
    echo "========================================="

    for VER in v3.5 v3.6 v3.6-reverted; do
        local CSV="$OUTDIR/$VER/mem.csv"
        if [ -f "$CSV" ]; then
            local PEAK=$(awk -F, 'NR>1 && $2+0>0{if($2+0>max)max=$2+0}END{print max+0}' "$CSV")
            local PROFILES=$(find "$OUTDIR/$VER/profiles" -name 'heap_*.pb.gz' 2>/dev/null | wc -l)
            echo "  $VER: peak RSS = $((PEAK/1024)) MiB, $PROFILES heap profiles"
        fi
    done

    echo ""
    echo "  Output directory: $OUTDIR"
    echo "  Files per version:"
    echo "    profiles/heap_*.pb.gz    — binary heap profiles (use with go tool pprof)"
    echo "    profiles/heap_*.txt      — text heap profiles (memstats)"
    echo "    mem.csv                  — RSS time series (timestamp_ms, rss_kb)"
    echo "    bench.log                — benchmark stdout"
    echo "    heap-inuse.svg           — full inuse_space flamegraph"
    echo "    heap-kvsToEvents.svg     — inuse_space focused on kvsToEvents/syncWatchers"
    echo "    heap-alloc.svg           — full alloc_space flamegraph"
    echo "    heap-alloc-kvsToEvents.svg — alloc_space focused on kvsToEvents/syncWatchers"
    echo ""
    [ -f "$OUTDIR/memory_comparison.png" ] && echo "  Memory chart: $OUTDIR/memory_comparison.png"
    echo ""
}

# ── Inline the benchmark config into the chart title ─────────────────────────
# The python script uses shell variables via environment
# Extract version labels from binary paths for chart legend
ETCD_V35_LABEL=$(echo "$ETCD_V35" | grep -oP 'v3\.\d+\.\d+' || echo "v3.5")
ETCD_V36_LABEL=$(echo "$ETCD_V36" | grep -oP 'v3\.\d+\.\d+' || echo "v3.6")
export BG_KEY_COUNT BG_KEY_SIZE RECONNECT_SLEEP ETCD_V35_LABEL ETCD_V36_LABEL

# ── Main ─────────────────────────────────────────────────────────────────────

MODE="${1:-all}"

check_prereqs "$MODE"
build_benchmark

case "$MODE" in
    v3.5)
        run_version v3.5 "$ETCD_V35"
        ;;
    v3.6)
        run_version v3.6 "$ETCD_V36"
        ;;
    v3.6-reverted)
        run_version v3.6-reverted "$ETCD_V36_REVERTED"
        ;;
    compare)
        # Skip benchmark runs, just regenerate comparison artifacts
        ;;
    all)
        run_version v3.5 "$ETCD_V35"
        run_version v3.6 "$ETCD_V36"
        run_version v3.6-reverted "$ETCD_V36_REVERTED"
        ;;
    *)
        die "Unknown mode: $MODE (use v3.5, v3.6, v3.6-reverted, compare, or all)"
        ;;
esac

[ "$MODE" != "compare" ] && kill_etcd

generate_svgs
print_pprof_comparison
generate_memory_chart
print_summary
