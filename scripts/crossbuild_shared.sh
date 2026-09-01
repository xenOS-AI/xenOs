#!/usr/bin/env bash
# xenOS Phase E3: rebuild the GTK3 dependency tree as SHARED musl .so files.
# The static-archive tree (crossbuild_deps.sh, -Ddefault_library=static) cannot host a
# GTK app via the kernel rootfs-exec (the whole 100MB image must fit one kernel heap
# buffer). A dynamic .so main is tiny; the kernel maps the interpreter and the app's
# DT_NEEDED .so chain from the ext4 rootfs. So the libs must exist as SHARED musl .so.
#
# Bottom-up order (each shared lib is needed by the shared consumer above it), matched
# to the proven static recipes in crossbuild_deps.sh. Builds into the SAME sysroot so
# pkg-config finds whichever form it needs; shared .so outputs are then staged into
# $ROOTFS/usr/lib (the ext4 rootfs "root" dir).
#
#   ./crossbuild_shared.sh [all|<pkg>...]
SYS="${SYS:-/home/timo/crossmusl/sysroot}"
SRC="/home/timo/crossmusl/src"
ROOTFS="${ROOTFS:-/home/timo/crossmusl/rootfs-libs}"
INC="/home/timo/crossmusl/linuxinc"
mkdir -p "$ROOTFS/usr/lib"

PKG="${1:-all}"

# state ++ shared (autotools): --enable-shared --disable-static
shared_autotools() {
  local name="$1" dir="$2" lnkfn="$3"
  echo "=== [$name] configure (shared) ==="
  local preconf="cd \"$SRC/$dir\" && rm -f config.cache config.log && export CC=musl-gcc
export CPPFLAGS=\"-I$INC -I$SYS/include\"
export LDFLAGS=\"-L$SYS/lib -Wl,-rpath-link,$SYS/lib\"
export PKG_CONFIG_LIBDIR=\"$SYS/lib/pkgconfig\"
export PKG_CONFIG=/usr/bin/pkg-config"
  # shellcheck disable=SC2086
  eval "$preconf"
  ./configure --host=x86_64-linux-musl --prefix="$SYS" \
    --enable-shared --disable-static $lnkfn \
    >/tmp/$(echo $name)_cfg.log 2>&1 || { echo "CFG_FAIL $name"; tail -15 /tmp/$(echo $name)_cfg.log; return 1; }
  make -j4 >/tmp/$(echo $name)_make.log 2>&1 || { echo "MAKE_FAIL $name"; tail -20 /tmp/$(echo $name)_make.log; return 1; }
  make install >/tmp/$(echo $name)_inst.log 2>&1 || { echo "INST_FAIL $name"; tail -10 /tmp/$(echo $name)_inst.log; return 1; }
  echo "=== [$name] OK ==="
  return 0
}

# state ++ shared (meson): -Ddefault_library=shared
shared_meson() {
  local name="$1" rel="$2" crossfile="$3" extra="$4"
  echo "=== [$name] meson (shared) ==="
  ( cd "$SRC/$rel" && rm -rf build
    export PKG_CONFIG_LIBDIR="$SYS/lib/pkgconfig"
    export PKG_CONFIG=/usr/bin/pkg-config
    export CFLAGS="-I$SYS/include"
    [ -z "$crossfile" ] && crossfile=/home/timo/crossmusl/wl-cross-cpp.txt
    meson setup build --cross-file="$crossfile" --prefix="$SYS" \
      -Ddefault_library=shared $extra \
      >/tmp/$(echo $name)_cfg.log 2>&1 || { echo "CFG_FAIL $name"; tail -15 /tmp/$(echo $name)_cfg.log; return 1; }
    ninja -C build >/tmp/$(echo $name)_make.log 2>&1 || { echo "MAKE_FAIL $name"; tail -20 /tmp/$(echo $name)_make.log; return 1; }
    ninja -C build install >/tmp/$(echo $name)_inst.log 2>&1 || { echo "INST_FAIL $name"; tail -12 /tmp/$(echo $name)_inst.log; return 1; } )
  echo "=== [$name] OK ==="
  return 0
}

# stage the produced .so files (and SONAME symlinks) of one pkg into the rootfs
stage() { # stage <libstem...>
  local found=0
  for s in "$@"; do
    if ls "$SYS/lib"/"$s".so* >/dev/null 2>&1; then
      cp -P "$SYS/lib"/"$s".so* "$ROOTFS/usr/lib/" && found=1
    fi
  done
  [ "$found" = 1 ] && echo "  staged: $*"
}

# ---- bottom of the tree (plain C libs, fast) ----
if [[ "$PKG" == all || "$PKG" == zlib ]]; then
  ( cd "$SRC/zlib-1.3.1" && export CC=musl-gcc && ./configure --prefix="$SYS" >/tmp/zlib_cfg.log 2>&1 \
      || { echo "zlib CFG"; tail -10 /tmp/zlib_cfg.log; exit 1; }
    make -j4 >/tmp/zlib_make.log 2>&1 || { echo "zlib MAKE"; tail -15 /tmp/zlib_make.log; exit 1; }
    make install >/tmp/zlib_inst.log 2>&1 ); echo "zlib OK"; 
  # zlib static-only path installs libz.a; add the shared lib explicitly
  [ -f "$SRC/zlib-1.3.1/libz.so" ] && cp -P "$SRC/zlib-1.3.1/libz.so"* "$SYS/lib/"
  # zlib pc may list -L prefix only; ensure stage
  cp -P "$SRC/zlib-1.3.1/libz.so"* "$ROOTFS/usr/lib/" 2>/dev/null && echo "zlib staged"
fi

if [[ "$PKG" == all || "$PKG" == expat ]]; then  # automake libtool
  shared_autotools expat expat-2.6.2 "--without-docbook --without-examples --without-tests" || exit 1
  stage libexpat
fi

if [[ "$PKG" == all || "$PKG" == pcre2 ]]; then
  # pcre2 autotools
  shared_autotools pcre2 pcre2-10.44 "--disable-pcre2grep --disable-pcre2test" || exit 1
  stage libpcre2-8
fi

if [[ "$PKG" == all || "$PKG" == libffi ]]; then
  shared_autotools libffi libffi-3.4.6 "--disable-docs" || exit 1
  stage libffi
fi

if [[ "$PKG" == all || "$PKG" == libpng ]]; then
  shared_autotools libpng libpng-1.6.43 "" || exit 1
  stage libpng16 libpng
fi

if [[ "$PKG" == all || "$PKG" == pixman ]]; then  # meson-only from 0.40+
  shared_meson pixman pixman-0.43.4 /home/timo/crossmusl/wl-cross.txt \
    "-Dtests=disabled -Ddemos=disabled -Dgtk=disabled"
  stage libpixman-1
fi

if [[ "$PKG" == all || "$PKG" == freetype-shared ]]; then   # already has a shared recipe
  ( cd "$SRC" && [ -d freetype-2.13.3 ] || { curl -fsSL -o freetype.tar.gz "https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.gz" && tar xzf freetype.tar.gz; }
    cd freetype-2.13.3 && rm -rf build-musl-shared && mkdir build-musl-shared && cd build-musl-shared
    export CC=musl-gcc
    export CPPFLAGS="-I$INC -I$SYS/include"
    export LDFLAGS="-L$SYS/lib"
    export PKG_CONFIG_LIBDIR="$SYS/lib/pkgconfig"
    ../../freetype-2.13.3/configure --host=x86_64-linux-musl --prefix="$SYS" \
      --enable-shared --disable-static --without-zlib --without-bzip2 --without-png \
      >/tmp/freetype_cfg.log 2>&1 || { echo "FREETYPE CFG"; tail -12 /tmp/freetype_cfg.log; exit 1; }
    make -j4 >/tmp/freetype_make.log 2>&1 || { echo "FREETYPE MAKE"; tail -15 /tmp/freetype_make.log; exit 1; }
    make install >/tmp/freetype_inst.log 2>&1 )
  echo "freetype OK"; stage libfreetype
fi

if [[ "$PKG" == all || "$PKG" == fontconfig ]]; then
  shared_autotools fontconfig fontconfig-2.15.0 "--disable-docs --disable-nls --enable-libxml2=no --enable-iconv=no" || exit 1
  stage libfontconfig
fi

if [[ "$PKG" == all || "$PKG" == wayland ]]; then  # meson; static was built; want shared libwayland-client/server
  ( cd "$SRC/wayland-1.22.0"
    sed -i "s/dependency('wayland-scanner', native: true, version: meson.project_version())/dependency('wayland-scanner', native: true)/" src/meson.build
    rm -rf build
    export PKG_CONFIG=/usr/bin/pkg-config
    unset PKG_CONFIG_LIBDIR   # leave the NATIVE path free so meson finds host wayland-scanner.pc
    meson setup build --cross-file=/home/timo/crossmusl/wl-cross.txt --prefix="$SYS" \
      -Ddocumentation=false -Dtests=false -Ddtd_validation=false -Dscanner=false \
      -Ddefault_library=shared \
      >/tmp/wayland_cfg.log 2>&1 || { echo "WAYLAND CFG"; tail -15 /tmp/wayland_cfg.log; exit 1; }
    ninja -C build >/tmp/wayland_make.log 2>&1 || { echo "WAYLAND MAKE"; tail -20 /tmp/wayland_make.log; exit 1; }
    ninja -C build install >/tmp/wayland_inst.log 2>&1 || { echo "WAYLAND INST"; tail -12 /tmp/wayland_inst.log; exit 1; }
    cp -f build/src/libwayland-util.so* "$SYS/lib/" 2>/dev/null )
  echo "wayland OK"
  stage libwayland-client libwayland-server libwayland-cursor libwayland-egl libwayland-util
fi

if [[ "$PKG" == all || "$PKG" == xkbcommon ]]; then # already shared; ensure staged
  stage libxkbcommon
fi

# ---- glib (the GTK foundation) ----
if [[ "$PKG" == all || "$PKG" == glib ]]; then
  shared_meson glib glib-2.80.4 /home/timo/crossmusl/wl-cross.txt \
    "-Dlibmount=disabled -Dselinux=disabled -Dlibelf=disabled -Dtests=false -Dinstalled_tests=false -Dgtk_doc=false -Dman=false -Ddtrace=false -Dsystemtap=false -Dintrospection=disabled -Dnls=disabled -Dbsymbolic_functions=false"
  stage libglib-2.0 libgobject-2.0 libgio-2.0 libgmodule-2.0 libgthread-2.0
fi

# ---- harfbuzz (C++) ----
if [[ "$PKG" == all || "$PKG" == harfbuzz ]]; then
  shared_meson harfbuzz harfbuzz-9.0.0 /home/timo/crossmusl/wl-cross-musccc.txt \
    "-Dglib=disabled -Dfreetype=disabled -Dcairo=disabled -Dgobject=disabled -Dicu=disabled -Dtests=disabled -Ddocs=disabled -Dutilities=disabled -Dintrospection=disabled"
  stage libharfbuzz libharfbuzz-subset
fi

# ---- cairo (autotools) ----
if [[ "$PKG" == all || "$PKG" == cairo ]]; then
  ( cd "$SRC/cairo-1.16.0"
    export CC=musl-gcc
    export CPPFLAGS="-I$INC -I$SYS/include -Ubool"
    export LDFLAGS="-L$SYS/lib -Wl,-rpath-link,$SYS/lib"
    export PKG_CONFIG_LIBDIR="$SYS/lib/pkgconfig"
    export PKG_CONFIG=/usr/bin/pkg-config
    rm -f config.cache config.log
    ./configure --host=x86_64-linux-musl --prefix="$SYS" \
      --enable-shared --disable-static --with-x=no --enable-script=no --enable-interpreter=no \
      --enable-gobject=yes --enable-tests=no --enable-pdf=yes --enable-ps=yes --enable-svg=yes \
      --enable-png=yes --disable-xlib --disable-gtk-doc \
      >/tmp/cairo_cfg.log 2>&1 || { echo "CAIRO CFG"; tail -15 /tmp/cairo_cfg.log; exit 1; }
    # build ONLY the libraries (skip the test-suite binaries that fail to link); then install
    make -j4 libcairo.la libcairo-gobject.la libcairo-script-interpreter.la >/tmp/cairo_make.log 2>&1 \
      || { echo "CAIRO MAKE"; tail -20 /tmp/cairo_make.log; exit 1; }
    make install-libLTLIBRARIES install-data-am >/tmp/cairo_inst.log 2>&1 || { echo "CAIRO INST"; tail -12 /tmp/cairo_inst.log; exit 1; }
    cp -P .libs/libcairo.so* .libs/libcairo-gobject.so* "$SYS/lib/" 2>/dev/null
    ) && echo "cairo OK"
  stage libcairo libcairo-gobject libcairo-script-interpreter
fi

# ---- gdk-pixbuf ----
if [[ "$PKG" == all || "$PKG" == gdk-pixbuf ]]; then
  # meson; needs cross pkg-config env (PKG_CONFIG on cmdline) like the static recipe; install lib manually
  ( cd "$SRC/gdk-pixbuf-2.42.12" && rm -rf build
    export PKG_CONFIG_LIBDIR="$SYS/lib/pkgconfig"
    export PKG_CONFIG=/usr/bin/pkg-config
    export CFLAGS="-I$SYS/include"
    meson setup build --cross-file=/home/timo/crossmusl/wl-cross-cpp.txt --prefix="$SYS" \
      -Ddefault_library=shared -Dintrospection=disabled -Dtests=false -Dinstalled_tests=false \
      -Dman=false -Ddocs=false -Dpng=disabled -Djpeg=disabled -Dtiff=disabled -Dbuiltin_loaders=none \
      -Dgio_sniffing=false \
      >/tmp/gdkpixbuf_cfg.log 2>&1 || { echo "GDKPIXBUF CFG"; tail -15 /tmp/gdkpixbuf_cfg.log; exit 1; }
    ninja -C build >/tmp/gdkpixbuf_make.log 2>&1 || { echo "GDKPIXBUF MAKE"; tail -20 /tmp/gdkpixbuf_make.log; exit 1; }
    cp -f build/gdk-pixbuf/libgdk_pixbuf-2.0.so* "$SYS/lib/"
    cp -f build/gdk-pixbuf/libgdk_pixbuf-2.0.so* "$ROOTFS/usr/lib/" 2>/dev/null
    # headers already staged by the static recipe
    echo "gdk-pixbuf OK" )
fi

# ---- atk ----
if [[ "$PKG" == all || "$PKG" == atk ]]; then
  shared_meson atk atk-2.38.0 /home/timo/crossmusl/wl-cross-cpp.txt "-Dintrospection=false"
  stage libatk-1.0
fi

# ---- pango ----
if [[ "$PKG" == all || "$PKG" == pango ]]; then
  shared_meson pango pango-1.54.0 /home/timo/crossmusl/wl-cross-cpp.txt \
    "-Dfontconfig=enabled -Dcairo=enabled -Dfreetype=enabled -Dlibthai=disabled -Dxft=disabled -Dintrospection=disabled -Dbuild-testsuite=false -Dgtk_doc=false"
  stage libpango-1.0 libpangocairo-1.0 libpangoft2-1.0 libpangoxft-1.0
fi

# ---- gtk3 (the big one) ----
if [[ "$PKG" == all || "$PKG" == gtk ]]; then
  ( cd "$SRC/gtk-3.24.52" && rm -rf build
    export PKG_CONFIG_LIBDIR="$SYS/lib/pkgconfig"
    export PKG_CONFIG=/usr/bin/pkg-config
    export CFLAGS="-I$SYS/include"
    export LDFLAGS="-L$SYS/lib -Wl,-rpath-link,$SYS/lib"
    meson setup build --cross-file=/home/timo/crossmusl/wl-cross-cpp.txt --prefix="$SYS" \
      -Dc_args=-I$SYS/include -Dcpp_args=-I$SYS/include \
      -Ddefault_library=shared -Dx11_backend=false -Dwayland_backend=true -Dbroadway_backend=false \
      -Dintrospection=false -Dgtk_doc=false -Dman=false -Ddemos=false -Dexamples=false \
      -Dtests=false -Dinstalled_tests=false -Dtracker3=false -Dcolord=no -Dcloudproviders=false \
      -Dlibepoxy:glx=no -Dlibepoxy:x11=false -Dlibepoxy:egl=yes \
      >/tmp/gtk_cfg.log 2>&1 || { echo "GTK CFG"; tail -15 /tmp/gtk_cfg.log; exit 1; }
    ninja -C build >/tmp/gtk_make.log 2>&1 || { echo "GTK MAKE"; tail -25 /tmp/gtk_make.log; exit 1; }
    # install lib + headers manually (ninja 'all' aborts on im-*.so input modules)
    cp -f build/gtk/libgtk-3.so* build/gdk/libgdk-3.so* "$SYS/lib/"
    cp -rf gtk/ gdk/ ignore 2>/dev/null || true
    echo "gtk3 OK" )
  stage libgtk-3 libgdk-3
fi

echo
echo "==== shared-build done ===="
echo "sysroot .so now:"
ls -l "$SYS"/lib/*.so* 2>/dev/null | awk '{print $5, $9}'
echo "rootfs usr/lib .so:"
ls -l "$ROOTFS"/usr/lib/*.so* 2>/dev/null | awk '{print $5, $9}'