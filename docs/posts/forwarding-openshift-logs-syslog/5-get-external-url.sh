#!/bin/bash
# Get the external IP and NodePort for the rsyslog server,
# then patch the ClusterLogForwarder to use it.

NODE_IP=$(oc get nodes -l node-role.kubernetes.io/worker \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')

# Fall back to InternalIP if ExternalIP is not set (common on bare-metal clusters)
if [ -z "$NODE_IP" ]; then
  NODE_IP=$(oc get nodes -l node-role.kubernetes.io/worker \
    -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
fi

NODE_PORT=$(oc get svc rsyslog-external -n syslog-server \
  -o jsonpath='{.spec.ports[?(@.name=="syslog-tcp")].nodePort}')

SYSLOG_URL="tcp://${NODE_IP}:${NODE_PORT}"

echo "External syslog URL: ${SYSLOG_URL}"
echo ""
echo "Patching ClusterLogForwarder..."

oc patch clusterlogforwarder instance -n openshift-logging \
  --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/outputs/0/syslog/url\",\"value\":\"${SYSLOG_URL}\"}]"

echo "Done. Verify with:"
echo "  oc get clusterlogforwarder instance -n openshift-logging -o jsonpath='{.spec.outputs[0].syslog.url}'"
