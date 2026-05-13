#!/usr/bin/env bash
set -euo pipefail

# launchd WatchPaths agents start with a minimal PATH that excludes Homebrew.
# Prepend both Apple Silicon (/opt/homebrew) and Intel (/usr/local) locations
# so mise and mix are reachable regardless of which Homebrew prefix is in use.
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "[deploy] rebuilding escripts from $REPO_ROOT"

cd "$REPO_ROOT/elixir"
mise exec -- mix escript.build
echo "[deploy] elixir/bin/symphony built"

cd "$REPO_ROOT/wrapper"
mise exec -- mix escript.build
echo "[deploy] wrapper/bin/smithy built"

# Bounce the running daemon. -k kills any existing instance before restart,
# making the operation safe to re-run at any time.
launchctl kickstart -k "gui/$UID/com.shawnpetros.smithy.smithy"
echo "[deploy] daemon bounced"
