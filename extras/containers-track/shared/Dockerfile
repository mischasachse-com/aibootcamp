# =============================================================================
# Containers Track — shared image for all dayN apps.
#
# The build context is the REPOSITORY ROOT, because the day apps are thin
# FastAPI wrappers that reuse files outside extras/:
#   common/      shared OpenAI client factory (Entra-only auth)
#   dayN/src/    the lab scripts the wrappers import via importlib
#   data/        fictional scenario fixtures (blackbox, incidents, manuals)
#
# Build (from the repo root):
#   docker build -f extras/containers-track/shared/Dockerfile \
#       --build-arg DAY=day1 -t corbit-track-day1 .
#
# The image mirrors the repo layout under /app so the lab scripts'
# `REPO_ROOT = Path(__file__).resolve().parents[2]` resolves to /app and
# `data/...` lookups work unchanged. Adding a future dayN folder needs no
# change here — --build-arg DAY=dayN selects extras/containers-track/dayN/app/.
#
# No secrets are ever baked in: configuration arrives via env vars at
# `docker run` / Container Apps deploy time. Auth is Entra-only
# (DefaultAzureCredential -> managed identity in Azure).
# =============================================================================

ARG PYTHON_VERSION=3.12

# --- deps stage: install the day's pinned requirements into a prefix ---------
FROM python:${PYTHON_VERSION}-slim AS deps
ARG DAY
COPY extras/containers-track/${DAY}/app/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir --prefix=/install -r /tmp/requirements.txt

# --- runtime stage ------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim
ARG DAY

ENV PYTHONPATH=/app \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PORT=8000

RUN useradd --create-home --uid 1000 appuser

COPY --from=deps /install /usr/local

# Repo mirror — the wrappers import these via PYTHONPATH / importlib.
COPY common/ /app/common/
COPY day1/src/ /app/day1/src/
COPY day2/src/ /app/day2/src/
COPY day3/src/ /app/day3/src/
COPY data/ /app/data/

# The selected day's FastAPI app.
COPY extras/containers-track/${DAY}/app/ /app/app/

# Persistent audit volume mount point (Day 3; harmless for other days).
RUN mkdir -p /app/audit && chown -R appuser:appuser /app

USER appuser
WORKDIR /app/app

EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import os,urllib.request;urllib.request.urlopen('http://127.0.0.1:'+os.environ.get('PORT','8000')+'/health')" || exit 1

CMD ["sh", "-c", "exec python -m uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000}"]
