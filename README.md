# search-mcp-stack

Deployment packaging and configuration stack for GrokSearch FastMCP HTTP server with `code-guda-gateway` token verification and Caddy ingress.

## Architecture Overview

```
                          Internet / Clients
                                 │
                                 ▼
                     ┌───────────────────────┐
                     │         Caddy         │
                     │ (search.karldigi.dev) │
                     └───────────┬───────────┘
                                 │
         ┌───────────────────────┼──────────────────────┐
         │                       │                      │
         ▼                       ▼                      ▼
    /internal*                 /mcp*             Fallback / (UI/API)
   [Respond 404]         [Reverse Proxy]            [Reverse Proxy]
  (Blocks public)        127.0.0.1:8800             127.0.0.1:8080
                                 │                         │
                                 ▼                         ▼
                        ┌─────────────────┐       ┌─────────────────┐
                        │ GrokSearch MCP  │       │code-guda-gateway│
                        │    (FastMCP)    │       │  (Admin / Keys) │
                        └────────┬────────┘       └────────┬────────┘
                                 │                         ▲
                                 │ Bearer Token Verify     │
                                 └─────────────────────────┘
                               http://127.0.0.1:8080/internal/keys/verify
                               (Bearer GROK_SEARCH_MCP_INTERNAL_TOKEN)
```

1. **Caddy Ingress (`search.karldigi.dev`)**:
   - `/internal*` routes are rejected immediately with HTTP 404 (protecting internal verification endpoints).
   - `/mcp*` routes proxy to GrokSearch FastMCP HTTP transport on `127.0.0.1:8800` (`flush_interval -1` for streaming).
   - All other routes fall through to `code-guda-gateway` on `127.0.0.1:8080` (admin UI and gateway proxy APIs).

2. **Authentication Flow**:
   - Client sends request to `https://search.karldigi.dev/mcp` with `Authorization: Bearer <gateway_user_key>`.
   - GrokSearch calls `POST http://127.0.0.1:8080/internal/keys/verify` sending `Authorization: Bearer <GROK_SEARCH_MCP_INTERNAL_TOKEN>` and JSON body `{"key": "<gateway_user_key>"}`.
   - If verified, GrokSearch processes the search tool request, forwarding queries to `GUDA_BASE_URL` with machine key `GUDA_API_KEY`.

## macOS / Client Configuration

Clients (Cursor, Claude Desktop, Roo, etc.) connect via SSE/HTTP without needing local `uv` or Python runtimes:

```json
{
  "mcpServers": {
    "grok-search": {
      "url": "https://search.karldigi.dev/mcp",
      "headers": {
        "Authorization": "Bearer <your_code_guda_gateway_key>"
      }
    }
  }
}
```

Or via environment variable:
```bash
export GROK_SEARCH_MCP_URL=https://search.karldigi.dev/mcp
```

## Operator Notes

- **x.ai Web / Grok2API Behavior**: If `initialize` / SSE connection succeeds but search queries return empty content from upstream models (e.g. `grok-4.3-fast` or x.ai web session limits), investigate grok2api / upstream provider status rather than bearer authentication.
- **Phase 5 Non-Goals**: Advanced key scopes (`kind`), granular per-key rate limiting, and automated Coolify live mesh deployment are tracked for future phases.

## Installation on Host (Linux / Systemd)

```bash
sudo ./install.sh --domain search.karldigi.dev --listen-addr 127.0.0.1:8080
```

1. Edit `/etc/grok-search-mcp.env` to set `GROK_SEARCH_MCP_INTERNAL_TOKEN` and `GUDA_API_KEY`.
2. Restart the service:
   ```bash
   sudo systemctl restart grok-search-mcp
   ```

## Updating

```bash
sudo ./update.sh
```
