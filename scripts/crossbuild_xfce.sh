#!/usr/bin/env bash
# Cross-build the Xfce 4.18 desktop against the xenOS shared-musl sysroot.
#
# Run F.1 (crossbuild_xwayland.sh) and crossbuild_shared.sh first.  The build
# is deliberately split so a failed package can be retried without rebuilding
# the entire desktop:
#   scripts/crossbuild_xfce.sh [all|base|deps|apps|stage]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SYS="${SYS:-/home/timo/crossmusl/sysroot}"
SRC="${SRC:-/home/timo/crossmusl/src}"
ROOTFS="${ROOTFS:-/home/timo/crossmusl/rootfs-libs}"
INC="${INC:-/home/timo/crossmusl/linuxinc}"
JOBS="${JOBS:-4}"
PKG="${1:-all}"
readonly XFE=(--host=x86_64-linux-musl "--prefix=$SYS" --enable-shared --disable-static)

mkdir -p "$ROOTFS/usr/lib" "$ROOTFS/usr/bin"

require_tree() {
  for dir in "$SYS" "$SRC" "$INC"; do
    [ -d "$dir" ] || { echo "missing required directory: $dir" >&2; exit 1; }
  done
}

configure_env() {
  export CC=musl-gcc
  export CFLAGS="-O2 -mstackrealign"
  export CPPFLAGS="-I$INC -I$SYS/include"
  export LDFLAGS="-L$SYS/lib -Wl,-rpath-link,$SYS/lib"
  export PKG_CONFIG_LIBDIR="$SYS/lib/pkgconfig"
  export PKG_CONFIG=/usr/bin/pkg-config
  # Cross-built GLib generators are required by xfconf.  Keeping this in PATH
  # avoids modifying /usr/bin (and makes the recipe usable without sudo).
  export PATH="$SYS/bin:$PATH"
}

act() { # <name> <source-dir> <build-dir> <configure args...>
  local name="$1" dir="$2" build_dir="$3"
  shift 3
  [ -d "$SRC/$dir" ] || { echo "missing source: $SRC/$dir" >&2; return 1; }
  echo "=== [$name] ==="
  (
    cd "$SRC/$dir"
    rm -rf "$build_dir"
    mkdir "$build_dir"
    cd "$build_dir"
    configure_env
    ../configure "${XFE[@]}" "$@" >"/tmp/${name}_cfg.log" 2>&1 \
      || { echo "CFG_FAIL $name"; tail -25 "/tmp/${name}_cfg.log"; return 1; }
    make -j"$JOBS" >"/tmp/${name}_make.log" 2>&1 \
      || { echo "MAKE_FAIL $name"; tail -30 "/tmp/${name}_make.log"; return 1; }
    make install >"/tmp/${name}_inst.log" 2>&1 \
      || { echo "INSTALL_FAIL $name"; tail -25 "/tmp/${name}_inst.log"; return 1; }
  )
  echo "=== [$name] OK ==="
}

require_tree

if [[ "$PKG" == all || "$PKG" == base ]]; then
  act libxfce4util libxfce4util-4.18.2 build-musl --with-vala=no
  GDBUS_CODEGEN="$SYS/bin/gdbus-codegen" act xfconf xfconf-4.18.3 build-musl
  # Xfce is run through Xwayland, so this must not be a Wayland-only build.
  act libxfce4ui libxfce4ui-4.18.6 build-musl --enable-x11=yes
  act exo exo-4.18.0 build-musl --enable-debug=no
  act garcon garcon-4.18.2 build-musl --enable-debug=no
fi

if [[ "$PKG" == all || "$PKG" == deps ]]; then
  act libSM libSM-1.2.4 build-musl
  act libICE libICE-1.1.1 build-musl
fi

if [[ "$PKG" == all || "$PKG" == apps ]]; then
  act xfce4-panel xfce4-panel-4.18.6 build-musl
  act xfce4-session xfce4-session-4.18.4 build-musl
  act xfce4-settings xfce4-settings-4.18.6 build-musl
  act xfdesktop xfdesktop-4.18.1 build-musl
fi

if [[ "$PKG" == all || "$PKG" == stage ]]; then
  SYS="$SYS" ROOTFS="$ROOTFS" "$ROOT/scripts/stage_xfce_rootfs.sh"
fi

echo
echo "==== Xfce cross-build done ===="
for binary in xfce4-panel xfdesktop xfce4-session xfsettingsd xfconf-query; do
  [ -x "$SYS/bin/$binary" ] && printf '%s\n' "$SYS/bin/$binary"
done
