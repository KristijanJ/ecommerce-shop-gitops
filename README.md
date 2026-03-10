# ecommerce-shop-gitops

GitOps configuration for the ecommerce shop, running on a Proxmox homelab k3s cluster modelled after a production AWS EKS setup.

Part of a multi-repo project:

| Repo                                                                         | Purpose                                                        |
| ---------------------------------------------------------------------------- | -------------------------------------------------------------- |
| [ecommerce-shop-gitops](https://github.com/KristijanJ/ecommerce-shop-gitops) | **This repo** — Kubernetes manifests, ArgoCD, platform tooling |
| [ecommerce-shop-be](https://github.com/KristijanJ/ecommerce-shop-be)         | Express.js REST API                                            |
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
│  │  │    (Next.js)         │  │    (Express.js)          │ │    │
│  │  └──────────────────────┘  └──────────────────────────┘ │    │
│  │  ┌─────────────────────────────────────────────────────┐ │    │
│  │  │                  monitoring                         │ │    │
│  │  │      Prometheus · Grafana · Loki · Promtail         │ │    │
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

**Stateless services** (frontend, backend) run in Kubernetes. **Stateful services** (PostgreSQL, Redis) run on a dedicated services VM — mirroring how AWS RDS and ElastiCache are managed outside of EKS in production.

---

## Platform Stack

| Component                     | Purpose                    | Notes                                                 |
| ----------------------------- | -------------------------- | ----------------------------------------------------- |
| **ArgoCD**                    | GitOps continuous delivery | App of Apps pattern                                   |
| **Kustomize**                 | Environment overlays       | `base/` + `envs/homelab/` + `envs/prod/`              |
| **Traefik**                   | Ingress controller         | DaemonSet on control-plane, k3s svclb for LB IPs      |
| **Vault**                     | Secrets backend            | Dev mode in homelab, swappable to AWS Secrets Manager |
| **External Secrets Operator** | Secret sync                | Pulls from Vault → Kubernetes Secrets                 |
| **kube-prometheus-stack**     | Metrics & dashboards       | Prometheus + Grafana + Alertmanager                   |
| **Loki + Promtail**           | Log aggregation            | Promtail DaemonSet ships pod logs to Loki             |
| **Metrics Server**            | Resource metrics           | Required for HPA                                      |

---

## GitOps Design

### App of Apps

ArgoCD is bootstrapped with two root Applications:

```text
argocd/bootstrap/
├── 01-root-platform.yaml   → watches argocd/appSets/platform/  (Traefik, Vault, Prometheus, Loki, ...)
└── 02-root-apps.yaml       → watches argocd/appSets/application/ (frontend, backend, infrastructure)
```

Any change pushed to this repo is picked up automatically — no manual `kubectl apply` needed after the initial bootstrap.

### Kustomize base/overlay

```text
apps/
├── backend/
│   ├── base/               # Environment-agnostic manifests
│   └── envs/
│       ├── homelab/        # Proxmox k3s patches (ingress host, network policies)
│       └── prod/           # EKS-specific patches
└── frontend/
    ├── base/
    └── envs/
        ├── homelab/        # Proxmox k3s patches (API URL, ingress host, network policies)
        └── prod/
```

`namePrefix: homelab-` in the homelab overlay means all resources are namespaced by environment, so multiple environments can coexist in the same cluster.

### Sync waves

Deployment ordering within a sync is controlled by `argocd.argoproj.io/sync-wave`:

```text
wave -2  ExternalSecret    → ESO creates db-credentials and jwt-secret from Vault
wave -1  Migration Job     → Prisma runs database migrations (retries until secrets exist)
wave  0  Deployment        → Application pods start (secrets are guaranteed to be present)
```

The migration Job is an ArgoCD hook (`hook: Sync`, `hook-delete-policy: BeforeHookCreation`), so it is deleted and recreated on every sync rather than patched — which would fail since Job specs are immutable.

---

## Secrets Management

No secret values exist anywhere in this repository. Git holds only the _shape_ of secrets, not their values.

```text
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
{namespace="homelab-backend"} | json | level="error"
{namespace="homelab-frontend"} | json | msg=~".*payment.*"
```

---

## Security

### NetworkPolicies

Both application namespaces use a **default-deny-all** policy with explicit allow rules:

| Namespace          | Allowed ingress    | Allowed egress                  |
| ------------------ | ------------------ | ------------------------------- |
| `homelab-frontend` | Traefik only       | Backend :3000, Redis :6379, DNS |
| `homelab-backend`  | Traefik + Frontend | PostgreSQL :5432, DNS           |

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

## Quick Start — Homelab

### Prerequisites

- Proxmox VMs up and k3s cluster running
- `kubectl` configured to point at the cluster
- `argocd` CLI installed

### 1. Run the bootstrap script

```bash
./scripts/start-homelab.sh
```

This handles everything in order: installs ArgoCD, deploys the platform stack, seeds Vault, and deploys the applications.

### 2. Access

- **Frontend:** <http://ecommerce.192.168.0.20.traefik.me>
- **Backend API:** <http://api.192.168.0.20.traefik.me>
- **ArgoCD:** `make argocd-ui` → <https://localhost:8080>
- **Grafana:** `make grafana-ui` → <http://localhost:3000> (admin/admin)
- **Vault:** `make vault-ui` → <http://localhost:8200> (token: root)

---

## After Proxmox Restart

When Proxmox is shut down and powered back on, the following steps are needed:

### 1. Wait for the cluster to come up

VMs auto-start (start-on-boot enabled). k3s starts automatically via systemd on each node. Give it ~2 minutes for all nodes to rejoin and pods to reschedule.

```bash
kubectl get nodes        # all should be Ready
kubectl get pods -A      # wait for everything to be Running
```

### 2. Fix the ArgoCD repo-server (if needed)

When a node shuts down abruptly, pods on that node get stuck in `Unknown` state. Kubernetes does not automatically reschedule them. The most common victim is `argocd-repo-server`.

**Symptom:** ArgoCD UI shows `connection error: dial tcp <ip>:8081: connect: connection refused` across all apps.

**Fix:**

```bash
kubectl get pods -n argocd                          # find the Unknown pod
kubectl delete pod -n argocd <repo-server-pod>      # delete it — reschedules immediately
```

### 3. Reseed Vault

Vault runs in dev mode — all secrets are wiped on pod restart. Without this step the backend will fail to connect to the database.

```bash
make vault-seed
```

### 4. Verify

```bash
kubectl get pods -A                  # everything Running
curl http://api.192.168.0.20.traefik.me/products   # should return JSON
```

---

## Makefile Reference

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
