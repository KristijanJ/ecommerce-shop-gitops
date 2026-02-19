# ecommerce-shop-gitops

GitOps config for the ecommerce shop. Supports local development with Kind and is built to extend to EKS.

## Stack

- **ArgoCD** — GitOps continuous delivery
- **Kustomize** — environment overlays
- **kube-prometheus-stack** — Prometheus, Grafana, Alertmanager
- **metrics-server** — HPA support

## Local development (Kind)

Check you have everything installed:

```bash
make check-requirements
```

Spin up the full environment (cluster + ArgoCD + monitoring):

```bash
make start
```

Kind doesn't pull from registries, so load images manually:

```bash
make load-backend-image           # default tag from Makefile
make load-frontend-image          # override with FE_TAG=x.x.x
```

Deploy the applications:

```bash
make deploy-all
```

### ArgoCD

```bash
make argocd-password              # initial admin password
make argocd-ui                    # https://localhost:8080
```

If the repo is private, add your SSH key:

```bash
argocd repo add git@github.com:your-org/your-repo.git --ssh-private-key-path ~/.ssh/id_rsa
```

## Monitoring

```bash
make grafana-ui                   # http://localhost:3000  (admin / admin)
make prometheus-ui                # http://localhost:9090
make alertmanager-ui              # http://localhost:9093
```

## Useful commands

```bash
make pods                         # all pods across namespaces
make logs-backend
make logs-frontend
make hpa
make argocd-status
make events                       # recent warning events
```

## Teardown

```bash
make clean                        # remove ArgoCD applications
make nuke                         # delete the entire cluster
```

Run `make help` to see all available commands.
