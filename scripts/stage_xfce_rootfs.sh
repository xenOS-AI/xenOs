#!/usr/bin/env bash
# Stage the xenOS F.2 Xfce userspace + F.1 Xwayland into the rootfs-libs tree.
# The guest kernel dynamic loader serves/usr/lib + /usr/bin from this tree.
set -u
SYS=/home/timo/crossmusl/sysroot
ROOTFS=/home/timo/crossmusl/rootfs-libs
mkdir -p "$ROOTFS/usr/lib" "$ROOTFS/usr/bin" "$ROOTFS/etc/xdg"

# all shared libs (only .so, no archives)
cp -af "$SYS"/lib/*.so* "$ROOTFS/usr/lib/" 2>/dev/null
# binaries installed by xfce / dbus / xwayland / xkb
install -m755 "$SYS"/bin/xfce4-panel "$SYS"/bin/xfdesktop "$SYS"/bin/xfce4-session \
  "$SYS"/bin/xfsettingsd "$SYS"/bin/xfce4-settings-manager "$SYS"/bin/xfce4-display-settings \
  "$SYS"/bin/xfconf-query "$SYS"/bin/dbus-daemon "$SYS"/bin/dbus-uuidgen \
  "$SYS"/bin/Xwayland "$SYS"/bin/xkbcomp "$ROOTFS/usr/bin/" 2>/dev/null
# xfce data (config) the session needs at runtime
[ -d "$SYS/etc/xdg/xfce4" ] && cp -a "$SYS/etc/xdg/xfce4" "$ROOTFS/etc/xdg/"
[ -d "$SYS/share/xsessions" ] && mkdir -p "$ROOTFS/usr/share/xsessions" && cp -a "$SYS/share/xsessions/." "$ROOTFS/usr/share/xsessions/" 2>/dev/null
[ -d "$SYS/share/xfce4" ] && mkdir -p "$ROOTFS/usr/share" && cp -a "$SYS/share/xfce4" "$ROOTFS/usr/share/"
echo "=== staged Xfce/Xwayland into $ROOTFS ==="
ls "$ROOTFS"/usr/bin/ 2>/dev/null
echo "--- .so count in rootfs ---"; ls "$ROOTFS/usr/lib/" | grep -c "\.so"