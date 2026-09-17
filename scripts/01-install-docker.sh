#!/usr/bin/env bash
# 01-install-docker.sh — Docker CE as the Minikube driver on CentOS 9
set -euo pipefail

dnf install -y dnf-plugins-core
dnf config-manager --add-repo=https://download.docker.com/linux/centos/docker-ce.repo
dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker

# Allow running docker/minikube as a non-root deploy user (recommended over root for CNPG work)
DEPLOY_USER="${SUDO_USER:-$(logname)}"
usermod -aG docker "$DEPLOY_USER"
echo "Added $DEPLOY_USER to the docker group — log out/in (or 'newgrp docker') for it to take effect."

systemctl status docker --no-pager
