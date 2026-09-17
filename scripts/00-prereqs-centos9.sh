#!/usr/bin/env bash
# 00-prereqs-centos9.sh
# Base OS prep for a CentOS/RHEL 9-compatible host that will run Minikube + CNPG.
# POC-friendly: do not perform a full OS update and do not require firewalld.
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "ERROR: run this script as root."
  exit 1
fi

if command -v dnf >/dev/null 2>&1; then
  echo "== Detected DNF-based OS =="
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    echo "OS: ${PRETTY_NAME:-unknown}"
  fi
else
  echo "ERROR: dnf is required. This POC targets CentOS/RHEL 9-compatible systems."
  exit 1
fi

echo "== Installing base tooling =="
# Deliberately no 'dnf update': on RHEL/enterprise lab hosts it may require
# subscription/repository access and is not required to run this POC.
dnf install -y curl wget git vim tar unzip jq bash-completion \
  conntrack socat python3 python3-pip

echo "== Container/Kubernetes kernel prerequisites =="
# br_netfilter provides the bridge sysctl keys on systems where the module is not
# loaded automatically. Ignore the load failure only if the module is unavailable;
# the relevant sysctl checks below will then report the actual state.
modprobe br_netfilter 2>/dev/null || true

cat > /etc/sysctl.d/99-k8s.conf <<'SYSCTL'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
vm.max_map_count = 262144
SYSCTL

# Apply what is available. On some minimal kernels the bridge keys can be absent;
# do not make an otherwise usable Docker/Minikube POC fail solely on those keys.
sysctl --system >/tmp/tars-k8s-sysctl.log 2>&1 || {
  echo "WARNING: one or more sysctl settings could not be applied."
  cat /tmp/tars-k8s-sysctl.log
}

for key in net.ipv4.ip_forward vm.max_map_count; do
  value="$(sysctl -n "$key" 2>/dev/null || echo unavailable)"
  echo "  $key = $value"
done

if systemctl list-unit-files firewalld.service >/dev/null 2>&1; then
  echo "== firewalld detected; leaving current state unchanged =="
  echo "   Minikube/Docker POC does not require firewalld to be enabled by this script."
else
  echo "== firewalld not installed; skipping (not required for this POC) =="
fi

echo "== Host resources =="
echo "Recommended for this 8GB laptop POC: 4 vCPU / 5GB Minikube RAM / 40GB disk."
echo "nproc: $(nproc)"
free -h
df -h /

echo "Prereqs done. Reboot is normally not required; if Docker/kernel modules behave oddly, reboot before continuing."
