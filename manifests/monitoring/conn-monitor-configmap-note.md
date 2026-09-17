# Loading the script into the CronJob

The CronJob mounts `conn_monitor.py` from a ConfigMap. Create it from the script file before
applying the CronJob:

```bash
kubectl create configmap conn-monitor-script \
  --from-file=conn_monitor.py=../scripts/monitor/conn_monitor.py \
  -n tars-common
kubectl apply -f conn-monitor-secret.yaml -n tars-common   # after filling in the real password
kubectl apply -f conn-monitor-cronjob.yaml
```
