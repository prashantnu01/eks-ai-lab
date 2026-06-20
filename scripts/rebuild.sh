#!/usr/bin/env bash
# Rebuild the entire lab environment from scratch (~20 min).
# Replace <ACCOUNT_ID> with your AWS account id before running.
set -euo pipefail

ACCOUNT_ID="${ACCOUNT_ID:-<ACCOUNT_ID>}"
REGION="us-east-1"
CLUSTER="eks-ai-lab"
export AWS_PAGER=""

echo "==> 1/5 Creating EKS cluster (with OIDC for IRSA)"
eksctl create cluster \
  --name "$CLUSTER" \
  --region "$REGION" \
  --nodegroup-name standard-workers \
  --node-type t3.medium \
  --nodes 2 --nodes-min 1 --nodes-max 3 \
  --managed --with-oidc \
  --vpc-cidr 192.168.0.0/16 \
  --tags "Environment=lab,Owner=prashant,Project=eks-ai-lab,CostCenter=learning"

echo "==> 2/5 Creating IRSA service account (bedrock-sa)"
eksctl create iamserviceaccount \
  --name bedrock-sa \
  --namespace default \
  --cluster "$CLUSTER" \
  --region "$REGION" \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonBedrockFullAccess \
  --approve --override-existing-serviceaccounts

echo "==> 3/5 Authenticating Docker to ECR"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS \
    --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "==> 4/5 Deploying app"
kubectl apply -f "$(dirname "$0")/../k8s/deployment.yaml"
kubectl apply -f "$(dirname "$0")/../k8s/service.yaml"

echo "==> 5/5 Verifying"
kubectl get nodes
kubectl get pods -l app=bedrock-api
kubectl get service bedrock-api
