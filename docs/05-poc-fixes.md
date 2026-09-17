# 05 — POC Fixes Applied

This revision is intended for the **CNPG migration POC/demo**, not production hardening.

## Fixes included

1. **CloudNativePG version**
   - Updated the default operator from 1.24.1 to **1.30.0**.
   - 1.24 is EOL; 1.30 is the current supported line used by this POC.

2. **Barman Cloud CNPG-I plugin**
   - Added cert-manager installation.
   - Added the Barman Cloud CNPG-I plugin.
   - Replaced the deprecated in-tree `spec.backup.barmanObjectStore` configuration with a namespace-scoped `ObjectStore` and `spec.plugins` configuration.
   - Updated `ScheduledBackup` and DR recovery references to use the plugin.

3. **POC backup seeding**
   - The production schedule remains weekly.
   - The primary deployment now creates and waits for an initial on-demand backup before the DR cluster is deployed. This prevents the DR bootstrap from starting against an empty repository during a fresh POC run.

4. **ScheduledBackup cron format**
   - Corrected the schedule to CNPG's six-field cron format: Sunday 22:00 is `0 0 22 * * 0`.

5. **Minikube sizing**
   - Increased the default POC Minikube size to 6 vCPU / 20 GiB RAM / 60 GiB disk because the primary PostgreSQL pods intentionally retain the TARS-like resource settings.
   - The values can be overridden with `MINIKUBE_CPUS`, `MINIKUBE_MEMORY`, and `MINIKUBE_DISK`.

6. **Runbook correction**
   - Fixed the connection-monitor log command to use the `tars-common` namespace.

7. **Test-data loader port collision (`scripts/09-load-test-data.sh`, `fake_inserts.py`)**
   - The loader's `kubectl port-forward` hardcoded local port 5432. On a host that already runs
     its own PostgreSQL on 5432 (common on dev boxes), the forward silently failed to bind and
     `fake_inserts.py` connected straight through to that unrelated host instance instead — which
     correctly rejected the password, surfacing as a confusing `password authentication failed for
     user "tars_admin"` error with no obvious link to a port conflict.
   - Fixed by forwarding to a dedicated local port (`15432` by default, overridable via
     `TARS_PGPORT`) and by having the script verify the forward is actually reachable before
     invoking the loader, instead of assuming success. See "Troubleshooting" in the README.

8. **Documentation correction: Pooler service name**
   - `docs/01-architecture-theory.md`, `docs/03-connection-pooling-theory.md`, and the README's
     step-by-step guide referred to the Pooler's Service as `tarsdb-pgbouncer-rw`. The actual
     Service (confirmed against a live cluster) is `tarsdb-pgbouncer` — a CNPG `Pooler`'s Service
     takes the `Pooler` object's own name, with no `-rw` suffix. Corrected in all three places.

## Deliberately left as follow-up hardening

- PgBouncer client/server TLS certificates and enforcement.
- Production NetworkPolicies.
- Production-grade object storage instead of single-node MinIO.
- Separate local backup repository equivalent to TARS repo1.
- Production alert email/SMTP configuration.
- Pinned production images for MinIO and helper containers.
- pgAdmin deployment.
- Production storage classes, anti-affinity, topology spread and multi-node placement.
- Production secret-management integration.
- Real multi-site DR/fencing rather than two namespaces in one Minikube cluster.
- `teardown.sh` degrading gracefully when the Minikube API server is unreachable (currently it
  needs a live cluster and fails immediately under `set -e` if Minikube is `Stopped`; documented
  workaround in the README's "Troubleshooting" section and `docs/06-architecture-diagrams.md` §7).
