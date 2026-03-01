# ecommerce-shop-gitops

GitOps configuration for the ecommerce shop, running on a local KinD cluster modelled after a production AWS EKS setup.

Part of a multi-repo project:

| Repo                                                                         | Purpose                                                        |
| ---------------------------------------------------------------------------- | -------------------------------------------------------------- |
| [ecommerce-shop-gitops](https://github.com/KristijanJ/ecommerce-shop-gitops) | **This repo** — Kubernetes manifests, ArgoCD, platform tooling |
| [ecommerce-shop-be](https://github.com/KristijanJ/ecommerce-shop-be)         | Express.js REST API                                            |
| [ecommerce-shop-fe](https://github.com/KristijanJ/ecommerce-shop-fe)         | Next.js frontend                                               |
| [ecommerce-infra](https://github.com/KristijanJ/ecommerce-infra)             | Local Docker Compose for PostgreSQL and Redis                  |

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                        KinD Cluster                              │
│  ┌──────────────┐  ┌───────────────────────────────────────────┐ │
│  │ control-plane│  │           worker nodes (x3)               │ │
│  │   (Traefik)  │  │                                           │ │
│  └──────┬───────┘  │  ┌───────────────┐  ┌──────────────────┐  │ │
│         │          │  │local-frontend │  │  local-backend   │  │ │
│    hostPort        │  │  (Next.js)    │  │   (Express.js)   │  │ │
│    80 / 443        │  └──────┬────────┘  └────────┬─────────┘  │ │
│         │          │         │                    │            │ │
│         │          │  ┌──────▼────────────────────▼─────────┐  │ │
│         │          │  │          monitoring                 │  │ │
│         │          │  │  Prometheus · Grafana · Loki        │  │ │
│         │          │  │  Alertmanager · Promtail            │  │ │
│         │          │  └─────────────────────────────────────┘  │ │
│         │          │  ┌─────────────────────────────────────┐  │ │
│         │          │  │   vault · external-secrets · argocd │  │ │
│         │          │  └─────────────────────────────────────┘  │ │
│         │          └───────────────────────────────────────────┘ │
└─────────┼────────────────────────────────────────────────────────┘
          │ Ingress
    ┌─────▼─────────────────────────────────────────────┐
    │              Docker (host machine)                │
    │          PostgreSQL :5432 · Redis :6379           │
    └───────────────────────────────────────────────────┘
```

**Stateless services** (frontend, backend) run in Kubernetes. **Stateful services** (PostgreSQL, Redis) run in Docker — mirroring how AWS RDS and ElastiCache are managed outside of EKS in production.

---

## Platform Stack

| Component                     | Purpose                    | Notes                                              |
| ----------------------------- | -------------------------- | -------------------------------------------------- |
| **ArgoCD**                    | GitOps continuous delivery | App of Apps pattern                                |
| **Kustomize**                 | Environment overlays       | `base/` + `envs/local/` + `envs/prod/`             |
| **Traefik**                   | Ingress controller         | DaemonSet on control-plane, hostPort 80/443        |
| **Vault**                     | Secrets backend            | Dev mode locally, swappable to AWS Secrets Manager |
| **External Secrets Operator** | Secret sync                | Pulls from Vault → Kubernetes Secrets              |
| **kube-prometheus-stack**     | Metrics & dashboards       | Prometheus + Grafana + Alertmanager                |
| **Loki + Promtail**           | Log aggregation            | Promtail DaemonSet ships pod logs to Loki          |
| **Metrics Server**            | Resource metrics           | Required for HPA                                   |
| **cloud-provider-kind**       | LoadBalancer support       | Assigns real IPs to LoadBalancer services in KinD  |

---

## GitOps Design

### App of Apps

ArgoCD is bootstrapped with two root Applications:

```
argocd/bootstrap/
├── 01-root-platform.yaml   → watches argocd/appSets/platform/  (Traefik, Vault, Prometheus, Loki, ...)
└── 02-root-apps.yaml       → watches argocd/appSets/application/ (frontend, backend, infrastructure)
```

Any change pushed to this repo is picked up automatically — no manual `kubectl apply` needed after the initial bootstrap.

### Kustomize base/overlay

```
apps/
├── backend/
│   ├── base/               # Environment-agnostic manifests
│   └── envs/
│       ├── local/          # KinD-specific patches (image, config, network policies)
│       └── prod/           # EKS-specific patches
└── frontend/
    ├── base/
    └── envs/
        ├── local/
        └── prod/
```

`namePrefix: local-` in the local overlay means all resources are namespaced by environment, so local and prod environments can coexist in the same cluster.

### Sync waves

Deployment ordering within a sync is controlled by `argocd.argoproj.io/sync-wave`:

```
wave -2  ExternalSecret    → ESO creates db-credentials and jwt-secret from Vault
wave -1  Migration Job     → Prisma runs database migrations (retries until secrets exist)
wave  0  Deployment        → Application pods start (secrets are guaranteed to be present)
```

The migration Job is an ArgoCD hook (`hook: Sync`, `hook-delete-policy: BeforeHookCreation`), so it is deleted and recreated on every sync rather than patched — which would fail since Job specs are immutable.

---

## Secrets Management

No secret values exist anywhere in this repository. Git holds only the _shape_ of secrets, not their values.

```
Vault (dev mode)
  └── secret/db    → db-credentials  K8s Secret  (backend namespace)
  └── secret/jwt   → jwt-secret      K8s Secret  (backend + frontend namespaces)
        ↑
  ExternalSecret (pointer in Git) → ESO pulls and creates the K8s Secret
```

When moving to AWS: swap the `ClusterSecretStore` backend from Vault to AWS Secrets Manager using IRSA. Nothing else in the manifests changes.

---

## Observability

The full PLG stack (Prometheus + Loki + Grafana) is deployed via ArgoCD:

- **Prometheus** scrapes cluster and node metrics
- **Promtail** (DaemonSet) ships pod logs from every node to Loki
- **Grafana** provides a single dashboard for both metrics and logs
- Both apps use **structured JSON logging** via [pino](https://getpino.io) — every log line is a JSON object Loki can parse and filter

Query logs in Grafana → Explore → Loki datasource:

```logql
{namespace="local-backend"} | json | level="error"
{namespace="local-frontend"} | json | msg=~".*payment.*"
```

---

## Security

### NetworkPolicies

Both application namespaces use a **default-deny-all** policy with explicit allow rules:

| Namespace        | Allowed ingress    | Allowed egress                  |
| ---------------- | ------------------ | ------------------------------- |
| `local-frontend` | Traefik only       | Backend :3000, Redis :6379, DNS |
| `local-backend`  | Traefik + Frontend | PostgreSQL :5432, DNS           |

### No secrets in Git

Covered above — Vault + ESO ensure no credentials are ever committed.

---

## Reliability

| Feature            | Implementation                                                                    |
| ------------------ | --------------------------------------------------------------------------------- |
| Health checks      | `/health` (liveness) and `/ready` (readiness) on both apps                        |
| Autoscaling        | HPA on frontend and backend                                                       |
| Disruption budget  | PodDisruptionBudget ensures minimum availability during node drains               |
| Migration ordering | Sync-wave -1 guarantees migrations run before pods start                          |
| Self-healing       | `selfHeal: true` on all ArgoCD apps — cluster corrects itself if manually changed |

---

## Quick Start

### Prerequisites

```bash
make check-requirements
```

Requires: `docker`, `kind`, `kubectl`, `argocd`, `helm`, `cloud-provider-kind`

### 1. Start local databases

```bash
# In the ecommerce-infra repo
make start-local
```

### 2. Start the cluster

```bash
make start        # creates KinD cluster, installs ArgoCD, bootstraps all apps
```

### 3. Load application images

KinD doesn't pull from public registries by default:

```bash
make load-backend-image   # BE_TAG=x.x.x to override
make load-frontend-image  # FE_TAG=x.x.x to override
```

### 4. Seed Vault

```bash
make vault-seed
```

After a minute or two, ArgoCD will have synced everything. The apps are accessible at:

- **Frontend:** https://ecommerce.127.0.0.1.traefik.me
- **Backend API:** https://api.127.0.0.1.traefik.me
- **ArgoCD:** `make argocd-ui` → https://localhost:8080

---

## Makefile Reference

```bash
make help               # full command list

# Cluster
make start              # full environment bootstrap
make cluster-create     # KinD cluster only
make cluster-delete     # delete cluster
make cluster-status     # node status
make lb                 # LoadBalancer support (separate terminal)

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

# Teardown
make clean              # remove ArgoCD applications
make nuke               # delete entire cluster
```

---

## Planned: EKS

The local setup is intentionally structured to map cleanly to AWS:

| Local                    | AWS                                                  |
| ------------------------ | ---------------------------------------------------- |
| KinD cluster             | EKS                                                  |
| Traefik                  | AWS Load Balancer Controller                         |
| Vault (dev mode)         | AWS Secrets Manager + IRSA                           |
| self-signed TLS          | cert-manager + ACM / Let's Encrypt                   |
| Docker Compose databases | RDS (Postgres) + ElastiCache (Redis)                 |
| Manual image load        | GitHub Actions → ECR → image tag update in this repo |
