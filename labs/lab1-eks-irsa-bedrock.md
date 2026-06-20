# Lab 1 — EKS cluster + IRSA + Bedrock call

**Goal:** Stand up an EKS cluster and call Amazon Bedrock from inside a pod with
**no hardcoded credentials**, using IAM Roles for Service Accounts (IRSA).

## What was built
- EKS cluster via `eksctl` with the `--with-oidc` flag (enables IRSA).
- IRSA wiring: OIDC provider → IAM role → Kubernetes service account (`bedrock-sa`).
- An `aws-cli` test pod running under `bedrock-sa`.
- A live Bedrock call from inside the pod — credentials never touched.

## Proof it works
```bash
kubectl exec <pod> -- aws sts get-caller-identity
# Returns an *assumed-role* ARN, not the SSO identity — IRSA is in effect.
```

## Key learning
The full chain: **OIDC JWT → `STS:AssumeRoleWithWebIdentity` → temporary
credentials → Bedrock**. The trust policy is pinned to a specific namespace +
service account, so only `bedrock-sa` pods can assume the role.

## Bedrock model gotcha
- `us.anthropic.claude-haiku-4-5-20251001-v1:0` — works (Claude 4.x needs the
  `us.` cross-region inference profile prefix).
- `anthropic.claude-3-haiku-20240307-v1:0` — legacy, access denied on this account.
