#!/usr/bin/env bash
# xenOS Phase F.1: cross-build Xwayland (Xorg's X server as a Wayland client) to
# shared musl .so against the established crossmusl sysroot, then stage into the
# rootfs-libs tree the guest kernel serves (/usr/lib).
#
#   ./crossbuild_xwayland.sh [all|foundation|xwdeps|xwayland-deps|xwayland|stage|x11]
#
# GTK/wayland libs (crossbuild_shared.sh) already provide: pixman, cairo, fontconfig,
# freetype, libwayland, libxkbcommon, zlib, libpng, expat, pcre2. This adds what
# Xwayland needs: the X11 protocol foundation + XCB + Xlib + extension libs, the
# server-side deps (fonts/shm-fences/modegen/XKB/libmd/libdrm), then the Xwayland
# server (no glamor/glx => pure wl_shm software rendering, no Mesa for F.1).
SYS="${SYS:-/home/timo/crossmusl/sysroot}"
SRC="/home/timo/crossmusl/src"
ROOTFS="${ROOTFS:-/home/timo/crossmusl/rootfs-libs}"
INC="/home/timo/crossmusl/linuxinc"
mkdir -p "$ROOTFS/usr/lib" "$ROOTFS/usr/bin"

PKG="${1:-all}"

x11_autotools() {  # <name> <dir> <extra-conf-args...>
  local name="$1" dir="$2"; shift 2
  echo "=== [$name] configure ==="
  ( cd "$SRC/$dir"
    export CC=musl-gcc
    export CFLAGS="-O2 -mstackrealign"
    export CPPFLAGS="-I$INC -I$SYS/include"
    export LDFLAGS="-L$SYS/lib -Wl,-rpath-link,$SYS/lib"
    export PKG_CONFIG_LIBDIR="$SYS/lib/pkgconfig"
    export PKG_CONFIG=/usr/bin/pkg-config
    rm -f config.cache config.log
    ./configure --host=x86_64-linux-musl --prefix="$SYS" \
      --enable-shared --disable-static "$@" \
      >/tmp/${name}_cfg.log 2>&1 || { echo "CFG_FAIL $name"; tail -20 /tmp/${name}_cfg.log; return 1; }
    make -j4 >/tmp/${name}_make.log 2>&1 || { echo "MAKE_FAIL $name"; tail -25 /tmp/${name}_make.log; return 1; }
    make install >/tmp/${name}_inst.log 2>&1 || { echo "INST_FAIL $name"; tail -15 /tmp/${name}_inst.log; return 1; }
  ) && echo "=== [$name] OK ===" || return 1
}

xwayland_meson() {  # <name> <dir> <crossfile> <extra -D args...>
  local name="$1" dir="$2" cf="$3"; shift 3
  echo "=== [$name] meson ==="
  ( cd "$SRC/$dir"
    # PKG_CONFIG_LIBDIR must be unset: the cross-file shim pkg-config-cross.sh
    # sets the sysroot path itself; exporting it leaks into NATIVE tool lookups
    # (wayland-scanner) and hides the host /usr/lib/pkgconfig/*.pc.
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_PATH
    export CC=musl-gcc CFLAGS="-O2 -mstackrealign -I$SYS/include"
    rm -rf build
    meson setup build --cross-file="$cf" --native-file=/home/timo/crossmusl/native.txt \
      --prefix="$SYS" -Ddefault_library=shared "$@" \
      >/tmp/${name}_cfg.log 2>&1 || { echo "CFG_FAIL $name"; tail -25 /tmp/${name}_cfg.log; return 1; }
    ninja -C build >/tmp/${name}_make.log 2>&1 || { echo "MAKE_FAIL $name"; tail -30 /tmp/${name}_make.log; return 1; }
    ninja -C build install >/tmp/${name}_inst.log 2>&1 || { echo "INST_FAIL $name"; tail -15 /tmp/${name}_inst.log; return 1; }
    true
  ) && echo "=== [$name] OK ===" || return 1
}

stage() {  # stage <libstem...>
  local found=0
  for s in "$@"; do
    if ls "$SYS/lib"/"$s".so* >/dev/null 2>&1; then
      cp -P "$SYS/lib"/"$s".so* "$ROOTFS/usr/lib/" && found=1
    fi
  done
  [ "$found" = 1 ] && echo "  staged: $*"
}

# ---- environment setup (run once): real UAPI headers + native file ---- 
if [[ "$PKG" == all || "$PKG" == setup ]]; then
  # musl ships no kernel headers; copy the host's real UAPI headers into $INC
  for d in linux asm asm-generic drm; do
    [ -d "/usr/include/$d" ] && cp -a "/usr/include/$d" "$INC/$d"
  done
  # musl lacks <sys/ioccom.h> (_IO macro set used by drm.h); forward to UAPI
  mkdir -p "$INC/sys"
  [ -f "$INC/sys/ioccom.h" ] || cat > "$INC/sys/ioccom.h" <<'EOF'
#ifndef _SYS_IOCCOM_H
#define _SYS_IOCCOM_H
#include <asm-generic/ioctl.h>
#endif
EOF
  # native (build-machine) pkg-config so host tools like wayland-scanner resolve
  cat > /home/timo/crossmusl/native.txt <<'EOF'
[binaries]
pkg-config = '/usr/bin/pkg-config'
c = '/usr/bin/gcc'
cpp = '/usr/bin/g++'
EOF
  echo "setup OK (UAPI headers into $INC, native.txt written)"
fi

# ---- F.1a: X11 protocol headers + X-Auth + XCB ----
if [[ "$PKG" == all || "$PKG" == foundation ]]; then
  ( cd "$SRC/xorgproto-2025.1"
    export CC=musl-gcc CFLAGS="-O2"
    make distclean >/dev/null 2>&1
    ./configure --host=x86_64-linux-musl --prefix="$SYS" >/tmp/xorgproto_cfg.log 2>&1 \
      && make -j4 >/tmp/xorgproto_make.log 2>&1 && make install >/tmp/xorgproto_inst.log 2>&1 ) \
    && echo "xorgproto OK" || { echo "xorgproto FAIL"; exit 1; }
  ( cd "$SRC/xcb-proto-1.17.0" && ./configure --host=x86_64-linux-musl --prefix="$SYS" \
    >/tmp/xcbproto_cfg.log 2>&1 && make -j4 >/tmp/xcbproto_make.log 2>&1 && make install >/tmp/xcbproto_inst.log 2>&1 ) \
    && echo "xcb-proto OK" || { echo "xcb-proto FAIL"; exit 1; }
  ( cd "$SRC/xtrans-1.5.0" && ./configure --host=x86_64-linux-musl --prefix="$SYS" \
    >/tmp/xtrans_cfg.log 2>&1 && make -j4 >/tmp/xtrans_make.log 2>&1 && make install >/tmp/xtrans_inst.log 2>&1 ) \
    && echo "xtrans OK" || { echo "xtrans FAIL"; exit 1; }
  # util-macros provides xorg-macros.pc + the proto .pc files (some land in share/)
  ( cd "$SRC/util-macros-1.20.1" && ./configure --prefix="$SYS" >/dev/null 2>&1 && make install >/dev/null 2>&1 )
  # proto .pc files are installed to share/pkgconfig; the pattern uses lib/pkgconfig
  cp -f "$SYS"/share/pkgconfig/*.pc "$SYS/lib/pkgconfig/" 2>/dev/null
  x11_autotools libXau libXau-1.0.11 || exit 1
  x11_autotools libXdmcp libXdmcp-1.1.5 || exit 1
  x11_autotools libxcb libxcb-1.17.0 || exit 1
  stage libxcb libxcb-dri2 libxcb-render libxcb-shm libxcb-xfixes libxcb-xkb \
        libxcb-randr libxcb-xinput libxcb-xinerama libxcb-xtest
fi

# ---- Xlib core + extensions ----
if [[ "$PKG" == all || "$PKG" == x11 ]]; then
  x11_autotools libX11 libX11-1.8.10 || exit 1
  x11_autotools libXext libXext-1.3.6 || exit 1
  x11_autotools libXrender libXrender-0.9.11 || exit 1
  stage libX11 libXext libXrender
fi

# ---- Xwayland server-side deps ----
if [[ "$PKG" == all || "$PKG" == xwdeps ]]; then
  x11_autotools libfontenc libfontenc-1.1.8 || exit 1
  x11_autotools libxshmfence libxshmfence-1.3.2 || exit 1
  x11_autotools libXfont2 libXfont2-2.0.6 || exit 1
  ( cd "$SRC/libxcvt-0.1.3" && rm -rf build
    export PKG_CONFIG_LIBDIR="$SYS/lib/pkgconfig" PKG_CONFIG=/usr/bin/pkg-config
    meson setup build . --cross-file=/home/timo/crossmusl/wl-cross.txt --prefix="$SYS" \
      >/tmp/libxcvt_cfg.log 2>&1 || { echo "CFG libxcvt"; tail -15 /tmp/libxcvt_cfg.log; exit 1; }
    ninja -C build >/tmp/libxcvt_make.log 2>&1 || { echo "MAKE libxcvt"; tail -20 /tmp/libxcvt_make.log; exit 1; }
    ninja -C build install >/tmp/libxcvt_inst.log 2>&1 ) || exit 1
  stage libXfont2 libfontenc libxshmfence libxcvt
fi

# ---- extra Xwayland deps (XKB, SHA1, DRM) + wayland-protocols >= 1.34 ----
if [[ "$PKG" == all || "$PKG" == xwayland-deps ]]; then
  # libxkbfile (meson) + xkbcomp (autotools) — server XKB
  ( cd "$SRC/libxkbfile-1.2.0" && rm -rf build
    unset PKG_CONFIG_LIBDIR; export PKG_CONFIG=/usr/bin/pkg-config
    meson setup build . --cross-file=/home/timo/crossmusl/wl-cross.txt --prefix="$SYS" \
      >/tmp/xkbfile_cfg.log 2>&1 && ninja -C build >/tmp/xkbfile_make.log 2>&1 \
      && ninja -C build install >/tmp/xkbfile_inst.log 2>&1 ) \
    || { echo "libxkbfile FAIL"; tail -12 /tmp/xkbfile_cfg.log; exit 1; }
  ( cd "$SRC/xkbcomp-1.4.7" && export CC=musl-gcc
    export CPPFLAGS="-I$SYS/include -I$INC" LDFLAGS="-L$SYS/lib"
    ./configure --host=x86_64-linux-musl --prefix="$SYS" >/tmp/xkbcomp_cfg.log 2>&1 \
      && make -j4 >/tmp/xkbcomp_make.log 2>&1 && make install >/tmp/xkbcomp_inst.log 2>&1 ) \
    || { echo "xkbcomp FAIL"; tail -12 /tmp/xkbcomp_cfg.log; exit 1; }
  # libmd — SHA1 provider matching xsha1.c's HAVE_SHA1_IN_LIBMD (<sha1.h>, SHA1_Init)
  ( cd "$SRC/libmd" && autoreconf -fi >/dev/null 2>&1; rm -rf build-musl && mkdir build-musl && cd build-musl
    export CC=musl-gcc CFLAGS="-O2 -mstackrealign" CPPFLAGS="-I$SYS/include -I$INC" LDFLAGS="-L$SYS/lib"
    export PKG_CONFIG_LIBDIR="$SYS/lib/pkgconfig" PKG_CONFIG=/usr/bin/pkg-config
    ../configure --host=x86_64-linux-musl --prefix="$SYS" --enable-shared --disable-static \
      >/tmp/libmd_cfg.log 2>&1 && make -j4 >/tmp/libmd_make.log 2>&1 \
      && make install >/tmp/libmd_inst.log 2>&1 ) \
    || { echo "libmd FAIL"; tail -12 /tmp/libmd_cfg.log; exit 1; }
  # libdrm — required by Xwayland even without glamor (drm_fourcc/xf86drm)
  ( cd "$SRC/libdrm-2.4.121" && rm -rf build-musl
    unset PKG_CONFIG_LIBDIR; export PKG_CONFIG=/usr/bin/pkg-config
    meson setup build-musl . --cross-file=/home/timo/crossmusl/wl-cross.txt --prefix="$SYS" \
      -Ddefault_library=shared -Dtests=false -Dman-pages=disabled -Dvalgrind=disabled \
      -Dcairo-tests=disabled -Dintel=disabled -Damdgpu=disabled -Dradeon=disabled \
      -Dnouveau=disabled -Dvmwgfx=disabled -Dfreedreno=disabled -Detnaviv=disabled \
      -Dtegra=disabled -Dvc4=disabled -Dexynos=disabled -Domap=disabled -Dudev=false \
      -Dinstall-test-programs=false \
      >/tmp/libdrm_cfg.log 2>&1 && ninja -C build-musl >/tmp/libdrm_make.log 2>&1 \
      && ninja -C build-musl install >/tmp/libdrm_inst.log 2>&1 ) \
    || { echo "libdrm FAIL"; tail -12 /tmp/libdrm_cfg.log; exit 1; }
  # wayland-protocols >= 1.34 (Xwayland 24.x requirement; 1.32 was too old)
  if [ -d "$SRC/wayland-protocols-1.34" ]; then
    ( cd "$SRC/wayland-protocols-1.34" && rm -rf build
      unset PKG_CONFIG_LIBDIR; export PKG_CONFIG=/usr/bin/pkg-config
      meson setup build . --cross-file=/home/timo/crossmusl/wl-cross.txt --prefix="$SYS" -Dtests=false \
        >/tmp/wp_cfg.log 2>&1 && ninja -C build >/tmp/wp_make.log 2>&1 \
        && ninja -C build install >/tmp/wp_inst.log 2>&1 ) \
      || { echo "wayland-protocols FAIL"; tail -12 /tmp/wp_cfg.log; exit 1; }
  fi
  cp -f "$SYS"/share/pkgconfig/wayland-protocols.pc "$SYS/lib/pkgconfig/" 2>/dev/null
  stage libxkbfile libmd libdrm libxcvt
  cp -P "$SYS"/bin/xkbcomp "$ROOTFS/usr/bin/" 2>/dev/null && echo "  staged: xkbcomp"
fi

# ---- Xwayland server (software-only: no glamor/glx => no Mesa for F.1) ----
if [[ "$PKG" == all || "$PKG" == xwayland ]]; then
  ( cd "$SRC/xwayland-24.1.5"
    unset PKG_CONFIG_LIBDIR PKG_CONFIG_PATH
    export CC="musl-gcc" CFLAGS="-O2 -mstackrealign -I$SYS/include"
    rm -rf build
    meson setup build --cross-file=/home/timo/crossmusl/wl-cross-cpp.txt \
      --native-file=/home/timo/crossmusl/native.txt --prefix="$SYS" \
      -Dglamor=false -Dglx=false -Dxvfb=false -Dxwayland_ei=false \
      -Dsecure-rpc=false -Dxdmcp=false -Dxdm-auth-1=false -Dlisten_tcp=false \
      -Dsha1=libmd \
      >/tmp/xwayland_cfg.log 2>&1 || { echo "XWAYLAND CFG FAIL"; tail -25 /tmp/xwayland_cfg.log; exit 1; }
    ninja -C build >/tmp/xwayland_make.log 2>&1 || { echo "XWAYLAND MAKE FAIL"; tail -30 /tmp/xwayland_make.log; exit 1; }
  ) || { echo "XWAYLAND BUILD FAILED"; exit 1; }
  install -Dm755 "$SRC/xwayland-24.1.5/build/hw/xwayland/Xwayland" "$SYS/bin/Xwayland"
  echo "Xwayland installed: $SYS/bin/Xwayland"
fi

# ---- stage everything the guest needs to run Xwayland ----
if [[ "$PKG" == all || "$PKG" == stage ]]; then
  install -m755 "$SYS/bin/Xwayland" "$ROOTFS/usr/bin/Xwayland"
  install -m755 "$SYS/bin/xkbcomp" "$ROOTFS/usr/bin/xkbcomp"
  stage libX11 libXext libXrender libXfont2 libfontenc libxshmfence libxcvt libxkbfile \
        libxcb libxcb-render libxcb-shm libxcb-xfixes libxcb-xkb libxcb-xinput \
        libxcb-randr libxcb-xinerama libxcb-xtest libXau libXdmcp libmd libdrm
  echo "rootfs staged"
fi

echo
echo "==== Phase F.1 cross-build done ===="
ls -l "$SYS"/bin/Xwayland 2>/dev/null | awk '{print "Xwayland:", $5, $9}'
ls -l "$ROOTFS"/usr/bin/Xwayland 2>/dev/null | awk '{print "rootfs:", $5, $9}'