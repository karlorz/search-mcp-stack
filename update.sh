#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_ROOT="${INSTALL_ROOT:-}"
TEST_MODE="${SEARCH_STACK_TEST_MODE:-0}"
GROKSEARCH_DIR="${GROKSEARCH_DIR:-/opt/GrokSearch}"
SERVICE_NAME="grok-search-mcp"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      cat <<EOF
Usage: $0 [options]

Options:
  --dry-run                 Show actions without executing state-changing commands
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

T_GROKSEARCH_DIR="$(target_path "$GROKSEARCH_DIR")"

log "Updating GrokSearch at $T_GROKSEARCH_DIR to SHA $GROKSEARCH_SHA"

if [[ "$TEST_MODE" == "1" || "$DRY_RUN" == "1" ]]; then
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
  uv sync --frozen
  chown -R groksearch:groksearch "$T_GROKSEARCH_DIR"
)

if command -v systemctl >/dev/null 2>&1; then
  log "Restarting $SERVICE_NAME service..."
  run_cmd systemctl restart "$SERVICE_NAME"
fi

log "Update complete to SHA $GROKSEARCH_SHA"
