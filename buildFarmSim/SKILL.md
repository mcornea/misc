# buildFarmSim — etcd Build-Farm Workload Simulator

## Overview

Simulates the Kubernetes job lifecycle that the OpenShift build-farm generates against etcd.
Models namespaces with secrets/configmaps, jobs with pods and events, metadata patches,
and watchers with reconnect gaps. Used to reproduce memory/performance regressions
between etcd versions (e.g., v3.5 vs v3.6).

## Prerequisites

- Go toolchain (1.21+)
- etcd binaries at paths referenced in config (e.g., `/root/etcd-v3.5/etcd`, `/root/etcd-v3.6/etcd`)
- graphviz (`dot`) for SVG generation from pprof profiles

## Build

```bash
cd etcd-issues/etcd-issues/etcd/buildFarmSim
go build -o buildfarmsim .
```

## Config files

| File | Purpose |
|---|---|
| `config-quick-v36.json` | **Quick reproducer** — minimal ~3 min run showing `kvsToEvents` regression (v3.6) |
| `config-quick-v35.json` | Same quick workload against v3.5 for comparison |
| `config-full-v36.json` | Full reproducer — sustained heap/RSS difference vs v3.5 |
| `config-full-v35.json` | Same RSS workload against v3.5 for comparison |

Key config fields:
- `numNamespaces` × `jobsPerNamespace` = total jobs (quick: 10 × 10 = 100)
- `jobSizeKB` — size of each job object in KiB (default: 21)
- `secretsPerNamespace` / `configmapsPerNamespace` — static large objects per namespace
- `metadataIterations` / `metadataDelay` — simulates build-farm-metadata-adder patches
- `qps` — rate limit for PUTs
- `watchReconnectSleep` — sleep duration after watcher disconnect before reconnecting (default: `"60s"`)
- `watchStartDelay` — delay before launching watchers, allows revisions to accumulate first (default: `"0s"`)
- `watchInitialRev` — if >0, seed watcher `lastRev` so first connect uses `WithRev(initialRev+1)`, forcing `syncWatchers` to process the full revision backlog (default: `0`)
- `runDuration` — total run time from program start; exits automatically when reached (default: `""`, wait for Ctrl+C)

## Running the workload

### Option 1: Direct run

```bash
./buildfarmsim -f config-quick-v36.json
```

This starts etcd (if `etcdBinPath` is set), runs the workload, then holds until Ctrl+C.
Metrics are written to the configured `metricsOutputFile` (CSV).

### Option 2: With profile capture (recommended)

```bash
./capture_profiles.sh <config.json> <output_dir>
```

This wraps `buildfarmsim` and captures heap profiles (binary `.pb.gz` + text with memstats)
from all etcd nodes every 10 seconds throughout the run. Example:

```bash
./capture_profiles.sh config-quick-v36.json run-quick-v36
./capture_profiles.sh config-quick-v35.json run-quick-v35
```

Output structure:
```
run-v35/
  workload.log          # buildfarmsim stdout/stderr
  profiles/
    heap_127-0-0-1-2379_0001.pb.gz   # binary heap profile, node 0, capture 1
    heap_127-0-0-1-2379_0001.txt     # text heap profile (has memstats)
    heap_127-0-0-1-2380_0001.pb.gz   # node 1
    ...
```

## Generating SVGs from profiles

After a run completes, generate SVGs from the peak (largest) heap profile:

```bash
# Find the peak profile
PEAK=$(ls -S run-v35/profiles/heap_*.pb.gz | head -1)

# Generate inuse_space SVG — use -nodefraction=0 -edgefraction=0 -nodecount=0
# to show all nodes/edges, then replace dashed lines with solid for clarity:
go tool pprof -svg -inuse_space -nodefraction=0 -edgefraction=0 -nodecount=0 "$PEAK" \
  | sed 's/style="dashed"/style="solid"/g' > run-v35/heap-inuse.svg

# Generate alloc_space SVG (total allocations)
go tool pprof -svg -alloc_space -nodefraction=0 -edgefraction=0 -nodecount=0 "$PEAK" \
  | sed 's/style="dashed"/style="solid"/g' > run-v35/heap-alloc.svg

# Focused SVG — show only call chains through a specific function:
go tool pprof -svg -inuse_space -focus="kvsToEvents" -nodefraction=0 -edgefraction=0 "$PEAK" \
  | sed 's/style="dashed"/style="solid"/g' > run-v35/heap-kvsToEvents.svg

# CPU profile (capture manually while workload is running)
curl -s "http://127.0.0.1:2379/debug/pprof/profile?seconds=30" -o run-v35/cpu.pb.gz
go tool pprof -svg run-v35/cpu.pb.gz > run-v35/cpu.svg
```

**SVG flags explained:**
- `-nodefraction=0 -edgefraction=0 -nodecount=0` — show all nodes and edges regardless of size
- `sed 's/style="dashed"/style="solid"/g'` — pprof renders small edges as dotted/dashed lines; this makes them all solid
- `-focus="funcName"` — only show call chains that pass through the named function

## Quick reproducer (~3 min)

Minimal workload that demonstrates the `kvsToEvents` regression with clear signal:

```bash
# 1. Build
go build -o buildfarmsim .

# 2. Run v3.6 — wait ~3 min for watcher reconnect, then Ctrl+C
./capture_profiles.sh config-quick-v36.json run-quick-v36

# 3. Check for kvsToEvents in peak profile
PEAK=$(ls -S run-quick-v36/profiles/heap_*.pb.gz | head -1)
go tool pprof -text -inuse_space -focus="kvsToEvents" -nodefraction=0 "$PEAK"

# 4. (Optional) Run v3.5 comparison — kvsToEvents should not appear
./capture_profiles.sh config-quick-v35.json run-quick-v35
PEAK=$(ls -S run-quick-v35/profiles/heap_*.pb.gz | head -1)
go tool pprof -text -inuse_space -focus="kvsToEvents" -nodefraction=0 "$PEAK"
```

## Full comparison workflow (v3.5 vs v3.6)

```bash
# 1. Build
go build -o buildfarmsim .

# 2. Run v3.6
./capture_profiles.sh config-full-v36.json run-full-v36
# Wait ~5 min, then Ctrl+C

# 3. Run v3.5
./capture_profiles.sh config-full-v35.json run-full-v35
# Wait ~5 min, then Ctrl+C

# 4. Generate SVGs from peak profiles
for VER in rss-v35 rss-v36; do
  PEAK=$(ls -S run-${VER}/profiles/heap_*.pb.gz | head -1)
  go tool pprof -svg -inuse_space -nodefraction=0 -edgefraction=0 -nodecount=0 "$PEAK" \
    | sed 's/style="dashed"/style="solid"/g' > run-${VER}/heap-inuse.svg
done

# 5. Generate comparison charts from metrics CSVs
./buildfarmsim -plot metrics-full-v36.csv,metrics-full-v35.csv -legend v3.6,v3.5 -o full-comparison.html
```

## Reproducing the `kvsToEvents` memory regression (v3.6 vs v3.5)

The v3.6 regression (etcd#21355, PR #17563) causes `syncWatchers` to deserialize ALL keys
in the revision range via `kvsToEvents`, not just watched keys. The `rangeEventsWithReuse`
function keeps the events slice persistently across `syncWatchersLoop` iterations, so the
allocation is never freed.

### Root cause call chain (v3.6 only)

```
syncWatchersLoop → syncWatchers → rangeEventsWithReuse → rangeEvents → kvsToEvents → KeyValue.Unmarshal
```

Two changes in v3.6 cause the regression:
1. **Removed `wg.contains()` filter** — `kvsToEvents` deserializes ALL keys, not just watched ones
2. **Persistent events slice reuse** — `rangeEventsWithReuse` keeps the backing array across loop iterations

### Full reproducer (`config-full-v36.json`)

Demonstrates persistent, measurable RSS difference between v3.5 and v3.6:

```bash
# Run v3.6
./capture_profiles.sh config-full-v36.json run-full-v36
# Wait ~5 min, then Ctrl+C

# Run v3.5
./capture_profiles.sh config-full-v35.json run-full-v35
# Wait ~5 min, then Ctrl+C

# Generate comparison chart
./buildfarmsim -plot metrics-full-v36.csv,metrics-full-v35.csv -legend v3.6,v3.5 -o full-comparison.html
```

Key config settings for reproducing the RSS regression:
- `watchInitialRev: 1` — forces watchers to sync from rev 1, processing the entire store history
- `watchStartDelay: "90s"` — watchers start after all writes complete, maximizing the backlog
- `watchReconnectInterval: "120s"` — long enough for `syncWatchers` to process the full range
- `watchReconnectSleep: "60s"` — gap between reconnect cycles

### Observed results

**RSS comparison (idle phase, same workload, same DB size ~890 MiB):**

| Version | Idle RSS | Heap (pprof inuse) | `kvsToEvents` Unmarshal |
|---------|----------|-------------------|------------------------|
| v3.6 | **2,224 MiB** | **901 MiB** | **850 MiB (94.3%)** |
| v3.5 | **1,197 MiB** | **372 MiB** | **0 MiB** |
| **Delta** | **+1,027 MiB (+86%)** | **+529 MiB** | **+850 MiB** |

The entire RSS difference is attributable to the `rangeEventsWithReuse` → `kvsToEvents` →
`KeyValue.Unmarshal` call chain. The allocation persists because `rangeEventsWithReuse`
reuses the events slice — left-trimming only advances the slice header without releasing the
backing array.

## Cleanup

```bash
make clean          # kills etcd, removes data-etcd-*, log-*, run-*, metrics-*.csv, *.html, and the binary
```

## Workload phases (visible in metrics CSV)

1. **ns-objects** — creating secrets + configmaps (static, ~2 GiB)
2. **job-lifecycle** — 13 PUTs per job (job, pod, events, metadata patches)
3. **idle** — workload complete, metrics still collecting

## Expected DB sizes

| Object | Count | Size | Total |
|---|---|---|---|
| Secrets | 15,000 | 100 KiB | ~1,500 MiB |
| ConfigMaps | 5,000 | 100 KiB | ~500 MiB |
| Jobs | 10,000 | 21 KiB | ~210 MiB |
| Pods | 10,000 | 10 KiB | ~100 MiB |
| Events | 40,000 | 1 KiB | ~40 MiB |
| **With revisions + overhead** | | | **~4-5 GiB** |
