#!/bin/bash
# RTNL mutex contention monitor
#
# Deploys a privileged pod that continuously measures
# getaddrinfo("localhost") latency and logs spikes with
# timestamps. Run before kube-burner to capture the
# correlation between pod creation and probe timeouts.
#
# The pod runs until you delete it. Tail logs with:
#   oc logs -f rtnl-monitor -n default
#
# Clean up with:
#   oc delete pod rtnl-monitor -n default
#
# Usage:
#   export KUBECONFIG=/tmp/kubeconfig
#   ./rtnl-monitor.sh

set -euo pipefail

if [[ -z "${KUBECONFIG:-}" ]]; then
  echo "ERROR: KUBECONFIG is not set"
  exit 1
fi

NS="default"
POD_NAME="rtnl-monitor"
NODE=$(oc get nodes --no-headers -o jsonpath='{.items[0].metadata.name}')

oc -n "$NS" delete pod "$POD_NAME" --ignore-not-found 2>/dev/null
sleep 2

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NS}
spec:
  nodeName: ${NODE}
  hostNetwork: true
  containers:
  - name: monitor
    image: registry.redhat.io/rhel10/support-tools
    imagePullPolicy: IfNotPresent
    command:
    - python3
    - -c
    - |
      import socket, time

      INTERVAL = 0.1
      THRESHOLD_MS = 10
      count = 0
      spikes = 0
      max_ms = 0

      print("ts,latency_ms", flush=True)

      while True:
          start = time.monotonic()
          try:
              socket.getaddrinfo("localhost", 80)
          except Exception as e:
              ts = time.strftime("%Y-%m-%d %H:%M:%S")
              print(f"{ts},ERROR:{e}", flush=True)
              time.sleep(INTERVAL)
              continue
          elapsed_ms = (time.monotonic() - start) * 1000
          count += 1
          if elapsed_ms > max_ms:
              max_ms = elapsed_ms
          ts = time.strftime("%Y-%m-%d %H:%M:%S")
          if elapsed_ms > THRESHOLD_MS:
              spikes += 1
              marker = " ***" if elapsed_ms > 1000 else ""
              print(f"{ts},{elapsed_ms:.1f}{marker}", flush=True)
          elif count % 300 == 0:
              print(f"{ts},ok max={max_ms:.0f}ms spikes={spikes}/{count}", flush=True)
              max_ms = 0
              spikes = 0
          time.sleep(INTERVAL)
    securityContext:
      privileged: true
  tolerations:
  - operator: Exists
  restartPolicy: Always
EOF

oc -n "$NS" wait "pod/${POD_NAME}" --for=condition=Ready --timeout=120s

echo ""
echo "Monitor running on ${NODE}."
echo ""
echo "  Tail logs:  oc logs -f ${POD_NAME} -n ${NS}"
echo "  Clean up:   oc delete pod ${POD_NAME} -n ${NS}"
echo ""
echo "--- tailing logs (Ctrl-C to detach) ---"
echo ""
oc -n "$NS" logs -f "$POD_NAME"
