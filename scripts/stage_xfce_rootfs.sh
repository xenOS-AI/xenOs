#!/usr/bin/env bash
# Stage the Xfce/Xwayland runtime, preserving SONAME links and runtime data.
# The result is merged into build/rootfs by build.sh before ext4 is generated.
set -euo pipefail

SYS="${SYS:-/home/timo/crossmusl/sysroot}"
ROOTFS="${ROOTFS:-/home/timo/crossmusl/rootfs-libs}"

required_bins=(
  xfce4-panel xfdesktop xfce4-session xfsettingsd xfconf-query
  xfce4-settings-manager xfce4-display-settings
  dbus-daemon dbus-uuidgen Xwayland xkbcomp
)

[ -d "$SYS/lib" ] || { echo "missing sysroot library directory: $SYS/lib" >&2; exit 1; }
mkdir -p "$ROOTFS/usr/lib" "$ROOTFS/usr/bin" "$ROOTFS/usr/share" "$ROOTFS/etc"

for binary in "${required_bins[@]}"; do
  [ -x "$SYS/bin/$binary" ] \
    || { echo "missing required Xfce runtime binary: $SYS/bin/$binary" >&2; exit 1; }
done

# Copy links as links: flattening libfoo.so -> libfoo.so.1 breaks DT_NEEDED.
shopt -s nullglob
libraries=("$SYS"/lib/*.so*)
[ "${#libraries[@]}" -gt 0 ] || { echo "no shared libraries in $SYS/lib" >&2; exit 1; }
cp -a "${libraries[@]}" "$ROOTFS/usr/lib/"
for binary in "${required_bins[@]}"; do
  install -m755 "$SYS/bin/$binary" "$ROOTFS/usr/bin/$binary"
done

# Optional helpers are selected by Xfce's desktop entries/configuration.
for binary in exo-open exo-desktop-item-edit garcon-gtk3-query; do
  [ -x "$SYS/bin/$binary" ] && install -m755 "$SYS/bin/$binary" "$ROOTFS/usr/bin/$binary"
done

copy_tree() { # <source-relative-path> <destination-relative-path>
  local source="$SYS/$1" destination="$ROOTFS/$2"
  [ -d "$source" ] || return 0
  mkdir -p "$destination"
  cp -a "$source/." "$destination/"
}

# These are runtime inputs, not build-only metadata.  In particular Xwayland
# needs xkb data, dbus-daemon needs its configuration, and GTK/Xfce locate
# schemas, desktop files, icons and their defaults below share/.
copy_tree etc/xdg etc/xdg
copy_tree etc/dbus-1 etc/dbus-1
copy_tree share/xfce4 usr/share/xfce4
copy_tree share/xsessions usr/share/xsessions
copy_tree share/applications usr/share/applications
copy_tree share/glib-2.0 usr/share/glib-2.0
copy_tree share/icons usr/share/icons
copy_tree share/themes usr/share/themes
copy_tree share/mime usr/share/mime
copy_tree share/X11 usr/share/X11
copy_tree share/dbus-1 usr/share/dbus-1

printf '=== staged Xfce/Xwayland into %s ===\n' "$ROOTFS"
printf 'binaries: %s; shared-library entries: %s\n' \
  "${#required_bins[@]}" "$(find "$ROOTFS/usr/lib" -maxdepth 1 -name '*.so*' | wc -l)"
