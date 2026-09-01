#!/usr/bin/env bash
# xenOS Phase D: cross-build static-musl userspace deps (libffi, libwayland) into a
# sysroot that build.sh links (CROSSROOT). Deps: musl-gcc, meson, ninja, autotools,
# libtool, pkg-config. musl ships no kernel headers -> linuxinc/ stubs are required.
#   usage: scripts/crossbuild_deps.sh [libffi] [wayland]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYS="${SYS:-/home/timo/crossmusl/sysroot}"
SRC=/home/timo/crossmusl/src
INC=/home/timo/crossmusl/linuxinc
mkdir -p "$SRC" "$SYS" "$INC/linux"

# musl lacks <linux/*> kernel headers -> stub the two libs want
[ -f "$INC/linux/limits.h" ] || cat > "$INC/linux/limits.h" <<'EOF'
#ifndef MUSL_LINUX_LIMITS_H
#define MUSL_LINUX_LIMITS_H
#include <limits.h>
#define PATH_MAX 4096
#endif
EOF
[ -f "$INC/linux/types.h" ] || cat > "$INC/linux/types.h" <<'EOF'
#ifndef MUSL_LINUX_TYPES_H
#define MUSL_LINUX_TYPES_H
#include <stdint.h>
#include <sys/types.h>
typedef uint8_t __u8; typedef int8_t __s8; typedef uint16_t __u16; typedef int16_t __s16;
typedef uint32_t __u32; typedef int32_t __s32; typedef uint64_t __u64; typedef int64_t __s64;
typedef unsigned long __kernel_size_t; typedef long __kernel_ssize_t;
#define __user
#endif
EOF

# cross pkg-config: target deps resolve ONLY from the sysroot
cat > /home/timo/crossmusl/pkg-config-cross.sh <<'EOF'
#!/bin/sh
export PKG_CONFIG_LIBDIR="/home/timo/crossmusl/sysroot/lib/pkgconfig"
unset PKG_CONFIG_PATH
exec /usr/bin/pkg-config "$@"
EOF
chmod +x /home/timo/crossmusl/pkg-config-cross.sh

if [[ "${1:-all}" == libffi || "${1:-all}" == all ]]; then
  ver=3.4.6
  cd "$SRC"
  [ -d libffi-$ver ] || { curl -sSL -o libffi.tgz https://github.com/libffi/libffi/releases/download/v$ver/libffi-$ver.tar.gz && tar xzf libffi.tgz; }
  rm -rf libffi-$ver/build && mkdir -p libffi-$ver/build && cd libffi-$ver/build
  CC=musl-gcc CPPFLAGS="-I$INC" ../configure --host=x86_64-linux-musl --prefix="$SYS" \
    --enable-static --disable-shared --disable-docs >/dev/null
  make -j4 && make install
fi

if [[ "${1:-all}" == wayland || "${1:-all}" == all ]]; then
  ver=1.22.0
  cd "$SRC"
  [ -d wayland-$ver ] || { curl -sSL -o wayland.tgz https://gitlab.freedesktop.org/wayland/wayland/-/archive/$ver/wayland-$ver.tar.gz && tar xzf wayland.tgz; }
  cat > "$SRC/wl-cross.txt" <<EOF
[binaries]
c = '/usr/bin/musl-gcc'
ar = '/usr/bin/ar'
strip = '/usr/bin/strip'
pkg-config = '/home/timo/crossmusl/pkg-config-cross.sh'
[built-in options]
c_args = ['-I$INC']
[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF
  cd wayland-$ver
  # relax the native wayland-scanner version pin (host scanner may be newer)
  sed -i "s/dependency('wayland-scanner', native: true, version: meson.project_version())/dependency('wayland-scanner', native: true)/" src/meson.build
  rm -rf build && meson setup build --cross-file="$SRC/wl-cross.txt" --prefix="$SYS" \
    -Ddocumentation=false -Dtests=false -Ddtd_validation=false -Dscanner=false \
    -Ddefault_library=static >/dev/null
  ninja -C build && ninja -C build install
  cp build/src/libwayland-util.a "$SYS/lib/"
fi

if [[ "${1:-all}" == protocols || "${1:-all}" == all ]]; then
  ver=1.32
  cd "$SRC"
  [ -d wayland-protocols-$ver ] || { curl -sSL -o wp.tgz https://gitlab.freedesktop.org/wayland/wayland-protocols/-/archive/$ver/wayland-protocols-$ver.tar.gz && tar xzf wp.tgz; }
  rm -rf wayland-protocols-$ver/build && cd wayland-protocols-$ver
  meson setup build --cross-file="$SRC/wl-cross.txt" --prefix="$SYS" -Dtests=false >/dev/null
  ninja -C build install
fi

if [[ "${1:-all}" == pixman || "${1:-all}" == all ]]; then
  ver=0.43.4
  cd "$SRC"
  [ -d pixman-$ver ] || { curl -sSL -o p.tgz https://www.cairographics.org/releases/pixman-$ver.tar.gz && tar xzf p.tgz; }
  rm -rf pixman-$ver/build && cd pixman-$ver
  meson setup build --cross-file="$SRC/wl-cross.txt" --prefix="$SYS" -Dtests=disabled \
    -Ddemos=disabled -Dgtk=disabled -Ddefault_library=static >/dev/null
  ninja -C build && ninja -C build install
fi

if [[ "${1:-all}" == xkbcommon || "${1:-all}" == all ]]; then
  ver=1.6.0
  cd "$SRC"
  [ -d libxkbcommon-$ver ] || { curl -sSL -o xk.txz "https://github.com/xkbcommon/libxkbcommon/releases/download/xkbcommon-$ver/libxkbcommon-$ver.tar.xz" && tar xJf xk.txz; }
  rm -rf libxkbcommon-$ver/build && cd libxkbcommon-$ver
  meson setup build --cross-file="$SRC/wl-cross.txt" --prefix="$SYS" \
    -Denable-x11=false -Denable-docs=false -Denable-tools=false -Denable-wayland=false \
    -Denable-xkbregistry=false -Ddefault_library=static >/dev/null
  ninja -C build && ninja -C build install
  mkdir -p "$SYS/share/X11/xkb"   # xkb_context_new needs an existing data dir
fi
echo "cross deps installed to $SYS"
if [[ "${1:-all}" == freetype || "${1:-all}" == all ]]; then
  ver=2.13.3
  cd "$SRC"
  [ -d freetype-$ver ] || { curl -fsSL -o ft.tgz "https://download.savannah.gnu.org/releases/freetype/freetype-$ver.tar.gz" && tar xzf ft.tgz; }
  rm -rf freetype-$ver/build-musl && cd freetype-$ver
  mkdir build-musl && cd build-musl
  CC=musl-gcc CPPFLAGS="-I$INC" ../configure --host=x86_64-linux-musl --prefix="$SYS" \
    --enable-static --disable-shared --without-zlib --without-bzip2 --without-png \
    --without-harfbuzz --without-brotli >/dev/null
  make -j2 && make install
  # NOTE: static libfreetype.a blobs are ~700KB+; the kernel's single-blob embed can't
  # take that (boot stalls before linux_launch) -- Phase E/F must host libs as SHARED
  # .so on the ext4 rootfs, not as one giant embedded static blob.
fi

if [[ "${1:-all}" == freetype-shared || "${1:-all}" == all ]]; then
  # Phase E/F pivot: real DEps ride the rootfs as SHARED musl libs, not static blobs.
  ver=2.13.3
  cd "$SRC/freetype-$ver"
  rm -rf build-musl-shared && mkdir build-musl-shared && cd build-musl-shared
  CC=musl-gcc CPPFLAGS="-I$INC" ../configure --host=x86_64-linux-musl --prefix=/usr/local \
    --enable-shared --disable-static --without-zlib --without-bzip2 --without-png \
    --without-harfbuzz --without-brotli >/dev/null
  make -j2
  mkdir -p "${ROOTFS:-/home/timo/crossmusl/rootfs-libs}/usr/lib"
  cp -L .libs/libfreetype.so* "${ROOTFS:-/home/timo/crossmusl/rootfs-libs}/usr/lib/" 2>/dev/null
  rm -f "${ROOTFS:-/home/timo/crossmusl/rootfs-libs}/usr/lib/libfreetype.so"
  echo "  -> libfreetype.so.6 staged for the rootfs (shared musl, SONAME-versioned)"
fi

if [[ "${1:-all}" == zlib || "${1:-all}" == all ]]; then   # Phase E2: zlib (cairo/pango/fontconfig dep)
  cd "$SRC"; [ -d zlib-1.3.1 ] || { curl -fsSL -o z.tgz "https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz" && tar xzf z.tgz; }
  cd zlib-1.3.1 && CC=musl-gcc AR=ar RANLIB=ranlib ./configure --static --prefix="$SYS" >/dev/null && make -j2 && make install
  cat > "$SYS/lib/pkgconfig/zlib.pc" <<'PC'
prefix=/home/timo/crossmusl/sysroot; exec_prefix=${prefix}; libdir=${exec_prefix}/lib; includedir=${prefix}/include
Name: zlib; Description: zlib static musl; Version: 1.3.1; Libs: -L${libdir} -lz; Cflags: -I${includedir}
PC
fi
if [[ "${1:-all}" == cairo || "${1:-all}" == all ]]; then # Phase E2: cairo 2D (pixman+zlib+freetype)
  cd "$SRC"; [ -d cairo-1.16.0 ] || { curl -fsSL -o c.txz "https://www.cairographics.org/releases/cairo-1.16.0.tar.xz" && tar xJf c.txz; }
  cd cairo-1.16.0 && rm -f config.cache
  CC=musl-gcc CPPFLAGS="-I$INC -I$SYS/include" PKG_CONFIG_LIBDIR="$SYS/lib/pkgconfig" \
    PKG_CONFIG="$SRC/../pkg-config-cross.sh" ./configure --host=x86_64-linux-musl --prefix="$SYS" \
    --enable-static --disable-shared --with-x=no --enable-script=no --enable-interpreter=no \
    --enable-gobject=no --enable-tests=no --disable-pdf --disable-ps --disable-svg \
    --disable-png --disable-xlib --disable-gtk-doc >/dev/null
  make -j2 && make install
fi

if [[ "${1:-all}" == expat || "${1:-all}" == all ]]; then   # Phase E2: expat (fontconfig deps)
  cd "$SRC"; [ -d expat-2.6.2 ] || { curl -fsSL -o ex.tgz "https://github.com/libexpat/libexpat/releases/download/R_2_6_2/expat-2.6.2.tar.gz" && tar xzf ex.tgz; }
  cd expat-2.6.2 && CC=musl-gcc CPPFLAGS="-I$INC" ./configure --host=x86_64-linux-musl --prefix="$SYS" \
    --enable-static --disable-shared --without-docbook --without-examples --without-tests >/dev/null
  make -j2 && make install
fi
if [[ "${1:-all}" == fontconfig || "${1:-all}" == all ]]; then # Phase E2: fontconfig (freetype+expat; needs gperf on host!)
  cd "$SRC"; [ -d fontconfig-2.15.0 ] || { curl -fsSL -o fc.txz "https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.15.0.tar.xz" && tar xJf fc.txz; }
  cd fontconfig-2.15.0 && rm -f config.cache
  CC=musl-gcc CPPFLAGS="-I$INC -I$SYS/include" PKG_CONFIG="$SRC/../pkg-config-cross.sh" \
    PKG_CONFIG_LIBDIR="$SYS/lib/pkgconfig" ./configure --host=x86_64-linux-musl --prefix="$SYS" \
    --enable-static --disable-shared --disable-docs --disable-nls --enable-libxml2=no --enable-iconv=no >/dev/null
  make -j2 && make install
  # NOTE: needs host `gperf` (fcobjshash.h); install via: sudo pacman -S gperf
fi

if [[ "${1:-all}" == pcre2 || "${1:-all}" == all ]]; then  # Phase E2: pcre2 (glib regex) - autotools, not meson
  cd "$SRC"; [ -d pcre2-10.44 ] || { curl -fsSL -o pc.tgz "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.gz" && tar xzf pc.tgz; }
  cd pcre2-10.44 && CC=musl-gcc CPPFLAGS="-I$INC" ./configure --host=x86_64-linux-musl --prefix="$SYS" \
    --enable-static --disable-shared --disable-pcre2grep --disable-pcre2test >/dev/null
  make -j2 && make install
fi
if [[ "${1:-all}" == glib || "${1:-all}" == all ]]; then  # Phase E2: glib (GTK foundation) - meson; needs host python3 'packaging'
  cd "$SRC"; [ -d glib-2.80.4 ] || { curl -fsSL -o g.txz "https://download.gnome.org/sources/glib/2.80/glib-2.80.4.tar.xz" && tar xJf g.txz; }
  cd glib-2.80.4 && rm -rf build
  meson setup build --cross-file="$SRC/wl-cross.txt" --prefix="$SYS" -Ddefault_library=static \
    -Dlibmount=disabled -Dselinux=disabled -Dlibelf=disabled -Dtests=false -Dinstalled_tests=false \
    -Dgtk_doc=false -Dman=false -Ddtrace=false -Dsystemtap=false -Dintrospection=disabled \
    -Dnls=disabled -Dbsymbolic_functions=false >/dev/null
  ninja -C build && ninja -C build install
fi

if [[ "${1:-all}" == harfbuzz || "${1:-all}" == all ]]; then # Phase E2: harfbuzz (C++!) via the prebuilt musl-cross g++ (musl.cc)
  cd "$SRC"; [ -d harfbuzz-9.0.0 ] || { curl -fsSL -o hb.txz "https://github.com/harfbuzz/harfbuzz/releases/download/9.0.0/harfbuzz-9.0.0.tar.xz" && tar xJf hb.txz; }
  cd harfbuzz-9.0.0 && rm -rf build
  meson setup build --cross-file="$SRC/../wl-cross-musccc.txt" --prefix="$SYS" -Ddefault_library=static \
    -Dglib=disabled -Dfreetype=disabled -Dcairo=disabled -Dgobject=disabled -Dicu=disabled \
    -Dtests=disabled -Ddocs=disabled -Dutilities=disabled -Dintrospection=disabled >/dev/null
  ninja -C build && ninja -C build install
fi
if [[ "${1:-all}" == pango || "${1:-all}" == all ]]; then # Phase E2: pango text-layout (glib+gobject+cairo+pixman+fontconfig+harfbuzz+freetype)
  cd "$SRC"; [ -d pango-1.54.0 ] || { curl -fsSL -o p.txz "https://download.gnome.org/sources/pango/1.54/pango-1.54.0.tar.xz" && tar xJf p.txz; }
  cd pango-1.54.0 && rm -rf build
  meson setup build --cross-file="$SRC/../wl-cross-cpp.txt" --prefix="$SYS" \
    -Ddefault_library=static -Dfontconfig=enabled -Dcairo=enabled -Dfreetype=enabled \
    -Dlibthai=disabled -Dxft=disabled -Dintrospection=disabled -Dbuild-testsuite=false -Dgtk_doc=false >/dev/null
  ninja -C build && ninja -C build install
fi
# NOTE cross-GNOME static pkg-config fixes (all in $SYS/lib/pkgconfig/): glib-2.0.pc
# glib_mkenums/genmarshal -> $SYS/bin absolute; fontconfig.pc Cflags -I + Libs -lz -lexpat -lm;
# freetype2.pc Cflags -I.../freetype2; cairo-ft.pc Requires cairo freetype2 fontconfig;
# cairo.pc Requires gobject-2.0 glib-2.0 pixman-1 fontconfig freetype2 (NOT Requires.private --
# meson links without --static so the transitive .a deps must be PUBLIC). musl C++ toolchain:
# /tmp/x86_64-linux-musl-cross (musl.cc) provides g++ + musl libstdc++; wl-cross-cpp.txt + wl-cross-musccc.txt.
