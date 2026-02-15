# E-Commerce Shop GitOps

## Local development

Create a kind cluster using `./scripts/kind-cluster.sh create`.

Install ArgoCD using `./scripts/install-argo-cd.sh kind`.  
Add ssh key if repo is private using `argocd repo add git@github.com:argoproj/argocd-example-apps.git --ssh-private-key-path ~/.ssh/id_rsa`.

### ArgoCD initial pass

kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

### Docker images

For Kind clusters, you have to load images using e.g. `kind load docker-image kristijan92/ecommerce-shop-fe:1.0.0 --name ecommerce-shop-cluster`

## Monitoring Access Commands (After Deployment)

### Grafana

kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
Access at: http://localhost:3000
Credentials: admin / admin

### Prometheus

kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
Access at: http://localhost:9090

### Alertmanager

kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093
Access at: http://localhost:9093
