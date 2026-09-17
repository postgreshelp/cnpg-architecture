#!/usr/bin/env bash
# setup-edb-registry.sh — turns an EDB account's registry credentials into a working
# imagePullSecret in both tars-db and tars-db-dr, so the clusters can pull EDB-supported images
# (EDB Postgres Advanced Server, EDB's hardened community builds, etc).
#
# What this script does NOT and CANNOT do: obtain the credentials themselves. Those come from
# your EDB account — log in at https://www.enterprisedb.com, go to your subscription/portal
# access page, and generate a registry username + token/password there. This script only wires
# whatever you already have into Kubernetes.
#
# Usage: ./setup-edb-registry.sh
#   (interactive — prompts for registry host, username, password/token; password input is
#    hidden and never written to disk or the log file)
set -euo pipefail

echo "== EDB container registry setup =="
echo "You'll need credentials from your EDB account portal (Subscriptions -> Repos/Registry access)."
echo

read -r -p "EDB registry hostname [docker.enterprisedb.com]: " REGISTRY_HOST
REGISTRY_HOST="${REGISTRY_HOST:-docker.enterprisedb.com}"
# NOTE: confirm the exact hostname on your EDB portal — EDB has used different registry hosts
# for different product lines/subscription tiers historically. Don't assume the default above
# is correct for your account without checking.

read -r -p "EDB registry username/email: " REGISTRY_USER
read -r -s -p "EDB registry password/token: " REGISTRY_PASS
echo

for ns in tars-db tars-db-dr; do
  kubectl create secret docker-registry edb-registry-creds \
    --docker-server="$REGISTRY_HOST" \
    --docker-username="$REGISTRY_USER" \
    --docker-password="$REGISTRY_PASS" \
    -n "$ns" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  imagePullSecret 'edb-registry-creds' applied in namespace $ns"
done

unset REGISTRY_PASS

cat << 'NEXT'

Secret created. To actually use an EDB image instead of the community CNPG image:

  1. In manifests/cluster/cluster-primary.yaml and manifests/dr/cluster-dr-replica.yaml, set:
       spec:
         imageName: <your-edb-registry-host>/<your-edb-image>:<tag>
         imagePullSecrets:
           - name: edb-registry-creds
     (the imagePullSecrets block is already present, commented out, in both files below the
     imageName line — just uncomment it and update imageName next to it)

  2. Re-apply:
       kubectl apply -f manifests/cluster/cluster-primary.yaml
       kubectl apply -f manifests/dr/cluster-dr-replica.yaml

  3. CNPG will roll the change out instance-by-instance (primaryUpdateStrategy: unsupervised),
     replacing the community image with your EDB one without downtime for the whole cluster.

Verify the pull actually worked before trusting it:
  kubectl get pods -n tars-db -l cnpg.io/cluster=tarsdb-primary
  kubectl describe pod <pod-name> -n tars-db | grep -A3 Events
NEXT
