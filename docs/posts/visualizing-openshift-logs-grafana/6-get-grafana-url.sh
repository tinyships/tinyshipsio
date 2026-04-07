#!/bin/bash
NAMESPACE="grafana-logging"
ROUTE=$(oc get route logging-grafana-route -n ${NAMESPACE} -o jsonpath='{.spec.host}' 2>/dev/null)
SECRET="secret/logging-grafana-admin-credentials"
USERNAME=$(oc get ${SECRET} -n ${NAMESPACE} -o jsonpath='{.data.GF_SECURITY_ADMIN_USER}' 2>/dev/null | base64 -d)
PASSWORD=$(oc get ${SECRET} -n ${NAMESPACE} -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' 2>/dev/null | base64 -d)

echo "========================================"
echo "  Grafana Login Details"
echo "========================================"
echo "URL:      https://${ROUTE}"
echo "Username: ${USERNAME:-admin}"
echo "Password: ${PASSWORD}"
echo "========================================"
