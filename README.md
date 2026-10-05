# search-mcp-stack

Deployment packaging and configuration stack for GrokSearch FastMCP HTTP server with `code-guda-gateway` token verification and Caddy ingress.

This is a **pin-harvest monorepo**, not a merged binary. FastMCP and the GuDa gateway stay two processes. Product source is vendored as git submodules at the SHAs in `versions.env`:

| Path | Product | Pin |
| --- | --- | --- |
| `mcp/` | `karlorz/GrokSearch` (`main`) | `GROKSEARCH_SHA` |
| `gateway/` | `karlorz/code-guda-gateway` (`main`) | `GUDA_GATEWAY_SHA` |

kr01 install still clones those pins into `/opt/GrokSearch` and the gateway install path. The submodules are the in-repo source tree for development and later refactor. Do not fold MCP tool handlers into the Go gateway.

```bash
git clone --recurse-submodules https://github.com/karlorz/search-mcp-stack.git
git submodule update --init --recursive
```

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
                                 │ Token Verify            │
                                 └─────────────────────────┘
                               http://127.0.0.1:8080/internal/keys/verify
                               (X-Internal-Token: GROK_SEARCH_MCP_INTERNAL_TOKEN)
```

1. **Caddy Ingress (`search.karldigi.dev`)**:
   - `/internal*` routes are rejected immediately with HTTP 404 (protecting internal verification endpoints).
   - CLI auth routes (`/auth/cli/start`, `/auth/cli/approve`, `/auth/cli/callback`, `/auth/cli/check`) proxy to GrokSearch on `127.0.0.1:8800`. Unknown `/auth/cli/*` paths are not wildcard-proxied.
   - M2 REST routes (`/api/v1/search`, `/api/v1/fetch`, `/api/v1/map`) proxy to GrokSearch on `127.0.0.1:8800`; unknown `/api/v1/*` paths are not wildcard-proxied to 8800 and fall through to the gateway.
   - `/mcp*` routes proxy to GrokSearch FastMCP HTTP transport on `127.0.0.1:8800` (`flush_interval -1` for streaming).
   - All other routes fall through to `code-guda-gateway` on `127.0.0.1:8080` (admin UI, OAuth discovery/authorize/register/token, and gateway proxy APIs).

2. **Authentication Flow**:
   - Bearer clients send `Authorization: Bearer <gateway_user_key>` to `https://search.karldigi.dev/mcp`.
   - GrokSearch calls `POST http://127.0.0.1:8080/internal/keys/verify` sending header `X-Internal-Token: <GROK_SEARCH_MCP_INTERNAL_TOKEN>` and JSON body `{"token": "<gateway_user_key>"}`.
   - If verified, GrokSearch processes the search tool request, forwarding queries to `GUDA_BASE_URL` with machine key `GUDA_API_KEY`.
   - ChatGPT web and Doubao use OAuth instead of a pasted bearer. Discovery, registration, consent, and token routes stay on the gateway (Caddy fallback). `/mcp` stays on FastMCP. Set `GROK_SEARCH_MCP_OAUTH_ISSUER` only after the gateway is serving `/.well-known/oauth-protected-resource/mcp`. OAuth-minted `gsk_` keys are for `/mcp` only. `install.sh` and `update.sh` deploy the GrokSearch checkout, not the gateway pin; deploy the gateway with its own installer first.
   - For `grok-search` Skill+CLI OAuth (`auth-start` / `auth-status`), GrokSearch acts as the approve+poll coordinator bridging to the gateway OAuth server. Install/update in this repo deploys GrokSearch MCP and stack Caddy routing, not the gateway. The operator provisions the fixed public CLI OAuth client on the deployed gateway via `POST /register` with redirect URI `https://search.karldigi.dev/auth/cli/callback`, then puts the returned `client_id` in `/etc/grok-search-mcp.env` (`GROK_SEARCH_CLI_OAUTH_CLIENT_ID`).
   - **Template Drift Note**: The gateway installer maintains its own template at `gateway/scripts/templates/Caddyfile.code-guda-gateway` which only knows about `/internal*` and fallback. If the gateway installer is rerun, the stack-owned Caddy snippet (`caddy/Caddyfile.code-guda-gateway`) must be reapplied (e.g. by rerunning `install.sh --skip-mcp` or copying the snippet) so that `/auth/cli/*` and `/mcp*` routes to port 8800 are not overwritten.

3. **Public Engine Identity**:
   - A fresh install renders `GROK_SEARCH_MCP_PUBLIC_URL=https://search.karldigi.dev/mcp` into `/etc/grok-search-mcp.env` from the selected `--domain` and MCP path.
   - `get_config_info` uses this value to confirm that the client is using the remote HTTP plugin engine. It never exposes loopback upstream URLs, credentials, local paths, upstream error bodies, or exception details.
   - This value is descriptive only; Caddy and internal service routing remain unchanged.

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
2. Restart the service after the env file is filled:
   ```bash
   sudo systemctl restart grok-search-mcp
   ```
3. For connector OAuth, deploy the gateway first (`GUDA_OAUTH_ISSUER` and `GUDA_OAUTH_OPERATOR_PASSWORD_HASH` on the gateway). Then set `GROK_SEARCH_MCP_OAUTH_ISSUER` to the public origin and restart `grok-search-mcp` again. Leave the issuer unset until that gateway metadata URL returns 200.

## Updating

```bash
sudo ./update.sh --public-mcp-url https://search.karldigi.dev/mcp
```

On the first update after this feature lands, pass the deployment's real public URL explicitly. `update.sh` adds it to an existing `/etc/grok-search-mcp.env` only when the variable is absent. Existing credentials and operator-defined values are preserved, repeated updates do not duplicate the entry, and a custom-domain deployment is never mislabeled with the production default.
