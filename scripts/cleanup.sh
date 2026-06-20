#!/usr/bin/env bash
# Cost cleanup. Default: delete app only (keeps cluster).
# Pass --all to tear down the whole cluster.
set -euo pipefail

REGION="us-east-1"
CLUSTER="eks-ai-lab"
export AWS_PAGER=""

if [[ "${1:-}" == "--all" ]]; then
  echo "==> Full teardown: deleting cluster $CLUSTER"
  eksctl delete cluster --name "$CLUSTER" --region "$REGION"
else
  echo "==> Deleting app only (cluster stays up). Use --all for full teardown."
  kubectl delete deployment bedrock-api --ignore-not-found
  kubectl delete service bedrock-api --ignore-not-found
fi
