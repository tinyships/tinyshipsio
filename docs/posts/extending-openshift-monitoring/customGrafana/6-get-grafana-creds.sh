#!/bin/bash

# Change this if you used a different namespace
NAMESPACE="my-custom-metrics"

echo "========================================"
echo "  Grafana Login Details"
echo "========================================"

# Get the Route URL
URL=$(oc get route custom-grafana-route -n $NAMESPACE -o jsonpath='{"https://"}{.spec.host}')
echo "URL:      $URL"

# Get the Username
USERNAME=$(oc get secret custom-grafana-admin-credentials -n $NAMESPACE -o jsonpath='{.data.GF_SECURITY_ADMIN_USER}' | base64 -d)
echo "Username: $USERNAME"

# Get the Password
PASSWORD=$(oc get secret custom-grafana-admin-credentials -n $NAMESPACE -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' | base64 -d)
echo "Password: $PASSWORD"

echo "========================================"
