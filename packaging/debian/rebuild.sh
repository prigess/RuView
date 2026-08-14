#!/bin/bash
# Rebuild sensing-server from the bundled source. POC self-contained workflow:
# the .deb ships the full v2/ Rust workspace under /usr/src/ruview/v2.
#
# Usage:
#   sudo /usr/lib/ruview/rebuild.sh           # build + install + restart
#   sudo /usr/lib/ruview/rebuild.sh --no-restart
#   sudo /usr/lib/ruview/rebuild.sh --debug   # debug build instead of release
#
# Requires: a Rust toolchain (cargo + rustc). If missing, this script will
# offer to install rustup non-interactively.
set -euo pipefail

SRC_DIR="/usr/src/ruview/v2"
CRATE="wifi-densepose-sensing-server"
BIN_NAME="sensing-server"
INSTALL_PATH="/usr/bin/${BIN_NAME}"
PROFILE="release"
DO_RESTART=1

for arg in "$@" ; do
    case "$arg" in
        --no-restart) DO_RESTART=0 ;;
        --debug)      PROFILE="debug" ;;
        --help|-h)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown argument: $arg" >&2 ; exit 1 ;;
    esac
done

if [ "$(id -u)" != "0" ]; then
    echo "rebuild.sh must run as root (sudo)." >&2
    exit 1
fi

if [ ! -d "$SRC_DIR" ]; then
    echo "ERROR: source not found at $SRC_DIR" >&2
    echo "Reinstall the ruview-sensing package to restore sources." >&2
    exit 1
fi

# Make sure cargo is available; offer to install if not.
if ! command -v cargo >/dev/null 2>&1 ; then
    # Try the standard rustup location too.
    if [ -x "$HOME/.cargo/bin/cargo" ]; then
        export PATH="$HOME/.cargo/bin:$PATH"
    fi
fi
if ! command -v cargo >/dev/null 2>&1 ; then
    cat <<'EOF'
Rust toolchain not found. The bundled source needs cargo to rebuild.

Install with:
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
    source "$HOME/.cargo/env"

Then re-run this script.
EOF
    exit 2
fi

echo "[rebuild] cargo: $(command -v cargo)"
echo "[rebuild] profile: $PROFILE"
echo "[rebuild] source : $SRC_DIR"

cd "$SRC_DIR"
if [ "$PROFILE" = "release" ]; then
    cargo build --release -p "$CRATE"
    BUILT="$SRC_DIR/target/release/$BIN_NAME"
else
    cargo build -p "$CRATE"
    BUILT="$SRC_DIR/target/debug/$BIN_NAME"
fi

if [ ! -f "$BUILT" ]; then
    echo "ERROR: build did not produce $BUILT" >&2
    exit 3
fi

# Atomic-ish install: write next to the target, then mv into place.
install -m 0755 "$BUILT" "${INSTALL_PATH}.new"
mv -f "${INSTALL_PATH}.new" "$INSTALL_PATH"
echo "[rebuild] installed: $INSTALL_PATH ($(stat -c%s "$INSTALL_PATH" 2>/dev/null || stat -f%z "$INSTALL_PATH") bytes)"

if [ "$DO_RESTART" = "1" ] && [ -d /run/systemd/system ]; then
    systemctl restart ruview-sensing.service
    sleep 1
    systemctl status ruview-sensing.service --no-pager --lines=5 || true
else
    echo "[rebuild] skipped restart (use: systemctl restart ruview-sensing)"
fi
