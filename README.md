# ecommerce-shop-gitops

Kubernetes manifests and ArgoCD configuration for the ecommerce shop. The same repo drives two clusters: a k3s cluster on a Proxmox homelab (`homelab`) and an AWS EKS cluster (`aws-prod`) that is created for a session and destroyed afterwards. Each cluster runs its own ArgoCD and reads this repo.

Part of a multi-repo project:

| Repo                                                                         | Purpose                                                             |
| ---------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| [ecommerce-shop-gitops](https://github.com/KristijanJ/ecommerce-shop-gitops) | This repo. Kubernetes manifests, ArgoCD, platform tooling           |
| [ecommerce-infra](https://github.com/KristijanJ/ecommerce-infra)             | Terraform for AWS, Docker Compose and Ansible for Proxmox and local |
| [ecommerce-shop-be](https://github.com/KristijanJ/ecommerce-shop-be)         | NestJS REST API                                                     |
| [ecommerce-shop-fe](https://github.com/KristijanJ/ecommerce-shop-fe)         | Next.js frontend                                                    |

---

## Environments

|            | homelab                                                 | aws-prod                                            |
| ---------- | ------------------------------------------------------- | --------------------------------------------------- |
| Cluster    | k3s on Proxmox: one control plane, two workers          | EKS, created with Terraform in `ecommerce-infra`    |
| Lifetime   | Always on, restarted daily                              | Created per session, destroyed afterwards           |
| Ingress    | Traefik                                                 | AWS Load Balancer Controller (one shared ALB)       |
| TLS        | cert-manager, Let's Encrypt, Route53 DNS-01             | ACM certificate on the ALB                          |
| Secrets    | Vault in dev mode, synced by External Secrets           | AWS Secrets Manager, synced by External Secrets     |
| PostgreSQL | Services VM (`192.168.0.30`)                            | RDS                                                 |
| Redis      | Services VM (`192.168.0.30`)                            | Redis Deployment in the cluster, no persistence     |
| Frontend   | <https://ecommerce-homelab.projects.jovanovski.dev>     | <https://ecommerce-k8s.projects.jovanovski.dev>     |
| Backend    | <https://ecommerce-homelab-api.projects.jovanovski.dev> | <https://ecommerce-k8s-api.projects.jovanovski.dev> |

The homelab hostnames resolve to `192.168.0.20`, so they work only on the home network.

Both environments use the same base manifests and the same platform components where possible. The differences live in the overlays and in per-environment Helm values.

### Homelab layout

```text
┌──────────────────────────────────────────────────────────────────┐
│                         Proxmox homelab                          │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │                       k3s cluster                          │  │
│  │                                                            │  │
│  │  control-plane 192.168.0.20 (Traefik)                      │  │
│  │  worker-1      192.168.0.21                                │  │
│  │  worker-2      192.168.0.22                                │  │
│  │  The k3s service load balancer forwards 80/443 on all nodes│  │
│  │                                                            │  │
│  │  homelab-frontend (Next.js)   homelab-backend (NestJS)     │  │
│  │  monitoring: Prometheus, Grafana, Loki, Tempo, Collector   │  │
│  │  vault, external-secrets, cert-manager, argocd             │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │              Services VM  192.168.0.30                     │  │
│  │              PostgreSQL :5432, Redis :6379                 │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

### aws-prod layout

```text
Internet
   │  HTTPS (ACM certificate)
   ▼
Application Load Balancer  (shared by both Ingresses, group.name: ecommerce)
   │
   ▼
EKS cluster ecommerce-cluster-prod (eu-central-1)
   aws-prod-frontend   Next.js, Redis
   aws-prod-backend    NestJS, migration Job
   monitoring          Prometheus, Grafana, Loki, Tempo, Collector
   external-secrets    reads AWS Secrets Manager through EKS Pod Identity
   argocd
   kube-system         AWS Load Balancer Controller, EBS CSI driver (both installed by Terraform)
   │
   ▼
RDS PostgreSQL
```

---

## Platform stack

ArgoCD installs these from `argocd/appSets/platform/`. The "Where" column shows which clusters get the component.

| Component                    | Purpose                | Where    | Notes                                                                |
| ---------------------------- | ---------------------- | -------- | -------------------------------------------------------------------- |
| ArgoCD                       | GitOps delivery        | both     | App of Apps, one instance per cluster                                |
| Traefik                      | Ingress controller     | homelab  | DaemonSet on the control plane                                       |
| AWS Load Balancer Controller | Ingress controller     | aws-prod | Installed by Terraform, not by ArgoCD                                |
| cert-manager                 | TLS certificates       | homelab  | Let's Encrypt with Route53 DNS-01                                    |
| Vault                        | Secrets backend        | homelab  | Dev mode, in memory                                                  |
| External Secrets Operator    | Secret sync            | both     | Vault on homelab, Secrets Manager on aws-prod                        |
| kube-prometheus-stack        | Metrics and dashboards | both     | Prometheus, Grafana, Alertmanager                                    |
| Loki                         | Log storage            | both     | Receives logs from the collector over OTLP                           |
| Tempo                        | Trace storage          | both     | Single binary, 3 day retention, local PVC                            |
| OpenTelemetry Collector      | Telemetry pipeline     | both     | Apps send OTLP, the collector forwards to Tempo, Loki and Prometheus |
| Metrics Server               | Resource metrics       | both     | Needed for the HPAs                                                  |

---

## GitOps design

### App of Apps

```text
argocd/bootstrap/
├── 00-cluster-<env>.yaml   labels the cluster with env=<env> (homelab or aws-prod)
├── 01-root-platform.yaml   watches argocd/appSets/platform/
└── 02-root-apps.yaml       watches argocd/appSets/application/ (infrastructure, backend, frontend)
```

The ApplicationSets use the `clusters` generator and select clusters by the `env` label on the cluster Secret. Each appset lists the environments it applies to, so one file serves both clusters. Traefik, Vault and cert-manager list only `homelab`.

Apply `00-cluster-<env>.yaml` before the root Applications. Without the label the generators match nothing, and `prune` removes the Applications.

The root Applications track `HEAD` of `main`. A merged change reaches the cluster without a manual `kubectl apply`.

### Kustomize base and overlays

```text
apps/
├── backend/
│   ├── base/                 manifests shared by every environment
│   └── envs/{homelab,aws-prod,local}/
├── frontend/
│   ├── base/
│   └── envs/{homelab,aws-prod,local}/
└── infrastructure/
    └── envs/{homelab,aws-prod,local}/   ClusterSecretStore, ClusterIssuer, storage class
```

Each overlay sets a `namePrefix` (`homelab-`, `aws-prod-`), which also becomes the namespace name (`homelab-backend`, `aws-prod-frontend`). It pins the image tag in `images:`.

- The homelab overlays add the Traefik Ingress with its TLS block, and network policies.
- The aws-prod overlays add the ALB Ingress, point the ExternalSecrets at AWS Secrets Manager, and the frontend overlay adds the in-cluster Redis.

The `local` overlays are for a kind cluster. No ApplicationSet selects `local` yet, so they are not synced by the root Applications.

### Sync waves

```text
wave -2  ExternalSecret   External Secrets creates db-credentials and jwt-secret
wave -1  Migration Job    TypeORM runs the database migrations
wave  0  Deployment       the application pods start
```

The migration Job is an ArgoCD hook (`hook: Sync`, `hook-delete-policy: BeforeHookCreation`). ArgoCD deletes and recreates it on every sync, because Job specs are immutable.

---

## CI/CD

```text
merge to main in ecommerce-shop-be or ecommerce-shop-fe
  → GitHub Actions: lint, test, build the image
  → push to Docker Hub as kristijan92/ecommerce-shop-{be,fe}:<first 7 characters of the commit SHA>
  → the workflow commits the new tag to apps/<service>/envs/homelab/kustomization.yaml in this repo
  → ArgoCD on the homelab syncs the change
```

A GitHub App token lets the app repos push to this repo. The App is the only bypass actor on the ruleset that protects `main` here. Each app repo's `release.yaml` has the details.

The workflows change only the homelab overlays. The aws-prod and local overlays keep the tag they were last given by hand. To deploy a build on aws-prod, change `newTag` in `apps/<service>/envs/aws-prod/kustomization.yaml` and merge it.

---

## Secrets management

No secret values live in this repo. Each app has ExternalSecret manifests that name the keys to read, and External Secrets creates the Kubernetes Secrets.

```text
homelab:   Vault secret/db, secret/jwt            →  db-credentials, jwt-secret
aws-prod:  Secrets Manager /ecommerce/prod/db,
           /ecommerce/prod/jwt                    →  db-credentials, jwt-secret
```

The base ExternalSecrets point at the `vault-secret-store` ClusterSecretStore. The aws-prod overlays patch them to the `aws-secret-store` ClusterSecretStore, which reads Secrets Manager in `eu-central-1`. External Secrets authenticates to AWS with EKS Pod Identity. Terraform in `ecommerce-infra` creates the secrets and the role.

### Vault on the homelab

Vault runs in dev mode with the root token `root` and keeps its data in memory. A restart empties it, so `scripts/seed-vault.sh` writes the secrets again on every start. `start-homelab.sh` calls it, and `make vault-seed` runs it alone.

The script reads `scripts/vault-seed.env`, which is gitignored. Create it from the template:

```bash
cp scripts/vault-seed.example.env scripts/vault-seed.env
# fill in the values
```

The file holds the database settings (`DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASS`, `DB_DATABASE`), `JWT_SECRET`, and the access key of the cert-manager IAM user. It writes `secret/db`, `secret/jwt` and `secret/cert-manager-user`.

---

## TLS on the homelab

cert-manager issues Let's Encrypt production certificates for the two homelab hostnames. The cluster is not reachable from the internet, so it uses the DNS-01 challenge against Route53.

- The cert-manager ApplicationSet is `argocd/appSets/platform/cert-manager.yaml`, with values in `values/cert-manager/values.homelab.yaml`.
- `apps/infrastructure/envs/homelab/cluster-cert-issuer.yaml` defines the ClusterIssuer `cert-manager-issuer`. It uses the ACME production server and the Route53 solver for the `projects.jovanovski.dev` zone in `eu-central-1`.
- The solver uses the IAM user `homelab-cert-manager`. The user can only assume the role `homelab-cert-manager`, and the role may only read changes and edit TXT records in that hosted zone.
- The user's access key sits in Vault at `secret/cert-manager-user`. An ExternalSecret (`cert-iam-user-secret.yaml`) copies it into the `cert-manager-user-secret` Secret in the `cert-manager` namespace.
- Each homelab Ingress has the annotation `cert-manager.io/cluster-issuer: cert-manager-issuer` and a `tls:` block. cert-manager creates the `ecommerce-fe-tls` and `ecommerce-be-tls` Secrets.

Certificates last 90 days and renew by themselves. Check them with:

```bash
kubectl get certificate -A
kubectl describe certificate -n homelab-frontend
kubectl get challenges -A
```

To test changes without hitting the production rate limits, point `server` in the ClusterIssuer at `https://acme-staging-v02.api.letsencrypt.org/directory` and use a different `privateKeySecretRef` name. Browsers do not trust staging certificates.

---

## aws-prod

The EKS cluster, the VPC and RDS come from Terraform in [ecommerce-infra](https://github.com/KristijanJ/ecommerce-infra). This repo holds what runs inside the cluster.

### Start

1. In `ecommerce-infra`, run `make aws-tf-apply` (environment `prod`) and update the kubeconfig for the new cluster.
2. In this repo, run `make start-aws-prod`.

The script asks you to confirm the kubectl context and enter the AWS SSO profile. Then it:

1. installs ArgoCD,
2. applies the cluster Secret and the platform root Application, and waits for External Secrets,
3. applies the apps root Application,
4. creates the Route53 records for the Ingress hosts,
5. waits for the backend Deployment and runs `node dist/database/seed.js` in a backend pod.

The DNS records are created by `scripts/route53-alb.sh upsert` because the ALB hostname exists only after the Load Balancer Controller creates it. The script reads the hostname from the Ingress status and writes alias records for the hosts in both Ingresses.

### Stop

Run these in order:

1. `make teardown-aws-prod` in this repo. It deletes the Route53 records, then the ArgoCD applications and the PVCs. It waits until the ALBs, load balancer Services and EBS volumes are gone. The Load Balancer Controller and the EBS CSI driver must still be running, because they delete those resources.
2. `make aws-tf-destroy` in `ecommerce-infra`.

The teardown script refuses to run unless the kubectl context contains `ecommerce-cluster-prod`. If it reports leftover resources, do not run the destroy. Check the controller logs with `kubectl logs -n kube-system deploy/aws-load-balancer-controller`.

### Known behavior

After a cold start Grafana can show no data sources. The datasource sidecar writes its file after Grafana has read its provisioning. Reload it with a POST to `/api/admin/provisioning/datasources/reload`, or restart the Grafana Deployment.

The aws-prod overlays have no network policies yet.

---

## Observability

Prometheus, Loki, Tempo, an OpenTelemetry Collector and Grafana run in the `monitoring` namespace. The apps send traces, metrics and logs over OTLP to the collector (`opentelemetry-collector.monitoring:4318`), and the collector forwards them:

- Traces go to Tempo.
- Logs go to Loki through its OTLP endpoint.
- Metrics go to Prometheus through its OTLP receiver. Prometheus also scrapes cluster and node metrics.
- The collector's `spanmetrics` connector turns traces into request-count and latency histograms. With the connector's default namespace the series are named `traces_span_metrics_calls_total` and `traces_span_metrics_duration_milliseconds_bucket`. The histograms carry trace ID exemplars, so a point on a latency graph links to its trace. The apps' own metrics have no exemplars, because the JS SDK does not attach them.
- Grafana has Prometheus, Loki and Tempo as datasources. It links a log line to its trace, a trace to its logs and an exemplar to its trace.

Each app sets `OTEL_SERVICE_NAME` (`ecommerce-be`, `ecommerce-fe`), `OTEL_EXPORTER_OTLP_ENDPOINT` and `OTEL_RESOURCE_ATTRIBUTES=service.instance.id=$(POD_NAME)` in its Deployment. The instance ID gives each replica its own metric series. Without it, replicas share one series and `rate()` reports a number that is too high.

Only what the apps send through the collector reaches Loki. Logs from system and platform pods are not collected.

Query logs in Grafana under Explore with the Loki datasource:

```logql
{service_name="ecommerce-be"}
{service_name="ecommerce-fe"}
```

---

## Security

### Network policies (homelab)

Both homelab application namespaces use a default-deny policy with explicit allow rules.

| Namespace          | Allowed ingress   | Allowed egress                                         |
| ------------------ | ----------------- | ------------------------------------------------------ |
| `homelab-frontend` | Traefik only      | Backend :3000, Redis :6379, collector :4317/:4318, DNS |
| `homelab-backend`  | Traefik, frontend | PostgreSQL :5432, collector :4317/:4318, DNS           |

### Secrets

See [Secrets management](#secrets-management).

---

## Reliability

| Feature            | Implementation                                                                                                       |
| ------------------ | -------------------------------------------------------------------------------------------------------------------- |
| Health checks      | Liveness and readiness probes: `/health` and `/ready` on the backend, `/api/health` and `/api/ready` on the frontend |
| Autoscaling        | HPA on the frontend and the backend                                                                                  |
| Disruption budget  | PodDisruptionBudget on both apps                                                                                     |
| Migration ordering | The sync-wave -1 Job runs migrations before the pods start                                                           |
| Self-healing       | `selfHeal: true` on the ArgoCD apps reverts manual changes                                                           |

---

## Homelab quick start

### Prerequisites

- The Proxmox VMs and the k3s cluster are running.
- The worker VMs use the Proxmox CPU type `host`. Tempo 3.x does not start on the default `kvm64` type, because it needs x86-64-v2 instructions.
- `kubectl` points at the cluster.
- `scripts/vault-seed.env` exists (see [Vault on the homelab](#vault-on-the-homelab)).

### Start

```bash
make start-homelab
```

The script asks you to confirm the kubectl context. Then it installs ArgoCD, deploys the platform, creates the `vault-token` Secret and seeds Vault, and deploys the apps.

### Access

- Frontend: <https://ecommerce-homelab.projects.jovanovski.dev>
- Backend API: <https://ecommerce-homelab-api.projects.jovanovski.dev>
- ArgoCD: run `make argocd-ui`, then open <https://localhost:8080>. The user is `admin`, and `make argocd-password` prints the password.
- Grafana: run `make grafana-ui`, then open <http://localhost:3000> (admin/admin).
- Vault: run `make vault-ui`, then open <http://localhost:8200> (token `root`).

### After a Proxmox restart

The VMs start on boot and k3s starts through systemd. Give the nodes about two minutes to rejoin.

```bash
kubectl get nodes      # all Ready
kubectl get pods -A    # wait for Running
```

When a node shuts down abruptly, its pods can stay in `Unknown` and Kubernetes does not reschedule them. The usual one is `argocd-repo-server`. The ArgoCD UI then shows `connection error: dial tcp <ip>:8081: connect: connection refused` on every app. Delete the stuck pod and it reschedules:

```bash
kubectl get pods -n argocd
kubectl delete pod -n argocd <repo-server-pod>
```

Vault lost its data in the restart, so seed it again. Without this the backend cannot read the database credentials, and cert-manager cannot renew certificates.

```bash
make vault-seed
```

Then check the result:

```bash
kubectl get pods -A
kubectl get certificate -A
curl https://ecommerce-homelab-api.projects.jovanovski.dev/products
```

---

## Local kind cluster

This setup is the oldest part of the repo and is untested since the homelab and aws-prod environments were added. It may be broken.

`make start` creates a kind cluster (`kind/cluster.yaml`, one control plane and three workers), installs ArgoCD, seeds Vault with fixed values and loads the app images from the local Docker daemon. `make lb` runs `cloud-provider-kind` in a separate terminal to provide LoadBalancer addresses. `make nuke` deletes the cluster.

---

## Repository contents

| Path                          | What it is                                                                        |
| ----------------------------- | --------------------------------------------------------------------------------- |
| `apps/`                       | Kustomize base and overlays for the backend, frontend and cluster-level resources |
| `argocd/bootstrap/`           | Cluster Secrets and the two root Applications                                     |
| `argocd/appSets/platform/`    | ApplicationSets and Helm values for the platform components                       |
| `argocd/appSets/application/` | ApplicationSets for the apps                                                      |
| `scripts/`                    | Start and teardown scripts, the Vault seed script, the Route53 script             |
| `kind/`                       | kind cluster config                                                               |
| `ansible/`                    | Inventory for the Proxmox VMs                                                     |
| `k6-load-testing/`            | k6 load test against the homelab frontend                                         |
| `Makefile`                    | Shortcuts for the scripts and common kubectl commands                             |

---

## Makefile reference

`make help` prints the full list.

```bash
# Start and stop
make start-homelab      # homelab: ArgoCD, platform, Vault seed, apps
make start-aws-prod     # aws-prod: ArgoCD, platform, apps, Route53, DB seed
make teardown-aws-prod  # remove everything ArgoCD deployed, run before terraform destroy
make start              # local kind cluster
make clean              # delete the root Applications and everything they manage
make nuke               # delete the kind cluster

# Local kind cluster
make cluster-create     # create the kind cluster
make cluster-delete     # delete it
make cluster-status     # node list
make load-backend-image   # BE_TAG=x.y.z
make load-frontend-image  # FE_TAG=x.y.z
make lb                 # cloud-provider-kind (needs sudo)

# ArgoCD
make argocd-install     # install ArgoCD into the kind cluster
make argocd-ui          # https://localhost:8080
make argocd-password    # initial admin password
make argocd-status      # application sync status

# Vault (homelab)
make vault-seed         # write the secrets from scripts/vault-seed.env
make vault-get          # read secret/db and secret/jwt
make vault-ui           # http://localhost:8200

# Monitoring
make grafana-ui         # http://localhost:3000 (admin/admin)
make prometheus-ui      # http://localhost:9090
make alertmanager-ui    # http://localhost:9093

# Debugging
make pods               # all pods
make logs-backend       # tail backend logs
make logs-frontend      # tail frontend logs
make hpa                # HPA status
make events             # recent warning events
make check-requirements # check local tools
```

---

## Planned

- Checks on this repo and the infra repo (`kubeconform`, `terraform validate`).
- A `promote` workflow that opens a PR to move an image tag to the aws-prod overlay.
- CodePipeline for the Terraform deploy and destroy, and for the start and teardown scripts.
- external-dns to replace `scripts/route53-alb.sh`.
- S3 storage for Loki and Tempo.
