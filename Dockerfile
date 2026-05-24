# Pinned to immutable digests so the build/runtime contents can't drift when an
# upstream tag is moved. Update these together with the trailing version comment.
# python:3.11-slim -> 3.11.15-slim-trixie
FROM python@sha256:a3ab0b966bc4e91546a033e22093cb840908979487a9fc0e6e38295747e49ac0

# ghcr.io/astral-sh/uv:latest -> 0.11.16
COPY --from=ghcr.io/astral-sh/uv@sha256:440fd6477af86a2f1b38080c539f1672cd22acb1b1a47e321dba5158ab08864d /uv /uvx /bin/

WORKDIR /app

ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/app/.venv/bin:$PATH"

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

COPY src/ ./src/
COPY schema.sql alembic.ini ./
COPY alembic/ ./alembic/

RUN uv sync --frozen --no-dev

# Run as an unprivileged user. The app writes nothing to disk (photos live in
# Postgres), so the runtime user only needs read access to /app.
RUN groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --home-dir /app --no-create-home app \
    && chown -R app:app /app
USER app

CMD ["sh", "-c", "uvicorn pulse_server.app:app --host 0.0.0.0 --port ${PORT:-8787} --proxy-headers --forwarded-allow-ips '*'"]
