#!/usr/bin/env bash
# 02-install-minikube-kubectl.sh
set -euo pipefail

echo "== kubectl =="
KVER="$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)"
curl -LO "https://storage.googleapis.com/kubernetes-release/release/${KVER}/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/kubectl
kubectl version --client

echo "== Minikube =="
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
install minikube-linux-amd64 /usr/local/bin/minikube
rm -f minikube-linux-amd64

echo "== Starting Minikube (sized for an 8GB-RAM laptop: CNPG primary+replica+DR+MinIO POC on one box) =="
MINIKUBE_CPUS="${MINIKUBE_CPUS:-4}"
MINIKUBE_MEMORY="${MINIKUBE_MEMORY:-5g}"
MINIKUBE_DISK="${MINIKUBE_DISK:-40g}"
minikube start --driver=docker --cpus="$MINIKUBE_CPUS" --memory="$MINIKUBE_MEMORY" --disk-size="$MINIKUBE_DISK" --force

minikube status
kubectl get nodes

echo "== Enable metrics-server (used by Pooler/Cluster autoscaling visibility, optional but useful) =="
minikube addons enable metrics-server

echo "== Namespaces =="
kubectl create namespace tars-db      --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace tars-db-dr   --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace minio        --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace tars-common  --dry-run=client -o yaml | kubectl apply -f -   # for conn-monitor, matching TARS's tars-monitor ns

echo "Minikube ready."
