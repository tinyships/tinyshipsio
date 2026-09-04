#!/bin/bash
set -euo pipefail

CATALOG_DIR="custom-catalog"
SOURCE_DIR_REDHAT="full-catalog"
SOURCE_DIR_CERTIFIED="full-catalog-certified"

# Red Hat Operators catalog
OPERATORS=(
  # Currently installed operators: include these to ensure existing
  # subscriptions can resolve updates after switching catalogs
  "netobserv-operator"
  "loki-operator"
  "openshift-cert-manager-operator"
  "rhbk-operator"
  "odf-operator"
  # ODF dependency operators: auto-managed by ODF but must be present
  # in the catalog for OLM to resolve updates
  "cephcsi-operator"
  "mcg-operator"
  "ocs-client-operator"
  "ocs-operator"
  "odf-csi-addons-operator"
  "odf-dependencies"
  "odf-external-snapshotter-operator"
  "odf-prometheus-operator"
  "ocs-tls-profiles"
  "recipe"
  "rook-ceph-operator"
  # Developer-facing operators
  "openshift-pipelines-operator-rh"
  "openshift-gitops-operator"
  "amq-streams"
  "amq-broker-rhel8"
  "serverless-operator"
  "rh-service-binding-operator"
  "web-terminal"
  "devworkspace-operator"
  # Shared operators
  "quay-operator"
  # Admin-facing operators
  "cluster-logging"
  "compliance-operator"
  "file-integrity-operator"
  "rhacs-operator"
  "local-storage-operator"
  "nfd"
  "costmanagement-metrics-operator"
)

# Certified Operators catalog
CERTIFIED_OPERATORS=(
  "crunchy-postgres-operator"
  "datadog-operator"
)

if [ ! -d "${SOURCE_DIR_REDHAT}" ] || [ ! -d "${SOURCE_DIR_CERTIFIED}" ]; then
  echo "Error: ${SOURCE_DIR_REDHAT} and/or ${SOURCE_DIR_CERTIFIED} not found."
  echo "Extract both catalogs from their index images first (use your cluster's minor version):"
  echo "  podman create --name temp-idx registry.redhat.io/redhat/redhat-operator-index:v4.22"
  echo "  podman cp temp-idx:/configs ${SOURCE_DIR_REDHAT}"
  echo "  podman rm temp-idx"
  echo "  podman create --name temp-idx-certified registry.redhat.io/redhat/certified-operator-index:v4.22"
  echo "  podman cp temp-idx-certified:/configs ${SOURCE_DIR_CERTIFIED}"
  echo "  podman rm temp-idx-certified"
  exit 1
fi

rm -rf "${CATALOG_DIR}"
mkdir -p "${CATALOG_DIR}"

FOUND=0
MISSING=0

copy_operators() {
  local source_dir="$1"
  local -n operators_ref="$2"

  echo "Copying operator packages from ${source_dir}..."
  for operator in "${operators_ref[@]}"; do
    if [ -d "${source_dir}/${operator}" ]; then
      cp -r "${source_dir}/${operator}" "${CATALOG_DIR}/${operator}"
      echo "  Copied: ${operator}"
      FOUND=$((FOUND+1))
    else
      echo "  MISSING: ${operator}"
      MISSING=$((MISSING+1))
    fi
  done
}

copy_operators "${SOURCE_DIR_REDHAT}" OPERATORS
copy_operators "${SOURCE_DIR_CERTIFIED}" CERTIFIED_OPERATORS

echo ""
echo "Validating catalog..."
opm validate "${CATALOG_DIR}"

echo ""
echo "Catalog built successfully in ${CATALOG_DIR}/"
echo "Operators included: ${FOUND}"
if [ ${MISSING} -gt 0 ]; then
  echo "WARNING: ${MISSING} operator(s) not found in source index"
fi
