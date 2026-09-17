#!/usr/bin/env bash
# firewall-rules.sh — CentOS 9 firewalld rules for the ports this stack needs.
# Adjust the zone/interface names for your real network layout; this assumes a single-host lab
# with Minikube's docker driver (traffic mostly stays inside the docker/minikube network, but
# these are opened in case you expose NodePorts/port-forwards externally).
set -euo pipefail

ZONE="${ZONE:-public}"

# Kubernetes API (minikube control plane)
firewall-cmd --zone="$ZONE" --add-port=8443/tcp --permanent

# NodePort range, in case you expose Pooler/Cluster services as NodePort for external testing
firewall-cmd --zone="$ZONE" --add-port=30000-32767/tcp --permanent

# MinIO API + console, if you want to browse the console from outside the host
firewall-cmd --zone="$ZONE" --add-port=9000/tcp --permanent
firewall-cmd --zone="$ZONE" --add-port=9001/tcp --permanent

# PostgreSQL / pgBouncer, if/when you port-forward or NodePort-expose 5432 externally
firewall-cmd --zone="$ZONE" --add-port=5432/tcp --permanent

firewall-cmd --reload
firewall-cmd --list-ports --zone="$ZONE"
