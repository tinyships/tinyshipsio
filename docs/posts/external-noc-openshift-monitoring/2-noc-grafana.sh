#!/bin/bash
set -euo pipefail

NOC_DIR="/opt/noc-monitoring"

echo "Creating directory structure..."
sudo mkdir -p "${NOC_DIR}/grafana/provisioning/datasources"
sudo mkdir -p "${NOC_DIR}/data/grafana"

echo "Generating Grafana datasource..."
sudo tee "${NOC_DIR}/grafana/provisioning/datasources/prometheus.yaml" > /dev/null <<'EOF'
apiVersion: 1
datasources:
- name: OpenShift Metrics
  type: prometheus
  url: http://noc-prometheus:9090
  isDefault: true
  editable: true
EOF

echo "Setting permissions..."
sudo chown -R 472:472 "${NOC_DIR}/data/grafana"

echo "Starting Grafana..."
sudo podman run -d --name noc-grafana \
  --network noc-monitoring \
  --restart=always \
  -p 3000:3000 \
  -v "${NOC_DIR}/grafana/provisioning:/etc/grafana/provisioning:Z" \
  -v "${NOC_DIR}/data/grafana:/var/lib/grafana:Z" \
  -e GF_SECURITY_ADMIN_USER=admin \
  -e GF_SECURITY_ADMIN_PASSWORD=changeme \
  -e GF_SERVER_HTTP_ADDR=0.0.0.0 \
  -e GF_SERVER_HTTP_PORT=3000 \
  docker.io/grafana/grafana:latest

echo ""
echo "========================================="
echo "  NOC Grafana Started"
echo "========================================="
echo "  Grafana: http://$(hostname -f):3000"
echo "  Login:   admin / changeme"
echo "========================================="
echo ""
echo "Change the default password after first login."
