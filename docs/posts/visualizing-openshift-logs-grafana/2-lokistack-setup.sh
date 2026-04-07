#!/bin/bash
# Creates an ObjectBucketClaim backed by NooBaa, extracts the S3 credentials,
# builds the Loki secret, then deploys the LokiStack.
set -e

NAMESPACE="openshift-logging"
OBC_NAME="logging-loki-bucket"

echo "==> Creating ObjectBucketClaim..."
cat <<EOF | oc apply -f -
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: ${OBC_NAME}
  namespace: ${NAMESPACE}
spec:
  generateBucketName: logging-loki
  storageClassName: openshift-storage.noobaa.io
EOF

echo "==> Waiting for OBC to bind..."
until [ "$(oc get obc ${OBC_NAME} -n ${NAMESPACE} -o jsonpath='{.status.phase}')" = "Bound" ]; do
  echo "  waiting..."
  sleep 5
done

echo "==> Extracting S3 credentials..."
BUCKET_HOST=$(oc get cm ${OBC_NAME} -n ${NAMESPACE} -o jsonpath='{.data.BUCKET_HOST}')
BUCKET_PORT=$(oc get cm ${OBC_NAME} -n ${NAMESPACE} -o jsonpath='{.data.BUCKET_PORT}')
BUCKET_NAME=$(oc get cm ${OBC_NAME} -n ${NAMESPACE} -o jsonpath='{.data.BUCKET_NAME}')
ACCESS_KEY=$(oc get secret ${OBC_NAME} -n ${NAMESPACE} -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
SECRET_KEY=$(oc get secret ${OBC_NAME} -n ${NAMESPACE} -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)

echo "==> Creating Loki S3 secret..."
oc create secret generic logging-loki-s3 \
  -n ${NAMESPACE} \
  --from-literal=endpoint="http://${BUCKET_HOST}:${BUCKET_PORT}" \
  --from-literal=bucketnames="${BUCKET_NAME}" \
  --from-literal=access_key_id="${ACCESS_KEY}" \
  --from-literal=access_key_secret="${SECRET_KEY}" \
  --from-literal=region="us-east-1" \
  --dry-run=client -o yaml | oc apply -f -

echo "==> Deploying LokiStack..."
oc apply -f 3-lokistack.yaml

echo "==> Waiting for LokiStack to be ready (this takes a few minutes)..."
until oc get lokistack logging-loki -n ${NAMESPACE} \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; do
  echo "  waiting..."
  sleep 10
done

echo "LokiStack is ready."
