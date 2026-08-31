#!/bin/bash
set -euo pipefail

NOC_DIR="/opt/noc-monitoring"

echo "Creating Podman network..."
sudo podman network create noc-monitoring 2>/dev/null || true

echo "Creating directory structure..."
sudo mkdir -p "${NOC_DIR}/prometheus"
sudo mkdir -p "${NOC_DIR}/data/prometheus"

echo "Generating Prometheus configuration..."
sudo tee "${NOC_DIR}/prometheus/prometheus.yml" > /dev/null <<'EOF'
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
EOF

echo "Setting permissions..."
sudo chown -R 65534:65534 "${NOC_DIR}/data/prometheus"

echo "Starting Prometheus with remote-write receiver enabled..."
sudo podman run -d --name noc-prometheus \
  --network noc-monitoring \
  --restart=always \
  -p 9090:9090 \
  -v "${NOC_DIR}/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:Z" \
  -v "${NOC_DIR}/data/prometheus:/prometheus:Z" \
  docker.io/prom/prometheus:latest \
  --config.file=/etc/prometheus/prometheus.yml \
  --web.enable-remote-write-receiver \
  --storage.tsdb.retention.time=30d \
  --web.listen-address=0.0.0.0:9090

echo ""
echo "========================================="
echo "  NOC Prometheus Started"
echo "========================================="
echo "  Prometheus: http://$(hostname -f):9090"
echo "  Remote-write endpoint:"
echo "    http://$(hostname -f):9090/api/v1/write"
echo "========================================="
