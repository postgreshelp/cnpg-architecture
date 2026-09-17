#!/usr/bin/env bash
# 05-create-minio-buckets.sh — create the "postgresbackup" bucket (matches TARS bucket name exactly)
set -euo pipefail

MINIO_ACCESS_KEY="$(kubectl get secret minio-creds -n minio -o jsonpath='{.data.ACCESS_KEY_ID}' | base64 -d)"
MINIO_SECRET_KEY="$(kubectl get secret minio-creds -n minio -o jsonpath='{.data.ACCESS_SECRET_KEY}' | base64 -d)"

kubectl run mc-client --rm -i --restart=Never --image=quay.io/minio/mc:latest -n minio \
  --env="MC_ACCESS=${MINIO_ACCESS_KEY}" --env="MC_SECRET=${MINIO_SECRET_KEY}" --command -- sh -c '
  mc alias set localminio http://minio.minio:9000 "$MC_ACCESS" "$MC_SECRET" &&
  mc mb --ignore-existing localminio/postgresbackup &&
  mc ls localminio
'
echo "Bucket postgresbackup created (or already existed)."
