#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="${INSTALL_ROOT:-}"
TEST_MODE="${SEARCH_STACK_TEST_MODE:-0}"

# Defaults
DOMAIN="${DOMAIN:-search.karldigi.dev}"
LISTEN_ADDR="${LISTEN_ADDR:-127.0.0.1:8080}"
GROKSEARCH_DIR="${GROKSEARCH_DIR:-/opt/GrokSearch}"
ENV_FILE="${ENV_FILE:-/etc/grok-search-mcp.env}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/grok-search-mcp.service}"
CADDY_SNIPPET="${CADDY_SNIPPET:-/etc/caddy/Caddyfile.code-guda-gateway}"
USER_NAME="groksearch"

RENDER_ONLY=0
SKIP_CADDY=0
SKIP_PREREQS=0
DRY_RUN=0
SMOKE=0

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --domain DOMAIN           Caddy public domain (default: search.karldigi.dev)
  --listen-addr ADDR        Upstream gateway listen address (default: 127.0.0.1:8080)
  --render-only             Only render configuration and unit files (test / staging)
  --skip-caddy              Do not install or overwrite Caddy snippet
  --skip-prereqs            Do not attempt to install uv or system dependencies
  --dry-run                 Show actions without executing state-changing commands
  --smoke                   Run loopback health check after starting service
  -h, --help                Show this message
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      DOMAIN="$2"
      shift 2
      ;;
    --listen-addr)
      LISTEN_ADDR="$2"
      shift 2
      ;;
    --render-only)
      RENDER_ONLY=1
      shift
      ;;
    --skip-caddy)
      SKIP_CADDY=1
      shift
      ;;
    --skip-prereqs)
      SKIP_PREREQS=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --smoke)
      SMOKE=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage
      ;;
  esac
done

# Load pins
VERSIONS_FILE="$SCRIPT_DIR/versions.env"
if [[ ! -f "$VERSIONS_FILE" ]]; then
  printf 'Error: versions.env not found at %s\n' "$VERSIONS_FILE" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$VERSIONS_FILE"

log() {
  printf '==> %s\n' "$1"
}

run_cmd() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf '[dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

check_root() {
  if [[ "$RENDER_ONLY" == "1" || "$TEST_MODE" == "1" || "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    printf 'Error: install.sh must be run as root or via sudo\n' >&2
    exit 1
  fi
}

check_root

target_path() {
  local p="$1"
  if [[ -n "$INSTALL_ROOT" ]]; then
    printf '%s%s' "$INSTALL_ROOT" "$p"
  else
    printf '%s' "$p"
  fi
}

# 1. Render and install configurations
T_SERVICE="$(target_path "$SERVICE_FILE")"
T_ENV="$(target_path "$ENV_FILE")"
T_CADDY="$(target_path "$CADDY_SNIPPET")"

log "Creating target directories..."
mkdir -p "$(dirname "$T_SERVICE")"
mkdir -p "$(dirname "$T_ENV")"
mkdir -p "$(dirname "$T_CADDY")"

log "Rendering systemd service unit to $T_SERVICE"
cp "$SCRIPT_DIR/systemd/grok-search-mcp.service" "$T_SERVICE"

if [[ ! -f "$T_ENV" ]]; then
  log "Installing initial environment file to $T_ENV"
  cp "$SCRIPT_DIR/systemd/grok-search-mcp.env.example" "$T_ENV"
  chmod 600 "$T_ENV" 2>/dev/null || true
else
  log "Environment file $T_ENV already exists; keeping existing configuration"
fi

if [[ "$SKIP_CADDY" == "0" ]]; then
  log "Rendering Caddy snippet to $T_CADDY"
  sed \
    -e "s|{{DOMAIN}}|$DOMAIN|g" \
    -e "s|{{LISTEN_ADDR}}|$LISTEN_ADDR|g" \
    "$SCRIPT_DIR/caddy/Caddyfile.code-guda-gateway" > "$T_CADDY"
fi

if [[ "$RENDER_ONLY" == "1" || "$TEST_MODE" == "1" ]]; then
  log "Render complete (test/render mode)."
  exit 0
fi

# 2. System prerequisites & user creation
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
  log "Creating service user: $USER_NAME"
  run_cmd useradd --system --no-create-home --shell /usr/sbin/nologin "$USER_NAME" || true
fi

if [[ "$SKIP_PREREQS" == "0" ]]; then
  if ! command -v uv >/dev/null 2>&1; then
    log "Installing uv..."
    if [[ "$DRY_RUN" == "0" ]]; then
      curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="/usr/local/bin" sh
    fi
  fi
fi

# Copy uv to a path groksearch can execute. The official installer often
# leaves /usr/local/bin/uv as a symlink into /root/.local/bin.
if [[ "$DRY_RUN" == "0" && "$RENDER_ONLY" == "0" && "$TEST_MODE" == "0" ]]; then
  uv_src="$(command -v uv || true)"
  if [[ -n "$uv_src" ]]; then
    uv_real="$(readlink -f "$uv_src")"
    log "Installing uv binary to /usr/local/libexec/uv from $uv_real"
    mkdir -p /usr/local/libexec
    install -m 0755 "$uv_real" /usr/local/libexec/uv
  fi
fi

# 3. Clone or update GrokSearch repository
T_GROKSEARCH_DIR="$(target_path "$GROKSEARCH_DIR")"
mkdir -p "$(dirname "$T_GROKSEARCH_DIR")"

if [[ ! -d "$T_GROKSEARCH_DIR/.git" ]]; then
  log "Cloning GrokSearch from $GROKSEARCH_REPO to $T_GROKSEARCH_DIR"
  run_cmd git clone "$GROKSEARCH_REPO" "$T_GROKSEARCH_DIR"
fi

log "Checking out GrokSearch at $GROKSEARCH_SHA"
if [[ "$DRY_RUN" == "0" ]]; then
  (
    cd "$T_GROKSEARCH_DIR"
    git fetch origin "$GROKSEARCH_REF" || git fetch origin
    git checkout "$GROKSEARCH_SHA"
  )
  python_dir="$(target_path /opt/uv-python)"
  cache_dir="$(target_path /opt/GrokSearch/.cache)"
  mkdir -p "$python_dir" "$cache_dir"
  chown -R "$USER_NAME:$USER_NAME" "$T_GROKSEARCH_DIR" "$python_dir" "$cache_dir"
  uv_bin=/usr/local/libexec/uv
  [[ -x "$uv_bin" ]] || uv_bin="$(command -v uv)"
  log "Syncing venv as $USER_NAME with UV_PYTHON_INSTALL_DIR=$python_dir"
  run_cmd sudo -u "$USER_NAME" env \
    UV_PYTHON_INSTALL_DIR="$python_dir" \
    UV_CACHE_DIR="$cache_dir" \
    "$uv_bin" --directory "$T_GROKSEARCH_DIR" sync --frozen
fi

# 4. Service activation
if command -v systemctl >/dev/null 2>&1; then
  log "Reloading systemd and enabling grok-search-mcp service..."
  run_cmd systemctl daemon-reload
  run_cmd systemctl enable grok-search-mcp.service
  run_cmd systemctl restart grok-search-mcp.service
fi

if [[ "$SMOKE" == "1" ]]; then
  log "Running smoke check against loopback port 8800..."
  if [[ "$DRY_RUN" == "0" ]]; then
    sleep 2
    curl -sS -I "http://127.0.0.1:8800/mcp" || {
      printf 'Warning: Smoke check on http://127.0.0.1:8800/mcp did not return HTTP success\n' >&2
    }
  fi
fi

log "Installation complete!"
printf "\nNext steps:\n"
printf "1. Edit %s to set GROK_SEARCH_MCP_INTERNAL_TOKEN and GUDA_API_KEY\n" "$ENV_FILE"
printf "2. Restart the service: sudo systemctl restart grok-search-mcp\n"
printf "3. Verify status: sudo systemctl status grok-search-mcp\n\n"
