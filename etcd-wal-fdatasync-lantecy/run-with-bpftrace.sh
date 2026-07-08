#!/bin/bash
set -euo pipefail

###############################################################################
# Run the Go fdatasync reproducer with bpftrace to validate the kernel
# function breakdown matches cluster-density-v2 tracing.
#
# Expected pattern on kernel 6.12 (el10):
#   SLOW fdatasyncs dominated by xlog_force_lsn (up to 10ms) and
#   xlog_cil_force_seq (up to 9ms) — same as etcd WAL during cluster-density.
#
# Expected pattern on kernel 5.14 (el9):
#   Fewer slow events, shorter xlog_force/cil_force contributions.
#
# Prerequisites:
#   - Root access
#   - XFS filesystem at TEST_DIR
#   - bpftrace installed
#   - Go reproducer binary (will build if not present)
#
# Usage:
#   sudo ./run-with-bpftrace.sh [--test-dir /path/on/xfs] [--runtime 30]
#
# On OCP cluster nodes via privileged pod:
#   # Copy this script and the binary to the node
#   oc cp run-with-bpftrace.sh <pod>:/tmp/
#   oc cp fdatasync-repro <pod>:/tmp/
#   oc exec <pod> -- bash /tmp/run-with-bpftrace.sh --test-dir /var/tmp/xfs-test
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="/var/tmp/xfs-fdatasync-test"
RUNTIME=30
BINARY="${SCRIPT_DIR}/fdatasync-repro"
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --test-dir)   TEST_DIR="$2"; shift 2 ;;
    --runtime)    RUNTIME="$2"; shift 2 ;;
    --binary)     BINARY="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help)    sed -n '2,/^###/p' "$0" | head -n -1 | sed 's/^# \?//'; exit 0 ;;
    *)            echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="${SCRIPT_DIR}/bpftrace-validation-$(date +%Y%m%d-%H%M%S)"
fi
mkdir -p "$OUTPUT_DIR"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$OUTPUT_DIR/run.log"; }
die() { log "ERROR: $*"; exit 1; }

# --- Preflight ---
[[ $(id -u) -eq 0 ]] || die "Must run as root"
command -v bpftrace &>/dev/null || die "bpftrace not found (dnf install -y bpftrace)"

mkdir -p "$TEST_DIR"
FS_TYPE=$(stat -f -c %T "$TEST_DIR" 2>/dev/null || df -T "$TEST_DIR" | tail -1 | awk '{print $2}')
[[ "$FS_TYPE" == "xfs" ]] || die "Test directory $TEST_DIR is on $FS_TYPE, not XFS"

# Build if needed
if [[ ! -x "$BINARY" ]]; then
  if command -v go &>/dev/null && [[ -f "${SCRIPT_DIR}/main.go" ]]; then
    log "Building reproducer..."
    (cd "$SCRIPT_DIR" && go build -o fdatasync-repro)
  else
    die "Binary not found at $BINARY and cannot build (no go compiler or main.go)"
  fi
fi

KERNEL=$(uname -r)
CPU_COUNT=$(nproc)

log "=== fdatasync Reproducer + bpftrace Validation ==="
log "Kernel:   $KERNEL"
log "CPUs:     $CPU_COUNT"
log "Test dir: $TEST_DIR (XFS)"
log "Runtime:  ${RUNTIME}s"
log "Binary:   $BINARY"
log "Output:   $OUTPUT_DIR"
log ""

# --- Write bpftrace script ---
# Traces the Go reproducer's fdatasync calls with XFS kernel breakdown.
# Go binaries have comm truncated to 15 chars. We match on PID instead
# to avoid truncation issues.

cat > "$OUTPUT_DIR/repro-breakdown.bt" << 'BTEOF'
BEGIN {
  printf("Tracing fdatasync for PID %d...\n", $1);
  @slow_threshold = 5000;
}

tracepoint:syscalls:sys_enter_fdatasync /pid == $1/ {
  @fds_start[tid] = nsecs;
}

kprobe:__filemap_fdatawrite_range /pid == $1/ { @fdw_start[tid] = nsecs; }
kretprobe:__filemap_fdatawrite_range /pid == $1 && @fdw_start[tid]/ {
  @fdw_lat[tid] = nsecs - @fdw_start[tid];
  delete(@fdw_start[tid]);
}

kprobe:xlog_force_lsn /pid == $1/ { @xlf_start[tid] = nsecs; }
kretprobe:xlog_force_lsn /pid == $1 && @xlf_start[tid]/ {
  @xlf_lat[tid] = nsecs - @xlf_start[tid];
  delete(@xlf_start[tid]);
}

kprobe:xlog_wait_on_iclog /pid == $1/ { @iw_start[tid] = nsecs; }
kretprobe:xlog_wait_on_iclog /pid == $1 && @iw_start[tid]/ {
  @iw_lat[tid] = nsecs - @iw_start[tid];
  delete(@iw_start[tid]);
}

kprobe:xlog_sync /pid == $1/ { @xs_start[tid] = nsecs; }
kretprobe:xlog_sync /pid == $1 && @xs_start[tid]/ {
  @xs_lat[tid] = nsecs - @xs_start[tid];
  delete(@xs_start[tid]);
}

kprobe:xlog_cil_force_seq /pid == $1/ { @cf_start[tid] = nsecs; }
kretprobe:xlog_cil_force_seq /pid == $1 && @cf_start[tid]/ {
  @cf_lat[tid] = nsecs - @cf_start[tid];
  delete(@cf_start[tid]);
}

tracepoint:syscalls:sys_exit_fdatasync /pid == $1 && @fds_start[tid]/ {
  $total = nsecs - @fds_start[tid];
  $total_us = $total / 1000;

  @fdatasync_hist = hist($total_us);
  @fds_count++;

  $xlf_us = @xlf_lat[tid] / 1000;
  $iw_us = @iw_lat[tid] / 1000;
  $xs_us = @xs_lat[tid] / 1000;
  $cf_us = @cf_lat[tid] / 1000;
  $fdw_us = @fdw_lat[tid] / 1000;

  if ($total_us > @slow_threshold) { @slow_count++; }

  if ($total_us > 5000) {
    @veryslow_count++;
    printf("SLOW fdatasync #%d: tid=%d total=%dus  fdatawrite=%dus  xlog_force=%dus  cil_force=%dus  iclog_wait=%dus  xlog_sync=%dus\n",
      @veryslow_count, tid, $total_us, $fdw_us, $xlf_us, $cf_us, $iw_us, $xs_us);
  }

  if ($xlf_us > 0) {
    @xlog_force_hist = hist($xlf_us);
    @xlog_force_count++;
  }
  if ($iw_us > 0) { @iclog_wait_hist = hist($iw_us); }
  if ($cf_us > 0) { @cil_force_hist = hist($cf_us); }
  if ($fdw_us > 0) { @writeback_hist = hist($fdw_us); }

  delete(@fds_start[tid]);
  delete(@xlf_lat[tid]);
  delete(@iw_lat[tid]);
  delete(@xs_lat[tid]);
  delete(@cf_lat[tid]);
  delete(@fdw_lat[tid]);
}

interval:s:__RUNTIME__ { exit(); }

END {
  printf("\n=== bpftrace summary ===\n");
  printf("Total fdatasyncs:   %d\n", @fds_count);
  printf("Slow (>5ms):        %d\n", @slow_count);
  printf("Very slow (>5ms):   %d\n", @veryslow_count);
  printf("XFS log forces:     %d\n", @xlog_force_count);
  printf("\n--- fdatasync total latency (us) ---\n");
  print(@fdatasync_hist);
  printf("\n--- xlog_force_lsn latency (us) ---\n");
  print(@xlog_force_hist);
  printf("\n--- xlog_wait_on_iclog latency (us) ---\n");
  print(@iclog_wait_hist);
  printf("\n--- xlog_cil_force_seq latency (us) ---\n");
  print(@cil_force_hist);
  printf("\n--- __filemap_fdatawrite_range latency (us) ---\n");
  print(@writeback_hist);

  clear(@fds_start); clear(@fds_count); clear(@slow_count); clear(@veryslow_count);
  clear(@fdw_start); clear(@fdw_lat); clear(@xlf_start); clear(@xlf_lat);
  clear(@iw_start); clear(@iw_lat); clear(@xs_start); clear(@xs_lat);
  clear(@cf_start); clear(@cf_lat);
  clear(@xlog_force_count); clear(@slow_threshold);
  clear(@fdatasync_hist); clear(@xlog_force_hist); clear(@iclog_wait_hist);
  clear(@cil_force_hist); clear(@writeback_hist);
}
BTEOF

sed -i "s/__RUNTIME__/$((RUNTIME + 5))/" "$OUTPUT_DIR/repro-breakdown.bt"

# --- Capture XFS stats before ---
if [[ -f /proc/fs/xfs/stat ]]; then
  echo 1 > /proc/sys/fs/xfs/stats_clear 2>/dev/null || true
fi

# --- Start reproducer in background ---
log "Starting Go reproducer (${RUNTIME}s + warmup)..."

"$BINARY" \
  -dir "$TEST_DIR" \
  -duration "$((RUNTIME + 5))s" \
  -wal-rate 300 \
  -bg-writers 40 \
  -bg-syncers 0 \
  -bg-interval 1ms \
  > "$OUTPUT_DIR/repro-output.txt" 2>&1 &
REPRO_PID=$!

log "Reproducer PID: $REPRO_PID"
sleep 2

# Verify it's running
if ! kill -0 "$REPRO_PID" 2>/dev/null; then
  log "Reproducer failed to start. Output:"
  cat "$OUTPUT_DIR/repro-output.txt" | tee -a "$OUTPUT_DIR/run.log"
  die "Reproducer exited immediately"
fi

# --- Run bpftrace ---
log "Starting bpftrace (tracing PID $REPRO_PID for $((RUNTIME + 5))s)..."

bpftrace -p "$REPRO_PID" "$OUTPUT_DIR/repro-breakdown.bt" "$REPRO_PID" \
  > "$OUTPUT_DIR/bpftrace-output.txt" 2>"$OUTPUT_DIR/bpftrace-warnings.txt" || true

# Wait for reproducer to finish
wait "$REPRO_PID" 2>/dev/null || true

log ""
log "=== Reproducer Output ==="
cat "$OUTPUT_DIR/repro-output.txt" | tee -a "$OUTPUT_DIR/run.log"

log ""
log "=== bpftrace Results ==="

SLOW_COUNT=$(grep -c "^SLOW" "$OUTPUT_DIR/bpftrace-output.txt" 2>/dev/null || echo 0)
log "Slow fdatasync events (>5ms): $SLOW_COUNT"
log ""

# Show slow events
if [[ "$SLOW_COUNT" -gt 0 ]]; then
  log "--- Individual slow events ---"
  grep "^SLOW" "$OUTPUT_DIR/bpftrace-output.txt" | tee -a "$OUTPUT_DIR/run.log"
  log ""
fi

# Show bpftrace summary
sed -n '/=== bpftrace summary ===/,$ p' "$OUTPUT_DIR/bpftrace-output.txt" | tee -a "$OUTPUT_DIR/run.log"

# --- XFS stats ---
log ""
if [[ -f /proc/fs/xfs/stat ]]; then
  IFS=" " read -ra L <<< "$(grep "^log " /proc/fs/xfs/stat)"
  log "XFS log stats:"
  log "  log_writes:      ${L[1]}"
  log "  log_blocks:      ${L[2]}"
  log "  log_noiclogs:    ${L[3]}"
  log "  log_force:       ${L[4]}"
  log "  log_force_sleep: ${L[5]}"
  if [[ ${L[4]} -gt 0 ]]; then
    RATIO=$(awk "BEGIN{printf \"%.1f\", ${L[5]} * 100.0 / ${L[4]}}")
    log "  sleep/force:     ${RATIO}%"
  fi
fi

# --- Comparison with cluster-density ---
log ""
log "================================================================"
log "VALIDATION CHECKLIST"
log "================================================================"
log ""
log "Compare against cluster-density-v2 bpftrace (bpftrace-correlated-el10.txt):"
log ""
log "  Cluster-density el10 pattern:"
log "    - 38 slow events (>5ms) in 30s"
log "    - xlog_force_lsn: up to 10105us (dominant bottleneck)"
log "    - xlog_cil_force_seq: up to 9068us (CIL push serialization)"
log "    - fdatawrite: <600us (not the bottleneck)"
log "    - Total slow events: 5-16ms range"
log ""
log "  Cluster-density el9 pattern:"
log "    - 46 slow events (>5ms) in 30s (more but shorter)"
log "    - xlog_force_lsn: up to 3599us (much lower)"
log "    - xlog_cil_force_seq: up to 3855us (lower)"
log "    - Max total: ~10ms (vs 16ms on el10)"
log ""
log "  Key regression signatures to check:"
log "    [1] xlog_force_lsn histogram shifted right on el10 vs el9"
log "    [2] xlog_cil_force_seq has high-latency outliers on el10"
log "    [3] >10ms events present on el10 but rare/absent on el9"
log "    [4] fdatawrite stays small on both (not the bottleneck)"
log ""
log "Results saved to: $OUTPUT_DIR/"

# Cleanup
rm -rf "$TEST_DIR"
