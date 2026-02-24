# etcd pprof Heap Profile Analysis

## What This Directory Contains

Continuous etcd heap profile captures from OCP clusters under kube-burner `build-farm` workload, used to diagnose memory spikes in etcd 3.6 (OCP 4.21) vs etcd 3.5 (OCP 4.20).

## Script

`run_etcd_pprof_analysis.sh` — self-contained, cluster-agnostic script that captures pprof heap profiles from all etcd pods every minute until Ctrl+C, then runs analysis.

### Usage

```bash
# Start continuous capture (run kube-burner separately in another terminal)
./run_etcd_pprof_analysis.sh --output-dir ./pprof-4.20 --interval 60

# Ctrl+C to stop — analysis runs automatically on exit
```

### Options

- `--output-dir DIR` — where to save captures (default: `./pprof-analysis-YYYYMMDD-HHMMSS`)
- `--interval SECS` — seconds between profile captures (default: 60)

### Requirements

- `oc` logged into the target OCP cluster
- `go` (optional, for `go tool pprof -top` analysis on exit)

### What It Captures Per Interval

For each etcd pod (auto-discovered):
- **Binary heap profile** (`.pb.gz`) — for `go tool pprof` interactive analysis
- **Text heap profile** (`?debug=1` `.txt`) — human-readable, includes MemStats at bottom
- **`/proc/1/status`** — VmRSS, VmHWM, RssAnon, RssFile

Plus a background memory monitor sampling `/proc/1/status` every 30s into a TSV.

### What It Produces on Exit (Ctrl+C)

- `analysis_report.txt` — combined summary report
- `memstats_summary.tsv` — HeapAlloc/HeapInuse/HeapSys/NumGC per capture per node
- `proc_status_summary.txt` — VmRSS/VmHWM/RssAnon/RssFile per capture per node (GiB)
- `memory_monitor_summary.txt` — peak RSS per pod, top 10 highest readings
- `top_allocations.txt` — `go tool pprof -top -inuse_space` on the largest profile
- `etcd_log_*.json` — etcd logs from each pod covering the capture window
- `metadata.txt` — cluster name, OCP/etcd/Go versions, pod list

## Output Structure

```
pprof-<cluster>/
├── profiles/
│   ├── heap_<node-ip>_0001.pb.gz    # binary profile, capture #1
│   ├── heap_<node-ip>_0001.txt      # text profile, capture #1
│   ├── proc_status_0001.txt         # /proc/1/status, capture #1
│   ├── heap_<node-ip>_0002.pb.gz    # capture #2
│   └── ...                          # one set per interval per pod
├── memory_monitor.tsv               # 30s RSS sampling
├── memstats_summary.tsv             # extracted MemStats table
├── proc_status_summary.txt          # RSS comparison table
├── memory_monitor_summary.txt       # peak RSS analysis
├── top_allocations.txt              # pprof top output
├── etcd_log_*.json                  # etcd pod logs (JSON format)
├── metadata.txt                     # cluster/version info
└── analysis_report.txt              # combined report
```

## How to Analyze After Capture

### Interactive pprof (single profile)

```bash
# Open the largest (peak) profile in browser
go tool pprof -http=:8080 $(ls -S profiles/heap_*.pb.gz | head -1)
```

### Compare two profiles (diff)

```bash
# Show what grew between capture #5 and #20
go tool pprof -http=:8080 -diff_base=profiles/heap_10-0-24-15_0005.pb.gz profiles/heap_10-0-24-15_0020.pb.gz
```

### Compare 4.20 vs 4.21

```bash
# Compare peak profiles between clusters
go tool pprof -http=:8080 -diff_base=pprof-4.20/profiles/heap_*_0020.pb.gz pprof-4.21/profiles/heap_*_0020.pb.gz
```

### Top allocators (CLI)

```bash
go tool pprof -top -inuse_space profiles/heap_10-0-24-15_0020.pb.gz
go tool pprof -top -alloc_space profiles/heap_10-0-24-15_0020.pb.gz  # lifetime allocs
```

### Extract MemStats from a text profile

```bash
tail -30 profiles/heap_10-0-24-15_0020.txt
# Shows: HeapAlloc, HeapSys, HeapInuse, HeapIdle, HeapReleased, Stack, Sys, NumGC
```

### Plot RSS over time from monitor TSV

```bash
# Quick terminal plot of leader RSS
awk -F'\t' 'NR>1 && $2 ~ /10-0-24-15/ {printf "%s %.1f\n", $1, $3/1048576}' memory_monitor.tsv
```

## Key Metrics to Compare Between 4.20 and 4.21

| Metric | Source | What It Tells You |
|--------|--------|-------------------|
| Peak VmRSS | `memory_monitor_summary.txt` | Total physical memory at worst |
| Peak RssAnon | `memory_monitor_summary.txt` | Go heap + stack physical memory |
| Peak RssFile | `proc_status_summary.txt` | BoltDB mmap page cache |
| HeapAlloc | `memstats_summary.tsv` | Live Go heap allocations |
| HeapSys | `memstats_summary.tsv` | Virtual address space reserved by Go |
| HeapSys - HeapReleased | `memstats_summary.tsv` | Actually committed Go heap |
| NumGC | `memstats_summary.tsv` | GC pressure indicator |
| Top allocator | `top_allocations.txt` | Where memory is going |

## Known Findings (4.21 / etcd 3.6.5 / Go 1.24.11)

- Peak RSS: **13.1 GiB** on leader (baseline 0.4 GiB)
- RSS dominated by **BoltDB mmap** (~7 GiB RssFile), not Go heap
- Go heap peaked at **~1.8 GiB in-use**, 64% in `mvccpb.(*KeyValue).Unmarshal`
- Two call paths: range queries in Raft apply (39%) and watch event generation (14%)
- HeapSys grew to 9 GiB (virtual) — normal Go behavior, not a leak
- DB grew from 120 MiB to 7.5 GiB in 20 minutes under load
- 98 snapshots triggered (snapshot-count=10000 in etcd 3.6 vs 100000 in 3.5)
- Secrets range queries returning 758 MiB per response correlated with peak spikes

## Cert Path Convention

The script auto-discovers pods and cert paths. For manual curl:

```bash
oc exec -n openshift-etcd <POD> -c etcd -- sh -c \
  'curl -s --cacert /etc/kubernetes/static-pod-certs/configmaps/etcd-all-bundles/server-ca-bundle.crt \
   --cert /etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-<NODE>.crt \
   --key /etc/kubernetes/static-pod-certs/secrets/etcd-all-certs/etcd-peer-<NODE>.key \
   https://localhost:2379/debug/pprof/heap' > heap.pb.gz
```

Where `<NODE>` is the full node name (e.g., `ip-10-0-24-15.eu-central-1.compute.internal`).
