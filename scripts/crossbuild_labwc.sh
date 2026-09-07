#!/usr/bin/env bash
# xenOS labwc: cross-build the wlroots compositor stack to shared musl.
#   ./crossbuild_labwc.sh [inputdeps|wlroots|labwc|stage|all]
# Produces (into $SYS): wlroots-0.20 (pixman renderer ONLY, headless+wayland+noop
# backends) and labwc (wlroots-0.20, -xwayland -icon -svg), then stages the .so
# tree into the ext4 rootfs. Requires the Phase-1 bumps already built by
# crossbuild_shared.sh (wayland 1.24.0) + crossbuild_deps.sh (wayland-protocols 1.47):
#   wlroots 0.20 needs wayland-server>=1.24, xkbcommon>=1.8, libdrm>=2.4.129,
#   wayland-protocols>=1.47, pixman-1>=0.46. labwc needs wayland-server>=1.22.90,
#   wayland-protocols>=1.39.
#
# GOTCHAS baked in (all hit during the 2026-09 bring-up, see skill reference):
# - wlroots' meson forces PKG_CONFIG_LIBDIR onto the NATIVE wayland-scanner lookup,
#   swallowing PKG_CONFIG_PATH. Fix: stage a host wayland-scanner.pc INTO
#   $SYS/lib/pkgconfig (its wayland_scanner var points at the host binary).
# - labwc needs libinput.h unconditionally + links libinput; libinput needs
#   libevdev + mtdev + libudev. Use the tiny libudev-zero (no systemd/glibc).
# - xkbcommon ships NO tarballs since 1.8.0 -> use the GitHub refs/tags archive.
# - libdrm 2.4.130 dropped the `armada`/`rockchip` meson options.
set -euo pipefail
SYS="${SYS:-/home/timo/crossmusl/sysroot}"
SRC="${SRC:-/home/timo/crossmusl/src}"
ROOTFS="${ROOTFS:-/home/timo/crossmusl/rootfs-libs}/usr/lib"
INC="/home/timo/crossmusl/linuxinc"
HOSTPKG="/home/timo/crossmusl/hostpkg"
mkdir -p "$HOSTPKG" "$ROOTFS"

# cross pkg-config must resolve ONLY the sysroot; native scanner via hostpkg.
crossenv() {
  export PKG_CONFIG_LIBDIR="$SYS/lib/pkgconfig"
  export PKG_CONFIG=/usr/bin/pkg-config
  unset PKG_CONFIG_PATH
  [ -f "$SYS/lib/pkgconfig/wayland-scanner.pc" ] || \
    { echo "host wayland-scanner.pc missing in sysroot; run once: cp hostpkg->sysroot"; exit 1; }
}
# host wayland-scanner .pc (meson cross sets PKG_CONFIG_LIBDIR on the native dep too)
ensure_scanner() {
  cat > "$SYS/lib/pkgconfig/wayland-scanner.pc" <<EOF
prefix=/usr
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include
Name: wayland-scanner
Description: Wayland scanner
Version: 1.24.0
wayland_scanner=/usr/bin/wayland-scanner
EOF
}
stage() { for s in "$@"; do cp -P "$SYS"/lib/"$s".so* "$ROOTFS"/ 2>/dev/null; done; }

if [[ "${1:-all}" == all || "$1" == inputdeps ]]; then
  ensure_scanner
  # ---- libevdev (meson) ----
  ( cd "$SRC"
    [ -d libevdev-1.13.1 ] || { curl -fsSL -o lev.tgz https://gitlab.freedesktop.org/libevdev/libevdev/-/archive/libevdev-1.13.1/libevdev-1.13.1.tar.gz && tar xzf lev.tgz; }
    cd libevdev-* && rm -rf build
    crossenv
    meson setup build --cross-file=/home/timo/crossmusl/wl-cross.txt --prefix="$SYS" \
      -Ddefault_library=shared -Dtests=disabled -Ddocumentation=disabled \
      -Dc_args="-I$INC -mstackrealign" >/tmp/lev_cfg.log 2>&1
    ninja -C build && ninja -C build install )
  # ---- libudev-zero (make; no systemd) ----
  ( cd "$SRC"
    [ -d libudev-zero-1.0.2 ] || curl -fsSL -o ud0.tgz https://github.com/illiliti/libudev-zero/archive/refs/tags/1.0.2.tar.gz
    tar xzf ud0.tgz 2>/dev/null || true
    cd libudev-zero-1.0.2
    make CC=musl-gcc PREFIX="$SYS" LIBDIR="$SYS/lib" INCLUDEDIR="$SYS/include" >/tmp/udev0_make.log 2>&1
    make install PREFIX="$SYS" LIBDIR="$SYS/lib" INCLUDEDIR="$SYS/include" >/tmp/udev0_inst.log 2>&1 )
  # ---- mtdev (autotools; host triple rejected by its old config.sub) ----
  ( cd "$SRC"
    [ -d mtdev-1.1.6 ] || curl -fsSL -o mt.tbz "https://www.freedesktop.org/software/mtdev/mtdev-1.1.6.tar.bz2"
    tar xjf mt.tbz 2>/dev/null || true
    cd mtdev-1.1.6 && rm -f config.cache
    export CC=musl-gcc CFLAGS="-O2 -mstackrealign" \
      CPPFLAGS="-I$INC -I$SYS/include" LDFLAGS="-L$SYS/lib"
    ./configure --prefix="$SYS" --enable-shared --disable-static >/tmp/mt_cfg.log 2>&1
    make -j4 && make install )
  # ---- libinput (meson; libudev-zero + libevdev + mtdev; no libwacom) ----
  ( cd "$SRC"
    [ -d libinput-1.26.2 ] || { curl -fsSL -o in.tgz https://gitlab.freedesktop.org/libinput/libinput/-/archive/1.26.2/libinput-1.26.2.tar.gz && tar xzf in.tgz; }
    cd libinput-1.26.2 && rm -rf build
    crossenv
    meson setup build --cross-file=/home/timo/crossmusl/wl-cross.txt --prefix="$SYS" \
      -Ddefault_library=shared -Dlibwacom=false -Dtests=false -Ddocumentation=false \
      -Ddebug-gui=false -Dinstall-tests=false -Dc_args="-I$INC -mstackrealign" \
      >/tmp/in_cfg.log 2>&1
    ninja -C build && ninja -C build install )
  echo "inputdeps OK -> staged:"
  stage libinput libevdev libudev libmtdev
fi

if [[ "${1:-all}" == all || "$1" == wlroots ]]; then
  ensure_scanner
  ( cd "$SRC"
    [ -d wlroots-0.20.2 ] || { curl -fsSL -o wlr.tgz https://gitlab.freedesktop.org/wlroots/wlroots/-/archive/0.20.2/wlroots-0.20.2.tar.gz && tar xzf wlr.tgz; }
    cd wlroots-0.20.2 && rm -rf build
    crossenv
    # pixman renderer ONLY (gles2/vulkan off) + headless/wayland/noop backends
    # (drm/libinput/x11/session off -> no udev/seatd). -Dc_args gives sysroot includes.
    meson setup build --cross-file=/home/timo/crossmusl/wl-cross.txt --prefix="$SYS" \
      -Ddefault_library=shared -Drenderers= -Dbackends= -Dallocators= \
      -Dsession=disabled -Dxwayland=disabled -Dexamples=false -Dxcb-errors=disabled \
      -Dlibliftoff=disabled -Dcolor-management=disabled \
      -Dc_args="-I$INC -I$SYS/include -I$SYS/include/libdrm -mstackrealign" \
      >/tmp/wlr_cfg.log 2>&1
    ninja -C build && ninja -C build install )
  echo "wlroots OK -> staged:"
  stage libwlroots-0.20
fi

if [[ "${1:-all}" == all || "$1" == labwc ]]; then
  [ -f "$SYS/lib/pkgconfig/wlroots-0.20.pc" ] || { echo "wlroots first"; exit 1; }
  ( cd "$SRC"
    [ -d labwc-master ] || { curl -fsSL -o labwc-master.tgz https://github.com/labwc/labwc/archive/refs/heads/master.tar.gz && tar xzf labwc-master.tgz; }
    cd labwc-master && rm -rf build
    crossenv
    meson setup build --cross-file=/home/timo/crossmusl/wl-cross.txt --prefix="$SYS" \
      -Dxwayland=disabled -Dicon=disabled -Dsvg=disabled -Dnls=disabled \
      -Dman-pages=disabled -Dtest=disabled -Dstatic_analyzer=disabled \
      -Dc_args="-I$INC -I$SYS/include -mstackrealign" \
      >/tmp/labwc_cfg.log 2>&1
    ninja -C build && ninja -C build install )
  echo "labwc OK:"
  # host-loadable check: needs LD_LIBRARY_PATH to the musl sysroot (else it guesses
  # the host glibc /lib and every musl .so symbol is "not found")
  LD_LIBRARY_PATH="$SYS/lib" "$SYS/bin/labwc" --version
fi

echo "==== crossbuild_labwc done ===="
ls -l "$SYS"/lib/libwlroots-0.20.so* "$SYS"/bin/labwc 2>/dev/null