# Prometheus scraping

`enablePodMonitor: true` on the Cluster/DR manifests creates a `PodMonitor` CRD object, but it
only does something if the Prometheus Operator is already installed in this Minikube. For a full
lab setup:

```bash
kubectl create namespace monitoring
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prom-stack prometheus-community/kube-prometheus-stack -n monitoring
```

CNPG then exposes standard `pg_*` metrics (connections, replication lag, WAL, checkpoints) on
each instance pod's `:9187/metrics` — scrape target is created automatically once the
PodMonitor CRD exists and the Prometheus Operator's `podMonitorSelector` picks it up (default
kube-prometheus-stack config does, via label match).
