# Lab 2 — Real Python app + Deployment + Service

**Goal:** Replace the throwaway test pod with a real containerized FastAPI app,
deployed as a proper Kubernetes Deployment fronted by a LoadBalancer Service.

## What was built
- **FastAPI app** (`app/app.py`) with `GET /`, `GET /health`, `POST /ask`.
- **Dockerfile** with a non-root user and requirements-first layer caching.
- **Deployment** — 2 replicas, `RollingUpdate` with `maxUnavailable: 0`,
  resource requests/limits, liveness + readiness probes on `/health`.
- **LoadBalancer Service** → AWS ELB provisioned automatically.
- Image published to Docker Hub: `prashantnu01/bedrock-api:v1`.

## Call it
```bash
ELB=$(kubectl get service bedrock-api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -X POST "http://$ELB/ask" \
  -H "Content-Type: application/json" \
  -d '{"question": "Hello from EKS"}'
```

## Key learning
- **Probe-gated rolling updates:** with `maxUnavailable: 0`, a new pod must pass
  its readiness probe before an old pod is terminated → zero downtime.
- The app inherits Bedrock access purely via `serviceAccountName: bedrock-sa`.
