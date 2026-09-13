#!/usr/bin/env bash
# xenOS shared build environment.
#
# SINGLE SOURCE OF TRUTH for the project-local, user-agnostic toolchain.
# Every build / run / test / cross-build script sources THIS file instead of
# hardcoding a developer's home directory. Nothing here depends on who the user
# is or where their checkout lives; all generated state lives under a
# project-local `.toolchain/` root that `scripts/bootstrap.sh` provisions.
#
#   . scripts/xenos_env.sh          # in a script (preserves set -euo pipefail)
#   source scripts/xenos_env.sh     # interactively
#
# Override any derived path with the matching XENOS_* env var before running.

# Resolve the repo root from this file's location (robust to `cd` + symlinks).
_XENOS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
if [ -n "${ROOT:-}" ] && [ "$ROOT" != "$_XENOS_ROOT" ]; then
    : # a caller set ROOT itself; trust it (e.g. a test harness)
else
    ROOT="$_XENOS_ROOT"
fi
export ROOT

# ---------------------------------------------------------------------------
# Project-local toolchain root. Same layout for every user. The default lives
# inside the checkout (gitignored); set XENOS_TOOLCHAIN to share a toolchain
# across checkouts (e.g. /opt/xenos-toolchain) if you prefer.
# ---------------------------------------------------------------------------
XENOS_TOOLCHAIN="${XENOS_TOOLCHAIN:-$ROOT/.toolchain}"
XENOS_CROSSROOT="${XENOS_CROSSROOT:-$XENOS_TOOLCHAIN/sysroot}"   # was CROSSROOT / $SYS
XENOS_SRC="${XENOS_SRC:-$XENOS_TOOLCHAIN/src}"                    # was $SRC
XENOS_INC="${XENOS_INC:-$XENOS_TOOLCHAIN/linuxinc}"               # was $INC
XENOS_ROOTFS="${XENOS_ROOTFS:-$XENOS_TOOLCHAIN/rootfs-libs}"      # was $ROOTFS
XENOS_HOSTPKG="${XENOS_HOSTPKG:-$XENOS_TOOLCHAIN/hostpkg}"        # was $HOSTPKG
XENOS_BIN="$XENOS_TOOLCHAIN/bin"                                  # project-bin (c3c, patchelf...)
XENOS_XKB="${XENOS_XKB:-$XENOS_CROSSROOT/share/X11/xkb}"          # baked libxkbcommon config root

# Back-compat aliases the existing recipes already reference. Keeping these means
# the cross-build scripts and build.sh work unchanged once they source this file.
export SYS="$XENOS_CROSSROOT"
export SRC="$XENOS_SRC"
export INC="$XENOS_INC"
export ROOTFS="$XENOS_ROOTFS"
export HOSTPKG="$XENOS_HOSTPKG"
export CROSSROOT="$XENOS_CROSSROOT"
export XKB="$XENOS_XKB"

# Prepend the project-local bin dir (c3c, patchelf, ...) to PATH, but never let
# an empty value (which would insert "." / cwd) pollute the path.
if [ -n "$XENOS_BIN" ]; then
    export PATH="$XENOS_BIN:$PATH"
fi

# Ensure all toolchain directories exist.
mkdir -p "$XENOS_TOOLCHAIN" "$XENOS_CROSSROOT" "$XENOS_SRC" \
         "$XENOS_INC" "$XENOS_ROOTFS" "$XENOS_HOSTPKG" "$XENOS_BIN"

# ---------------------------------------------------------------------------
# Host-tool detection: `xenos_have <cmd>` writes HOST_PATH and returns 0/1.
# xenos_require <cmd>?<package-hint>... aborts with an actionable message.
# ---------------------------------------------------------------------------
xenos_have() { HOST_PATH="$(command -v "$1" 2>/dev/null)"; [ -n "$HOST_PATH" ]; }

xenos_require() {
    local need=$1; shift
    if ! xenos_have "$need"; then
        echo "error: required host tool not found: $need" >&2
        echo "       install it, or run:  ./scripts/bootstrap.sh  (auto-installs missing tools)" >&2
        [ $# -gt 0 ] && echo "       package hint: $*" >&2
        exit 127
    fi
}

xenos_require_c3() {
    if ! xenos_have c3c && [ ! -x "$XENOS_BIN/c3c" ]; then
        echo "error: the C3 compiler is not installed." >&2
        echo "       install it, or run:  ./scripts/bootstrap.sh" >&2
        exit 127
    fi
    # prefer the project-local c3c if present, else the one already on PATH
    if [ -x "$XENOS_BIN/c3c" ]; then HOST_PATH="$XENOS_BIN/c3c"; else HOST_PATH="$(command -v c3c)"; fi
}