FROM python:3.11-slim

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

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

CMD ["sh", "-c", "uvicorn nutrition_server.app:app --host 0.0.0.0 --port ${PORT:-8787} --proxy-headers --forwarded-allow-ips '*'"]
