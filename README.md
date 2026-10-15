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

|            | homelab                                                     | aws-prod                                            |
| ---------- | ----------------------------------------------------------- | --------------------------------------------------- |
| Cluster    | k3s on Proxmox: one control plane, two workers              | EKS, created with Terraform in `ecommerce-infra`    |
| Lifetime   | Always on, restarted daily                                  | Created per session, destroyed afterwards           |
| Ingress    | Traefik                                                     | AWS Load Balancer Controller (one shared ALB)       |
| TLS        | cert-manager, Let's Encrypt, Route53 DNS-01                 | ACM certificate on the ALB                          |
| Secrets    | Vault in dev mode, synced by External Secrets               | AWS Secrets Manager, synced by External Secrets     |
| PostgreSQL | Services VM (`192.168.0.30`)                                | RDS                                                 |
| Redis      | Services VM (`192.168.0.30`)                                | Redis Deployment in the cluster, no persistence     |
| Frontend   | <https://ecommerce-homelab.projects.jovanovski.dev>         | <https://ecommerce-k8s.projects.jovanovski.dev>     |
| Backend    | <https://ecommerce-homelab-api.projects.jovanovski.dev>     | <https://ecommerce-k8s-api.projects.jovanovski.dev> |
| Keycloak   | <https://ecommerce-homelab-auth.projects.jovanovski.dev>    | Not deployed                                        |
| Grafana    | <https://ecommerce-homelab-grafana.projects.jovanovski.dev> | Port-forward with `make grafana-ui`                 |
| ArgoCD     | <https://ecommerce-homelab-argocd.projects.jovanovski.dev>  | Port-forward with `make argocd-ui`                  |

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
│  │  vault, external-secrets, cert-manager, keycloak, argocd   │  │
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
| Keycloak                     | Identity provider      | homelab  | Database on the services VM, see the Keycloak section                |
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

### Releasing an app

A push to `main` in `ecommerce-shop-be` or `ecommerce-shop-fe` starts that repo's `release.yaml`. A push that changes only `.md` files does not. The workflow:

1. Runs lint and the tests.
2. Builds the image and pushes it to Docker Hub as `kristijan92/ecommerce-shop-{be,fe}:<first 7 characters of the commit SHA>`.
3. Sets `newTag` in `apps/<service>/envs/homelab/kustomization.yaml` in this repo, on the branch `bump/backend-homelab` or `bump/frontend-homelab`.
4. Opens a pull request from that branch and turns on auto-merge with the squash method.

The `validate` workflow runs on the pull request. When it passes, GitHub merges the PR and ArgoCD on the homelab syncs the new tag. A second build before the merge replaces the commit on the same branch, so each service has at most one open bump PR.

The workflow opens the PR with a token from a GitHub App. A PR opened with the default `GITHUB_TOKEN` does not start other workflows, so `validate` would not run and the PR could not merge. The App needs read and write access to contents and pull requests in this repo. Each app repo's `release.yaml` has the details.

The workflows change only the homelab overlays. The aws-prod and local overlays keep the tag they were last given by hand. To deploy a build on aws-prod, change `newTag` in `apps/<service>/envs/aws-prod/kustomization.yaml` and merge it.

### Branch protection

The ruleset `protect-main` covers `main`. It blocks deleting the branch and force pushes, and it requires a pull request and a passing `validate` check. No approval is required. The ruleset has no bypass actors, so the maintainer and the GitHub App follow the same rules. The repo settings allow auto-merge and delete a branch after its PR merges.

### Checks on pull requests

`.github/workflows/validate.yaml` runs on every pull request and on every push to `main`. It runs `scripts/validate/validate.sh`, the same script as `make validate`. The workflow uses no secrets, so it also runs safely on pull requests from forks.

| Check              | What it does                                                                                                                                      |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Tools              | Confirms that `helm`, `kubectl`, `kubeconform`, `yq` and `gitleaks` are installed                                                                 |
| Kustomize overlays | Builds the homelab and aws-prod overlay of each app with `kubectl kustomize` and checks the result with `kubeconform`                             |
| Helm charts        | For each platform ApplicationSet and environment, downloads the pinned chart, renders it with the environment's values file and checks the result |
| ArgoCD manifests   | Checks every ApplicationSet, root Application and cluster Secret                                                                                  |
| Secret scan        | Runs `gitleaks` over the git history                                                                                                              |

`kubeconform` checks each manifest against the Kubernetes 1.36 schemas and the community [CRD catalog](https://github.com/datreeio/CRDs-catalog). It runs in strict mode, so a field that the schema does not know fails the check, and so does a kind that has no schema. `scripts/validate/config.env` lists three kinds that are skipped. `ClusterSecretStore` and `SecretStore` are skipped because `kubeconform` cannot load their catalog schemas. `CustomResourceDefinition` is skipped because the charts ship their CRDs as the vendors wrote them.

The checks cover the `homelab` and `aws-prod` overlays and charts. The `local` overlays are left out, because no ApplicationSet selects them.

A passing check shows that the manifests render and match their schemas. It does not show that a container starts, that a Vault key exists, or that resources sync in the right order.

### Rendered changes

On pull requests the workflow also runs `scripts/validate/diff-rendered.sh`. It renders every overlay and chart for the base commit and for the PR, then lists the resources that are added, changed or removed in each app. The report is on the summary page of the run. Apps without changes are only counted.

Secret values are replaced before the comparison, so the report never contains them. CustomResourceDefinitions are left out. For each app the report lists at most 30 resources and shows at most 10 diffs of 40 lines each. A failure in this step does not fail the check.

### Running the checks locally

```bash
make validate-install-tools   # kubeconform, yq and gitleaks to ~/.local/bin
make validate                 # every check
make validate-kustomize       # one check at a time
make validate-helm
make validate-argocd
make validate-secrets
make diff                     # rendered changes against origin/main
make diff BASE=<ref>          # against another ref
```

`helm` and `kubectl` have to be installed by hand. `scripts/validate/config.env` pins the tool versions and their SHA-256 checksums, and the installer checks every download. Each check is its own script in `scripts/validate/` and can run alone.

The scripts download each chart once into `~/.cache/gitops-charts`. Locally the Helm check takes about 7 seconds with the charts cached and 20 seconds without. CI keeps the folder between runs and adds a line about it to the run summary: an exact hit, a partial hit from the newest older cache, or a miss.

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

The file holds the database settings (`DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASS`, `DB_DATABASE`), `JWT_SECRET`, the access key of the cert-manager IAM user, the three Keycloak values (`KEYCLOAK_DB_PASS`, `KEYCLOAK_ADMIN_PASSWORD` and `KEYCLOAK_CONFIG_CLI_CLIENT_SECRET`), and two Grafana values (`GRAFANA_KEYCLOAK_CLIENT_SECRET` and `GRAFANA_ADMIN_PASSWORD`). It writes `secret/db`, `secret/jwt`, `secret/cert-manager-user`, `secret/keycloak` and `secret/grafana`.

---

## TLS on the homelab

cert-manager issues Let's Encrypt production certificates for the homelab hostnames. The cluster is not reachable from the internet, so it uses the DNS-01 challenge against Route53.

- The cert-manager ApplicationSet is `argocd/appSets/platform/cert-manager.yaml`, with values in `values/cert-manager/values.homelab.yaml`.
- `apps/infrastructure/envs/homelab/cluster-cert-issuer.yaml` defines the ClusterIssuer `cert-manager-issuer`. It uses the ACME production server and the Route53 solver for the `projects.jovanovski.dev` zone in `eu-central-1`.
- The solver uses the IAM user `homelab-cert-manager`. The user can only assume the role `homelab-cert-manager`, and the role may only read changes and edit TXT records in that hosted zone.
- The user's access key sits in Vault at `secret/cert-manager-user`. An ExternalSecret (`cert-iam-user-secret.yaml`) copies it into the `cert-manager-user-secret` Secret in the `cert-manager` namespace.
- Each homelab Ingress has the annotation `cert-manager.io/cluster-issuer: cert-manager-issuer` and a `tls:` block. cert-manager creates the `ecommerce-fe-tls`, `ecommerce-be-tls` and `keycloak-tls` Secrets.

Certificates last 90 days and renew by themselves. Check them with:

```bash
kubectl get certificate -A
kubectl describe certificate -n homelab-frontend
kubectl get challenges -A
```

To test changes without hitting the production rate limits, point `server` in the ClusterIssuer at `https://acme-staging-v02.api.letsencrypt.org/directory` and use a different `privateKeySecretRef` name. Browsers do not trust staging certificates.

---

## Keycloak

Keycloak runs on the homelab at <https://ecommerce-homelab-auth.projects.jovanovski.dev>. It is the login for cluster tools. Grafana and ArgoCD use it today, and Headlamp is planned.

The ApplicationSet is `argocd/appSets/platform/keycloak.yaml`. It installs the `keycloakx` chart from codecentric (version 7.3.2, Keycloak 26.7.4) into the `keycloak` namespace with one replica. The values are in `values/keycloak/values.homelab.yaml`. The pod requests 200m CPU and 768Mi memory and has a 1280Mi memory limit.

### How it is set up

The values set the container command to `/opt/keycloak/bin/kc.sh start`. The chart does not set one, and without it the image prints its help text and exits.

TLS ends at Traefik. Keycloak listens on plain HTTP inside the cluster, trusts the forwarded headers from the proxy and builds its URLs from `KC_HOSTNAME`. The Ingress carries the annotation `cert-manager.io/cluster-issuer: cert-manager-issuer`, and cert-manager creates the `keycloak-tls` Secret. The console is at `/admin/`, and the OIDC endpoints are under `/realms/<realm>`.

### Database

Keycloak keeps its data in a `keycloak` database on the PostgreSQL server on the services VM (`192.168.0.30`). The Job `keycloak-db-init` creates the `keycloak` role and database when they are missing, and sets the role's password on every run. It connects with the admin credentials from Vault `secret/db`. The Job is an ArgoCD Sync hook, so ArgoCD deletes and recreates it on every sync.

### Secrets

Four ExternalSecrets in the same release read from Vault.

| Secret                   | Vault source                                                                                            | Used for                                            |
| ------------------------ | ------------------------------------------------------------------------------------------------------- | --------------------------------------------------- |
| `keycloak-db`            | `secret/keycloak`, key `db-pass`                                                                        | The password of the `keycloak` database role        |
| `keycloak-admin`         | `secret/keycloak`, key `admin-password`                                                                 | The password of the bootstrap admin user            |
| `keycloak-db-admin`      | `secret/db`, keys `db-host`, `db-port`, `db-user`, `db-pass`                                            | The init Job's connection to PostgreSQL             |
| `keycloak-realm-secrets` | `secret/grafana` key `grafana_keycloak_client_secret`, `secret/keycloak` key `config-cli-client-secret` | The realm Job's login and the Grafana client secret |

Set `KEYCLOAK_DB_PASS`, `KEYCLOAK_ADMIN_PASSWORD` and `KEYCLOAK_CONFIG_CLI_CLIENT_SECRET` in `scripts/vault-seed.env`, and `scripts/seed-vault.sh` writes `secret/keycloak`.

The ExternalSecrets spell out the default fields that External Secrets adds to every object (`conversionStrategy`, `decodingStrategy`, `metadataPolicy`, `creationPolicy` and `deletionPolicy`). Without them ArgoCD shows the objects as OutOfSync.

### Start order

```text
ApplicationSet  wave 2   after External Secrets (wave 1), so the ExternalSecret CRD exists
wave -1         the three ExternalSecrets
wave  0         the keycloak-db-init Job
wave  1         the Keycloak StatefulSet
PostSync        the keycloak-realm-config Job, after Keycloak is healthy
```

### Realm as code

The `platform` realm is defined in the ConfigMap `keycloak-realm-platform` in the same values file. It holds the groups `cluster-admins` and `viewers`, the `groups` client scope with its Group Membership mapper, and the `grafana` client. The Job `keycloak-realm-config` runs [keycloak-config-cli](https://github.com/adorsys/keycloak-config-cli) as an ArgoCD PostSync hook, so it applies the file after every sync of the Keycloak app.

The Job reaches Keycloak through the in-cluster service and logs in to the `master` realm as the service account of the client `keycloak-config-cli`. That client has no browser login. Its service account holds the roles of the `platform-realm` client (`manage-realm`, `manage-clients`, `manage-users` and the matching view and query roles), so it can change only the `platform` realm. Create the client by hand once, in the admin console, and put its secret in `KEYCLOAK_CONFIG_CLI_CLIENT_SECRET`. It replaces `$(env:GRAFANA_KEYCLOAK_CLIENT_SECRET)` in the file with the value from the `keycloak-realm-secrets` Secret, so the client secret is never in git. Grafana reads the same Vault key, so both sides always match. The tool deletes only the objects it created itself.

Change the realm by editing the ConfigMap. The next run overwrites changes made in the admin console to the objects in the file. Users are not in the file, so a new Keycloak needs a user added by hand and put in a group.

Check a run with:

```bash
kubectl logs -n keycloak job/keycloak-realm-config
```

### Grafana login

Grafana is at <https://ecommerce-homelab-grafana.projects.jovanovski.dev>. Its Ingress uses the same Traefik and cert-manager setup as Keycloak, so the DNS record for the host goes into the `jovanovski.dev` zone like the others. The Keycloak button on the login page signs in with the realm `platform`. The role comes from the `groups` claim: `cluster-admins` becomes Admin and `viewers` becomes Viewer. A user in neither group is denied.

The built-in `admin` user still exists. Its password comes from Vault (`GRAFANA_ADMIN_PASSWORD`) through the ExternalSecret `grafana-admin`, and the datasource and dashboard sidecars log in with it to call the reload endpoints. Do not remove that account.

### ArgoCD login

ArgoCD is at <https://ecommerce-homelab-argocd.projects.jovanovski.dev>. The Keycloak client `argocd` comes from the realm file, and its secret comes from Vault (`ARGOCD_KEYCLOAK_CLIENT_SECRET`) through the ExternalSecret `argocd-oidc` in the `argocd` namespace. Four ConfigMaps and one Ingress in `apps/infrastructure/envs/homelab` configure it:

| File                        | What it sets                                                                                            |
| --------------------------- | ------------------------------------------------------------------------------------------------------- |
| `argocd-cm.yaml`            | The URL and `oidc.config`, which points at the realm `platform` and reads the secret from `argocd-oidc` |
| `argocd-rbac-cm.yaml`       | `cluster-admins` becomes `role:admin` and `viewers` becomes `role:readonly`. Everyone else gets nothing |
| `argocd-cmd-params-cm.yaml` | `server.insecure`, so `argocd-server` serves plain HTTP behind Traefik, which ends TLS                  |
| `argocd-ingress.yaml`       | The host, with a Let's Encrypt certificate from cert-manager                                            |

ArgoCD installs from `install.yaml` with its own default ConfigMaps. The three ConfigMap files list only the keys this repo owns, so the other keys from the install stay. Each one has the annotation `Prune=false`, so removing a file does not delete the ConfigMap. ArgoCD reads `argocd-cmd-params-cm` at startup, so run `kubectl rollout restart deploy/argocd-server -n argocd` after a change to it.

The local `admin` user still works, and `make argocd-password` prints its password. For the CLI, use `argocd login ecommerce-homelab-argocd.projects.jovanovski.dev --sso --grpc-web`.

### DNS

Create an A record for `ecommerce-homelab-auth.projects.jovanovski.dev` in the `jovanovski.dev` Route53 hosted zone. Point it at `192.168.0.20` with a TTL of 300, like the other homelab hosts. Create the record before anything looks the name up. Resolvers cache a missing name for 15 minutes, the negative TTL in the zone's SOA, and a router can keep that answer for a while after the record exists. A line in `/etc/hosts` works around it.

### First login

The bootstrap admin user is `admin`, and its password comes from the Vault key `admin-password`. Keycloak creates this user only when its database is empty, so changing the Vault value later does not change the password.

Check the deployment with:

```bash
kubectl get pods,certificate -n keycloak
kubectl logs -n keycloak keycloak-keycloakx-0
kubectl logs -n keycloak job/keycloak-db-init
```

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

After a cold start Grafana can show no data sources. The datasource sidecar writes its file after Grafana has read its provisioning. Reload it with a POST to `/api/admin/provisioning/datasources/reload`, or restart the Grafana Deployment. The POST needs the admin login. Basic auth for the API stays on when the login form is hidden.

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
- Keycloak: <https://ecommerce-homelab-auth.projects.jovanovski.dev>
- ArgoCD: <https://ecommerce-homelab-argocd.projects.jovanovski.dev>. Log in with Keycloak, or as `admin` with the password from `make argocd-password`. `make argocd-ui` opens a tunnel to <http://localhost:8080>, which is plain HTTP on the homelab. The `argocd` CLI needs `--plaintext` through that tunnel.
- Grafana: <https://ecommerce-homelab-grafana.projects.jovanovski.dev>. Log in with Keycloak, or as `admin` with the password from `GRAFANA_ADMIN_PASSWORD`.
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
| `.github/`                    | The `validate` workflow and the Dependabot configuration for GitHub Actions       |
| `scripts/`                    | Start and teardown scripts, the Vault seed script, the Route53 script             |
| `scripts/validate/`           | The checks that CI and `make validate` run, and the rendered-changes report       |
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
make argocd-ui          # http://localhost:8080 on the homelab, https on kind and aws-prod
make argocd-password    # initial admin password
make argocd-status      # application sync status

# Vault (homelab)
make vault-seed         # write the secrets from scripts/vault-seed.env
make vault-get          # read secret/db and secret/jwt
make vault-ui           # http://localhost:8200

# Monitoring
make grafana-ui         # http://localhost:3000 (aws-prod: admin/admin, homelab: use its own host)
make prometheus-ui      # http://localhost:9090
make alertmanager-ui    # http://localhost:9093

# Debugging
make pods               # all pods
make logs-backend       # tail backend logs
make logs-frontend      # tail frontend logs
make hpa                # HPA status
make events             # recent warning events
make check-requirements # check local tools

# Validation
make validate-install-tools  # kubeconform, yq and gitleaks to ~/.local/bin
make validate           # every check that CI runs
make validate-kustomize # kustomize overlays
make validate-helm      # Helm charts of the platform ApplicationSets
make validate-argocd    # ApplicationSets and bootstrap manifests
make validate-secrets   # gitleaks over the git history
make diff               # rendered changes against origin/main (BASE=<ref> for another ref)
```

---

## Planned

- Keycloak on aws-prod, with its database on RDS.
- Login through Keycloak for Headlamp.
- Terraform checks on the infra repo (`terraform fmt`, `validate` and `plan`).
- A `promote` workflow that opens a PR to move an image tag to the aws-prod overlay.
- CodePipeline for the Terraform deploy and destroy, and for the start and teardown scripts.
- external-dns to replace `scripts/route53-alb.sh`.
- S3 storage for Loki and Tempo.
