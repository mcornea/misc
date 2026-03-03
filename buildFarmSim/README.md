# buildFarmSim

Reproduces the etcd v3.6 `kvsToEvents` memory regression
([etcd#21355](https://github.com/etcd-io/etcd/issues/21355)) by simulating
the Kubernetes job lifecycle that the OpenShift build-farm generates.

The simulator creates namespaces with secrets/configmaps, runs job lifecycles
(pods, events, metadata patches), and drives watchers through reconnect cycles
that trigger the `syncWatchers` code path where the regression lives.

## Prerequisites

- Go 1.21+
- etcd v3.5 and v3.6 binaries (paths configured in the JSON configs)
- graphviz (`dot`) for SVG generation from pprof profiles

## Quick start

```bash
make                    # show available targets
make run-quick-v36      # run quick workload against v3.6 (~3.5 min)
make run-quick-v35      # run same workload against v3.5 (~3.5 min)
make compare-quick      # generate comparison chart (quick-comparison.html)
```

## Make targets

```
make build              # build the simulator binary
make run CONFIG=f.json  # run any config with profile capture
make run-quick-v35      # quick workload, v3.5 (~3.5 min)
make run-quick-v36      # quick workload, v3.6 (~3.5 min)
make compare-quick      # chart from quick run metrics
make run-full-v35        # full workload, v3.5 (~5.5 min)
make run-full-v36        # full workload, v3.6 (~5.5 min)
make compare-full        # chart from full run metrics
make svgs               # generate heap SVGs from peak profiles
make clean              # kill etcd, remove all generated files
```

## Comparison workflows

### Quick comparison (~3 min per run)

Minimal workload (10 namespaces, 100 jobs) that shows the `kvsToEvents`
allocation in a single watcher reconnect cycle:

```bash
make run-quick-v36
make run-quick-v35
make compare-quick      # -> quick-comparison.html
```

### Full comparison (~5 min per run)

Larger workload (50 namespaces, 1000 jobs) that produces a sustained,
measurable RSS difference between versions:

```bash
make run-full-v36
make run-full-v35
make compare-full        # -> full-comparison.html
```

## Config files

| File | Purpose |
|---|---|
| `config-quick-v36.json` | Quick reproducer -- minimal run showing `kvsToEvents` regression (v3.6) |
| `config-quick-v35.json` | Same quick workload against v3.5 for comparison |
| `config-full-v36.json` | Full reproducer -- sustained heap/RSS difference (v3.6) |
| `config-full-v35.json` | Same full workload against v3.5 for comparison |

Key fields:

| Field | Description | Default |
|---|---|---|
| `numNamespaces` | Number of namespaces to create | 100 |
| `jobsPerNamespace` | Jobs per namespace | 100 |
| `jobSizeKB` | Size of each job object (KiB) | 21 |
| `secretsPerNamespace` | Large static secrets per namespace | 150 |
| `configmapsPerNamespace` | Large static configmaps per namespace | 50 |
| `watchStartDelay` | Delay before launching watchers | `"0s"` |
| `watchInitialRev` | Seed watcher rev to force full sync | 0 |
| `watchReconnectInterval` | Watcher context timeout (triggers reconnect) | `"30s"` |
| `watchReconnectSleep` | Sleep between reconnect cycles | `"60s"` |
| `runDuration` | Auto-exit after this duration (empty = Ctrl+C) | `""` |
| `qps` | PUT rate limit | 40 |

## Inspecting profiles

Each run directory contains heap profiles captured every 10 seconds:

```bash
# Find the peak (largest) heap profile
PEAK=$(ls -S run-quick-v36/profiles/heap_*.pb.gz | head -1)

# Check for kvsToEvents allocation (v3.6 only)
go tool pprof -text -inuse_space -focus="kvsToEvents" -nodefraction=0 "$PEAK"

# Generate SVGs from all run dirs at once
make svgs
```

## The regression

The root cause of the etcd v3.6 memory regression is still under investigation.
Profiling points to the `kvsToEvents` code path as a major source of heap
allocations during watcher sync, and the introduction of a new cache mechanism
in [PR #17563](https://github.com/etcd-io/etcd/pull/17563) is a suspected
contributor, but a definitive root cause has not yet been established. See
[etcd#21355](https://github.com/etcd-io/etcd/issues/21355) for the latest
discussion.

Call chain under investigation (v3.6):
```
syncWatchersLoop -> syncWatchers -> rangeEventsWithReuse -> rangeEvents -> kvsToEvents -> KeyValue.Unmarshal
```

### Observed results (full workload)

| Version | Idle RSS | Heap inuse | `kvsToEvents` |
|---------|----------|------------|---------------|
| v3.6 | 2,224 MiB | 901 MiB | 850 MiB (94.3%) |
| v3.5 | 1,197 MiB | 372 MiB | 0 MiB |
| Delta | +1,027 MiB (+86%) | +529 MiB | +850 MiB |

## Cleanup

```bash
make clean
```

Kills any running etcd processes and removes all generated files
(`data-etcd-*`, `log-*`, `run-*`, `metrics-*.csv`, `*.html`, binary).
