#!/bin/bash
# Run the imageglass-mcp server.
# Self-relative: works on any machine regardless of where the repo is cloned.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PKG_DIR="$PROJECT_DIR/code"

# Build if the binary doesn't exist yet.
if [ ! -f "$PKG_DIR/.build/debug/imageglass-mcp" ]; then
    echo "imageglass-mcp: binary not found — building..." >&2
    cd "$PKG_DIR"
    swift build --product imageglass-mcp >&2
fi

exec "$PKG_DIR/.build/debug/imageglass-mcp"
