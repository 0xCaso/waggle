#!/usr/bin/env bash
# Resolves the Sparkle command-line tools (sign_update, generate_appcast,
# generate_keys). They ship inside the same Sparkle-for-Swift-Package-Manager
# zip that `swift build` fetches, so after a build they live under
# .build/artifacts/sparkle/Sparkle/bin. SPARKLE_BIN_DIR overrides that location.
set -euo pipefail

# Prints the directory holding the Sparkle tools, or fails.
sparkle_bin_dir() {
    if [ -n "${SPARKLE_BIN_DIR:-}" ]; then
        echo "$SPARKLE_BIN_DIR"
        return 0
    fi
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    local built="$root/apps/macos/.build/artifacts/sparkle/Sparkle/bin"
    if [ -d "$built" ]; then
        echo "$built"
        return 0
    fi
    return 1
}

# Prints the path to one Sparkle tool, or fails with a clear message.
sparkle_tool() {
    local name="$1"
    local dir
    if ! dir="$(sparkle_bin_dir)"; then
        echo "error: Sparkle tools not found." >&2
        echo "Run 'swift build' in apps/macos first, or set SPARKLE_BIN_DIR." >&2
        return 1
    fi
    local tool="$dir/$name"
    if [ ! -x "$tool" ]; then
        echo "error: $name not found under $dir" >&2
        return 1
    fi
    echo "$tool"
}
