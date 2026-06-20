# syntax=docker/dockerfile:1
#
# v2 image — perl purged in the same RUN layer as install so the files are
# actually removed from the layer (a separate RUN layer does not shrink the
# image). This is what took the ECR scan from 6 CVEs (all perl) -> 0 findings.

FROM python:3.12-slim

# Layer-caching strategy: copy requirements first so `pip install` is only
# re-run when dependencies change, not on every app.py edit.
WORKDIR /app
COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt \
    && apt-get purge -y perl perl-base perl-modules-5.36 2>/dev/null || true \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

COPY app.py .

# Run as a non-root user (Well-Architected: security pillar).
RUN useradd --create-home --uid 10001 appuser
USER appuser

EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
