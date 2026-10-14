#!/usr/bin/env bash
# OCPBUGS-127458 reproducer, PHASE-LOCKED variant — pure-traffic shape,
# constant oscillation period & amplitude (see README.md).
#
# Deploys the full stack on the target node:
#   1 probed router-equivalent pod (haproxy + nginx, hostNetwork)
#   15 idle low-weight probed victims (cascade targets)
#   7 wall-clock phase-locked wrk clients (edge <-> passthrough swings on the
#     exact 380 s grid — constant period, constant storm amplitude)
#   1 phase-locked restart amplifier (one rollout restart per 380 s cycle,
#     at mark 365 — 15 s before each edge phase)
#
# Calibrated 2026-10-14: 7 clients matches a real Prow ingress-perf run
# (load1 max 29.1 / mean 12.4 -> ours ~27 / ~12.6) and keeps killing.
#
# Required env:
#   NODE_NAME  kubernetes.io/hostname of the target node (e.g. ip-10-0-81-71.us-west-2.compute.internal)
#   NODE_IP    the same node's IP (clients + hostNetwork probes hit it)
# Optional env:
#   NS         namespace (default haproxy-repro)
#   KUBECONFIG cluster credentials with admin (e.g. /tmp/kubeconfig)
#
# Usage:
#   export KUBECONFIG=/tmp/kubeconfig
#   NODE_NAME=ip-10-0-81-71.us-west-2.compute.internal NODE_IP=10.0.81.71 ./run.sh
set -euo pipefail

: "${NODE_NAME:?export NODE_NAME=<kubernetes.io/hostname of the target node>}"
: "${NODE_IP:?export NODE_IP=<node IP>}"
NS=${NS:-haproxy-repro}
DIR="$(cd "$(dirname "$0")" && pwd)"

sub() { sed "s/NODE_NAME/$NODE_NAME/g; s/NODE_IP/$NODE_IP/g" "$@"; }

echo "== 1/5 TLS cert (self-signed, 30 days) — generated once, reused after =="
if [ ! -f "$DIR/tls.pem" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=repro" \
    -keyout "$DIR/tls.pem" -out "$DIR/tls.pem" 2>/dev/null
  echo "   generated $DIR/tls.pem"
else
  echo "   reusing existing $DIR/tls.pem"
fi

echo "== 2/5 namespace + service accounts + privileged SCC (hostNetwork) =="
oc apply -f "$DIR/manifests/00-namespace.yaml"
oc adm policy add-scc-to-user privileged -z haproxy-sa -n "$NS"

echo "== 3/5 configmaps (haproxy.cfg + tls.pem, nginx 1 KB page, healthz) =="
oc -n "$NS" create configmap haproxy-config \
  --from-file=haproxy.cfg="$DIR/files/haproxy.cfg" \
  --from-file=tls.pem="$DIR/tls.pem" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
oc -n "$NS" create configmap nginx-www \
  --from-file=1024.html="$DIR/files/1024.html" \
  --dry-run=client -o yaml | oc apply -f - >/dev/null
sub "$DIR/manifests/10-configmaps.yaml" | oc apply -f - >/dev/null

echo "== 4/5 workloads (router pod, 15 victims, 7 phase-locked clients, restarter) =="
for m in 20-haproxy-victim 30-victims 40-scenario-client 50-restarter; do
  sub "$DIR/manifests/$m.yaml" | oc apply -f - >/dev/null
  echo "   applied $m"
done

echo "== 5/5 waiting for the stack + verifying =="
oc -n "$NS" wait --for=condition=available deploy/haproxy-victim deploy/victim \
  deploy/scenario-client --timeout=300s

# allow the first probe cycle + bindings to settle
sleep 45

echo "--- verify: router healthz (must be 200, empty body)"
oc -n "$NS" run verify-hz --rm -i --restart=Never \
  --image=quay.io/cloud-bulldozer/ingress-perf:latest \
  --overrides="{\"spec\":{\"nodeName\":\"$NODE_NAME\"}}" \
  --command -- curl -s --max-time 5 "http://$NODE_IP:1936/healthz" -o /dev/null -w '%{http_code}\n'

echo "--- verify: edge (8443) response body size (must be ~976 = the 1 KB page)"
oc -n "$NS" run verify-edge --rm -i --restart=Never \
  --image=quay.io/cloud-bulldozer/ingress-perf:latest \
  --overrides="{\"spec\":{\"nodeName\":\"$NODE_NAME\"}}" \
  --command -- sh -c 'curl -sk --max-time 5 https://'"$NODE_IP"':8443/healthz | wc -c'

echo "--- verify: passthrough (8444, L4 to backend TLS) response body size (must be ~976)"
oc -n "$NS" run verify-pt --rm -i --restart=Never \
  --image=quay.io/cloud-bulldozer/ingress-perf:latest \
  --overrides="{\"spec\":{\"nodeName\":\"$NODE_NAME\"}}" \
  --command -- sh -c 'curl -sk --max-time 5 https://'"$NODE_IP"':8444/healthz | wc -c'

echo
echo "Stack is live. Start the kill watch in another terminal:"
echo "  NS=$NS KUBECONFIG=${KUBECONFIG:-\$KUBECONFIG} $DIR/watch.sh"
echo "Expected timeline: connection storms on the 190 s grid (marks 0/190);"
echo "one restart per 380 s cycle at mark 365; kills land in the storm window"
echo "of each cycle (~17 in the first 35 min at the calibrated load)."
