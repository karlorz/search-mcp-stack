#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="${INSTALL_ROOT:-}"
TEST_MODE="${SEARCH_STACK_TEST_MODE:-0}"
GROKSEARCH_DIR="${GROKSEARCH_DIR:-/opt/GrokSearch}"
ENV_FILE="${ENV_FILE:-/etc/grok-search-mcp.env}"
SERVICE_NAME="grok-search-mcp"
PUBLIC_MCP_URL="${GROK_SEARCH_MCP_PUBLIC_URL:-}"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --public-mcp-url)
      if [[ $# -lt 2 ]]; then
        printf 'Error: --public-mcp-url requires a value\n' >&2
        exit 1
      fi
      PUBLIC_MCP_URL="$2"
      shift 2
      ;;
    -h|--help)
      cat <<EOF
Usage: $0 [options]

Options:
  --dry-run                 Show actions without executing state-changing commands
  --public-mcp-url URL      Add the deployment's public MCP URL when absent
  -h, --help                Show this message
EOF
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      exit 1
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
  if [[ "$TEST_MODE" == "1" || "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    printf 'Error: update.sh must be run as root or via sudo\n' >&2
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

validate_public_mcp_url() {
  if [[ -z "$PUBLIC_MCP_URL" ]]; then
    return 0
  fi
  if [[ ! "$PUBLIC_MCP_URL" =~ ^https?://[^/?#[:space:]@]+(/[^?#[:space:]]*)?$ ]]; then
    printf 'Error: --public-mcp-url must be an absolute HTTP(S) URL without credentials, query, fragment, or whitespace\n' >&2
    exit 1
  fi
}

migrate_public_mcp_url() {
  if [[ ! -f "$T_ENV" ]] || [[ -z "$PUBLIC_MCP_URL" ]] \
    || grep -q '^GROK_SEARCH_MCP_PUBLIC_URL=' "$T_ENV"; then
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log "Would add GROK_SEARCH_MCP_PUBLIC_URL=$PUBLIC_MCP_URL to $T_ENV"
    return 0
  fi

  local temporary_env
  temporary_env="$(mktemp "${T_ENV}.tmp.XXXXXX")"
  cp -p "$T_ENV" "$temporary_env"
  printf '\nGROK_SEARCH_MCP_PUBLIC_URL=%s\n' "$PUBLIC_MCP_URL" >> "$temporary_env"
  mv "$temporary_env" "$T_ENV"
  log "Added the public MCP endpoint to $T_ENV"
}

T_GROKSEARCH_DIR="$(target_path "$GROKSEARCH_DIR")"
T_ENV="$(target_path "$ENV_FILE")"
validate_public_mcp_url

log "Updating GrokSearch at $T_GROKSEARCH_DIR to SHA $GROKSEARCH_SHA"

if [[ "$TEST_MODE" == "1" || "$DRY_RUN" == "1" ]]; then
  migrate_public_mcp_url
  log "Test/dry-run update complete."
  exit 0
fi

if [[ ! -d "$T_GROKSEARCH_DIR/.git" ]]; then
  printf 'Error: GrokSearch checkout not found at %s\n' "$T_GROKSEARCH_DIR" >&2
  exit 1
fi

(
  cd "$T_GROKSEARCH_DIR"
  git fetch origin "$GROKSEARCH_REF" || git fetch origin
  git checkout "$GROKSEARCH_SHA"
)

python_dir="$(target_path /opt/uv-python)"
cache_dir="$(target_path /opt/GrokSearch/.cache)"
mkdir -p "$python_dir" "$cache_dir"
chown -R groksearch:groksearch "$T_GROKSEARCH_DIR" "$python_dir" "$cache_dir"

uv_bin=/usr/local/libexec/uv
if [[ ! -x "$uv_bin" ]]; then
  printf 'Error: required uv runtime is missing at %s; run install.sh to provision it\n' "$uv_bin" >&2
  exit 1
fi
sudo -u groksearch env \
  UV_PYTHON_INSTALL_DIR="$python_dir" \
  UV_CACHE_DIR="$cache_dir" \
  "$uv_bin" --directory "$T_GROKSEARCH_DIR" sync --frozen

migrate_public_mcp_url

if command -v systemctl >/dev/null 2>&1; then
  log "Restarting $SERVICE_NAME service..."
  run_cmd systemctl restart "$SERVICE_NAME"
fi

log "Update complete to SHA $GROKSEARCH_SHA"
