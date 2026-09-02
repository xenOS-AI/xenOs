#!/usr/bin/env bash
# xenOS Phase F.2: cross-build the Xfce 4.18 desktop components to shared musl
# against the crossmusl sysroot, then stage into the rootfs-libs tree.
# Build order is bottom-up; run after crossbuild_xwayland.sh (F.1) has built the
# X11/CB + GTK foundation. See references/xwayland-crossbuild.md for the F.1 gotchas
# and the autotools/meson cross patterns (pkg-config-cross.sh, native.txt).
#
#   ./crossbuild_xfce.sh [all|base|deps|apps|stage]
SYS="${SYS:-/home/timo/crossmusl/sysroot}"
SRC="/home/timo/crossmusl/src"
ROOTFS="${ROOTFS:-/home/timo/crossmusl/rootfs-libs}"
INC="/home/timo/crossmusl/linuxinc"
LS_SHARED_CFLAGS="-O2 -mstackrealign"
XFE="--host=x86_64-linux-musl --prefix=$SYS --enable-shared --disable-static"
mkdir -p "$ROOTFS/usr/lib" "$ROOTFS/usr/bin"
PKG="${1:-all}"

# host glib codegen tools are symlinked into /usr/bin (to the cross RPATH'd ones)
host_tools() {
  for t in glib-genmarshal glib-mkenums glib-compile-resources gdbus-codegen; do
    [ -e "/usr/bin/$t" ] || sudo ln -sf "$SYS/bin/$t" /usr/bin/$t
  done
}

act() { # <name> <dir> <build-dir> <configure-args...>
  local name="$1" dir="$2" bd="$3"; shift 3
  echo "=== [$name] ==="
  ( cd "$SRC/$dir"
    rm -rf "$bd" && mkdir "$bd" && cd "$bd"
    export CC=musl-gcc CFLAGS="$LS_SHARED_CFLAGS" CPPFLAGS="-I$INC -I$SYS/include"
    export LDFLAGS="-L$SYS/lib -Wl,-rpath-link,$SYS/lib"
    export PKG_CONFIG_LIBDIR="$SYS/lib/pkgconfig" PKG_CONFIG=/usr/bin/pkg-config
    export PATH="$SYS/bin:$PATH"
    ../configure $XFE "$@" >/tmp/${name}_cfg.log 2>&1 \
      || { echo "CFG_FAIL $name"; tail -25 /tmp/${name}_cfg.log; return 1; }
    make -j4 >/tmp/${name}_make.log 2>&1 \
      || { echo "MAKE_FAIL $name"; tail -30 /tmp/${name}_make.log; return 1; }
    make install >/tmp/${name}_inst.log 2>&1 || true  # tolerate host /usr data-file installs
    true
  ) && echo "=== [$name] OK ===" || return 1
}

if [[ "$PKG" == all || "$PKG" == base ]]; then
  host_tools
  # xfce base libs (in dep order)
  act libxfce4util libxfce4util-4.18.2 build-musl --with-vala=no || exit 1
  GDBUS_CODEGEN="$SYS/bin/gdbus-codegen" act xfconf xfconf-4.18.3 build-musl || exit 1
  act libxfce4ui libxfce4ui-4.18.6 build-musl --enable-x11=no || exit 1
  act exo exo-4.18.0 build-musl --enable-debug=no || exit 1
  act garcon garcon-4.18.2 build-musl --enable-debug=no || exit 1
fi

if [[ "$PKG" == all || "$PKG" == deps ]]; then
  # extra X11/deps pulled in by the apps
  act libSM libSM-1.2.4 build-musl || exit 1
  act libICE libICE-1.1.1 build-musl || exit 1
  echo "deps build done (libXres/startup-notification/xcb-util/libwnck built separately)"
fi

if [[ "$PKG" == all || "$PKG" == apps ]]; then
  act xfce4-panel xfce4-panel-4.18.6 build-musl || exit 1
  act xfce4-session xfce4-session-4.18.4 build-musl || exit 1
  act xfce4-settings xfce4-settings-4.18.6 build-musl || exit 1
  act xfdesktop xfdesktop-4.18.1 build-musl || exit 1
fi

if [[ "$PKG" == all || "$PKG" == stage ]]; then
  bash /home/timo/Documents/xenOS/scripts/stage_xfce_rootfs.sh
fi

echo
echo "==== Phase F.2 done ===="
ls "$SYS"/bin/xfce4-panel "$SYS"/bin/xfdesktop "$SYS"/bin/xfce4-session \
   "$SYS"/bin/xfsettingsd "$SYS"/bin/xfconf-query 2>/dev/null | awk '{print $5,$9}'