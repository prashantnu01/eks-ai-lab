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

---

## Lab 4 — Karpenter node provisioning

> **Status: in progress.** Full runbook in [`labs/lab4-karpenter.md`](../labs/lab4-karpenter.md).

### What changes

Labs 1–3 run on a **static managed node group** — a fixed `t3.medium × 2` that is
always on whether or not the workload needs it. Lab 4 replaces that with
**Karpenter**, which provisions nodes *on demand* in response to unschedulable pods.

```mermaid
flowchart LR
    subgraph before["Before — managed node group"]
        d1[Deployment] --> mng[Fixed t3.medium x2<br/>always on]
    end

    subgraph after["After — Karpenter"]
        d2[Deployment] -->|pending pod| k[Karpenter controller]
        k -->|reads| pool[NodePool +<br/>EC2NodeClass]
        k -->|CreateFleet| node[Right-sized node<br/>Spot or On-Demand]
        node -->|idle| consolidate[Consolidate / scale toward 0]
    end

    before -.replaced by.-> after
```

### Provisioning flow

```mermaid
sequenceDiagram
    participant Sched as kube-scheduler
    participant Karp as Karpenter controller
    participant API as AWS EC2 / Fleet API
    participant Node as New EC2 node

    Sched->>Karp: pod is unschedulable (no capacity)
    Karp->>Karp: match pod requirements to NodePool constraints
    Karp->>API: CreateFleet — cheapest instance that fits (Spot first)
    API-->>Node: launch + bootstrap (AL2023, KarpenterNodeRole)
    Node->>Sched: registers, becomes Ready
    Sched->>Node: bind the pending pod
    Note over Karp,Node: when nodes go idle, Karpenter consolidates / removes them
```

### Why Karpenter

| Decision | Reason |
|---|---|
| Karpenter over static node group | Provisions the exact instance a pending pod needs, instead of paying for fixed idle capacity |
| Spot + On-Demand mix | Spot for cost, On-Demand fallback for availability — ~40–60% cheaper for bursty lab workloads |
| Instance flexibility (`t`/`m`/`c`, gen > 2) | Lets Karpenter right-size per workload rather than pinning one type |
| `consolidationPolicy: WhenEmptyOrUnderutilized` | Bin-packs and scales toward zero when idle — the core cost win |
| `limits.cpu` on the NodePool | Hard ceiling so a runaway scale-up can't provision unbounded EC2 |
| SQS interruption queue | Graceful drain on Spot reclamation rather than abrupt pod loss |

### What it sets up

Karpenter scales **nodes**; the next lab (HPA) scales **pods**. Together they form
the full autoscaling story: HPA adds pods under load → Karpenter adds nodes to fit
them → both scale back down when the load passes.
