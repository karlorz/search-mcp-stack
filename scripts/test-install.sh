#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
EXPECTED_PUBLIC_MCP_URL="https://search.karldigi.dev/mcp"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_file() {
  [[ -f "$1" ]] || fail "expected file $1 to exist"
}

assert_contains() {
  local file="$1"
  local pattern="$2"
  grep -Fq -- "$pattern" "$file" || fail "expected $file to contain: $pattern"
}

assert_not_contains() {
  local file="$1"
  local pattern="$2"
  if grep -Fq -- "$pattern" "$file"; then
    fail "expected $file NOT to contain: $pattern"
  fi
}

assert_equals() {
  local want="$1"
  local got="$2"
  [[ "$want" == "$got" ]] || fail "expected [$want], got [$got]"
}

printf '=== Step 1: Static checks on repo files ===\n'

VERSIONS_FILE="$ROOT/versions.env"
assert_file "$VERSIONS_FILE"

# Assert versions.env SHAs are 40-hex
GROKSEARCH_SHA="$(grep '^GROKSEARCH_SHA=' "$VERSIONS_FILE" | cut -d= -f2)"
GROKSEARCH_REF="$(grep '^GROKSEARCH_REF=' "$VERSIONS_FILE" | cut -d= -f2)"
GUDA_GATEWAY_SHA="$(grep '^GUDA_GATEWAY_SHA=' "$VERSIONS_FILE" | cut -d= -f2)"

[[ "$GROKSEARCH_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "GROKSEARCH_SHA is not a 40-hex SHA: $GROKSEARCH_SHA"
[[ "$GUDA_GATEWAY_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "GUDA_GATEWAY_SHA is not a 40-hex SHA: $GUDA_GATEWAY_SHA"
assert_equals "grok-with-tavily" "$GROKSEARCH_REF"

if [[ -f "$ROOT/.gitmodules" ]]; then
  assert_contains "$ROOT/.gitmodules" "path = mcp"
  assert_contains "$ROOT/.gitmodules" "path = gateway"
  assert_contains "$ROOT/.gitmodules" "https://github.com/karlorz/GrokSearch.git"
  assert_contains "$ROOT/.gitmodules" "https://github.com/karlorz/code-guda-gateway.git"
  assert_contains "$ROOT/.gitmodules" "branch = grok-with-tavily"
fi
if [[ -d "$ROOT/mcp/.git" || -f "$ROOT/mcp/.git" ]]; then
  mcp_head="$(git -C "$ROOT/mcp" rev-parse HEAD)"
  assert_equals "$GROKSEARCH_SHA" "$mcp_head"
  assert_contains "$ROOT/mcp/src/grok_search/config.py" "GROK_SEARCH_MCP_PUBLIC_URL"
  assert_contains "$ROOT/mcp/src/grok_search/config.py" "remote_engine_active"
fi
if [[ -d "$ROOT/gateway/.git" || -f "$ROOT/gateway/.git" ]]; then
  gateway_head="$(git -C "$ROOT/gateway" rev-parse HEAD)"
  assert_equals "$GUDA_GATEWAY_SHA" "$gateway_head"
fi

# Assert systemd unit template / source
UNIT_SRC="$ROOT/systemd/grok-search-mcp.service"
assert_file "$UNIT_SRC"
assert_contains "$UNIT_SRC" "/opt/GrokSearch/.venv/bin/grok-search"
assert_contains "$UNIT_SRC" "127.0.0.1"
assert_contains "$UNIT_SRC" "ReadWritePaths=/opt/GrokSearch /opt/uv-python"
assert_contains "$UNIT_SRC" "EnvironmentFile="
assert_contains "$UNIT_SRC" "NoNewPrivileges=true"
assert_contains "$UNIT_SRC" "ProtectSystem=strict"
assert_contains "$UNIT_SRC" "ProtectHome=true"
assert_contains "$UNIT_SRC" "PrivateTmp=true"
assert_contains "$UNIT_SRC" "PrivateDevices=true"
assert_contains "$UNIT_SRC" "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX"
assert_contains "$UNIT_SRC" "RestrictRealtime=true"
assert_contains "$UNIT_SRC" "LockPersonality=true"
assert_contains "$UNIT_SRC" "MemoryDenyWriteExecute=true"

# Assert env example
ENV_EXAMPLE="$ROOT/systemd/grok-search-mcp.env.example"
assert_file "$ENV_EXAMPLE"
assert_contains "$ENV_EXAMPLE" "GROK_SEARCH_MCP_VERIFY_URL=http://127.0.0.1:8080/internal/keys/verify"
assert_contains "$ENV_EXAMPLE" "GROK_SEARCH_MCP_HOST=127.0.0.1"
assert_contains "$ENV_EXAMPLE" "GROK_SEARCH_MCP_PORT=8800"
assert_contains "$ENV_EXAMPLE" "GROK_SEARCH_MCP_PATH=/mcp"
assert_contains "$ENV_EXAMPLE" 'GROK_SEARCH_MCP_PUBLIC_URL={{PUBLIC_MCP_URL}}'
assert_contains "$ENV_EXAMPLE" "UV_PYTHON_INSTALL_DIR=/opt/uv-python"
assert_contains "$ROOT/install.sh" "sync --frozen"
assert_contains "$ROOT/install.sh" "/usr/local/libexec/uv"
assert_contains "$ROOT/update.sh" "sync --frozen"
assert_contains "$ROOT/update.sh" "/usr/local/libexec/uv"
assert_not_contains "$ROOT/update.sh" "command -v uv"
assert_contains "$ROOT/update.sh" "required uv runtime is missing"
assert_contains "$ROOT/update.sh" "UV_PYTHON_INSTALL_DIR"
assert_contains "$ROOT/update.sh" "UV_CACHE_DIR"
# Ensure no real tokens assigned
if grep -E '^GROK_SEARCH_MCP_INTERNAL_TOKEN=[^#[:space:]]+' "$ENV_EXAMPLE" >/dev/null; then
  fail "env example should not contain real GROK_SEARCH_MCP_INTERNAL_TOKEN value"
fi
if grep -E '^GUDA_API_KEY=[^#[:space:]]+' "$ENV_EXAMPLE" >/dev/null; then
  fail "env example should not contain real GUDA_API_KEY value"
fi

# Assert README internal verify contract documentation
README_FILE="$ROOT/README.md"
assert_file "$README_FILE"
assert_contains "$README_FILE" "X-Internal-Token: GROK_SEARCH_MCP_INTERNAL_TOKEN"
assert_contains "$README_FILE" '{"token": "<gateway_user_key>"}'
assert_not_contains "$README_FILE" '{"key": "<gateway_user_key>"}'

# Assert Caddy template / snippet
CADDY_SRC="$ROOT/caddy/Caddyfile.code-guda-gateway"
assert_file "$CADDY_SRC"
assert_contains "$CADDY_SRC" "handle /internal*"
assert_contains "$CADDY_SRC" "respond 404"
assert_contains "$CADDY_SRC" "handle /mcp*"
assert_contains "$CADDY_SRC" "reverse_proxy 127.0.0.1:8800"
assert_contains "$CADDY_SRC" "flush_interval -1"
assert_not_contains "$CADDY_SRC" "handle_path"

# Assert Dockerfile
DOCKERFILE="$ROOT/docker/Dockerfile"
assert_file "$DOCKERFILE"
assert_contains "$DOCKERFILE" "uv"
assert_not_contains "$DOCKERFILE" "COPY .env"
assert_not_contains "$DOCKERFILE" "COPY *.env"

# Assert docker-compose.coolify.yml
COMPOSE_COOLIFY="$ROOT/docker/docker-compose.coolify.yml"
assert_file "$COMPOSE_COOLIFY"
# Must not publish host port directly (avoid conflicting with host / Traefik)
if grep -E '^\s*-\s*["'\'']?[0-9]+:8800' "$COMPOSE_COOLIFY" >/dev/null; then
  fail "docker-compose.coolify.yml must not publish host ports directly"
fi

# Assert no leaked secrets in repo tree
if grep -rnE '(gsk_[a-zA-Z0-9_-]{20,}|sk-[a-zA-Z0-9_-]{20,})' "$ROOT" \
  --exclude-dir=.git --exclude-dir=mcp --exclude-dir=gateway \
  | grep -v 'test-install.sh' >/dev/null; then
  fail "Found apparent real secret tokens (gsk_... or sk-...) in repository"
fi

printf '=== Step 2: Test install.sh rendering in fake root ===\n'

FAKE_ROOT="$TMP/root"
mkdir -p "$FAKE_ROOT"

assert_file "$ROOT/install.sh"
chmod +x "$ROOT/install.sh"

SEARCH_STACK_TEST_MODE=1 INSTALL_ROOT="$FAKE_ROOT" \
  "$ROOT/install.sh" \
  --render-only \
  --domain search.karldigi.dev \
  --listen-addr 127.0.0.1:8080 >/dev/null

INSTALLED_SERVICE="$FAKE_ROOT/etc/systemd/system/grok-search-mcp.service"
INSTALLED_ENV="$FAKE_ROOT/etc/grok-search-mcp.env"
INSTALLED_CADDY="$FAKE_ROOT/etc/caddy/Caddyfile.code-guda-gateway"

assert_file "$INSTALLED_SERVICE"
assert_file "$INSTALLED_ENV"
assert_file "$INSTALLED_CADDY"

assert_contains "$INSTALLED_SERVICE" "/opt/GrokSearch/.venv/bin/grok-search"
assert_contains "$INSTALLED_SERVICE" "EnvironmentFile=/etc/grok-search-mcp.env"
assert_contains "$INSTALLED_SERVICE" "User=groksearch"
assert_contains "$INSTALLED_ENV" "GROK_SEARCH_MCP_PUBLIC_URL=$EXPECTED_PUBLIC_MCP_URL"
assert_not_contains "$INSTALLED_ENV" "{{PUBLIC_MCP_URL}}"

assert_contains "$INSTALLED_CADDY" "search.karldigi.dev {"
assert_contains "$INSTALLED_CADDY" "handle /internal*"
assert_contains "$INSTALLED_CADDY" "respond 404"
assert_contains "$INSTALLED_CADDY" "handle /mcp*"
assert_contains "$INSTALLED_CADDY" "reverse_proxy 127.0.0.1:8800"
assert_contains "$INSTALLED_CADDY" "flush_interval -1"
assert_contains "$INSTALLED_CADDY" "reverse_proxy 127.0.0.1:8080"
assert_not_contains "$INSTALLED_CADDY" "handle_path"
assert_not_contains "$INSTALLED_CADDY" "{{DOMAIN}}"
assert_not_contains "$INSTALLED_CADDY" "{{LISTEN_ADDR}}"

printf '=== Step 2b: Reject unsafe URLs and escape template replacements ===\n'

UNSAFE_ROOT="$TMP/unsafe-root"
mkdir -p "$UNSAFE_ROOT"
if SEARCH_STACK_TEST_MODE=1 INSTALL_ROOT="$UNSAFE_ROOT" \
  "$ROOT/install.sh" --render-only --domain $'search.karldigi.dev\nEVIL=1' >/dev/null 2>&1; then
  fail "install.sh should reject a public domain containing a newline"
fi

ESCAPED_ROOT="$TMP/escaped-root"
mkdir -p "$ESCAPED_ROOT"
GROK_SEARCH_MCP_PUBLIC_URL='https://search.karldigi.dev/mcp&preview' \
  SEARCH_STACK_TEST_MODE=1 INSTALL_ROOT="$ESCAPED_ROOT" \
  "$ROOT/install.sh" --render-only >/dev/null
assert_contains \
  "$ESCAPED_ROOT/etc/grok-search-mcp.env" \
  "GROK_SEARCH_MCP_PUBLIC_URL=https://search.karldigi.dev/mcp&preview"

printf '=== Step 3: Test idempotency (do not overwrite existing env) ===\n'

printf 'EXISTING_CUSTOM_CONFIG=keep_me\n' > "$INSTALLED_ENV"

SEARCH_STACK_TEST_MODE=1 INSTALL_ROOT="$FAKE_ROOT" \
  "$ROOT/install.sh" \
  --render-only >/dev/null

assert_contains "$INSTALLED_ENV" "EXISTING_CUSTOM_CONFIG=keep_me"
assert_not_contains "$INSTALLED_ENV" "GROK_SEARCH_MCP_TRANSPORT=http"

printf '=== Step 4: Test update.sh public-endpoint migration ===\n'

assert_file "$ROOT/update.sh"
chmod +x "$ROOT/update.sh"

SEARCH_STACK_TEST_MODE=1 INSTALL_ROOT="$FAKE_ROOT" \
  "$ROOT/update.sh" >/dev/null

assert_contains "$INSTALLED_ENV" "EXISTING_CUSTOM_CONFIG=keep_me"
assert_not_contains "$INSTALLED_ENV" "GROK_SEARCH_MCP_PUBLIC_URL="

SEARCH_STACK_TEST_MODE=1 INSTALL_ROOT="$FAKE_ROOT" \
  "$ROOT/update.sh" --public-mcp-url "$EXPECTED_PUBLIC_MCP_URL" >/dev/null

assert_contains "$INSTALLED_ENV" "GROK_SEARCH_MCP_PUBLIC_URL=$EXPECTED_PUBLIC_MCP_URL"
assert_equals "1" "$(grep -c '^GROK_SEARCH_MCP_PUBLIC_URL=' "$INSTALLED_ENV")"

SEARCH_STACK_TEST_MODE=1 INSTALL_ROOT="$FAKE_ROOT" \
  "$ROOT/update.sh" --public-mcp-url "$EXPECTED_PUBLIC_MCP_URL" >/dev/null

assert_equals "1" "$(grep -c '^GROK_SEARCH_MCP_PUBLIC_URL=' "$INSTALLED_ENV")"

CUSTOM_ENV="$FAKE_ROOT/etc/custom-grok-search-mcp.env"
printf 'GROK_SEARCH_MCP_PUBLIC_URL=https://custom.example/mcp\nKEEP=1\n' > "$CUSTOM_ENV"
SEARCH_STACK_TEST_MODE=1 INSTALL_ROOT="$FAKE_ROOT" \
  ENV_FILE=/etc/custom-grok-search-mcp.env \
  "$ROOT/update.sh" --public-mcp-url "$EXPECTED_PUBLIC_MCP_URL" >/dev/null
assert_contains "$CUSTOM_ENV" "GROK_SEARCH_MCP_PUBLIC_URL=https://custom.example/mcp"
assert_contains "$CUSTOM_ENV" "KEEP=1"
assert_equals "1" "$(grep -c '^GROK_SEARCH_MCP_PUBLIC_URL=' "$CUSTOM_ENV")"

INJECTION_ENV="$FAKE_ROOT/etc/injection-grok-search-mcp.env"
printf 'KEEP=1\n' > "$INJECTION_ENV"
if SEARCH_STACK_TEST_MODE=1 INSTALL_ROOT="$FAKE_ROOT" \
  ENV_FILE=/etc/injection-grok-search-mcp.env \
  "$ROOT/update.sh" --public-mcp-url $'https://search.karldigi.dev/mcp\nEVIL=1' >/dev/null 2>&1; then
  fail "update.sh should reject a public URL containing a newline"
fi
assert_contains "$INJECTION_ENV" "KEEP=1"
assert_not_contains "$INJECTION_ENV" "EVIL=1"

printf 'All tests passed successfully.\n'
