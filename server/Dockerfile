# Pinned to immutable digests so the build/runtime contents can't drift when an
# upstream tag is moved. The tag alongside the digest is advisory — the digest
# wins — but it tells Dependabot which tag to track when proposing bumps
# (without it, Dependabot once bumped us to the full non-slim image: PR #39).
# python:3.11-slim -> 3.11.15-slim-trixie
FROM python:3.11-slim@sha256:a3ab0b966bc4e91546a033e22093cb840908979487a9fc0e6e38295747e49ac0

# ghcr.io/astral-sh/uv:0.11.16
COPY --from=ghcr.io/astral-sh/uv:0.11.16@sha256:440fd6477af86a2f1b38080c539f1672cd22acb1b1a47e321dba5158ab08864d /uv /uvx /bin/

WORKDIR /app

ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/app/.venv/bin:$PATH"

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY src/ ./src/
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
