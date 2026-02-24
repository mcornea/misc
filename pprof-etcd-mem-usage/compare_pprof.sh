#!/usr/bin/env bash
#
# compare_pprof.sh — Generate pprof visualizations comparing two etcd heap
# profile capture directories (e.g. 4.20 vs 4.21).
#
# Produces SVG call graphs, diff views, focused views, text summaries, and
# per-capture memory progression tables.
#
# Requirements:
#   - go (for `go tool pprof`)
#   - graphviz (for SVG/PNG output via `dot`)
#
# Usage:
#   ./compare_pprof.sh <baseline_dir> <target_dir> [output_dir]
#
# Example:
#   ./compare_pprof.sh ./4.20 ./4.21
#   ./compare_pprof.sh ./4.20 ./4.21 ./my-visualizations
#
set -euo pipefail

# ── Args ─────────────────────────────────────────────────────────────────────

BASELINE_DIR="${1:?Usage: $0 <baseline_dir> <target_dir> [output_dir]}"
TARGET_DIR="${2:?Usage: $0 <baseline_dir> <target_dir> [output_dir]}"
OUTPUT_DIR="${3:-./visualizations}"

BASELINE_DIR="$(realpath "$BASELINE_DIR")"
TARGET_DIR="$(realpath "$TARGET_DIR")"

# ── Validate inputs ─────────────────────────────────────────────────────────

for dir in "$BASELINE_DIR" "$TARGET_DIR"; do
    if [[ ! -d "$dir/profiles" ]]; then
        echo "ERROR: $dir/profiles/ not found. Expected pprof capture directory." >&2
        exit 1
    fi
done

if ! command -v go &>/dev/null; then
    echo "ERROR: 'go' not found. Install Go to use go tool pprof." >&2
    exit 1
fi

if ! command -v dot &>/dev/null; then
    echo "WARNING: 'dot' (graphviz) not found. SVG generation will fail." >&2
    echo "         Install with: sudo dnf install graphviz" >&2
    echo "         Text outputs will still be generated." >&2
    HAVE_DOT=false
else
    HAVE_DOT=true
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(realpath "$OUTPUT_DIR")"

# ── Extract version labels from metadata or directory names ──────────────────

extract_label() {
    local dir="$1"
    if [[ -f "$dir/metadata.txt" ]]; then
        local ocp etcd
        ocp=$(grep -oP 'OCP Version: \K.*' "$dir/metadata.txt" 2>/dev/null || true)
        etcd=$(grep -oP 'etcd Version: \K.*' "$dir/metadata.txt" 2>/dev/null || true)
        if [[ -n "$ocp" ]]; then
            echo "OCP ${ocp} (etcd ${etcd:-unknown})"
            return
        fi
    fi
    basename "$dir"
}

extract_short_label() {
    local dir="$1"
    if [[ -f "$dir/metadata.txt" ]]; then
        grep -oP 'OCP Version: \K[\d.]+' "$dir/metadata.txt" 2>/dev/null && return
    fi
    basename "$dir"
}

BASELINE_LABEL=$(extract_label "$BASELINE_DIR")
TARGET_LABEL=$(extract_label "$TARGET_DIR")
BASELINE_SHORT=$(extract_short_label "$BASELINE_DIR")
TARGET_SHORT=$(extract_short_label "$TARGET_DIR")

echo "========================================================================"
echo " pprof Comparison: $BASELINE_LABEL vs $TARGET_LABEL"
echo "========================================================================"
echo ""
echo "  Baseline: $BASELINE_DIR"
echo "  Target:   $TARGET_DIR"
echo "  Output:   $OUTPUT_DIR"
echo ""

# ── Find peak profiles ──────────────────────────────────────────────────────
# Peak = largest .pb.gz file (highest in-use memory at capture time)

find_peak_profile() {
    local dir="$1"
    ls -S "$dir/profiles"/heap_*.pb.gz 2>/dev/null | head -1
}

# Find all unique node IPs from profile filenames
find_nodes() {
    local dir="$1"
    ls "$dir/profiles"/heap_*.pb.gz 2>/dev/null \
        | xargs -I{} basename {} \
        | sed 's/heap_//;s/_[0-9]*.pb.gz//' \
        | sort -u
}

# Find peak profile for a specific node
find_node_peak() {
    local dir="$1" node="$2"
    ls -S "$dir/profiles"/heap_"${node}"_*.pb.gz 2>/dev/null | head -1
}

# Find the node with the most captures (likely the leader / most interesting)
find_primary_node() {
    local dir="$1"
    ls "$dir/profiles"/heap_*.pb.gz 2>/dev/null \
        | xargs -I{} basename {} \
        | sed 's/heap_//;s/_[0-9]*.pb.gz//' \
        | sort | uniq -c | sort -rn | head -1 | awk '{print $2}'
}

BASELINE_PEAK=$(find_peak_profile "$BASELINE_DIR")
TARGET_PEAK=$(find_peak_profile "$TARGET_DIR")

if [[ -z "$BASELINE_PEAK" || -z "$TARGET_PEAK" ]]; then
    echo "ERROR: Could not find .pb.gz profiles in one or both directories." >&2
    exit 1
fi

BASELINE_NODE=$(find_primary_node "$BASELINE_DIR")
TARGET_NODE=$(find_primary_node "$TARGET_DIR")

echo "  Baseline peak: $(basename "$BASELINE_PEAK")"
echo "  Target peak:   $(basename "$TARGET_PEAK")"
echo "  Baseline node: $BASELINE_NODE"
echo "  Target node:   $TARGET_NODE"
echo ""

# ── Find spike profile (largest file for target primary node) ────────────────

TARGET_SPIKE=$(find_node_peak "$TARGET_DIR" "$TARGET_NODE")
if [[ "$TARGET_SPIKE" == "$TARGET_PEAK" ]]; then
    # If the peak IS the spike, look for the second largest
    TARGET_SPIKE=$(ls -S "$TARGET_DIR/profiles"/heap_"${TARGET_NODE}"_*.pb.gz 2>/dev/null | sed -n '2p')
fi

# ── Helper: generate SVG if graphviz available ───────────────────────────────

pprof_svg() {
    local outfile="$1"; shift
    if $HAVE_DOT; then
        go tool pprof -svg "$@" > "$outfile" 2>/dev/null
        echo "  [SVG] $(basename "$outfile")"
    else
        echo "  [SKIP] $(basename "$outfile") (no graphviz)"
    fi
}

# ── 1. Individual profile SVGs ───────────────────────────────────────────────

echo "--- Generating individual profile SVGs ---"

pprof_svg "$OUTPUT_DIR/${BASELINE_SHORT}_peak_inuse_space.svg" \
    -inuse_space "$BASELINE_PEAK"

pprof_svg "$OUTPUT_DIR/${TARGET_SHORT}_peak_inuse_space.svg" \
    -inuse_space "$TARGET_PEAK"

pprof_svg "$OUTPUT_DIR/${BASELINE_SHORT}_peak_alloc_space.svg" \
    -alloc_space "$BASELINE_PEAK"

pprof_svg "$OUTPUT_DIR/${TARGET_SHORT}_peak_alloc_space.svg" \
    -alloc_space "$TARGET_PEAK"

if [[ -n "${TARGET_SPIKE:-}" ]]; then
    pprof_svg "$OUTPUT_DIR/${TARGET_SHORT}_spike_inuse_space.svg" \
        -inuse_space "$TARGET_SPIKE"
fi

# ── 2. Diff SVGs ─────────────────────────────────────────────────────────────

echo ""
echo "--- Generating diff SVGs (target minus baseline) ---"

pprof_svg "$OUTPUT_DIR/diff_${TARGET_SHORT}_vs_${BASELINE_SHORT}_inuse_space.svg" \
    -inuse_space -diff_base "$BASELINE_PEAK" "$TARGET_PEAK"

pprof_svg "$OUTPUT_DIR/diff_${TARGET_SHORT}_vs_${BASELINE_SHORT}_alloc_space.svg" \
    -alloc_space -diff_base "$BASELINE_PEAK" "$TARGET_PEAK"

if [[ -n "${TARGET_SPIKE:-}" ]]; then
    pprof_svg "$OUTPUT_DIR/diff_${TARGET_SHORT}_spike_vs_${BASELINE_SHORT}_inuse_space.svg" \
        -inuse_space -diff_base "$BASELINE_PEAK" "$TARGET_SPIKE"
fi

# ── 3. Focused SVGs (mvcc package, watcher sync path) ────────────────────────

echo ""
echo "--- Generating focused SVGs ---"

pprof_svg "$OUTPUT_DIR/${BASELINE_SHORT}_peak_mvcc_focused.svg" \
    -inuse_space -focus=mvcc "$BASELINE_PEAK"

pprof_svg "$OUTPUT_DIR/${TARGET_SHORT}_peak_mvcc_focused.svg" \
    -inuse_space -focus=mvcc "$TARGET_PEAK"

pprof_svg "$OUTPUT_DIR/${TARGET_SHORT}_peak_watcher_sync_focused.svg" \
    -inuse_space -focus="syncWatchers|rangeEvents|kvsToEvents|KeyValue.*Unmarshal" "$TARGET_PEAK"

# ── 4. Text reports ──────────────────────────────────────────────────────────

echo ""
echo "--- Generating text reports ---"

COMP_FILE="$OUTPUT_DIR/comparison_top.txt"
{
    echo "=== ${BASELINE_LABEL} - Peak Profile - Top 20 (inuse_space) ==="
    go tool pprof -top -inuse_space -nodecount=20 "$BASELINE_PEAK" 2>/dev/null
    echo ""
    echo "=== ${TARGET_LABEL} - Peak Profile - Top 20 (inuse_space) ==="
    go tool pprof -top -inuse_space -nodecount=20 "$TARGET_PEAK" 2>/dev/null
    echo ""
    echo "=== DIFF: ${TARGET_SHORT} minus ${BASELINE_SHORT} - Top 20 (inuse_space) ==="
    go tool pprof -top -inuse_space -nodecount=20 \
        -diff_base "$BASELINE_PEAK" "$TARGET_PEAK" 2>/dev/null
} > "$COMP_FILE"
echo "  [TXT] $(basename "$COMP_FILE")"

if [[ -n "${TARGET_SPIKE:-}" ]]; then
    SPIKE_FILE="$OUTPUT_DIR/${TARGET_SHORT}_spike_top.txt"
    {
        echo "=== ${TARGET_LABEL} - Spike Profile ($(basename "$TARGET_SPIKE")) - Top 20 (inuse_space) ==="
        go tool pprof -top -inuse_space -nodecount=20 "$TARGET_SPIKE" 2>/dev/null
        echo ""
        echo "=== DIFF: ${TARGET_SHORT} Spike minus ${BASELINE_SHORT} Peak (inuse_space) ==="
        go tool pprof -top -inuse_space -nodecount=20 \
            -diff_base "$BASELINE_PEAK" "$TARGET_SPIKE" 2>/dev/null
    } > "$SPIKE_FILE"
    echo "  [TXT] $(basename "$SPIKE_FILE")"
fi

# ── 5. Memory progression tables ─────────────────────────────────────────────

echo ""
echo "--- Generating memory progression tables ---"

# Track functions known to indicate regression and normal operation
TRACK_FUNCTIONS=(
    "mvccpb.*KeyValue.*Unmarshal"
    "raftpb.*Entry.*Unmarshal"
    "lessor.*Attach"
    "freelist.*free|freelist.*Free"
)
TRACK_HEADERS=(
    "mvccpb.KV.Unm"
    "raft.Entry.Unm"
    "lessor.Attach"
    "freelist.free"
)

generate_progression() {
    local dir="$1" node="$2" label="$3" outfile="$4"

    local profiles
    profiles=$(ls "$dir/profiles"/heap_"${node}"_*.pb.gz 2>/dev/null | sort)
    if [[ -z "$profiles" ]]; then
        echo "  [SKIP] No profiles for node $node in $dir"
        return
    fi

    {
        echo "=== ${label} - Node ${node} - In-Use Memory Progression ==="
        echo ""

        # Build header
        printf "%-8s  %12s" "Capture" "Total"
        for h in "${TRACK_HEADERS[@]}"; do
            printf "  %16s" "$h"
        done
        echo ""
        printf '%.0s-' {1..80}
        echo ""

        for f in $profiles; do
            local capture
            capture=$(basename "$f" | sed "s/heap_${node}_//;s/.pb.gz//")
            local output
            output=$(go tool pprof -top -inuse_space "$f" 2>/dev/null)
            local total
            total=$(echo "$output" | grep -oP '[\d.]+MB total' | head -1 | sed 's/ total//' || true)
            [[ -z "$total" ]] && total="N/A"

            printf "%-8s  %12s" "$capture" "$total"
            for pattern in "${TRACK_FUNCTIONS[@]}"; do
                local val
                val=$(echo "$output" | grep -E "$pattern" | awk '{print $1}' | head -1 || true)
                [[ -z "$val" ]] && val="0MB"
                printf "  %16s" "$val"
            done
            echo ""
        done
    } > "$outfile"
    echo "  [TXT] $(basename "$outfile")"
}

generate_progression "$TARGET_DIR" "$TARGET_NODE" "$TARGET_LABEL" \
    "$OUTPUT_DIR/${TARGET_SHORT}_leader_progression.txt"

generate_progression "$BASELINE_DIR" "$BASELINE_NODE" "$BASELINE_LABEL" \
    "$OUTPUT_DIR/${BASELINE_SHORT}_leader_progression.txt"

# Also generate for other nodes if they exist
for node in $(find_nodes "$TARGET_DIR"); do
    [[ "$node" == "$TARGET_NODE" ]] && continue
    generate_progression "$TARGET_DIR" "$node" "$TARGET_LABEL" \
        "$OUTPUT_DIR/${TARGET_SHORT}_${node}_progression.txt"
done

for node in $(find_nodes "$BASELINE_DIR"); do
    [[ "$node" == "$BASELINE_NODE" ]] && continue
    generate_progression "$BASELINE_DIR" "$node" "$BASELINE_LABEL" \
        "$OUTPUT_DIR/${BASELINE_SHORT}_${node}_progression.txt"
done

# ── 6. Combined summary ─────────────────────────────────────────────────────

echo ""
echo "--- Generating combined summary ---"

SUMMARY_FILE="$OUTPUT_DIR/summary.txt"
{
    echo "========================================================================"
    echo " pprof Comparison Summary"
    echo " Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "========================================================================"
    echo ""
    echo "Baseline: $BASELINE_LABEL"
    echo "  Dir:        $BASELINE_DIR"
    echo "  Peak:       $(basename "$BASELINE_PEAK")"
    echo "  Peak size:  $(go tool pprof -top -inuse_space "$BASELINE_PEAK" 2>/dev/null | grep -oP '[\d.]+MB total' | head -1)"
    echo ""
    echo "Target: $TARGET_LABEL"
    echo "  Dir:        $TARGET_DIR"
    echo "  Peak:       $(basename "$TARGET_PEAK")"
    echo "  Peak size:  $(go tool pprof -top -inuse_space "$TARGET_PEAK" 2>/dev/null | grep -oP '[\d.]+MB total' | head -1)"
    if [[ -n "${TARGET_SPIKE:-}" ]]; then
        echo "  Spike:      $(basename "$TARGET_SPIKE")"
        echo "  Spike size: $(go tool pprof -top -inuse_space "$TARGET_SPIKE" 2>/dev/null | grep -oP '[\d.]+MB total' | head -1)"
    fi
    echo ""
    echo "------------------------------------------------------------------------"
    echo " Top 5 Diff (target peak minus baseline peak, inuse_space, flat)"
    echo "------------------------------------------------------------------------"
    go tool pprof -top -inuse_space -nodecount=5 \
        -diff_base "$BASELINE_PEAK" "$TARGET_PEAK" 2>/dev/null \
        | tail -n +3
    echo ""
    echo "------------------------------------------------------------------------"
    echo " Generated Files"
    echo "------------------------------------------------------------------------"
    ls -1 "$OUTPUT_DIR"
} > "$SUMMARY_FILE"
echo "  [TXT] $(basename "$SUMMARY_FILE")"

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "========================================================================"
echo " Done. Output in: $OUTPUT_DIR"
echo "========================================================================"
echo ""
echo "To view SVGs, open in a browser:"
echo "  firefox $OUTPUT_DIR/diff_${TARGET_SHORT}_vs_${BASELINE_SHORT}_inuse_space.svg"
echo ""
echo "Key files:"
echo "  diff_${TARGET_SHORT}_vs_${BASELINE_SHORT}_inuse_space.svg  — visual diff (what grew)"
echo "  comparison_top.txt                                         — text comparison"
echo "  ${TARGET_SHORT}_leader_progression.txt                     — memory over time"
echo "  summary.txt                                                — overview"
