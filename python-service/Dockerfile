# ---- Stage 1: install dependencies into a virtual environment ----
FROM python:3.11-slim AS builder

# Set this to the same version as `uv --version` on your machine,
# so the build can read the uv.lock you created.
ARG UV_VERSION=0.8.0
RUN pip install --no-cache-dir "uv==${UV_VERSION}"

ENV UV_PROJECT_ENVIRONMENT=/opt/venv \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never

WORKDIR /build
COPY pyproject.toml uv.lock ./

# Exactly the versions in uv.lock; no dev tools (pytest, httpx)
RUN uv sync --frozen --no-dev --no-install-project

# ---- Stage 2: minimal runtime ----
# Same base as the builder, so the venv's Python path still matches
FROM python:3.11-slim

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Dedicated non-root user with a fixed numeric id (Kubernetes runAsNonRoot can verify it)
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
# Only the application files. They stay owned by root, so the app can't modify its own code.
COPY main.py auth.py log_setup.py token_pb2.py token_pb2_grpc.py ./

USER 10001:10001

EXPOSE 8000
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
