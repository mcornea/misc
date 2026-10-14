#!/usr/bin/env bash
# Teardown: removes the reproducer stack (namespace incl. all workloads).
set -euo pipefail
NS=${NS:-haproxy-repro}
echo "deleting namespace $NS (all workloads, configmaps, RBAC)..."
oc delete namespace "$NS" --wait=false
echo "removing the privileged SCC grant..."
oc adm policy remove-scc-from-user privileged -z haproxy-sa -n "$NS" 2>/dev/null || true
echo "done."
