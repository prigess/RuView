#!/usr/bin/env bash
# Deploy sensing-server to Orange Pi (or any aarch64 Linux target)
# Usage: ./deploy-sensing-server.sh [target_host] [target_user]
#
# Prerequisites:
# - Rust toolchain with aarch64-unknown-linux-gnu target
# - cross (cargo install cross)
# - Docker running (cross uses Docker)
# - SSH access to target

set -euo pipefail

TARGET_HOST="${1:-192.168.7.205}"
TARGET_USER="${2:-root}"
TARGET_SSH="${TARGET_USER}@${TARGET_HOST}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
V2_DIR="${REPO_ROOT}/v2"
CRATE="wifi-densepose-sensing-server"
BIN_NAME="sensing-server"
TARGET_TRIPLE="aarch64-unknown-linux-gnu"

echo "=== RuView Sensing Server Deployment ==="
echo "Target: ${TARGET_SSH}"
echo ""

# Check prerequisites
command -v cross >/dev/null 2>&1 || { echo "Error: cross not installed. Run: cargo install cross --git https://github.com/cross-rs/cross"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "Error: Docker not installed or not in PATH"; exit 1; }
docker info >/dev/null 2>&1 || { echo "Error: Docker daemon not running"; exit 1; }

# Build
echo "[1/4] Cross-compiling for ${TARGET_TRIPLE}..."
cd "${V2_DIR}"
cross build --release --target "${TARGET_TRIPLE}" -p "${CRATE}"

BINARY="${V2_DIR}/target/${TARGET_TRIPLE}/release/${BIN_NAME}"
if [ ! -f "$BINARY" ]; then
    echo "Error: Binary not found at $BINARY"
    exit 1
fi
echo "Built: $BINARY ($(du -h "$BINARY" | cut -f1))"

# Copy
echo ""
echo "[2/4] Copying binary to ${TARGET_SSH}..."
scp "$BINARY" "${TARGET_SSH}:/tmp/${BIN_NAME}.new"

# Deploy
echo ""
echo "[3/4] Stopping service and swapping binary..."
ssh "${TARGET_SSH}" bash -s <<'DEPLOY_SCRIPT'
set -e
systemctl stop ruview-sensing || true
DEST=/root/RuView/v2/target/release/sensing-server
if [ -f "$DEST" ]; then
    mv "$DEST" "${DEST}.old"
fi
mv /tmp/sensing-server.new "$DEST"
chmod +x "$DEST"
DEPLOY_SCRIPT

# Restart
echo ""
echo "[4/4] Starting service..."
ssh "${TARGET_SSH}" "systemctl start ruview-sensing && sleep 2 && systemctl status ruview-sensing --no-pager"

echo ""
echo "=== Deployment complete ==="
echo "Test: curl -s http://${TARGET_HOST}:3022/api/v1/sensing/latest | jq .classification"
