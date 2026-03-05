# misc

A collection of scripts for OpenShift cluster operations and debugging.

## Contents

- **`aws-ipi-deploy-ocp.sh`** — Deploy a self-managed OpenShift cluster on AWS using IPI.
- **`pprof-etcd-mem-usage/`** — Capture and compare etcd heap profiles to diagnose memory usage across cluster versions.
- **`patch-etcd-image.sh`** — Patch the etcd image on an OpenShift cluster by overriding the etcd-operator and rolling out a custom image.
- **`prow-job-trigger/`** — Go CLI to trigger Prow CI jobs via the gangway API using an OpenShift CI token.
