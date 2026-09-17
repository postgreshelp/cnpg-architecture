#!/usr/bin/env bash
# 04-deploy-minio.sh — self-hosted S3-compatible object store for Barman Cloud (repo2 equivalent)
set -euo pipefail

# Create/update credentials first.
kubectl apply -f ../manifests/secrets/minio-creds-secret.yaml -n minio

# Storage and MinIO resources.
kubectl apply -f ../manifests/minio/minio-pvc.yaml
kubectl apply -f ../manifests/minio/minio-deployment.yaml
kubectl apply -f ../manifests/minio/minio-service.yaml

echo "== Waiting for MinIO to be ready =="

# Restart so an existing MinIO deployment reloads newly generated Secret values.
kubectl rollout restart deployment/minio -n minio
kubectl rollout status deployment/minio -n minio --timeout=180s

kubectl get svc -n minio

echo "MinIO console: run 'kubectl port-forward -n minio svc/minio 9001:9001' then browse http://localhost:9001"
echo "Default creds are in manifests/secrets/minio-creds-secret.yaml — CHANGE THEM before any real use."
