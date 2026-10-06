#!/bin/bash

# Removes everything ArgoCD deployed on the AWS prod cluster and waits until the AWS resources
# behind it (ALBs, EBS volumes) are gone. Run it BEFORE terraform destroy.
# The AWS Load Balancer Controller and the EBS CSI driver are managed by Terraform and must still
# be running, because they do the actual cleanup.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED_CLUSTER="ecommerce-cluster-prod"

# Waits until a command prints nothing. Usage: wait_empty <name> <timeout seconds> <command>
wait_empty() {
    for ((i = 0; i < $2 / 5; i++)); do
        [ -z "$(eval "$3" 2>/dev/null)" ] && echo "$1: none left" && return 0
        sleep 5
    done
    echo "$1: still present after $2s:"
    eval "$3"
    return 1
}

CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null)"
echo "Current kubectl context: ${CURRENT_CONTEXT:-none}"
if [[ "$CURRENT_CONTEXT" != *"$EXPECTED_CLUSTER"* ]]; then
    echo "Refusing to run: the context does not contain '$EXPECTED_CLUSTER'"
    exit 1
fi
read -p "Delete all ArgoCD applications and their resources? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted"; exit 1; }

# The roots have a finalizer, so this cascades to the ApplicationSets, Applications and workloads
make -C "$SCRIPT_DIR/.." clean || exit 1

# Ingresses and LoadBalancer Services disappear only after the controller deleted the ALB/NLB,
# and PersistentVolumes only after the EBS volume is deleted
FAILED=0
wait_empty "Applications" 300 "kubectl get applications -n argocd -o name" || FAILED=1
wait_empty "Ingresses (ALBs)" 600 "kubectl get ingress -A --no-headers" || FAILED=1
wait_empty "LoadBalancer Services" 600 "kubectl get svc -A --no-headers | awk '\$3==\"LoadBalancer\"'" || FAILED=1
wait_empty "PersistentVolumes (EBS)" 300 "kubectl get pv --no-headers" || FAILED=1

if [ "$FAILED" -ne 0 ]; then
    echo "Some resources are still present. Do not run terraform destroy yet."
    echo "Check the controller logs: kubectl logs -n kube-system deploy/aws-load-balancer-controller"
    exit 1
fi
echo "Teardown complete, safe to run terraform destroy"
