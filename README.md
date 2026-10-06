# ecommerce-shop-gitops

GitOps configuration for the ecommerce shop, running on a Proxmox homelab k3s cluster modelled after a production AWS EKS setup.

Part of a multi-repo project:

| Repo                                                                         | Purpose                                                        |
| ---------------------------------------------------------------------------- | -------------------------------------------------------------- |
| [ecommerce-shop-gitops](https://github.com/KristijanJ/ecommerce-shop-gitops) | This repo. Kubernetes manifests, ArgoCD, platform tooling      |
| [ecommerce-shop-be](https://github.com/KristijanJ/ecommerce-shop-be)         | NestJS REST API                                                |
| [ecommerce-shop-fe](https://github.com/KristijanJ/ecommerce-shop-fe)         | Next.js frontend                                               |

---

## Architecture

```text
┌──────────────────────────────────────────────────────────────────┐
│                     Proxmox Homelab                              │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                  k3s Cluster                            │    │
│  │                                                         │    │
│  │  ┌──────────────┐   ┌──────────────┐  ┌─────────────┐  │    │
│  │  │ control-plane│   │   worker-1   │  │  worker-2   │  │    │
│  │  │ 192.168.0.20 │   │ 192.168.0.21 │  │192.168.0.22 │  │    │
│  │  │   (Traefik)  │   │              │  │             │  │    │
│  │  └──────┬───────┘   └──────────────┘  └─────────────┘  │    │
│  │         │                                               │    │
│  │    svclb (klipper) forwards 80/443 on all nodes         │    │
│  │                                                         │    │
│  │  ┌──────────────────────┐  ┌──────────────────────────┐ │    │
│  │  │  homelab-frontend    │  │   homelab-backend        │ │    │
│  │  │    (Next.js)         │  │    (NestJS)              │ │    │
│  │  └──────────────────────┘  └──────────────────────────┘ │    │
│  │  ┌─────────────────────────────────────────────────────┐ │    │
│  │  │                  monitoring                         │ │    │
│  │  │   Prometheus · Grafana · Loki · Tempo · Collector   │ │    │
│  │  └─────────────────────────────────────────────────────┘ │    │
│  │  ┌─────────────────────────────────────────────────────┐ │    │
│  │  │        vault · external-secrets · argocd            │ │    │
│  │  └─────────────────────────────────────────────────────┘ │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              services VM  (192.168.0.30)                │    │
│  │              PostgreSQL :5432 · Redis :6379             │    │
│  └─────────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────────┘
```

Stateless services (frontend and backend) run in Kubernetes. Stateful services (PostgreSQL and Redis) run on a dedicated services VM, the same way AWS RDS and ElastiCache sit outside EKS in production.

---

## Platform stack

| Component                     | Purpose                    | Notes                                                 |
| ----------------------------- | -------------------------- | ----------------------------------------------------- |
| ArgoCD                        | GitOps continuous delivery | App of Apps pattern                                   |
| Kustomize                     | Environment overlays       | `base/` + `envs/homelab/`                             |
| Traefik                       | Ingress controller         | DaemonSet on control-plane, k3s svclb for LB IPs      |
| Vault                         | Secrets backend            | Dev mode in homelab, swappable to AWS Secrets Manager |
| External Secrets Operator     | Secret sync                | Pulls from Vault into Kubernetes Secrets              |
| kube-prometheus-stack         | Metrics & dashboards       | Prometheus + Grafana + Alertmanager                   |
| Loki                          | Log aggregation            | Receives logs from the collector over OTLP            |
| Tempo                         | Tracing backend            | Single-binary mode, 3 day retention, 5Gi PVC          |
| OpenTelemetry Collector       | Telemetry pipeline         | Apps push OTLP; fans out to Tempo, Loki, Prometheus   |
| Metrics Server                | Resource metrics           | Required for HPA                                      |

---

## GitOps design

### App of Apps

ArgoCD is bootstrapped with a cluster Secret and two root Applications:

```text
argocd/bootstrap/
├── 00-cluster-<env>.yaml   → labels the local cluster with env=<env> (homelab or aws-prod)
├── 01-root-platform.yaml   → watches argocd/appSets/platform/  (Traefik, Vault, Prometheus, Loki, ...)
└── 02-root-apps.yaml       → watches argocd/appSets/application/ (frontend, backend, infrastructure)
```

Each cluster runs its own ArgoCD. The ApplicationSets use the `clusters` generator and select clusters by the `env` label on the cluster Secret, so the same appset files work in every cluster. The local cluster has no Secret by default, so `00-cluster-<env>.yaml` must be applied before the root Applications. Without it the generators match nothing and `prune` removes the Applications.

Any change pushed to this repo is picked up automatically, with no manual `kubectl apply` needed after the initial bootstrap.

### Kustomize base/overlay

```text
apps/
├── backend/
│   ├── base/               # Environment-agnostic manifests
│   └── envs/
│       └── homelab/        # Proxmox k3s patches (ingress host, network policies)
└── frontend/
    ├── base/
    └── envs/
        └── homelab/        # Proxmox k3s patches (API URL, ingress host, network policies)
```

`namePrefix: homelab-` in the homelab overlay means all resources are namespaced by environment, so multiple environments can coexist in the same cluster.

### Sync waves

Deployment ordering within a sync is controlled by `argocd.argoproj.io/sync-wave`:

```text
wave -2  ExternalSecret    → ESO creates db-credentials and jwt-secret from Vault
wave -1  Migration Job     → TypeORM runs database migrations (retries until secrets exist)
wave  0  Deployment        → Application pods start (secrets are guaranteed to be present)
```

The migration Job is an ArgoCD hook (`hook: Sync`, `hook-delete-policy: BeforeHookCreation`). ArgoCD deletes and recreates it on every sync instead of patching it, because Job specs are immutable.

---

## Secrets management

No secret values exist anywhere in this repository. Git holds only the _shape_ of secrets, not their values.

```text
Vault (dev mode)
  └── secret/db    → db-credentials  K8s Secret  (backend namespace)
  └── secret/jwt   → jwt-secret      K8s Secret  (backend + frontend namespaces)
        ↑
  ExternalSecret (pointer in Git) → ESO pulls and creates the K8s Secret
```

When moving to AWS, swap the `ClusterSecretStore` backend from Vault to AWS Secrets Manager using IRSA. Nothing else in the manifests changes.

---

## Observability

Prometheus, Loki, Tempo, an OpenTelemetry Collector and Grafana run in the `monitoring` namespace, deployed through ArgoCD. The apps push traces, metrics and logs over OTLP to the collector (`opentelemetry-collector.monitoring:4318`), and the collector forwards them:

- Traces go to Tempo.
- Logs go to Loki through its OTLP endpoint.
- Metrics go to Prometheus through its OTLP receiver. Prometheus also scrapes cluster and node metrics.
- The collector's `spanmetrics` connector turns traces into request-count and latency histograms (`traces_span_metrics_calls_total` and `traces_span_metrics_duration_milliseconds_bucket`). The histograms carry trace-ID exemplars, so a point on a latency graph links to its trace. The apps' own metrics have no exemplars, because the JS SDK doesn't attach them.
- Grafana has Prometheus, Loki and Tempo as datasources. It links a log line to its trace, a trace to its logs and an exemplar to its trace.
- Both apps log with [pino](https://getpino.io). Logs are JSON by default.

Each app sets `OTEL_SERVICE_NAME` (`ecommerce-be`, `ecommerce-fe`), `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_RESOURCE_ATTRIBUTES=service.instance.id=$(POD_NAME)` in its deployment. The instance id gives each replica its own metric series. Without it, replicas share one series and `rate()` reports a number that is far too high. The network policies allow egress to the `monitoring` namespace on ports 4317 and 4318.

Promtail is no longer deployed, so logs from system and platform pods are not collected. Only what the apps send through the collector reaches Loki.

Query logs in Grafana under Explore, with the Loki datasource:

```logql
{service_name="ecommerce-be"}
{service_name="ecommerce-fe"}
```

---

## Security

### NetworkPolicies

Both application namespaces use a default-deny-all policy with explicit allow rules:

| Namespace          | Allowed ingress    | Allowed egress                                         |
| ------------------ | ------------------ | ------------------------------------------------------ |
| `homelab-frontend` | Traefik only       | Backend :3000, Redis :6379, collector :4317/:4318, DNS |
| `homelab-backend`  | Traefik + Frontend | PostgreSQL :5432, collector :4317/:4318, DNS           |

### No secrets in Git

See [Secrets management](#secrets-management). Vault and the External Secrets Operator keep credentials out of commits.

---

## Reliability

| Feature            | Implementation                                                                    |
| ------------------ | --------------------------------------------------------------------------------- |
| Health checks      | `/health` (liveness) and `/ready` (readiness) on both apps                        |
| Autoscaling        | HPA on frontend and backend                                                       |
| Disruption budget  | PodDisruptionBudget ensures minimum availability during node drains               |
| Migration ordering | Sync-wave -1 guarantees migrations run before pods start                          |
| Self-healing       | `selfHeal: true` on all ArgoCD apps, so the cluster corrects manual changes       |

---

## Quick start for the homelab

### Prerequisites

- Proxmox VMs up and k3s cluster running
- Worker VMs set to the Proxmox CPU type `host`. Tempo 3.x does not start on the default `kvm64` type, because it needs x86-64-v2 instructions
- `kubectl` configured to point at the cluster
- `argocd` CLI installed

### 1. Log in to the ArgoCD CLI

ArgoCD runs as a ClusterIP service, so port-forward first:

```bash
make argocd-ui   # port-forwards to localhost:8080, keep this running in a separate terminal
```

Then log in:

```bash
argocd login localhost:8080 --insecure --username admin --password $(make argocd-password)
```

### 2. Run the bootstrap script

```bash
./scripts/start-homelab.sh
```

The script installs ArgoCD, deploys the platform stack, seeds Vault and deploys the applications, in that order.

### 3. Access

- Frontend: <http://ecommerce.192.168.0.20.traefik.me>
- Backend API: <http://api.192.168.0.20.traefik.me>
- ArgoCD: run `make argocd-ui`, then open <https://localhost:8080>
- Grafana: run `make grafana-ui`, then open <http://localhost:3000> (admin/admin)
- Vault: run `make vault-ui`, then open <http://localhost:8200> (token: root)

---

## After a Proxmox restart

When Proxmox is shut down and powered back on, the following steps are needed:

### 1. Wait for the cluster to come up

VMs auto-start (start-on-boot enabled). k3s starts automatically via systemd on each node. Give it about 2 minutes for all nodes to rejoin and pods to reschedule.

```bash
kubectl get nodes        # all should be Ready
kubectl get pods -A      # wait for everything to be Running
```

### 2. Fix the ArgoCD repo-server (if needed)

When a node shuts down abruptly, pods on that node get stuck in `Unknown` state. Kubernetes does not automatically reschedule them. The most common victim is `argocd-repo-server`.

Symptom: the ArgoCD UI shows `connection error: dial tcp <ip>:8081: connect: connection refused` across all apps.

Fix:

```bash
kubectl get pods -n argocd                          # find the Unknown pod
kubectl delete pod -n argocd <repo-server-pod>      # delete it, it reschedules immediately
```

### 3. Reseed Vault

Vault runs in dev mode and loses all secrets on pod restart. Without this step the backend can't connect to the database.

```bash
make vault-seed
```

### 4. Verify

```bash
kubectl get pods -A                  # everything Running
curl http://api.192.168.0.20.traefik.me/products   # should return JSON
```

---

## Makefile reference

```bash
make help               # full command list

# ArgoCD
make argocd-ui          # https://localhost:8080
make argocd-password    # initial admin password
make argocd-status      # application sync status

# Vault
make vault-seed         # seed DB credentials + JWT secret
make vault-get          # read current secrets from Vault
make vault-ui           # http://localhost:8200

# Monitoring
make grafana-ui         # http://localhost:3000  (admin/admin)
make prometheus-ui      # http://localhost:9090
make alertmanager-ui    # http://localhost:9093

# Debugging
make pods               # all pods across namespaces
make logs-backend       # tail backend pod logs
make logs-frontend      # tail frontend pod logs
make hpa                # HPA status
make events             # recent warning events
```

---

## Planned: EKS

The homelab setup is intentionally structured to map cleanly to AWS:

| Homelab                  | AWS                                                  |
| ------------------------ | ---------------------------------------------------- |
| k3s on Proxmox           | EKS                                                  |
| Traefik                  | AWS Load Balancer Controller                         |
| Vault (dev mode)         | AWS Secrets Manager + IRSA                           |
| self-signed TLS          | cert-manager + ACM / Let's Encrypt                   |
| Services VM (PG + Redis) | RDS (Postgres) + ElastiCache (Redis)                 |
| Manual image load        | GitHub Actions → ECR → image tag update in this repo |
