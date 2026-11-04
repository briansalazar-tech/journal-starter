# syntax=docker/dockerfile:1
#
# Production image for the Journal API (Azure Container Apps).
#
# Build:  docker build -t journal-api .
# Run:    docker run --rm -p 8000:8000 --env-file .env journal-api
#
# Configuration comes from environment variables at runtime (DATABASE_URL,
# OPENAI_API_KEY, OPENAI_BASE_URL, OPENAI_MODEL). Nothing secret is baked
# into the image; .env is excluded by .dockerignore.

ARG PYTHON_VERSION=3.14

# ---- Stage 1: resolve and install dependencies with uv ----------------------
FROM python:${PYTHON_VERSION}-slim-bookworm AS builder

COPY --from=ghcr.io/astral-sh/uv:latest /uv /bin/uv

# Compile .pyc files for faster startup, copy (not hardlink) packages out of
# the cache mount, and use the image's Python rather than downloading one.
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=0

WORKDIR /app

# Install dependencies first, from the lockfile only, so this layer is reused
# when only application code changes.
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --frozen --no-dev --no-install-project

# ---- Stage 2: minimal runtime image -----------------------------------------
FROM python:${PYTHON_VERSION}-slim-bookworm AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/app/.venv/bin:$PATH"

# Run as an unprivileged user.
RUN groupadd --system app && useradd --system --gid app --no-create-home app

WORKDIR /app

COPY --from=builder --chown=app:app /app/.venv /app/.venv
COPY --chown=app:app api ./api

USER app

EXPOSE 8000

# Container Apps terminates TLS at its ingress and forwards requests, so trust
# the X-Forwarded-* headers it adds. No --reload in production.
CMD ["uvicorn", "api.main:app", "--host", "0.0.0.0", "--port", "8000", \
     "--proxy-headers", "--forwarded-allow-ips", "*"]
