"""
bedrock-api — a minimal FastAPI service that calls Amazon Bedrock.

Auth note: there are NO AWS credentials in this code. When this runs as a pod
on EKS, IRSA (IAM Roles for Service Accounts) injects a web-identity token and
role ARN as environment variables. boto3 discovers them through its default
credential provider chain and exchanges the token for short-lived credentials
via STS:AssumeRoleWithWebIdentity. See docs/architecture.md for the full chain.
"""

import json
import os

import boto3
from fastapi import FastAPI
from pydantic import BaseModel

# Cross-region inference profile id. Claude 4.x models on Bedrock require the
# "us." prefix (an inference profile) rather than a bare foundation-model id.
MODEL_ID = os.getenv("BEDROCK_MODEL_ID", "us.anthropic.claude-haiku-4-5-20251001-v1:0")
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
MAX_TOKENS = int(os.getenv("BEDROCK_MAX_TOKENS", "512"))

app = FastAPI(title="bedrock-api", version="2.0.0")

# boto3 resolves credentials lazily via the IRSA-injected env vars.
_bedrock = boto3.client("bedrock-runtime", region_name=AWS_REGION)


class AskRequest(BaseModel):
    question: str


@app.get("/")
def root():
    return {
        "service": "bedrock-api",
        "model": MODEL_ID,
        "region": AWS_REGION,
        "endpoints": ["GET /health", "POST /ask"],
    }


@app.get("/health")
def health():
    """Liveness + readiness probe target. Kept dependency-free on purpose."""
    return {"status": "ok"}


@app.post("/ask")
def ask(req: AskRequest):
    body = json.dumps(
        {
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": MAX_TOKENS,
            "messages": [{"role": "user", "content": req.question}],
        }
    )

    response = _bedrock.invoke_model(modelId=MODEL_ID, body=body)
    payload = json.loads(response["body"].read())
    answer = "".join(block.get("text", "") for block in payload.get("content", []))

    return {"question": req.question, "answer": answer, "model": MODEL_ID}
