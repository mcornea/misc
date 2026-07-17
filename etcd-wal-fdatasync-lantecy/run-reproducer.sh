#!/bin/bash
# XFS fdatasync P99 Latency Regression Reproducer
#
# Reproduces the etcd WAL fdatasync P99 regression between RHEL 9 (kernel 5.14)
# and RHEL 10 (kernel 6.12). Uses a Go program that mimics etcd's exact write
# pattern (WAL sequential append + fdatasync, bbolt random pwrite + fdatasync).
#
# Prerequisites:
#   - RHEL 9 or 10 machine (or Fedora with matching kernel)
#   - XFS filesystem (the script finds one automatically or you specify --dir)
#   - Go compiler (golang package)
#   - Root recommended (for XFS log statistics)
#
# Usage:
#   chmod +x run-reproducer.sh
#   sudo ./run-reproducer.sh [--dir /path/on/xfs] [--duration 60s]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DURATION="${1:-60s}"
TEST_DIR=""
OUTPUT_DIR=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dir)      TEST_DIR="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --output)   OUTPUT_DIR="$2"; shift 2 ;;
        *)          shift ;;
    esac
done

# Find an XFS mount if not specified
if [[ -z "$TEST_DIR" ]]; then
    XFS_MOUNT=$(findmnt -t xfs -n -o TARGET | head -1)
    if [[ -z "$XFS_MOUNT" ]]; then
        echo "ERROR: No XFS filesystem found. Use --dir /path/on/xfs" >&2
        exit 1
    fi
    TEST_DIR="${XFS_MOUNT}/xfs-fdatasync-repro"
    echo "Auto-detected XFS mount: $XFS_MOUNT"
fi

KERNEL=$(uname -r)
HOSTNAME=$(hostname -s 2>/dev/null || cat /etc/hostname 2>/dev/null || echo "unknown")

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="${SCRIPT_DIR}/results-${HOSTNAME}-${KERNEL}"
fi
mkdir -p "$OUTPUT_DIR"

echo "=========================================================================="
echo "  XFS fdatasync P99 Latency Regression Reproducer"
echo "  Simulates etcd WAL + bbolt write pattern"
echo "=========================================================================="
echo
echo "  Kernel:     $KERNEL"
echo "  Host:       $HOSTNAME"
echo "  Test dir:   $TEST_DIR"
echo "  Output:     $OUTPUT_DIR"
echo "  Duration:   $DURATION"
echo

# Build the Go reproducer
BINARY="${SCRIPT_DIR}/fdatasync-repro"
if [[ ! -f "$BINARY" ]] || [[ "$SCRIPT_DIR/main.go" -nt "$BINARY" ]]; then
    echo "--- Building Go reproducer ---"
    if ! command -v go &>/dev/null; then
        echo "ERROR: Go compiler not found. Install with: dnf install -y golang" >&2
        exit 1
    fi
    (cd "$SCRIPT_DIR" && go build -o fdatasync-repro .)
    echo "  Built: $BINARY"
    echo
fi

# Phase 1: Baseline (WAL + bbolt, no background IO)
echo "=== Phase 1: Baseline (WAL + bbolt, no background contention) ==="
echo "  WAL: 500 fdatasyncs/s, 2300B sequential append"
echo "  bbolt: commit every 100ms, 20 × 4KB random pages"
echo "  Duration: $DURATION"
echo

"$BINARY" \
    --dir "$TEST_DIR" \
    --duration "$DURATION" \
    --wal-rate 500 \
    --bg-writers 0 \
    2>&1 | tee "$OUTPUT_DIR/phase1-baseline.txt"

echo
echo

# Phase 2: With background IO contention (simulates cluster activity)
echo "=== Phase 2: With background IO contention ==="
echo "  Same as Phase 1, plus 40 background writers competing for XFS log"
echo "  (simulates kubelet, apiserver, CRI-O, OVN IO on the same XFS filesystem)"
echo "  40 bg-writers needed to generate enough CIL contention on 4-CPU nodes"
echo "  Duration: $DURATION"
echo

"$BINARY" \
    --dir "$TEST_DIR" \
    --duration "$DURATION" \
    --wal-rate 500 \
    --bg-writers 40 \
    2>&1 | tee "$OUTPUT_DIR/phase2-contention.txt"

echo
echo

# Phase 3: High proposal rate (simulates cluster-density-v2 peak)
echo "=== Phase 3: High proposal rate (cluster-density peak simulation) ==="
echo "  WAL: 1000 fdatasyncs/s (peak rate during cluster-density-v2)"
echo "  bbolt: commit every 100ms, 40 × 4KB random pages"
echo "  Background: 40 writers"
echo "  Duration: $DURATION"
echo

"$BINARY" \
    --dir "$TEST_DIR" \
    --duration "$DURATION" \
    --wal-rate 1000 \
    --bbolt-pages 40 \
    --bg-writers 40 \
    2>&1 | tee "$OUTPUT_DIR/phase3-peak.txt"

echo
echo "=========================================================================="
echo "  All results saved to: $OUTPUT_DIR/"
echo "=========================================================================="
echo
echo "  To compare kernels, run this script on both RHEL 9 and RHEL 10 machines"
echo "  and compare the WAL P99 latency between the two."
echo
echo "  Expected regression signature (40 bg-writers, 4 CPUs):"
echo "    RHEL 9  (kernel 5.14): WAL P99 ~7-9ms,  >5ms ~10-23%, >10ms < 0.5%"
echo "    RHEL 10 (kernel 6.12): WAL P99 ~10-11ms, >5ms ~49%,   >10ms ~1-2%"
echo "    Regression is FIPS-independent (confirmed on both FIPS and non-FIPS clusters)"
echo
echo "  Root cause: XFS CIL per-CPU rework + async flush removal + push serialization"
echo "  Commits: c0fb4765c508, 919edbadebe1, 39823d0fac94"
