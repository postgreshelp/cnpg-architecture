#!/usr/bin/env bash
# 09-load-test-data.sh — create schema + load 100k test rows via port-forward, same pattern as
# the original assignment's fake_inserts.py, retargeted at the CNPG primary service.
set -euo pipefail

# Pull the real generated app-user password out of the Secret rather than assuming a hardcoded
# one — this is what makes the loader safe to run after generate-secrets.sh randomizes creds.
export TARS_PGPASSWORD="$(kubectl get secret tarsdb-app-user -n tars-db -o jsonpath='{.data.password}' | base64 -d)"

echo "== Creating schema =="
# Must run as tars_admin (the database owner), not postgres: tables created by postgres would be
# owned by postgres, and owning the database does not grant privileges on another role's tables —
# fake_inserts.py connects as tars_admin and would hit "permission denied" on every insert.
# -h 127.0.0.1 forces password (scram) auth over TCP instead of peer auth on the unix socket,
# since there's no OS user named "tars_admin" inside the container for peer auth to match.
kubectl exec -i -n tars-db tarsdb-primary-1 -- env PGPASSWORD="$TARS_PGPASSWORD" \
  psql -h 127.0.0.1 -U tars_admin -d tars < ../sql/create_tables.sql

export TARS_PGPORT="${TARS_PGPORT:-15432}"

echo "== Port-forwarding tarsdb-primary-rw:5432 -> localhost:${TARS_PGPORT} in background =="
# A fixed local port (rather than 5432) avoids colliding with any Postgres already running
# on the host itself — kubectl port-forward fails to bind silently in the background, and
# psycopg2 would otherwise happily connect straight through to that unrelated host instance.
kubectl port-forward -n tars-db svc/tarsdb-primary-rw "${TARS_PGPORT}:5432" &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT

echo "== Waiting for the port-forward to come up =="
for i in $(seq 1 15); do
  kill -0 "$PF_PID" 2>/dev/null || { echo "port-forward process died"; exit 1; }
  (echo > "/dev/tcp/127.0.0.1/${TARS_PGPORT}") 2>/dev/null && break
  [ "$i" -eq 15 ] && { echo "port-forward never became reachable on ${TARS_PGPORT}"; exit 1; }
  sleep 1
done

pip3 install --quiet faker psycopg2-binary

python3 ../fake_inserts.py

echo "Data load complete."
