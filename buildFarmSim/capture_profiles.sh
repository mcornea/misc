#!/usr/bin/env bash
#
# capture_profiles.sh — Run buildfarmsim workload and capture heap profiles
# at regular intervals from all etcd nodes throughout the run.
#
# Usage:
#   ./capture_profiles.sh <config.json> <output_dir>
#
set -euo pipefail

CONFIG="${1:?Usage: $0 <config.json> <output_dir>}"
OUTDIR="${2:?Usage: $0 <config.json> <output_dir>}"
PROFILE_DIR="$OUTDIR/profiles"
CAPTURE_INTERVAL=10  # seconds between captures

# Extract cluster size from config
CLUSTER_SIZE=$(python3 -c "import json; print(json.load(open('$CONFIG')).get('clusterSize', 1))")

mkdir -p "$PROFILE_DIR"

# Clean previous state
pkill -9 etcd 2>/dev/null || true
sleep 2
rm -rf data-etcd-* log-*

echo "Starting workload with config: $CONFIG (cluster size: $CLUSTER_SIZE)"
echo "Profiles will be saved to: $PROFILE_DIR"

# Build list of node endpoints
NODES=()
for ((i=0; i<CLUSTER_SIZE; i++)); do
    PORT=$((2379 + i))
    NODES+=("127.0.0.1:${PORT}")
done

# --- Background profile capture ---
capture_profiles() {
    # Wait for etcd to be ready before capturing
    for _ in $(seq 1 30); do
        if curl -s "http://127.0.0.1:2379/version" > /dev/null 2>&1; then
            break
        fi
        sleep 1
    done

    SEQ=0
    while kill -0 "$1" 2>/dev/null; do
        SEQ=$((SEQ + 1))
        PADDED=$(printf "%04d" $SEQ)

        for NODE_ADDR in "${NODES[@]}"; do
            NODE_LABEL=$(echo "$NODE_ADDR" | tr '.:' '-')

            # Capture binary profile
            if curl -s "http://${NODE_ADDR}/debug/pprof/heap" -o "$PROFILE_DIR/heap_${NODE_LABEL}_${PADDED}.pb.gz" 2>/dev/null; then
                SIZE=$(wc -c < "$PROFILE_DIR/heap_${NODE_LABEL}_${PADDED}.pb.gz")
                if [ "$SIZE" -lt 100 ]; then
                    rm -f "$PROFILE_DIR/heap_${NODE_LABEL}_${PADDED}.pb.gz"
                fi
            fi

            # Capture text profile (for memstats extraction)
            if curl -s "http://${NODE_ADDR}/debug/pprof/heap?debug=1" -o "$PROFILE_DIR/heap_${NODE_LABEL}_${PADDED}.txt" 2>/dev/null; then
                SIZE=$(wc -c < "$PROFILE_DIR/heap_${NODE_LABEL}_${PADDED}.txt")
                if [ "$SIZE" -lt 100 ]; then
                    rm -f "$PROFILE_DIR/heap_${NODE_LABEL}_${PADDED}.txt"
                fi
            fi
        done

        sleep "$CAPTURE_INTERVAL"
    done

    echo ""
    echo "Captured $SEQ rounds of profile snapshots."
    echo "Profiles saved to: $PROFILE_DIR"
    echo "Binary profiles per node:"
    for NODE_ADDR in "${NODES[@]}"; do
        NODE_LABEL=$(echo "$NODE_ADDR" | tr '.:' '-')
        COUNT=$(ls "$PROFILE_DIR"/heap_${NODE_LABEL}_*.pb.gz 2>/dev/null | wc -l)
        echo "  $NODE_ADDR: $COUNT profiles"
    done
}

# Start the workload in the foreground, tee output to a log file
timeout 3600 ./buildfarmsim -f "$CONFIG" 2>&1 | tee "$OUTDIR/workload.log" &
BFPID=$!

# Start profile capture in the background
capture_profiles "$BFPID" &
CAPPID=$!

# Wait for the workload to finish, then let the capture loop notice and exit
wait "$BFPID" 2>/dev/null || true
wait "$CAPPID" 2>/dev/null || true
