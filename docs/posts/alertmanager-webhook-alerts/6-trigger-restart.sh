#!/bin/bash
set -e

echo "==> Sending SIGUSR1 to crash the log-generator container..."
oc exec -n logspam deploy/log-generator -- bash -c 'kill -USR1 1'

echo "==> Waiting for the container to restart..."
sleep 5
oc get pods -n logspam -l app=log-generator

echo ""
echo "==> The LogspamContainerRestarted alert should fire within ~3 minutes."
echo "    (increase() registers the restart + 1 minute 'for' duration)"
echo ""
echo "==> Watch the webhook receiver logs for the alert notification:"
echo "    oc logs -n logspam -l app=webhook-receiver -f"
