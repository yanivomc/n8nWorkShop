#!/bin/bash
# =============================================================================
# force-alert.sh — Fire fake Alertmanager webhooks at n8n
# Simulates real Prometheus → Alertmanager → n8n payloads per scenario.
# Use this to test S3 without waiting for Prometheus to fire.
# =============================================================================

EC2_IP="${EC2_PUBLIC_IP:-54.246.254.41}"
WEBHOOK_URL="http://${EC2_IP}:5678/webhook/prometheus-alert"
NAMESPACE="${NAMESPACE:-prod}"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

usage() {
  echo ""
  echo "Usage: $0 <scenario> [namespace] [status]"
  echo ""
  echo "Scenarios:"
  echo "  01  PodCrashLooping       (critical)"
  echo "  02  PodOOMKilled          (critical)"
  echo "  03  PodNotReady           (warning)"
  echo "  04  DeploymentMismatch    (warning)"
  echo "  05  NodeHighCPU           (warning)"
  echo "  all Fire all 5 scenarios in sequence"
  echo ""
  echo "Options:"
  echo "  namespace  Target namespace (default: prod)"
  echo "  status     firing | resolved (default: firing)"
  echo ""
  echo "Examples:"
  echo "  $0 01"
  echo "  $0 02 staging"
  echo "  $0 01 prod resolved"
  echo "  NAMESPACE=dev $0 all"
  echo ""
}

fire() {
  local PAYLOAD="$1"
  local ALERT_NAME="$2"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  🚀 Firing: ${ALERT_NAME}"
  echo "  → ${WEBHOOK_URL}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "${WEBHOOK_URL}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}")
  HTTP_CODE=$(echo "$RESPONSE" | tail -1)
  BODY=$(echo "$RESPONSE" | head -1)
  if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
    echo "  ✅ Accepted (HTTP ${HTTP_CODE})"
  else
    echo "  ❌ Failed (HTTP ${HTTP_CODE})"
    echo "  Response: ${BODY}"
  fi
}

SCENARIO="${1}"
NAMESPACE="${2:-${NAMESPACE:-prod}}"
STATUS="${3:-firing}"

if [ -z "$SCENARIO" ]; then
  usage
  exit 1
fi

# ── Scenario 01: PodCrashLooping ──────────────────────────────────────────
scenario_01() {
  fire "$(cat <<EOF
{
  "version": "4",
  "groupKey": "{}:{alertname=\"PodCrashLooping\"}",
  "truncatedAlerts": 0,
  "status": "${STATUS}",
  "receiver": "n8n-webhook",
  "groupLabels": { "alertname": "PodCrashLooping" },
  "commonLabels": {
    "alertname": "PodCrashLooping",
    "namespace": "${NAMESPACE}",
    "severity": "critical",
    "workshop": "true"
  },
  "commonAnnotations": {
    "summary": "Pod payments-app is crash looping",
    "description": "Pod payments-app-7d9f8b6c4-xkp2q in namespace ${NAMESPACE} restarted 12 times/min"
  },
  "externalURL": "http://${EC2_IP}:9090",
  "alerts": [
    {
      "status": "${STATUS}",
      "labels": {
        "alertname": "PodCrashLooping",
        "container": "payments",
        "namespace": "${NAMESPACE}",
        "pod": "payments-app-7d9f8b6c4-xkp2q",
        "severity": "critical",
        "workshop": "true"
      },
      "annotations": {
        "summary": "Pod payments-app is crash looping",
        "description": "Pod payments-app-7d9f8b6c4-xkp2q in namespace ${NAMESPACE} restarted 12 times/min"
      },
      "startsAt": "${NOW}",
      "endsAt": "0001-01-01T00:00:00Z",
      "generatorURL": "http://${EC2_IP}:9090/graph?g0.expr=rate%28kube_pod_container_status_restarts_total%5B5m%5D%29+%2A+60+%3E+0"
    }
  ]
}
EOF
)" "PodCrashLooping (${NAMESPACE}/payments-app)"
}

# ── Scenario 02: PodOOMKilled ─────────────────────────────────────────────
scenario_02() {
  fire "$(cat <<EOF
{
  "version": "4",
  "groupKey": "{}:{alertname=\"PodOOMKilled\"}",
  "truncatedAlerts": 0,
  "status": "${STATUS}",
  "receiver": "n8n-webhook",
  "groupLabels": { "alertname": "PodOOMKilled" },
  "commonLabels": {
    "alertname": "PodOOMKilled",
    "namespace": "${NAMESPACE}",
    "severity": "critical",
    "workshop": "true"
  },
  "commonAnnotations": {
    "summary": "Pod memory-hog OOMKilled",
    "description": "Container memory-hog in ${NAMESPACE}/memory-hog-6b8d9f5c7-r4t2n was killed — memory limit exceeded"
  },
  "externalURL": "http://${EC2_IP}:9090",
  "alerts": [
    {
      "status": "${STATUS}",
      "labels": {
        "alertname": "PodOOMKilled",
        "container": "memory-hog",
        "namespace": "${NAMESPACE}",
        "pod": "memory-hog-6b8d9f5c7-r4t2n",
        "severity": "critical",
        "workshop": "true"
      },
      "annotations": {
        "summary": "Pod memory-hog OOMKilled",
        "description": "Container memory-hog in ${NAMESPACE}/memory-hog-6b8d9f5c7-r4t2n was killed — memory limit exceeded"
      },
      "startsAt": "${NOW}",
      "endsAt": "0001-01-01T00:00:00Z",
      "generatorURL": "http://${EC2_IP}:9090/graph?g0.expr=kube_pod_container_status_last_terminated_reason%7Breason%3D%22OOMKilled%22%7D+%3D%3D+1"
    }
  ]
}
EOF
)" "PodOOMKilled (${NAMESPACE}/memory-hog)"
}

# ── Scenario 03: PodNotReady ──────────────────────────────────────────────
scenario_03() {
  fire "$(cat <<EOF
{
  "version": "4",
  "groupKey": "{}:{alertname=\"PodNotReady\"}",
  "truncatedAlerts": 0,
  "status": "${STATUS}",
  "receiver": "n8n-webhook",
  "groupLabels": { "alertname": "PodNotReady" },
  "commonLabels": {
    "alertname": "PodNotReady",
    "namespace": "${NAMESPACE}",
    "severity": "warning",
    "workshop": "true"
  },
  "commonAnnotations": {
    "summary": "Pod pending-victim not ready",
    "description": "Pod pending-victim-5c9d7b8f4-m2p6k in ${NAMESPACE} not ready for 2+ minutes"
  },
  "externalURL": "http://${EC2_IP}:9090",
  "alerts": [
    {
      "status": "${STATUS}",
      "labels": {
        "alertname": "PodNotReady",
        "namespace": "${NAMESPACE}",
        "pod": "pending-victim-5c9d7b8f4-m2p6k",
        "severity": "warning",
        "workshop": "true"
      },
      "annotations": {
        "summary": "Pod pending-victim not ready",
        "description": "Pod pending-victim-5c9d7b8f4-m2p6k in ${NAMESPACE} not ready for 2+ minutes"
      },
      "startsAt": "${NOW}",
      "endsAt": "0001-01-01T00:00:00Z",
      "generatorURL": "http://${EC2_IP}:9090/graph?g0.expr=kube_pod_status_ready%7Bcondition%3D%22true%22%7D+%3D%3D+0"
    }
  ]
}
EOF
)" "PodNotReady (${NAMESPACE}/pending-victim)"
}

# ── Scenario 04: DeploymentReplicasMismatch ───────────────────────────────
scenario_04() {
  fire "$(cat <<EOF
{
  "version": "4",
  "groupKey": "{}:{alertname=\"DeploymentReplicasMismatch\"}",
  "truncatedAlerts": 0,
  "status": "${STATUS}",
  "receiver": "n8n-webhook",
  "groupLabels": { "alertname": "DeploymentReplicasMismatch" },
  "commonLabels": {
    "alertname": "DeploymentReplicasMismatch",
    "namespace": "${NAMESPACE}",
    "severity": "warning",
    "workshop": "true"
  },
  "commonAnnotations": {
    "summary": "Deployment bad-deploy replica mismatch",
    "description": "Expected vs available replicas mismatch for bad-deploy in ${NAMESPACE}"
  },
  "externalURL": "http://${EC2_IP}:9090",
  "alerts": [
    {
      "status": "${STATUS}",
      "labels": {
        "alertname": "DeploymentReplicasMismatch",
        "deployment": "bad-deploy",
        "namespace": "${NAMESPACE}",
        "severity": "warning",
        "workshop": "true"
      },
      "annotations": {
        "summary": "Deployment bad-deploy replica mismatch",
        "description": "Expected vs available replicas mismatch for bad-deploy in ${NAMESPACE}"
      },
      "startsAt": "${NOW}",
      "endsAt": "0001-01-01T00:00:00Z",
      "generatorURL": "http://${EC2_IP}:9090/graph?g0.expr=kube_deployment_spec_replicas+%21%3D+kube_deployment_status_available_replicas"
    }
  ]
}
EOF
)" "DeploymentReplicasMismatch (${NAMESPACE}/bad-deploy)"
}

# ── Scenario 05: NodeHighCPU ──────────────────────────────────────────────
scenario_05() {
  fire "$(cat <<EOF
{
  "version": "4",
  "groupKey": "{}:{alertname=\"NodeHighCPU\"}",
  "truncatedAlerts": 0,
  "status": "${STATUS}",
  "receiver": "n8n-webhook",
  "groupLabels": { "alertname": "NodeHighCPU" },
  "commonLabels": {
    "alertname": "NodeHighCPU",
    "severity": "warning",
    "workshop": "true"
  },
  "commonAnnotations": {
    "summary": "Node ip-10-0-1-42 CPU > 85%",
    "description": "CPU usage on ip-10-0-1-42.eu-west-1.compute.internal has been above 85% for 2 minutes"
  },
  "externalURL": "http://${EC2_IP}:9090",
  "alerts": [
    {
      "status": "${STATUS}",
      "labels": {
        "alertname": "NodeHighCPU",
        "instance": "ip-10-0-1-42.eu-west-1.compute.internal",
        "node": "ip-10-0-1-42.eu-west-1.compute.internal",
        "severity": "warning",
        "workshop": "true"
      },
      "annotations": {
        "summary": "Node ip-10-0-1-42 CPU > 85%",
        "description": "CPU usage on ip-10-0-1-42.eu-west-1.compute.internal has been above 85% for 2 minutes"
      },
      "startsAt": "${NOW}",
      "endsAt": "0001-01-01T00:00:00Z",
      "generatorURL": "http://${EC2_IP}:9090/graph?g0.expr=100+-+%28avg+by%28instance%29+%28rate%28node_cpu_seconds_total%7Bmode%3D%22idle%22%7D%5B5m%5D%29%29+%2A+100%29+%3E+85"
    }
  ]
}
EOF
)" "NodeHighCPU (ip-10-0-1-42)"
}

# ── Dispatch ──────────────────────────────────────────────────────────────

case "$SCENARIO" in
  01|crashloop)   scenario_01 ;;
  02|oom)         scenario_02 ;;
  03|pending)     scenario_03 ;;
  04|deployment)  scenario_04 ;;
  05|cpu)         scenario_05 ;;
  all)
    scenario_01
    sleep 3
    scenario_02
    sleep 3
    scenario_03
    sleep 3
    scenario_04
    sleep 3
    scenario_05
    ;;
  *)
    echo "❌ Unknown scenario: $SCENARIO"
    usage
    exit 1
    ;;
esac

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Check n8n executions:"
echo "  http://${EC2_IP}:5678/workflow/${WORKFLOW_ID:-S3}/executions"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
