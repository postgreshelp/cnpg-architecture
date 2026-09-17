#!/usr/bin/env bash
# 03-install-cnpg-operator.sh — CloudNativePG operator + kubectl-cnpg plugin
set -euo pipefail

CNPG_VERSION="${CNPG_VERSION:-1.30.0}"   # bump as needed; check https://github.com/cloudnative-pg/cloudnative-pg/releases

echo "== Installing cert-manager (required by the Barman Cloud CNPG-I plugin) =="
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=180s
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=180s
kubectl wait --for=condition=Available deployment/cert-manager-cainjector -n cert-manager --timeout=180s

echo "== Installing the CloudNativePG operator (cluster-scoped) =="
#kubectl apply -f "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-${CNPG_VERSION%.*}/releases/cnpg-${CNPG_VERSION}.yaml"
kubectl apply --server-side -f "https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-${CNPG_VERSION%.*}/releases/cnpg-${CNPG_VERSION}.yaml"

echo "== Waiting for the operator to be ready =="
kubectl rollout status deployment -n cnpg-system cnpg-controller-manager --timeout=180s

echo "== Installing the Barman Cloud CNPG-I plugin =="
kubectl apply -f https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.15.0/manifest.yaml
kubectl rollout status deployment -n cnpg-system barman-cloud --timeout=180s

echo "== Installing the kubectl cnpg plugin (used throughout the SOPs) =="
curl -sSfL https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/main/hack/install-cnpg-plugin.sh | \
  sh -s -- -b /usr/local/bin

kubectl cnpg version

echo "CloudNativePG operator installed."
