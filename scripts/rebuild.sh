#!/usr/bin/env bash
# Rebuild the entire lab environment from scratch (~20 min), idempotently.
# Set your account id first:  export ACCOUNT_ID=123456789012
set -euo pipefail

ACCOUNT_ID="${ACCOUNT_ID:-<ACCOUNT_ID>}"
REGION="us-east-1"
CLUSTER="eks-ai-lab"
REPO="bedrock-api"
TAG="v2"
DIR="$(cd "$(dirname "$0")" && pwd)"
ECR_URI="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/${REPO}"
export AWS_PAGER=""

# Guard: refuse to run with the placeholder still in place.
if [[ "$ACCOUNT_ID" == "<ACCOUNT_ID>" ]]; then
  echo "ERROR: set your account id first ->  export ACCOUNT_ID=123456789012" >&2
  exit 1
fi

echo "==> 0/6 Checking AWS auth"
aws sts get-caller-identity >/dev/null || {
  echo "ERROR: AWS auth invalid/expired. Run 'aws sso login' (set AWS_PROFILE) and retry." >&2
  exit 1
}

echo "==> 1/6 Creating EKS cluster (with OIDC for IRSA)"
if eksctl get cluster --name "$CLUSTER" --region "$REGION" >/dev/null 2>&1; then
  echo "    cluster '$CLUSTER' already exists — skipping"
else
  eksctl create cluster \
    --name "$CLUSTER" \
    --region "$REGION" \
    --nodegroup-name standard-workers \
    --node-type t3.medium \
    --nodes 2 --nodes-min 1 --nodes-max 3 \
    --managed --with-oidc \
    --vpc-cidr 192.168.0.0/16 \
    --tags "Environment=lab,Owner=prashant,Project=eks-ai-lab,CostCenter=learning"
fi

echo "==> 2/6 Creating IRSA service account (bedrock-sa)"
eksctl create iamserviceaccount \
  --name bedrock-sa \
  --namespace default \
  --cluster "$CLUSTER" \
  --region "$REGION" \
  --attach-policy-arn arn:aws:iam::aws:policy/AmazonBedrockFullAccess \
  --approve --override-existing-serviceaccounts

echo "==> 3/6 Authenticating Docker to ECR"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "==> 4/6 Ensuring ECR repo + image ${REPO}:${TAG}"
# Create the private repo (scan-on-push, AES256) if it was deleted with the cluster.
aws ecr describe-repositories --repository-names "$REPO" --region "$REGION" >/dev/null 2>&1 || \
  aws ecr create-repository \
    --repository-name "$REPO" \
    --image-scanning-configuration scanOnPush=true \
    --encryption-configuration encryptionType=AES256 \
    --region "$REGION" >/dev/null

# Build + push only if the tagged image is missing.
if aws ecr describe-images --repository-name "$REPO" --image-ids imageTag="$TAG" \
     --region "$REGION" >/dev/null 2>&1; then
  echo "    ${REPO}:${TAG} already in ECR — skipping build"
else
  echo "    ${REPO}:${TAG} not found — building from app/ and pushing"
  docker build -t "${ECR_URI}:${TAG}" "$DIR/../app"
  docker push "${ECR_URI}:${TAG}"
fi

echo "==> 5/6 Deploying app (substituting account id into the image ref)"
sed "s|<ACCOUNT_ID>|${ACCOUNT_ID}|g" "$DIR/../k8s/deployment.yaml" | kubectl apply -f -
kubectl apply -f "$DIR/../k8s/service.yaml"

echo "==> 6/6 Verifying"
kubectl get nodes
kubectl rollout status deployment/bedrock-api --timeout=180s || true
kubectl get pods -l app=bedrock-api
kubectl get service bedrock-api
echo "Done. ELB DNS (may take ~2 min to resolve):"
kubectl get service bedrock-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}{"\n"}'
