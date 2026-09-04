#!/bin/bash
set -euo pipefail

ACTION="${1:-add}"
NAMESPACE="open5gs-data"
POD_LABEL="app=upf"
DELAY="500ms"

POD=$(oc get pod -n "$NAMESPACE" -l "$POD_LABEL" -o jsonpath='{.items[0].metadata.name}')

if [ "$ACTION" = "add" ]; then
  echo "==> Injecting ${DELAY} latency on ${POD} in ${NAMESPACE}..."
  oc exec -n "$NAMESPACE" "$POD" -- tc qdisc add dev eth0 root netem delay "$DELAY"
  echo "==> Latency injected. UPF traffic will now have ${DELAY} added delay."
  echo "==> Check FlowRTT in the Network Observability console for elevated round-trip times."
  echo ""
  echo "==> To remove the latency, run: bash 11-inject-latency.sh remove"
elif [ "$ACTION" = "remove" ]; then
  echo "==> Removing latency from ${POD} in ${NAMESPACE}..."
  oc exec -n "$NAMESPACE" "$POD" -- tc qdisc del dev eth0 root netem 2>/dev/null || true
  echo "==> Latency removed."
else
  echo "Usage: bash 11-inject-latency.sh [add|remove]"
  exit 1
fi
