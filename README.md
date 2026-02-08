# E-Commerce Shop GitOps

## Local development

Create a kind cluster using `./scripts/kind-cluster.sh create`.

Install ArgoCD using `./scripts/install-argo-cd.sh kind`.  
Add ssh key if repo is private using `argocd repo add git@github.com:argoproj/argocd-example-apps.git --ssh-private-key-path ~/.ssh/id_rsa`.
