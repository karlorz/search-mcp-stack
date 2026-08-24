FROM ghcr.io/astral-sh/uv:python3.11-bookworm-slim

# Build-time argument for pinned GrokSearch commit
ARG GROKSEARCH_SHA=aeb0f752c8ef086059db1aec5aa4ba3c3dba6844
ARG GROKSEARCH_REPO=https://github.com/karlorz/GrokSearch.git

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PYTHONUNBUFFERED=1 \
    GROK_SEARCH_MCP_TRANSPORT=http \
    GROK_SEARCH_MCP_HOST=0.0.0.0 \
    GROK_SEARCH_MCP_PORT=8800 \
    GROK_SEARCH_MCP_PATH=/mcp

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN git clone ${GROKSEARCH_REPO} . \
    && git checkout ${GROKSEARCH_SHA} \
    && uv sync --frozen --no-dev

EXPOSE 8800

CMD ["uv", "run", "--frozen", "grok-search"]
