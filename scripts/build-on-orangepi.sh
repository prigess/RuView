#!/usr/bin/env bash
# Build sensing-server natively on the Orange Pi 5 Pro.
#
# Usage:
#   ./scripts/build-on-orangepi.sh [host] [user]
#
# Defaults: host=192.168.7.205, user=root
#
# What it does:
#   1. Installs Rust on the Pi (if missing)
#   2. Rsyncs the v2/ workspace source (no target/ dir)
#   3. Runs cargo build --release -p wifi-densepose-sensing-server
#   4. Restarts the ruview-sensing service with the new binary

set -euo pipefail

TARGET_HOST="${1:-192.168.7.205}"
TARGET_USER="${2:-root}"
SSH="${TARGET_USER}@${TARGET_HOST}"
REMOTE_DIR="/root/RuView"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
V2_DIR="${REPO_ROOT}/v2"

echo "=== RuView Native Build on Orange Pi ==="
echo "Target : ${SSH}"
echo "Source : ${V2_DIR}"
echo ""

# ── 1. Install Rust if missing ────────────────────────────────────────────────
echo "[1/4] Checking Rust installation..."
ssh "${SSH}" bash <<'RUSTCHECK'
if ! command -v cargo &>/dev/null; then
    echo "  Installing Rust via rustup..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y curl gcc 2>/dev/null | grep -E "^(Get|Selecting|Unpacking)" || true
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
    source "$HOME/.cargo/env"
    echo "  Rust installed: $(rustc --version)"
else
    source "$HOME/.cargo/env" 2>/dev/null || true
    echo "  Rust already installed: $(rustc --version)"
fi
RUSTCHECK

echo ""

# ── 2. Sync source ────────────────────────────────────────────────────────────
echo "[2/4] Syncing source to ${SSH}:${REMOTE_DIR}/v2/ ..."
ssh "${SSH}" "mkdir -p ${REMOTE_DIR}/v2"

# Exclude build artifacts and large dirs that don't compile
rsync -az --delete \
    --exclude='target/' \
    --exclude='.git/' \
    --exclude='*.o' \
    --exclude='*.rlib' \
    --filter=':- .gitignore' \
    "${V2_DIR}/" \
    "${SSH}:${REMOTE_DIR}/v2/"

echo "  Sync complete."
echo ""

# ── 3. Build ──────────────────────────────────────────────────────────────────
echo "[3/4] Building on Orange Pi (this takes ~5-10 min first time, ~1 min incremental)..."
ssh "${SSH}" bash <<'BUILD'
set -e
source "$HOME/.cargo/env" 2>/dev/null || source "/root/.cargo/env"
export CARGO_NET_GIT_FETCH_WITH_CLI=true
export CARGO_INCREMENTAL=1

cd /root/RuView/v2
echo "  cargo build --release -p wifi-densepose-sensing-server"
time cargo build --release -p wifi-densepose-sensing-server 2>&1 | \
    grep -E "^(error|warning\[|Compiling|Finished|   Compiling)" | tail -30

echo "  Binary: $(ls -lh target/release/sensing-server 2>/dev/null || echo 'NOT FOUND')"
BUILD

echo ""

# ── 4. Restart service ────────────────────────────────────────────────────────
echo "[4/4] Restarting ruview-sensing..."
ssh "${SSH}" bash <<'RESTART'
set -e
systemctl stop ruview-sensing 2>/dev/null || true
sleep 1
systemctl start ruview-sensing
sleep 2
systemctl status ruview-sensing --no-pager --lines=5
RESTART

echo ""
echo "=== Done ==="
echo "Test: curl -s http://${TARGET_HOST}:3022/api/v1/sensing/latest | python3 -m json.tool | grep estimated_persons"
