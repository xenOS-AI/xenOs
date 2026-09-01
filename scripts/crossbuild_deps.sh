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
