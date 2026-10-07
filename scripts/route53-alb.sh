#!/bin/bash

# Creates or deletes the Route53 alias records for the hosts of the aws-prod Ingresses.
# Both Ingresses share one ALB (group.name), the ALB is created by the AWS Load Balancer Controller.
# Usage: route53-alb.sh upsert|delete
# Needs AWS credentials in the environment (export AWS_PROFILE) and kubectl pointing at the cluster.

ACTION="$1"
ZONE_NAME="jovanovski.dev"
REGION="eu-central-1"
NAMESPACES=(aws-prod-frontend aws-prod-backend)

[[ "$ACTION" == "upsert" || "$ACTION" == "delete" ]] || { echo "Usage: $0 upsert|delete"; exit 1; }

aws sts get-caller-identity >/dev/null 2>&1 || {
    echo "AWS login missing or expired. Run: aws sso login --profile <profile>"
    exit 1
}

ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name "$ZONE_NAME" \
    --query "HostedZones[?Name=='${ZONE_NAME}.'].Id | [0]" --output text)
if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "None" ]; then
    echo "Hosted zone $ZONE_NAME not found"
    exit 1
fi

# Prints the ALB DNS name of the first Ingress in a namespace, empty if it has none yet
alb_dns() {
    kubectl get ingress -n "$1" -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null
}

for NS in "${NAMESPACES[@]}"; do
    if [ "$ACTION" = "upsert" ]; then
        echo "Waiting for the ALB address on the Ingress in $NS (up to 10 minutes)..."
        ALB_DNS=""
        for ((i = 0; i < 60; i++)); do
            ALB_DNS=$(alb_dns "$NS")
            [ -n "$ALB_DNS" ] && break
            sleep 10
        done
        if [ -z "$ALB_DNS" ]; then
            echo "No ALB address after 10 minutes. Check: kubectl logs -n kube-system deploy/aws-load-balancer-controller"
            exit 1
        fi
        ALB_ZONE_ID=$(aws elbv2 describe-load-balancers --region "$REGION" \
            --query "LoadBalancers[?DNSName=='${ALB_DNS}'].CanonicalHostedZoneId | [0]" --output text)

        for HOST in $(kubectl get ingress -n "$NS" -o jsonpath='{.items[*].spec.rules[*].host}'); do
            aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch \
                "{\"Changes\":[{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$HOST\",\"Type\":\"A\",\"AliasTarget\":{\"HostedZoneId\":\"$ALB_ZONE_ID\",\"DNSName\":\"$ALB_DNS\",\"EvaluateTargetHealth\":false}}}]}" \
                >/dev/null || exit 1
            echo "$HOST -> $ALB_DNS"
        done
    else
        for HOST in $(kubectl get ingress -n "$NS" -o jsonpath='{.items[*].spec.rules[*].host}' 2>/dev/null); do
            # A DELETE must repeat the record exactly as it is stored, so read it first
            RECORD=$(aws route53 list-resource-record-sets --hosted-zone-id "$ZONE_ID" \
                --query "ResourceRecordSets[?Name=='${HOST}.' && Type=='A'] | [0]" --output json)
            if [ "$RECORD" = "null" ]; then
                echo "$HOST: no record, skipping"
                continue
            fi
            aws route53 change-resource-record-sets --hosted-zone-id "$ZONE_ID" --change-batch \
                "{\"Changes\":[{\"Action\":\"DELETE\",\"ResourceRecordSet\":$RECORD}]}" >/dev/null || exit 1
            echo "$HOST: record deleted"
        done
    fi
done
