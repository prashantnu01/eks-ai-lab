#!/usr/bin/env bash
# Cost cleanup. Default: delete app only (keeps cluster).
# Pass --all to tear down the whole cluster.
#
# Teardown gotcha this script handles automatically:
#   GuardDuty EKS Runtime Monitoring auto-creates a VPC interface endpoint
#   (com.amazonaws.<region>.guardduty-data) + a managed security group inside
#   the cluster VPC. eksctl doesn't know about them, so its CloudFormation
#   stack delete fails on the subnets/VPC they're attached to (DELETE_FAILED:
#   "subnet has dependencies"). We proactively remove the LoadBalancer ELB and,
#   after eksctl runs, sweep any GuardDuty leftovers so the VPC can drop.
set -euo pipefail

REGION="us-east-1"
CLUSTER="eks-ai-lab"
STACK="eksctl-${CLUSTER}-cluster"
export AWS_PAGER=""

# Remove GuardDuty-managed endpoint(s), orphaned ENIs, and the managed SG from a
# VPC, then delete the VPC and retry the eksctl CloudFormation stack delete.
sweep_guardduty_leftovers() {
  local vpc="$1"
  [[ -z "$vpc" || "$vpc" == "None" ]] && return 0

  echo "==> Sweeping GuardDuty leftovers in $vpc"

  # 1. Delete any VPC endpoints (guardduty-data etc.)
  local eps
  eps=$(aws ec2 describe-vpc-endpoints --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc" \
    --query "VpcEndpoints[].VpcEndpointId" --output text)
  if [[ -n "$eps" ]]; then
    echo "    deleting endpoints: $eps"
    aws ec2 delete-vpc-endpoints --region "$REGION" --vpc-endpoint-ids $eps >/dev/null || true
    sleep 30   # let the endpoint ENIs detach/reap
  fi

  # 2. Delete any now-detached (available) ENIs still in the VPC
  local enis
  enis=$(aws ec2 describe-network-interfaces --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc" "Name=status,Values=available" \
    --query "NetworkInterfaces[].NetworkInterfaceId" --output text)
  for eni in $enis; do
    echo "    deleting orphaned ENI: $eni"
    aws ec2 delete-network-interface --network-interface-id "$eni" --region "$REGION" 2>/dev/null || true
  done

  # 3. Delete GuardDuty-managed (and any other non-default) security groups
  local sgs
  sgs=$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=$vpc" \
    --query "SecurityGroups[?GroupName!='default'].GroupId" --output text)
  for sg in $sgs; do
    echo "    deleting security group: $sg"
    aws ec2 delete-security-group --group-id "$sg" --region "$REGION" 2>/dev/null || true
  done

  # 4. Delete the VPC directly (best effort), then nudge CloudFormation
  aws ec2 delete-vpc --vpc-id "$vpc" --region "$REGION" 2>/dev/null || true
}

if [[ "${1:-}" == "--all" ]]; then
  echo "==> Full teardown of $CLUSTER"

  # Capture the VPC id BEFORE deleting the cluster (we need it for the sweep).
  VPC_ID=$(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
    --query "cluster.resourcesVpcConfig.vpcId" --output text 2>/dev/null || echo "")

  # Delete the LoadBalancer Service first so its ELB (and ELB ENIs) go away
  # cleanly before the VPC teardown — otherwise they orphan and block deletion.
  echo "==> Removing app + LoadBalancer (releases the ELB)"
  kubectl delete service bedrock-api --ignore-not-found --wait=true 2>/dev/null || true
  kubectl delete deployment bedrock-api --ignore-not-found 2>/dev/null || true
  sleep 20

  echo "==> eksctl delete cluster (with wait)"
  if ! eksctl delete cluster --name "$CLUSTER" --region "$REGION" --wait --force; then
    echo "==> eksctl reported a failure — sweeping GuardDuty leftovers and retrying stack delete"
    sweep_guardduty_leftovers "$VPC_ID"
    aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION" 2>/dev/null || true
    aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region "$REGION" 2>/dev/null || true
  fi

  # Final safety net: if the VPC somehow still exists, sweep once more.
  if [[ -n "$VPC_ID" && "$VPC_ID" != "None" ]] && \
     aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region "$REGION" >/dev/null 2>&1; then
    echo "==> VPC still present — final sweep"
    sweep_guardduty_leftovers "$VPC_ID"
    aws cloudformation delete-stack --stack-name "$STACK" --region "$REGION" 2>/dev/null || true
  fi

  echo "==> Teardown complete. Verify nothing is left:"
  echo "    aws cloudformation list-stacks --region $REGION --query \"StackSummaries[?contains(StackName,'$CLUSTER') && StackStatus!='DELETE_COMPLETE']\""
else
  echo "==> Deleting app only (cluster stays up). Use --all for full teardown."
  kubectl delete service bedrock-api --ignore-not-found --wait=true
  kubectl delete deployment bedrock-api --ignore-not-found
fi
