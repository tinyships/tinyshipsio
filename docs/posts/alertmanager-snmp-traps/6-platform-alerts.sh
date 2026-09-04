#!/bin/bash
set -e

echo "==> Reading current AlertManager configuration..."
CURRENT=$(oc -n openshift-monitoring get secret alertmanager-main \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d)

echo "==> Current configuration:"
echo "$CURRENT"
echo ""

cat > /tmp/alertmanager-snmp.yaml <<'ALERTMANAGER_CONFIG'
global:
  resolve_timeout: 5m
route:
  receiver: default
  group_by:
  - namespace
  - alertname
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
  routes:
  - match:
      severity: critical
    receiver: snmp-critical
  - match:
      severity: warning
    receiver: snmp-warning
receivers:
- name: default
- name: snmp-critical
  webhook_configs:
  - url: "http://snmp-notifier.snmp-demo.svc.cluster.local:9464/alerts"
    send_resolved: true
- name: snmp-warning
  webhook_configs:
  - url: "http://snmp-notifier.snmp-demo.svc.cluster.local:9464/alerts"
    send_resolved: true
ALERTMANAGER_CONFIG

echo "==> Applying new AlertManager configuration with SNMP receivers..."
oc -n openshift-monitoring create secret generic alertmanager-main \
  --from-file=alertmanager.yaml=/tmp/alertmanager-snmp.yaml \
  --dry-run=client -o yaml | oc apply -f -

echo ""
echo "==> Verifying new configuration..."
oc -n openshift-monitoring get secret alertmanager-main \
  -o jsonpath='{.data.alertmanager\.yaml}' | base64 -d

echo ""
echo "==> Done. Platform alerts with severity critical or warning will now route to snmp-notifier."
echo "    Watch the snmptrapd logs: oc logs -n snmp-demo -l app=snmptrapd -f"

rm -f /tmp/alertmanager-snmp.yaml
