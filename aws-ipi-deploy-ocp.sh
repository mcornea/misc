#!/bin/bash
set -euo pipefail

#############################################
# Self-managed OpenShift 4.21.0 on AWS
# Cluster: mcornea00 | Region: eu-central-1
#############################################

# --- FILL THESE IN ---
BASE_DOMAIN="example.com"
PULL_SECRET_FILE="./pull-secret.txt"  # Path to your pull secret file (from console.redhat.com)
SSH_KEY_FILE="$HOME/.ssh/id_rsa.pub"
AWS_REGION="eu-central-1"
CLUSTER_NAME="mcornea00"
OCP_VERSION="4.21.0"
INSTALL_DIR="$HOME/${CLUSTER_NAME}"
# ----------------------

PULL_SECRET=$(cat "$PULL_SECRET_FILE")
SSH_KEY=$(cat "$SSH_KEY_FILE")

### Step 1: Configure AWS credentials (skip if already configured)
# aws configure

### Step 2: Create Route 53 hosted zone (skip if already exists)
echo "=== Checking Route 53 hosted zone for ${BASE_DOMAIN} ==="
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "${BASE_DOMAIN}" \
  --query "HostedZones[?Name=='${BASE_DOMAIN}.'].Id" --output text | head -1)

if [ -z "$ZONE_ID" ]; then
  echo "Creating hosted zone for ${BASE_DOMAIN}..."
  aws route53 create-hosted-zone --name "${BASE_DOMAIN}" --caller-reference "$(date +%s)"
  echo "IMPORTANT: Update your domain registrar NS records to point to the Route 53 nameservers above."
  echo "Press Enter once DNS delegation is configured..."
  read -r
else
  echo "Hosted zone found: ${ZONE_ID}"
fi

### Step 3: Download the installer
echo "=== Downloading OpenShift installer ${OCP_VERSION} ==="
WORK_DIR=$(mktemp -d)
oc adm release extract --tools \
  "quay.io/openshift-release-dev/ocp-release:${OCP_VERSION}-x86_64" \
  -a "$PULL_SECRET_FILE" --to "$WORK_DIR"

tar xzf "${WORK_DIR}/openshift-install-linux-${OCP_VERSION}.tar.gz" -C "$WORK_DIR"
INSTALLER="${WORK_DIR}/openshift-install"
chmod +x "$INSTALLER"

### Step 4: Create install-config.yaml
echo "=== Creating install-config.yaml ==="
mkdir -p "$INSTALL_DIR"

cat > "${INSTALL_DIR}/install-config.yaml" <<EOF
apiVersion: v1
metadata:
  name: ${CLUSTER_NAME}
baseDomain: ${BASE_DOMAIN}
platform:
  aws:
    region: ${AWS_REGION}
    userTags:
      TicketId: "731"
controlPlane:
  name: master
  replicas: 3
  platform:
    aws:
      type: m5.8xlarge
      zones:
        - ${AWS_REGION}a
        - ${AWS_REGION}b
        - ${AWS_REGION}c
compute:
  - name: worker
    replicas: 18
    platform:
      aws:
        type: m5.xlarge
        zones:
          - ${AWS_REGION}a
          - ${AWS_REGION}b
          - ${AWS_REGION}c
networking:
  machineNetwork:
    - cidr: 10.0.0.0/16
pullSecret: '${PULL_SECRET}'
sshKey: '${SSH_KEY}'
EOF

# Back up install-config (the installer consumes it)
cp "${INSTALL_DIR}/install-config.yaml" "${INSTALL_DIR}/install-config.yaml.bak"

### Step 5: Deploy the cluster
echo "=== Installing cluster ==="
"$INSTALLER" create cluster --dir "$INSTALL_DIR" --log-level=info

### Step 6: Set kubeconfig
export KUBECONFIG="${INSTALL_DIR}/auth/kubeconfig"
echo "=== Cluster installed. KUBECONFIG=${KUBECONFIG} ==="

### Step 7: Configure autoscaling
echo "=== Configuring ClusterAutoscaler ==="
oc apply -f - <<EOF
apiVersion: autoscaling.openshift.io/v1
kind: ClusterAutoscaler
metadata:
  name: default
spec:
  scaleDown:
    enabled: true
    delayAfterAdd: 10m
    unneededTime: 5m
  resourceLimits:
    maxNodesTotal: 114
EOF

echo "=== Configuring MachineAutoscalers (6 min / 38 max per AZ) ==="
for AZ in a b c; do
  MACHINESET=$(oc -n openshift-machine-api get machinesets -o name | grep "${AWS_REGION}${AZ}" | head -1 | cut -d/ -f2)
  if [ -z "$MACHINESET" ]; then
    echo "WARNING: No MachineSet found for zone ${AWS_REGION}${AZ}, skipping."
    continue
  fi
  echo "Creating MachineAutoscaler for ${MACHINESET}..."
  oc apply -f - <<EOF
apiVersion: autoscaling.openshift.io/v1beta1
kind: MachineAutoscaler
metadata:
  name: autoscaler-${MACHINESET}
  namespace: openshift-machine-api
spec:
  minReplicas: 6
  maxReplicas: 38
  scaleTargetRef:
    apiVersion: machine.openshift.io/v1beta1
    kind: MachineSet
    name: ${MACHINESET}
EOF
done

### Step 8: Create infra nodes (2 × r5.4xlarge)
echo "=== Creating infra MachineSets ==="
# Pick the first two AZs for the two infra replicas
INFRA_AZS=(a b)
for AZ in "${INFRA_AZS[@]}"; do
  # Use an existing worker MachineSet as a template
  WORKER_MS=$(oc -n openshift-machine-api get machinesets -o name | grep "${AWS_REGION}${AZ}" | head -1 | cut -d/ -f2)
  if [ -z "$WORKER_MS" ]; then
    echo "WARNING: No worker MachineSet found for zone ${AWS_REGION}${AZ}, skipping."
    continue
  fi
  INFRA_MS="${CLUSTER_NAME}-infra-${AWS_REGION}${AZ}"
  echo "Creating infra MachineSet ${INFRA_MS} from ${WORKER_MS}..."
  oc -n openshift-machine-api get machineset "$WORKER_MS" -o json \
    | jq --arg name "$INFRA_MS" --arg itype "r5.4xlarge" '
      .metadata.name = $name |
      .metadata.resourceVersion = null |
      .metadata.uid = null |
      .metadata.creationTimestamp = null |
      .spec.replicas = 1 |
      .spec.selector.matchLabels["machine.openshift.io/cluster-api-machineset"] = $name |
      .spec.template.metadata.labels["machine.openshift.io/cluster-api-machineset"] = $name |
      .spec.template.metadata.labels["node-role.kubernetes.io/infra"] = "" |
      del(.spec.template.metadata.labels["node-role.kubernetes.io/worker"]) |
      .spec.template.spec.providerSpec.value.instanceType = $itype |
      .spec.template.spec.taints = [{"key": "node-role.kubernetes.io/infra", "effect": "NoSchedule"}]
    ' | oc apply -f -
done

### Step 9: Label and taint existing nodes as infra
echo "=== Labeling and tainting infra nodes ==="
INFRA_NODES=("ip-10-0-36-89.eu-central-1.compute.internal" "ip-10-0-8-109.eu-central-1.compute.internal")
for NODE in "${INFRA_NODES[@]}"; do
  oc label node "$NODE" node-role.kubernetes.io/infra=""
  oc adm taint node "$NODE" node-role.kubernetes.io/infra:NoSchedule --overwrite
done

oc -n openshift-monitoring get configmap cluster-monitoring-config -o yaml 2>/dev/null || \
  oc -n openshift-monitoring create configmap cluster-monitoring-config --from-literal=config.yaml=""

oc -n openshift-monitoring patch configmap cluster-monitoring-config --type merge -p "$(cat <<'PATCH'
{"data":{"config.yaml":"prometheusK8s:\n  nodeSelector:\n    node-role.kubernetes.io/infra: \"\"\n  tolerations:\n    - key: node-role.kubernetes.io/infra\n      effect: NoSchedule\nalertmanagerMain:\n  nodeSelector:\n    node-role.kubernetes.io/infra: \"\"\n  tolerations:\n    - key: node-role.kubernetes.io/infra\n      effect: NoSchedule\n"}}
PATCH
)"

echo "=== Moving default ingress controller to infra nodes ==="
oc patch ingresscontroller default -n openshift-ingress-operator --type merge -p '{
  "spec": {
    "nodePlacement": {
      "nodeSelector": {
        "matchLabels": {
          "node-role.kubernetes.io/infra": ""
        }
      },
      "tolerations": [
        {
          "key": "node-role.kubernetes.io/infra",
          "effect": "NoSchedule"
        }
      ]
    }
  }
}'

echo "=== Done ==="
echo "Cluster: ${CLUSTER_NAME}"
echo "KUBECONFIG: ${KUBECONFIG}"
echo "Console: https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}"
