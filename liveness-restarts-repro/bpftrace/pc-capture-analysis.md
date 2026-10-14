# OCPBUGS-127458 mechanism capture — signature comparison

**Capture**: `placement-correlation.bt` (read-only kprobes + profile sampler)
**Kernel**: `6.12.0-211.64.1.el10_2` (EEVDF `place_entity` lag backport present)
**Node**: `ip-10-0-26-11` (4 vCPU m6.xlarge)
**Workload**: pure-traffic ingress-perf-shaped reproducer (`../run.sh`) — 10 wrk
clients × `-c500`, ~1 KB responses, edge↔passthrough swings, probed haproxy +
15 co-located victims. **No synthetic load.**
**Watched threads**: kubelet tids 15835/15836, wait threshold 100 ms, 600 s.

## Result: the same mechanism signature as the live ingress-perf failing run

| Signature | Live ingress-perf (infra-0, customer run) | This reproducer capture |
|---|---|---|
| Starved entity vruntime below `min_vruntime` at root cfs_rq | −161M / −541M ns (`handler14`, ovs-vswitchd) | **−2.37 billion ns** (kubelet tid 15835, line 49078 of the extract) |
| NEGATIVE `avg_vruntime` at root | −10.8B / −654B | **−2.72T** |
| Heavy curr task (200–400k weight) on CPU while watched thread starves | curr_weight 194992 / 403527 | curr_weight 252388 |
| Backward-placement regime share | 435/454 samples ineligible at root (96%) | **98.3%** of all reweight placements below min (3,412,124 / 3,470,310) |

## Key numbers from this capture

- 3,470,310 `REWEIGHT_AFTER` events + 3,997,163 `PLACE_CURR` events in 608 s
  (~12k placements/sec) — the placement machinery churning constantly under the
  workload.
- **98.3% of every reweight placement puts the entity below `min_vruntime`** on
  the failing kernel: the backward-placement regime is the norm, not an edge
  case.
- One starvation onset captured: kubelet tid 15835 waited **432 ms** while the
  root cfs_rq showed its entity 2.37 billion ns behind the progress floor and
  `avg_vruntime` at −2.72 trillion.

## Mechanism (consistent with the placement hypothesis)

The negative `avg_vruntime` is the corruption made visible: under sustained
saturation + weight/profile oscillation (the edge↔passthrough swings), the
lag-based placement math produces values outside any sane timeline, and
`place_entity()` re-positions waking entities (the kubelet's probe workers)
behind the heavy workload bulk — the same root-cfs_rq fingerprint captured
during the customer's failing ingress-perf run (ovs-vswitchd `handler14`,
3.5 s maximum wait). The kill cascade follows when the probe path misses its
1 s × 3 windows.

## Falsification (same matrix, other controls)

- `NO_PLACE_LAG` toggle → 0 kills on two kernels (`../PLACE_LAG_TEST.md`)
- RHCOS 9.8 / kernel 5.14 (pre-EEVDF) → 0 kills over the same 40 min at full
  saturation, through 3 restart windows
- 3-byte responses, 1 m samples, single-priority-class → 0 kills

Raw capture (7.4M lines) retained locally at `/tmp/opencode/pc-capture.txt`;
`pc-capture-evidence.txt` is the shareable extract.
