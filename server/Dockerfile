# Build the React client first, then copy only its static output into the Python
# runtime image. The Node toolchain never ships in production.
# node:24.12.0-alpine3.23
FROM node:26.7.0-alpine3.23@sha256:ce3cc39fe3b8b2602d3b1c4d63d301e46b48c550ecb627869853ddcdda418b63 AS web-build

WORKDIR /web

RUN corepack enable \
    && corepack prepare pnpm@10.10.0 --activate

COPY web/package.json web/pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile

COPY web/ ./
RUN pnpm test --run \
    && pnpm build

# Pinned to immutable digests so the build/runtime contents can't drift when an
# upstream tag is moved. The tag alongside the digest is advisory — the digest
# wins — but it tells Dependabot which tag to track when proposing bumps
# (without it, Dependabot once bumped us to the full non-slim image: PR #39).
# python:3.14-slim
FROM python:3.14-slim@sha256:d7a925f9eb9639a93e455b9f12c167569358818c0f62b51b88edbc8fcf34c421

# ghcr.io/astral-sh/uv:0.12.3
COPY --from=ghcr.io/astral-sh/uv:0.12.3@sha256:2d890623d310b57771ce840f0da5eed5fc6d657da05ffaa45d82797b53fa3abc /uv /uvx /bin/

WORKDIR /app

ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/app/.venv/bin:$PATH"

# Stable return origin for the separately hosted Vercel Progress client. Railway's
# OAUTH_REDIRECT_URI remains the Google callback so the existing iOS OAuth client
# and state cookies continue to use the API origin.
ENV WEB_APP_URL=https://pulse-progress.vercel.app

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY src/ ./src/
COPY --from=web-build /web/dist/ ./src/pulse_server/web_dist/
COPY schema.sql ./

RUN uv sync --frozen --no-dev

# The app runs entirely from the uv-managed venv; the base image's bundled
# pip/setuptools/wheel are unused at runtime. Removing them drops their CVE
# surface and the ability to install packages in a compromised container.
# (/usr/local/bin/python is the system interpreter; plain `python` would hit the venv.)
RUN /usr/local/bin/python -m pip uninstall -y pip setuptools wheel

# Run as an unprivileged user. The app writes nothing to disk in production
# (photo bytes live in S3-compatible object storage, metadata in Postgres;
# the LocalStore fallback is local-dev only), so the runtime user only needs
# read access to /app.
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --home-dir /app --no-create-home app \
    && chown -R app:app /app
USER app

# Container-level liveness probe against the unauthenticated /health route
# (Trivy DS-0026). urlopen raises on connection failure or non-2xx, failing
# the probe; stdlib-only because the slim image ships no curl/wget.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python -c 'import os,urllib.request as u; u.urlopen("http://127.0.0.1:%s/health" % os.environ.get("PORT","8787"), timeout=4)' || exit 1

CMD ["sh", "-c", "uvicorn pulse_server.app:app --host 0.0.0.0 --port ${PORT:-8787} --proxy-headers --forwarded-allow-ips '*'"]
