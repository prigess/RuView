#!/bin/sh
# Lightweight per-boot NPU check for RuView sensing-server.
# Runs as ExecStartPre — should always exit 0 so the service can start
# even when NPU is unavailable (it falls back to CPU paths).
set -e

DEV=/dev/rknpu0

# RK3588 NPU registers as misc device, major 10, minor varies (often 126).
if [ ! -c "$DEV" ]; then
    # Try common minors. mknod returns non-zero if it can't create — ignore.
    for minor in 126 127 128 ; do
        mknod "$DEV" c 10 "$minor" 2>/dev/null && break || true
    done
fi

# Permissive so service can run without root privileges in future.
[ -e "$DEV" ] && chmod 666 "$DEV" 2>/dev/null || true

# Non-fatal — service runs CPU-only if NPU is unavailable.
exit 0
