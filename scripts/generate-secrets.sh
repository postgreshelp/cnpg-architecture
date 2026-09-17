#!/usr/bin/env bash
# generate-secrets.sh — generates strong random passwords, renders the real Secret manifests
# from their .template files, and writes a local credentials.txt (git-ignored) so you can
# retrieve them afterwards. Called automatically by one-click-deploy.sh; safe to re-run
# (re-randomizes and re-applies, so only run it again if you actually want to rotate creds).
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

SECRETS_DIR="manifests/secrets"
OUT_CREDS="credentials.txt"

randpass() { tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24; echo; }

MINIO_USER="tarsminioadmin"
MINIO_PASS="$(randpass)"
PG_SUPERUSER_PASS="$(randpass)"
PG_APP_PASS="$(randpass)"

echo "== Rendering real Secret manifests from templates =="

sed -e "s/tarsminioadmin/${MINIO_USER}/" \
    -e "s/ChangeMe_Str0ngPass!/${MINIO_PASS}/" \
    "$SECRETS_DIR/minio-creds-secret.yaml.template" > "$SECRETS_DIR/minio-creds-secret.yaml"

sed -e "s/ChangeMe_PgSuperuser!/${PG_SUPERUSER_PASS}/" \
    "$SECRETS_DIR/postgres-superuser-secret.yaml.template" > "$SECRETS_DIR/postgres-superuser-secret.yaml"

sed -e "s/REPLACED_BY_GENERATE_SECRETS_SH/${PG_APP_PASS}/" \
    "$SECRETS_DIR/postgres-app-secret.yaml.template" > "$SECRETS_DIR/postgres-app-secret.yaml"

sed -e "s/\"CHANGE_ME\"/\"${PG_SUPERUSER_PASS}\"/" \
    "manifests/monitoring/conn-monitor-secret.yaml.template" > "manifests/monitoring/conn-monitor-secret.yaml"

cat > "$OUT_CREDS" << CREDS
# Generated $(date -u +"%Y-%m-%dT%H:%M:%SZ") by generate-secrets.sh — KEEP THIS FILE SAFE,
# it is git-ignored but not encrypted. Rotate via 'kubectl edit secret ...' + a pod restart
# if these ever leak.

MinIO
  access key : ${MINIO_USER}
  secret key : ${MINIO_PASS}
  console    : kubectl port-forward -n minio svc/minio 9001:9001  -> http://localhost:9001

PostgreSQL superuser (postgres)
  password   : ${PG_SUPERUSER_PASS}

PostgreSQL app user (tars_admin, database: tars)
  password   : ${PG_APP_PASS}
CREDS
chmod 600 "$OUT_CREDS"

echo "Secrets generated. Credentials written to $(pwd)/${OUT_CREDS} (chmod 600)."
