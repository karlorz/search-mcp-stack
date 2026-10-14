#!/usr/bin/env bash
# Test the exact gateway pin without checking out or modifying its product source.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="$(sed -n 's/^GUDA_GATEWAY_SHA=//p' "$ROOT/versions.env")"
[[ "$PIN" =~ ^[0-9a-f]{40}$ ]]
GATEWAY_REPO="${GATEWAY_REPO:-$ROOT/gateway}"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
git -C "$GATEWAY_REPO" archive "$PIN" | tar -x -C "$FIXTURE"
# Only the test callback changes: gateway product files stay byte-for-byte pinned.
python3 - "$FIXTURE/internal/mcpoauth/oauth_test.go" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
for old in ('https://example.com/callback', 'https://example.com/cb'):
    assert old in s
    s = s.replace(old, 'https://search.karldigi.dev/auth/cli/callback')
s = s.replace('u.Host != "example.com" || u.Path != "/callback"', 'u.Host != "search.karldigi.dev" || u.Path != "/auth/cli/callback"')
p.write_text(s)
PY
printf 'Testing gateway pin %s with hosted callback and dummy credentials\n' "$PIN"
(cd "$FIXTURE" && go test ./internal/mcpoauth ./internal/server)
