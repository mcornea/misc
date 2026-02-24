#!/bin/bash
set -euo pipefail

ETCD_IMAGE="${1:-quay.io/mcornea/etcd:latest}"

echo "Patching etcd image to: ${ETCD_IMAGE}"

# Step 1: Add CVO override to unmanage the etcd-operator deployment
echo "Adding CVO override for etcd-operator..."
oc patch clusterversion version --type json -p \
  '[{"op":"add","path":"/spec/overrides","value":[{"kind":"Deployment","namespace":"openshift-etcd-operator","name":"etcd-operator","unmanaged":true,"group":"apps"}]}]'

# Step 2: Set the etcd image on the operator deployment
echo "Setting IMAGE=${ETCD_IMAGE} on etcd-operator deployment..."
oc set env deployment/etcd-operator -n openshift-etcd-operator "IMAGE=${ETCD_IMAGE}"

# Step 3: Wait for the operator deployment to roll out
echo "Waiting for etcd-operator deployment rollout..."
oc rollout status deployment/etcd-operator -n openshift-etcd-operator --timeout=120s

# Step 4: Wait for etcd static pods to roll out across all nodes
echo "Waiting for etcd rollout to complete across all nodes..."
while true; do
  progressing=$(oc get etcd cluster -o jsonpath='{.status.conditions[?(@.type=="NodeInstallerProgressing")].status}')
  message=$(oc get etcd cluster -o jsonpath='{.status.conditions[?(@.type=="NodeInstallerProgressing")].message}')
  echo "  ${message}"
  if [[ "${progressing}" == "False" ]]; then
    break
  fi
  sleep 15
done

# Step 5: Verify
echo ""
echo "Etcd images in use:"
oc get pods -n openshift-etcd -l app=etcd -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.containers[*]}  {.name}: {.image}{"\n"}{end}{"\n"}{end}'

echo ""
echo "Done. Etcd image patched to ${ETCD_IMAGE}"
