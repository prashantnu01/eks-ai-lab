# Architecture

## System overview

```mermaid
flowchart TB
    user([Client]) -->|POST /ask| elb[AWS ELB<br/>LoadBalancer Service]

    subgraph eks["EKS Cluster — eks-ai-lab (us-east-1, k8s 1.34)"]
        elb --> svc[Service: bedrock-api]
        svc --> p1[Pod: bedrock-api<br/>FastAPI replica 1]
        svc --> p2[Pod: bedrock-api<br/>FastAPI replica 2]
        sa[ServiceAccount: bedrock-sa<br/>annotated with IAM role ARN]
        p1 -.uses.-> sa
        p2 -.uses.-> sa
    end

    subgraph aws["AWS Account"]
        ecr[(ECR: bedrock-api:v2<br/>scan on push, AES256)]
        oidc[OIDC Provider]
        sts[AWS STS]
        iam[IAM Role<br/>AmazonBedrockFullAccess]
        bedrock[Amazon Bedrock<br/>claude-haiku-4-5]
    end

    p1 -.image pull.-> ecr
    p2 -.image pull.-> ecr
    sa --> oidc
    oidc --> sts
    sts --> iam
    p1 -->|invoke_model| bedrock
    p2 -->|invoke_model| bedrock
```

## IRSA credential flow

No static AWS keys exist anywhere in the cluster. Every Bedrock call is authorized
through short-lived credentials minted per-pod:

```mermaid
sequenceDiagram
    participant Pod as Pod (boto3)
    participant Webhook as EKS Pod Identity Webhook
    participant STS as AWS STS
    participant OIDC as EKS OIDC Provider
    participant Bedrock as Amazon Bedrock

    Note over Pod,Webhook: Pod starts
    Webhook->>Pod: inject AWS_WEB_IDENTITY_TOKEN_FILE + AWS_ROLE_ARN
    Pod->>STS: AssumeRoleWithWebIdentity(JWT)
    STS->>OIDC: validate JWT signature
    OIDC-->>STS: valid
    STS->>STS: check trust policy<br/>(pinned to namespace + SA name)
    STS-->>Pod: temporary credentials (auto-refresh ~1h)
    Pod->>Bedrock: invoke_model with temp creds
    Bedrock-->>Pod: model response
```

## Why these choices

| Decision | Reason |
|---|---|
| IRSA over static keys | No long-lived secrets; creds scoped to one service account and auto-rotated |
| `maxUnavailable: 0` rollout | Readiness-gated, zero-downtime deploys (v1 → v2 proved it) |
| Same-layer `perl` purge | Removing files in the same `RUN` layer as install shrinks the image and cleared 6 CVEs |
| `us.` model prefix | Claude 4.x on Bedrock requires a cross-region inference profile, not a bare model id |
| LoadBalancer Service | Lets the AWS cloud controller provision and manage the ELB declaratively |
