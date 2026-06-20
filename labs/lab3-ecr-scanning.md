# Lab 3 — ECR + image scanning + CVE remediation

**Goal:** Move the image off Docker Hub into a private ECR repo with scan-on-push,
then actually fix what the scanner finds.

## What was built
- Private **ECR** repo `bedrock-api` — AES256 encryption, scan on push enabled.
- Docker authenticated to ECR via a short-lived IAM token.
- Pushed `v1` → scan found **6 CVEs (all `perl`, FixedIn: None)**.
- Fixed by purging `perl` **in the same `RUN` layer** as the pip install.
- Built + pushed `v2` → scan **clean (0 findings)**.
- Rolling update `v1` → `v2` with zero downtime (probes gated the switch).

## The fix that mattered
```dockerfile
RUN pip install --no-cache-dir -r requirements.txt \
    && apt-get purge -y perl perl-base perl-modules-5.36 \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*
```
Purging in a **separate** `RUN` layer would not shrink the image — the files
still live in the earlier layer. Same-layer purge actually removes them.

## Key learning
- Same-layer purge → smaller image + fewer CVEs.
- The **node IAM role** handles the ECR image pull; no imagePullSecrets needed.
- ECR auth tokens expire ~12h — re-run `get-login-password | docker login`.
