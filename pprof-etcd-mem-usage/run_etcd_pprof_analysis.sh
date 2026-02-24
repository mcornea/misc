#!/bin/bash
# =============================================================================
# etcd Heap Profile Continuous Capture
# =============================================================================
# Usage: ./run_etcd_pprof_analysis.sh [--output-dir DIR] [--interval SECS]
#
# Captures pprof heap profiles (binary + text) and /proc/1/status from all
# etcd pods every minute (or custom interval) until stopped with Ctrl+C.
# Also runs a background memory monitor (30s intervals) throughout.
# On exit (Ctrl+C), produces a summary analysis of all captured data.
#
# Run kube-burner separately in another terminal — this script just captures.
#
# Requirements:
#   - oc (logged into the target cluster)
#   - go (optional, for `go tool pprof` analysis at the end)
# =============================================================================
set -uo pipefail

# --------------- Configuration ---------------
OUTPUT_DIR=""
CAPTURE_INTERVAL=60
MONITOR_INTERVAL=30

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --interval)   CAPTURE_INTERVAL="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

OUTPUT_DIR="${OUTPUT_DIR:-$(pwd)/pprof-analysis-$(date +%Y%m%d-%H%M%S)}"

# --------------- Preflight checks ---------------
echo "=============================================="
echo " etcd pprof Continuous Capture"
echo "=============================================="
echo ""

if ! command -v oc &>/dev/null; then
    echo "ERROR: 'oc' not found in PATH" >&2; exit 1
fi
if ! oc whoami &>/dev/null; then
    echo "ERROR: Not logged into an OpenShift cluster" >&2; exit 1
fi

# --------------- Discover cluster info ---------------
echo "[*] Discovering cluster info..."
OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
CLUSTER_NAME=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}' 2>/dev/null || echo "unknown")
echo "    Cluster: $CLUSTER_NAME"
echo "    OCP Version: $OCP_VERSION"

# --------------- Discover etcd pods ---------------
echo "[*] Discovering etcd pods..."
mapfile -t ETCD_PODS < <(oc get pods -n openshift-etcd -l app=etcd -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort)

if [[ ${#ETCD_PODS[@]} -eq 0 ]]; then
    echo "ERROR: No etcd pods found" >&2; exit 1
fi

echo "    Found ${#ETCD_PODS[@]} etcd pods:"
declare -A POD_NODES
declare -A POD_IPS
declare -A NODE_SHORT

for POD in "${ETCD_PODS[@]}"; do
    NODE=$(oc get pod -n openshift-etcd "$POD" -o jsonpath='{.spec.nodeName}')
    IP=$(oc get pod -n openshift-etcd "$POD" -o jsonpath='{.status.podIP}')
    SHORT=$(echo "$IP" | tr '.' '-')
    POD_NODES["$POD"]="$NODE"
    POD_IPS["$POD"]="$IP"
    NODE_SHORT["$POD"]="$SHORT"
    echo "    - $POD  (node=$NODE, ip=$IP)"
done

# --------------- Check etcd version ---------------
FIRST_POD="${ETCD_PODS[0]}"
ETCD_VERSION_INFO=$(oc exec -n openshift-etcd "$FIRST_POD" -c etcd -- etcd --version 2>&1 || true)
ETCD_VERSION=$(echo "$ETCD_VERSION_INFO" | grep 'etcd Version' | awk '{print $NF}')
GO_VERSION=$(echo "$ETCD_VERSION_INFO" | grep 'Go Version' | sed 's/Go Version: //')
echo ""
echo "    etcd Version: $ETCD_VERSION"
echo "    Go Version: $GO_VERSION"

# --------------- Verify pprof endpoint ---------------
echo ""
echo "[*] Verifying pprof endpoint on $FIRST_POD..."
NODE="${POD_NODES[$FIRST_POD]}"
TEST_RESULT=$(oc exec -n openshift-etcd "$FIRST_POD" -c etcd -- sh -c \
    "curl -s -o /dev/null -w '%{http_code}' \
     --cacert /etc/kubernetes/static-pod-certs/configmaps/etcd-all-bundles/server-ca-bundle.crt \
     --cert /etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${NODE}.crt \
     --key /etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${NODE}.key \
     https://localhost:2379/debug/pprof/heap" 2>&1)

if [[ "$TEST_RESULT" != "200" ]]; then
    echo "ERROR: pprof endpoint returned HTTP $TEST_RESULT" >&2
    echo "  Tried cert: etcd-peer-${NODE}" >&2
    exit 1
fi
echo "    pprof endpoint OK (HTTP 200)"

# --------------- Create output directories ---------------
echo ""
echo "[*] Output directory: $OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR/profiles"

# Save metadata
cat > "$OUTPUT_DIR/metadata.txt" <<METADATA
Date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
Cluster: $CLUSTER_NAME
OCP Version: $OCP_VERSION
etcd Version: $ETCD_VERSION
Go Version: $GO_VERSION
etcd Pods: ${ETCD_PODS[*]}
Capture Interval: ${CAPTURE_INTERVAL}s
Script: $0
METADATA

# =============================================================================
# Helper: capture_profiles <output_dir> <label>
# =============================================================================
capture_profiles() {
    local OUTDIR="$1"
    local LABEL="$2"
    local PROC_FILE="${OUTDIR}/proc_status_${LABEL}.txt"
    mkdir -p "$OUTDIR"
    > "$PROC_FILE"

    for POD in "${ETCD_PODS[@]}"; do
        local NODE="${POD_NODES[$POD]}"
        local SHORT="${NODE_SHORT[$POD]}"
        local TS
        TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

        # Binary heap profile
        oc exec -n openshift-etcd "$POD" -c etcd -- sh -c \
          "curl -s --cacert /etc/kubernetes/static-pod-certs/configmaps/etcd-all-bundles/server-ca-bundle.crt \
           --cert /etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${NODE}.crt \
           --key /etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${NODE}.key \
           https://localhost:2379/debug/pprof/heap" > "${OUTDIR}/heap_${SHORT}_${LABEL}.pb.gz"

        # Text heap profile (debug=1)
        oc exec -n openshift-etcd "$POD" -c etcd -- sh -c \
          "curl -s --cacert /etc/kubernetes/static-pod-certs/configmaps/etcd-all-bundles/server-ca-bundle.crt \
           --cert /etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${NODE}.crt \
           --key /etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-${NODE}.key \
           'https://localhost:2379/debug/pprof/heap?debug=1'" > "${OUTDIR}/heap_${SHORT}_${LABEL}.txt"

        # /proc/1/status
        {
            echo "--- $POD ($SHORT) at $TS ---"
            oc exec -n openshift-etcd "$POD" -c etcd -- cat /proc/1/status
            echo ""
        } >> "$PROC_FILE"
    done
}

# =============================================================================
# Background memory monitor
# =============================================================================
MONITOR_PID=""
start_memory_monitor() {
    local TSV="$OUTPUT_DIR/memory_monitor.tsv"
    echo -e "timestamp\tpod\tVmRSS_kB\tVmHWM_kB\tRssAnon_kB\tRssFile_kB" > "$TSV"

    (
        while true; do
            local TS
            TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
            for POD in "${ETCD_PODS[@]}"; do
                local STATUS
                STATUS=$(oc exec -n openshift-etcd "$POD" -c etcd -- cat /proc/1/status 2>/dev/null || echo "ERROR")
                if [[ "$STATUS" == "ERROR" ]]; then
                    echo -e "${TS}\t${POD}\tERROR\tERROR\tERROR\tERROR" >> "$TSV"
                    continue
                fi
                local VMRSS VMHWM RSSANON RSSFILE
                VMRSS=$(echo "$STATUS" | awk '/^VmRSS:/{print $2}')
                VMHWM=$(echo "$STATUS" | awk '/^VmHWM:/{print $2}')
                RSSANON=$(echo "$STATUS" | awk '/^RssAnon:/{print $2}')
                RSSFILE=$(echo "$STATUS" | awk '/^RssFile:/{print $2}')
                echo -e "${TS}\t${POD}\t${VMRSS}\t${VMHWM}\t${RSSANON}\t${RSSFILE}" >> "$TSV"
            done
            sleep "$MONITOR_INTERVAL"
        done
    ) &
    MONITOR_PID=$!
    echo "    Monitor PID: $MONITOR_PID"
}

# =============================================================================
# Analysis helpers (run on Ctrl+C exit)
# =============================================================================
extract_memstats() {
    local SUMMARY="$OUTPUT_DIR/memstats_summary.tsv"
    echo -e "capture\tnode\tHeapAlloc_MiB\tHeapInuse_MiB\tHeapSys_MiB\tHeapIdle_MiB\tHeapReleased_MiB\tStack_MiB\tSys_MiB\tNumGC" > "$SUMMARY"

    for TXT in "$OUTPUT_DIR"/profiles/heap_*_*.txt; do
        [[ -f "$TXT" ]] || continue
        local FNAME
        FNAME=$(basename "$TXT" .txt)
        local NODE_S LABEL
        NODE_S=$(echo "$FNAME" | sed 's/^heap_//;s/_[^_]*$//')
        LABEL=$(echo "$FNAME" | sed 's/.*_//')

        local HA HI HS HID HR ST SY NGC
        HA=$(awk '/^# HeapAlloc =/{printf "%.1f", $4/1048576}' "$TXT")
        HI=$(awk '/^# HeapInuse =/{printf "%.1f", $4/1048576}' "$TXT")
        HS=$(awk '/^# HeapSys =/{printf "%.1f", $4/1048576}' "$TXT")
        HID=$(awk '/^# HeapIdle =/{printf "%.1f", $4/1048576}' "$TXT")
        HR=$(awk '/^# HeapReleased =/{printf "%.1f", $4/1048576}' "$TXT")
        ST=$(awk '/^# Stack =/{printf "%.1f", $4/1048576}' "$TXT")
        SY=$(awk '/^# Sys =/{printf "%.1f", $4/1048576}' "$TXT")
        NGC=$(awk '/^# NumGC =/{print $4}' "$TXT")

        echo -e "${LABEL}\t${NODE_S}\t${HA}\t${HI}\t${HS}\t${HID}\t${HR}\t${ST}\t${SY}\t${NGC}" >> "$SUMMARY"
    done
    echo "    MemStats summary: $SUMMARY"
}

extract_proc_summary() {
    local SUMMARY="$OUTPUT_DIR/proc_status_summary.txt"
    {
        printf "%-12s %-18s %10s %10s %12s %12s\n" "Capture" "Node" "VmRSS_GiB" "VmHWM_GiB" "RssAnon_GiB" "RssFile_GiB"
        printf "%s\n" "$(printf '%.0s-' {1..80})"

        for PROC in "$OUTPUT_DIR"/profiles/proc_status_*.txt; do
            [[ -f "$PROC" ]] || continue
            local FNAME PHASE
            FNAME=$(basename "$PROC" .txt)
            PHASE=$(echo "$FNAME" | sed 's/proc_status_//')

            local CURRENT_SHORT="" RSS="" HWM="" ANON="" RFILE=""
            while IFS= read -r line; do
                if [[ "$line" == ---* ]]; then
                    CURRENT_SHORT=$(echo "$line" | sed 's/.*(\(.*\)) .*/\1/')
                elif [[ "$line" == VmRSS:* ]]; then
                    RSS=$(echo "$line" | awk '{printf "%.2f", $2/1048576}')
                elif [[ "$line" == VmHWM:* ]]; then
                    HWM=$(echo "$line" | awk '{printf "%.2f", $2/1048576}')
                elif [[ "$line" == RssAnon:* ]]; then
                    ANON=$(echo "$line" | awk '{printf "%.2f", $2/1048576}')
                elif [[ "$line" == RssFile:* ]]; then
                    RFILE=$(echo "$line" | awk '{printf "%.2f", $2/1048576}')
                    printf "%-12s %-18s %10s %10s %12s %12s\n" "$PHASE" "$CURRENT_SHORT" "$RSS" "$HWM" "$ANON" "$RFILE"
                fi
            done < "$PROC"
        done
    } > "$SUMMARY"
    echo "    Proc status summary: $SUMMARY"
}

analyze_monitor() {
    local TSV="$OUTPUT_DIR/memory_monitor.tsv"
    local SUMMARY="$OUTPUT_DIR/memory_monitor_summary.txt"
    [[ -f "$TSV" ]] || return

    {
        echo "================================================================================"
        echo " Memory Monitor Summary"
        echo "================================================================================"
        echo ""
        local FIRST_TS LAST_TS LINES
        FIRST_TS=$(awk 'NR==2{print $1}' "$TSV")
        LAST_TS=$(tail -1 "$TSV" | awk '{print $1}')
        LINES=$(( $(wc -l < "$TSV") - 1 ))
        echo "  First: $FIRST_TS"
        echo "  Last:  $LAST_TS"
        echo "  Samples: $LINES"
        echo ""

        echo "  Per-pod peak VmRSS (kB -> GiB):"
        for POD in "${ETCD_PODS[@]}"; do
            local PEAK_LINE
            PEAK_LINE=$(grep "$POD" "$TSV" | grep -v ERROR | sort -t$'\t' -k3 -rn | head -1)
            local PEAK_TS PEAK_RSS PEAK_GIB
            PEAK_TS=$(echo "$PEAK_LINE" | awk -F'\t' '{print $1}')
            PEAK_RSS=$(echo "$PEAK_LINE" | awk -F'\t' '{print $3}')
            PEAK_GIB=$(echo "$PEAK_RSS" | awk '{printf "%.2f", $1/1048576}')
            echo "    $POD: ${PEAK_GIB} GiB (${PEAK_RSS} kB) at ${PEAK_TS}"
        done
        echo ""

        echo "  Top 10 highest VmRSS readings:"
        tail -n +2 "$TSV" | grep -v ERROR | sort -t$'\t' -k3 -rn | head -10 | \
            awk -F'\t' '{printf "    %s  %-50s  %10s kB  (%.2f GiB)\n", $1, $2, $3, $3/1048576}'
    } > "$SUMMARY"
    echo "    Monitor summary: $SUMMARY"
}

run_pprof_top() {
    local TOPFILE="$OUTPUT_DIR/top_allocations.txt"

    if ! command -v go &>/dev/null; then
        echo "    SKIP: 'go' not in PATH, cannot run pprof top analysis" | tee "$TOPFILE"
        return
    fi

    {
        echo "================================================================================"
        echo " Top Heap Allocators (go tool pprof -top -inuse_space)"
        echo "================================================================================"

        # Find the peak profile: largest .pb.gz
        local PEAK_PROFILE=""
        local PEAK_SIZE=0
        for PB in "$OUTPUT_DIR"/profiles/heap_*_*.pb.gz; do
            [[ -f "$PB" ]] || continue
            local SZ
            SZ=$(stat -c%s "$PB" 2>/dev/null || stat -f%z "$PB" 2>/dev/null || echo 0)
            if (( SZ > PEAK_SIZE )); then
                PEAK_SIZE=$SZ
                PEAK_PROFILE="$PB"
            fi
        done

        if [[ -z "$PEAK_PROFILE" ]]; then
            echo "  No profiles found"
            return
        fi

        echo ""
        echo "--- Peak profile: $(basename "$PEAK_PROFILE") ---"
        echo ""
        go tool pprof -top -inuse_space "$PEAK_PROFILE" 2>&1 || echo "(pprof failed)"
    } > "$TOPFILE" 2>&1
    echo "    Top allocations: $TOPFILE"
}

save_etcd_logs() {
    echo "[*] Saving etcd logs..."
    for POD in "${ETCD_PODS[@]}"; do
        local SHORT="${NODE_SHORT[$POD]}"
        oc logs -n openshift-etcd "$POD" -c etcd --since-time="$START_TS" \
            > "$OUTPUT_DIR/etcd_log_${SHORT}.json" 2>&1 || true
        local LINES
        LINES=$(wc -l < "$OUTPUT_DIR/etcd_log_${SHORT}.json")
        echo "    $SHORT: $LINES lines"
    done
}

generate_report() {
    local REPORT="$OUTPUT_DIR/analysis_report.txt"
    local CAPTURE_COUNT
    CAPTURE_COUNT=$(ls "$OUTPUT_DIR"/profiles/proc_status_*.txt 2>/dev/null | wc -l)
    {
        echo "================================================================================"
        echo " etcd Heap Profile Analysis Report"
        echo "================================================================================"
        echo ""
        echo "Cluster:        $CLUSTER_NAME"
        echo "OCP Version:    $OCP_VERSION"
        echo "etcd Version:   $ETCD_VERSION"
        echo "Go Version:     $GO_VERSION"
        echo "Start:          $START_TS"
        echo "End:            $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "Interval:       ${CAPTURE_INTERVAL}s"
        echo "Captures:       $CAPTURE_COUNT"
        echo ""
        echo "================================================================================"
        echo " RSS Memory Timeline (/proc/1/status)"
        echo "================================================================================"
        echo ""
        cat "$OUTPUT_DIR/proc_status_summary.txt" 2>/dev/null || echo "(not available)"
        echo ""
        echo "================================================================================"
        echo " Go Heap MemStats"
        echo "================================================================================"
        echo ""
        column -t -s$'\t' "$OUTPUT_DIR/memstats_summary.tsv" 2>/dev/null || \
            cat "$OUTPUT_DIR/memstats_summary.tsv" 2>/dev/null || echo "(not available)"
        echo ""
        echo "================================================================================"
        echo " Memory Monitor (${MONITOR_INTERVAL}s sampling)"
        echo "================================================================================"
        echo ""
        cat "$OUTPUT_DIR/memory_monitor_summary.txt" 2>/dev/null || echo "(not available)"
        echo ""
        echo "================================================================================"
        echo " Top Heap Allocators"
        echo "================================================================================"
        echo ""
        cat "$OUTPUT_DIR/top_allocations.txt" 2>/dev/null || echo "(not available)"
        echo ""
        echo "================================================================================"
        echo " Files"
        echo "================================================================================"
        echo ""
        find "$OUTPUT_DIR" -type f | sort | sed "s|$OUTPUT_DIR/||"
    } > "$REPORT"

    echo ""
    echo "=============================================="
    echo " Analysis complete!"
    echo "=============================================="
    echo " Report:   $REPORT"
    echo " Output:   $OUTPUT_DIR"
    echo " Captures: $CAPTURE_COUNT"
    echo ""
    echo " To explore the peak profile interactively:"
    echo "   go tool pprof -http=:8080 \$(ls -S $OUTPUT_DIR/profiles/heap_*.pb.gz | head -1)"
    echo ""
}

# =============================================================================
# Cleanup on exit (Ctrl+C or SIGTERM)
# =============================================================================
RUNNING=true

cleanup() {
    echo ""
    echo ""
    echo "[*] Caught signal — stopping..."
    RUNNING=false

    # Stop memory monitor
    if [[ -n "$MONITOR_PID" ]]; then
        kill "$MONITOR_PID" 2>/dev/null || true
        wait "$MONITOR_PID" 2>/dev/null || true
        echo "    Memory monitor stopped."
    fi

    # Save etcd logs
    save_etcd_logs

    # Run analysis
    echo ""
    echo "[*] Running analysis on captured data..."
    extract_memstats
    extract_proc_summary
    analyze_monitor
    run_pprof_top
    generate_report

    exit 0
}

trap cleanup SIGINT SIGTERM

# =============================================================================
# MAIN: continuous capture loop
# =============================================================================

START_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
START_EPOCH=$(date +%s)

# Start background memory monitor
echo ""
echo "[*] Starting background memory monitor (${MONITOR_INTERVAL}s intervals)..."
start_memory_monitor

echo ""
echo "=============================================="
echo " Capturing profiles every ${CAPTURE_INTERVAL}s"
echo " Press Ctrl+C to stop and run analysis"
echo "=============================================="
echo ""

CAPTURE_NUM=0
while $RUNNING; do
    CAPTURE_NUM=$((CAPTURE_NUM + 1))
    ELAPSED=$(( $(date +%s) - START_EPOCH ))
    ELAPSED_MIN=$(( ELAPSED / 60 ))
    ELAPSED_SEC=$(( ELAPSED % 60 ))
    LABEL=$(printf "%04d" "$CAPTURE_NUM")

    echo "[$(date -u '+%H:%M:%S')] Capture #${CAPTURE_NUM} (T+${ELAPSED_MIN}m${ELAPSED_SEC}s)..."
    capture_profiles "$OUTPUT_DIR/profiles" "$LABEL"

    # Quick inline RSS summary
    echo -n "    RSS: "
    for POD in "${ETCD_PODS[@]}"; do
        SHORT="${NODE_SHORT[$POD]}"
        RSS=$(grep "^VmRSS:" "$OUTPUT_DIR/profiles/proc_status_${LABEL}.txt" | head -1 | awk '{printf "%.1f", $2/1048576}')
        echo -n "${SHORT}=${RSS}G  "
    done
    echo ""

    # Wait for next interval, checking RUNNING every second
    WAITED=0
    while (( WAITED < CAPTURE_INTERVAL )) && $RUNNING; do
        sleep 1
        WAITED=$((WAITED + 1))
    done
done
