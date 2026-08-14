#!/usr/bin/env bash
# Build the ruview-sensing Debian package.
#
# By default this runs everything on the Orange Pi over SSH (native build),
# then SCPs the resulting .deb back to dist/. Pass --local to build on the
# current machine instead (only works on a Debian-family Linux box with
# dpkg-deb installed and a working aarch64 toolchain).
#
# Usage:
#   ./scripts/build-deb.sh                            # SSH to default 192.168.7.205
#   ./scripts/build-deb.sh --host 192.168.7.210
#   ./scripts/build-deb.sh --host pi.local --user pi
#   ./scripts/build-deb.sh --local                    # build here, output to dist/
#   ./scripts/build-deb.sh --skip-build               # reuse existing binary
#   ./scripts/build-deb.sh --version 0.3.1            # override version
#
# Output: dist/ruview-sensing_<version>-1_arm64.deb

set -euo pipefail

# ── argument parsing ─────────────────────────────────────────────────────────
HOST="192.168.7.205"
USER_NAME="root"
LOCAL=0
SKIP_BUILD=0
VERSION_OVERRIDE=""
DEB_REVISION="1"

while [ $# -gt 0 ]; do
    case "$1" in
        --host)        HOST="$2" ; shift 2 ;;
        --user)        USER_NAME="$2" ; shift 2 ;;
        --local)       LOCAL=1 ; shift ;;
        --skip-build)  SKIP_BUILD=1 ; shift ;;
        --version)     VERSION_OVERRIDE="$2" ; shift 2 ;;
        --help|-h)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2 ; exit 1 ;;
    esac
done

# ── paths + version ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PKG_DIR="${REPO_ROOT}/packaging/debian"
V2_DIR="${REPO_ROOT}/v2"
UI_DIR="${REPO_ROOT}/ui"
DIST_DIR="${REPO_ROOT}/dist"
mkdir -p "$DIST_DIR"

if [ -n "$VERSION_OVERRIDE" ]; then
    VERSION="$VERSION_OVERRIDE"
else
    VERSION=$(awk -F'"' '/^version = "/ { print $2; exit }' "${V2_DIR}/Cargo.toml")
    [ -n "$VERSION" ] || { echo "Could not derive version from v2/Cargo.toml" >&2 ; exit 1 ; }
fi

DEB_VERSION="${VERSION}-${DEB_REVISION}"
DEB_NAME="ruview-sensing_${DEB_VERSION}_arm64.deb"

echo "=== ruview-sensing Debian package build ==="
echo "Mode    : $([ $LOCAL -eq 1 ] && echo local || echo "remote (${USER_NAME}@${HOST})")"
echo "Version : ${DEB_VERSION}"
echo "Output  : dist/${DEB_NAME}"
echo ""

# ── helpers ──────────────────────────────────────────────────────────────────
stage_tree() {
    local stage="$1"
    local binary="$2"
    local version="$3"

    rm -rf "$stage"
    install -d \
        "$stage/DEBIAN" \
        "$stage/usr/bin" \
        "$stage/usr/lib/ruview" \
        "$stage/usr/share/ruview/ui" \
        "$stage/usr/share/doc/ruview-sensing" \
        "$stage/usr/src/ruview" \
        "$stage/lib/systemd/system" \
        "$stage/etc/ruview" \
        "$stage/var/lib/ruview" \
        "$stage/var/log/ruview"

    # Binary
    install -m 0755 "$binary" "$stage/usr/bin/sensing-server"

    # Helper scripts
    install -m 0755 "$PKG_DIR/init-npu.sh"          "$stage/usr/lib/ruview/init-npu.sh"
    install -m 0755 "$PKG_DIR/rebuild.sh"           "$stage/usr/lib/ruview/rebuild.sh"
    install -m 0755 "$REPO_ROOT/scripts/setup-npu-orangepi.sh" \
                                                     "$stage/usr/lib/ruview/setup-npu-orangepi.sh"

    # systemd unit + default config
    install -m 0644 "$PKG_DIR/ruview-sensing.service" \
                                                     "$stage/lib/systemd/system/ruview-sensing.service"
    install -m 0644 "$PKG_DIR/sensing.conf"          "$stage/etc/ruview/sensing.conf"

    # UI assets
    cp -a "$UI_DIR/." "$stage/usr/share/ruview/ui/"

    # Bundled source (rebuild on-device). Exclude target/, git, IDE noise.
    rsync -a --delete \
        --exclude='target/' \
        --exclude='.git/' \
        --exclude='*.rs.bk' \
        --exclude='.DS_Store' \
        "$V2_DIR/" "$stage/usr/src/ruview/v2/"

    # Docs
    install -m 0644 "$PKG_DIR/README.Debian" "$stage/usr/share/doc/ruview-sensing/README.Debian"
    install -m 0644 "$PKG_DIR/copyright"     "$stage/usr/share/doc/ruview-sensing/copyright"
    # changelog (single-entry; release pipeline can amend later)
    {
        printf "ruview-sensing (%s) unstable; urgency=medium\n\n" "$version"
        printf "  * Build of upstream %s.\n\n" "$version"
        printf " -- RuView Team <maintainers@ruview.local>  %s\n" "$(date -R)"
    } > "$stage/usr/share/doc/ruview-sensing/changelog.Debian"
    gzip -9n "$stage/usr/share/doc/ruview-sensing/changelog.Debian"

    # DEBIAN control files
    local installed_kb
    installed_kb=$(du -sk --exclude=DEBIAN "$stage" | cut -f1)
    sed -e "s/@VERSION@/${version}/g" \
        -e "s/@INSTALLED_SIZE@/${installed_kb}/g" \
        "$PKG_DIR/control.in" > "$stage/DEBIAN/control"

    install -m 0644 "$PKG_DIR/conffiles" "$stage/DEBIAN/conffiles"
    install -m 0755 "$PKG_DIR/postinst"  "$stage/DEBIAN/postinst"
    install -m 0755 "$PKG_DIR/prerm"     "$stage/DEBIAN/prerm"
    install -m 0755 "$PKG_DIR/postrm"    "$stage/DEBIAN/postrm"
}

# ── local mode ───────────────────────────────────────────────────────────────
if [ $LOCAL -eq 1 ]; then
    command -v dpkg-deb >/dev/null || { echo "dpkg-deb not found; --local needs Debian/Ubuntu." >&2 ; exit 1 ; }
    command -v rsync    >/dev/null || { echo "rsync not found." >&2 ; exit 1 ; }

    BINARY="${V2_DIR}/target/release/sensing-server"
    if [ $SKIP_BUILD -eq 0 ]; then
        echo "[local] cargo build --release -p wifi-densepose-sensing-server"
        ( cd "$V2_DIR" && cargo build --release -p wifi-densepose-sensing-server )
    fi
    [ -f "$BINARY" ] || { echo "Missing binary: $BINARY" >&2 ; exit 1 ; }

    STAGE="${DIST_DIR}/stage-${DEB_VERSION}"
    stage_tree "$STAGE" "$BINARY" "$VERSION"

    echo "[local] dpkg-deb --build (xz, level 6)..."
    dpkg-deb -Zxz -z6 --root-owner-group --build "$STAGE" "${DIST_DIR}/${DEB_NAME}"
    rm -rf "$STAGE"
    echo ""
    echo "✓ Built: ${DIST_DIR}/${DEB_NAME}  ($(du -h "${DIST_DIR}/${DEB_NAME}" | cut -f1))"
    exit 0
fi

# ── remote mode (build on the Pi) ────────────────────────────────────────────
SSH_TARGET="${USER_NAME}@${HOST}"
REMOTE_WORK="/tmp/ruview-deb-build"

echo "[remote] verifying ssh access..."
ssh -o BatchMode=yes -o ConnectTimeout=5 "$SSH_TARGET" 'echo ok && uname -m && dpkg --version | head -1' \
    || { echo "Cannot reach $SSH_TARGET" >&2 ; exit 1 ; }

echo "[remote] rsyncing source to $SSH_TARGET:$REMOTE_WORK ..."
ssh "$SSH_TARGET" "mkdir -p $REMOTE_WORK"
rsync -az --delete \
    --exclude='target/' \
    --exclude='.git/' \
    --exclude='dist/' \
    --exclude='node_modules/' \
    --exclude='.DS_Store' \
    "$REPO_ROOT/" "$SSH_TARGET:$REMOTE_WORK/"

echo "[remote] building binary + packaging on Pi (this takes a while)..."
ssh "$SSH_TARGET" \
    REMOTE_WORK="$REMOTE_WORK" \
    VERSION="$VERSION" \
    DEB_VERSION="$DEB_VERSION" \
    DEB_NAME="$DEB_NAME" \
    SKIP_BUILD="$SKIP_BUILD" \
    bash -s <<'REMOTE'
set -euo pipefail
cd "$REMOTE_WORK"

# Ensure cargo is available
if ! command -v cargo >/dev/null 2>&1 ; then
    if [ -x "$HOME/.cargo/bin/cargo" ]; then export PATH="$HOME/.cargo/bin:$PATH" ; fi
fi
if ! command -v cargo >/dev/null 2>&1 ; then
    echo "Installing Rust toolchain on Pi..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
    export PATH="$HOME/.cargo/bin:$PATH"
fi

if [ "$SKIP_BUILD" = "0" ]; then
    echo "[pi] cargo build --release -p wifi-densepose-sensing-server"
    ( cd v2 && cargo build --release -p wifi-densepose-sensing-server )
fi
BINARY="v2/target/release/sensing-server"
[ -f "$BINARY" ] || { echo "Missing binary: $BINARY" ; exit 1 ; }

# Re-run the stage_tree function inline (kept here so the remote is self-contained)
STAGE="${REMOTE_WORK}/stage-${DEB_VERSION}"
rm -rf "$STAGE"
install -d \
    "$STAGE/DEBIAN" \
    "$STAGE/usr/bin" \
    "$STAGE/usr/lib/ruview" \
    "$STAGE/usr/share/ruview/ui" \
    "$STAGE/usr/share/doc/ruview-sensing" \
    "$STAGE/usr/src/ruview" \
    "$STAGE/lib/systemd/system" \
    "$STAGE/etc/ruview" \
    "$STAGE/var/lib/ruview" \
    "$STAGE/var/log/ruview"

install -m 0755 "$BINARY" "$STAGE/usr/bin/sensing-server"

install -m 0755 packaging/debian/init-npu.sh           "$STAGE/usr/lib/ruview/init-npu.sh"
install -m 0755 packaging/debian/rebuild.sh            "$STAGE/usr/lib/ruview/rebuild.sh"
install -m 0755 scripts/setup-npu-orangepi.sh          "$STAGE/usr/lib/ruview/setup-npu-orangepi.sh"
install -m 0644 packaging/debian/ruview-sensing.service "$STAGE/lib/systemd/system/ruview-sensing.service"
install -m 0644 packaging/debian/sensing.conf           "$STAGE/etc/ruview/sensing.conf"

cp -a ui/. "$STAGE/usr/share/ruview/ui/"

rsync -a --delete \
    --exclude='target/' \
    --exclude='.git/' \
    --exclude='*.rs.bk' \
    --exclude='.DS_Store' \
    v2/ "$STAGE/usr/src/ruview/v2/"

install -m 0644 packaging/debian/README.Debian "$STAGE/usr/share/doc/ruview-sensing/README.Debian"
install -m 0644 packaging/debian/copyright     "$STAGE/usr/share/doc/ruview-sensing/copyright"
{
    printf "ruview-sensing (%s) unstable; urgency=medium\n\n" "$VERSION"
    printf "  * Build of upstream %s.\n\n" "$VERSION"
    printf " -- RuView Team <maintainers@ruview.local>  %s\n" "$(date -R)"
} > "$STAGE/usr/share/doc/ruview-sensing/changelog.Debian"
gzip -9n "$STAGE/usr/share/doc/ruview-sensing/changelog.Debian"

INSTALLED_KB=$(du -sk --exclude=DEBIAN "$STAGE" | cut -f1)
sed -e "s/@VERSION@/${VERSION}/g" \
    -e "s/@INSTALLED_SIZE@/${INSTALLED_KB}/g" \
    packaging/debian/control.in > "$STAGE/DEBIAN/control"

install -m 0644 packaging/debian/conffiles "$STAGE/DEBIAN/conffiles"
install -m 0755 packaging/debian/postinst  "$STAGE/DEBIAN/postinst"
install -m 0755 packaging/debian/prerm     "$STAGE/DEBIAN/prerm"
install -m 0755 packaging/debian/postrm    "$STAGE/DEBIAN/postrm"

echo "[pi] dpkg-deb --build ..."
dpkg-deb -Zxz -z6 --root-owner-group --build "$STAGE" "${REMOTE_WORK}/${DEB_NAME}"
rm -rf "$STAGE"
ls -lh "${REMOTE_WORK}/${DEB_NAME}"
REMOTE

echo "[remote] copying .deb back..."
scp "$SSH_TARGET:${REMOTE_WORK}/${DEB_NAME}" "${DIST_DIR}/${DEB_NAME}"

echo ""
echo "✓ Built: ${DIST_DIR}/${DEB_NAME}  ($(du -h "${DIST_DIR}/${DEB_NAME}" | cut -f1))"
echo ""
echo "Install on a fresh Pi:"
echo "  scp ${DIST_DIR}/${DEB_NAME} ${SSH_TARGET}:/tmp/"
echo "  ssh ${SSH_TARGET} 'sudo dpkg -i /tmp/${DEB_NAME}; sudo apt-get install -f -y'"
