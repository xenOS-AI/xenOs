#!/usr/bin/env bash
# xenOS bootstrap — ONE command to get a build-ready machine.
#
# "…not stuck for one user… pulls everything that is needed if they are not
#  found on the system. Make sure the user has to install as little as possible."
#
# Responsibilities:
#   1. Install missing HOST build tools via the native package manager
#      (apt / dnf / pacman / zypper / apk / brew — auto-detected) WITHOUT sudo
#      when it can't get it (it prints the one command to run instead).
#   2. Install the C3 compiler (c3c) if absent — into $XENOS_BIN (project-local),
#      no root needed, so it never touches system dirs.
#   3. Provision the CROSS-MUSL SYSTROOT (userspace deps) when asked, by
#      running the existing crossbuild recipes against the project-local paths.
#
#   ./scripts/bootstrap.sh               # host tools + c3c (fast; safe default)
#   ./scripts/bootstrap.sh sysroot       # also cross-build the userspace sysroot
#   ./scripts/bootstrap.sh all           # host tools + c3c + full sysroot
#   ./scripts/bootstrap.sh doctor        # report what's present / missing, no changes
#
# Everything is idempotent and safe to re-run.
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/xenos_env.sh"
MODE="${1:-host}"

say()  { printf '\033[34m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[bootstrap]\033[0m %s\n' "$*"; }
die()  { printf '\033[31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 0. Detect the distribution / package manager
# ---------------------------------------------------------------------------
detect_pm() {
    if command -v apt-get    >/dev/null 2>&1; then echo apt;   return; fi
    if command -v dnf        >/dev/null 2>&1; then echo dnf;   return; fi
    if command -v pacman     >/dev/null 2>&1; then echo pacman;return; fi
    if command -v zypper     >/dev/null 2>&1; then echo zypper;return; fi
    if command -v apk        >/dev/null 2>&1; then echo apk;   return; fi
    if command -v brew       >/dev/null 2>&1; then echo brew;  return; fi
    echo none
}
PM="$(detect_pm)"

# Maps a logical host tool to the package name on each distro, plus a fallback
# (source-tarball / pip) so that as few tools as possible require root.
host_pkg() {  # host_pkg <toolname> -> echoes the package name (or empty)
    local t="$1"
    case "$PM:$t" in
        apt:nasm)      echo nasm ;;
        apt:binutils)  echo binutils ;;
        apt:e2fsprogs) echo e2fsprogs ;;      # mke2fs
        apt:xorrisofs) echo xorriso ;;
        apt:qemu)      echo qemu-system-x86 ;;
        apt:musl)      echo musl-tools ;;     # musl-gcc + libc.so
        apt:meson)     echo meson ;;
        apt:ninja)     echo ninja-build ;;
        apt:pkg-config) echo pkg-config ;;
        apt:autotools) echo autoconf automake libtool ;;
        apt:patch)     echo patch ;;
        apt:patchelf)  echo patchelf ;;
        dnf:nasm)      echo nasm ;;
        dnf:binutils)  echo binutils ;;
        dnf:e2fsprogs) echo e2fsprogs ;;
        dnf:xorrisofs) echo xorriso ;;
        dnf:qemu)      echo qemu-system-x86 ;;
        dnf:musl)      echo musl-devel ;;     # musl-gcc
        dnf:meson)     echo meson ;;
        dnf:ninja)     echo ninja-build ;;
        dnf:pkg-config) echo pkgconf-pkg-config ;;
        dnf:autotools) echo autoconf automake libtool ;;
        dnf:patch)     echo patch ;;
        dnf:patchelf)  echo patchelf ;;
        pacman:nasm)   echo nasm ;;
        pacman:binutils) echo binutils ;;
        pacman:e2fsprogs) echo e2fsprogs ;;
        pacman:xorrisofs) echo libisoburn ;;
        pacman:qemu)   echo qemu-system-x86 ;;
        pacman:musl)   echo musl ;;
        pacman:meson)  echo meson ;;
        pacman:ninja)  echo ninja ;;
        pacman:pkg-config) echo pkgconf ;;
        pacman:autotools) echo autoconf automake libtool ;;
        pacman:patch)  echo patch ;;
        pacman:patchelf) echo patchelf ;;
        zypper:nasm)   echo nasm ;;
        zypper:binutils) echo binutils ;;
        zypper:e2fsprogs) echo e2fsprogs ;;
        zypper:xorrisofs) echo xorriso ;;
        zypper:qemu)   echo qemu-x86 ;;
        zypper:musl)   echo musl-gcc ;;
        zypper:meson)  echo meson ;;
        zypper:ninja)  echo ninja ;;
        zypper:pkg-config) echo pkg-config ;;
        zypper:autotools) echo autoconf automake libtool ;;
        zypper:patch)  echo patch ;;
        zypper:patchelf) echo patchelf ;;
        apk:*)         echo "" ;;            # alpine: musl is the C lib by default; handled below
        brew:nasm)     echo nasm ;;
        brew:binutils) echo binutils ;;
        brew:e2fsprogs) echo e2fsprogs ;;
        brew:xorrisofs) echo xorriso ;;
        brew:qemu)     echo qemu ;;
        brew:musl)     echo filosottile/musl-cross/musl-cross ;; # provides musl-gcc
        brew:meson)    echo meson ;;
        brew:ninja)    echo ninja ;;
        brew:pkg-config) echo pkgconf ;;
        brew:autotools) echo autoconf automake libtool ;;
        brew:patch)    echo gpatch ;;
        brew:patchelf) echo patchelf ;;
        *)             echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# 1. Host Tools
# ---------------------------------------------------------------------------
HOST_TOLS=(nasm binutils e2fsprogs qemu pkg-config ninja meson autotools patch)
# xorrisofs / musl / patchelf are optional-ish: detected but skipped if absent.
OPT_TOLS=(xorrisofs musl patchelf)

toollist() { # resolve a logical tool group to concrete package names
    local -a out=() p
    for t in "$@"; do
        p="$(host_pkg "$t")"
        [ -n "$p" ] && out+=($p)
    done
    printf '%s\n' "${out[*]}"
}

# Map a logical tool group to a REPRESENTATIVE command for presence testing.
# (Distinct from host_pkg, which maps to the install package name.)
# e.g. binutils->objcopy, e2fsprogs->mke2fs, qemu->qemu-system-x86_64.
tool_cmd() {
    case "$1" in
        nasm) echo nasm ;;
        binutils) echo objcopy ;;
        e2fsprogs) echo mke2fs ;;
        qemu) echo qemu-system-x86_64 ;;
        pkg-config) echo pkg-config ;;
        ninja) echo ninja ;;
        meson) echo meson ;;
        autotools) echo autoconf ;;
        patch) echo patch ;;
        xorrisofs) echo xorrisofs ;;
        musl) echo musl-gcc ;;
        patchelf) echo patchelf ;;
        *) echo "$1" ;;
    esac
}

need_host() { # need_host <toolname>  -> echo MISSING|ok
    local c; c="$(tool_cmd "$1")"
    xenos_have "$c" && echo ok || echo MISSING
}

doctor() {
    say "distro/PM: ${PM:-none}"
    say "toolchain: $XENOS_TOOLCHAIN"
    for t in "${HOST_TOLS[@]}"; do  printf '  %-12s %-8s (%s)\n' "$t" "$(need_host "$t")" "$(tool_cmd "$t")"; done
    for t in "${OPT_TOLS[@]}"; do   printf '  %-12s %-8s (%s)\n' "$t (opt)" "$(need_host "$t")" "$(tool_cmd "$t")"; done
    printf '  %-12s %-8s\n' "c3c" "$(xenos_have c3c && echo ok || (printf MISSING))"
    exit 0
}
[ "$MODE" = doctor ] && doctor

install_host() {
    local -a missing=() p
    for t in "${HOST_TOLS[@]}"; do
        [ "$(need_host "$t")" = MISSING ] && missing+=("$t")
    done
    # optional tools: only those genuinely absent
    for t in "${OPT_TOLS[@]}"; do
        [ "$(need_host "$t")" = MISSING ] && missing+=("$t")
    done
    if [ "${#missing[@]}" -eq 0 ]; then
        say "all core host tools present; nothing to install."
        return 0
    fi

    # Build the concrete package list.
    local -a pkgs=()
    for t in "${missing[@]}"; do
        p="$(host_pkg "$t")"
        [ -n "$p" ] && pkgs+=($p)
    done

    if [ "$PM" = none ] || [ "${#pkgs[@]}" -eq 0 ]; then
        warn "no auto-installable package mapped for: ${missing[*]}"
        warn "install them yourself (see package hints in scripts/xenos_env.sh) then re-run."
        return 0
    fi

    say "installing via $PM: ${pkgs[*]}"
    local needed_sudo=""
    case "$PM" in
        apt)    if [ "$(id -u)" -eq 0 ]; then apt-get update -qq && apt-get install -y "${pkgs[@]}"
                else needed_sudo=1; fi ;;
        dnf)    if [ "$(id -u)" -eq 0 ]; then dnf install -y "${pkgs[@]}"
                else needed_sudo=1; fi ;;
        pacman) if [ "$(id -u)" -eq 0 ]; then pacman --noconfirm -Sy --needed "${pkgs[@]}"
                else needed_sudo=1; fi ;;
        zypper) if [ "$(id -u)" -eq 0 ]; then zypper --non-interactive install "${pkgs[@]}"
                else needed_sudo=1; fi ;;
        apk)    if [ "$(id -u)" -eq 0 ]; then apk add --no-cache "${pkgs[@]}" 2>/dev/null || apk add "${pkgs[@]}"
                else needed_sudo=1; fi ;;
        brew)   brew install "${pkgs[@]}" ;;
    esac
    if [ -n "$needed_sudo" ]; then
        warn "running as a normal user; run this to finish the host install:"
        case "$PM" in
            apt)    echo "  sudo apt-get update && sudo apt-get install -y ${pkgs[*]}" ;;
            dnf)    echo "  sudo dnf install -y ${pkgs[*]}" ;;
            pacman) echo "  sudo pacman --noconfirm -Syu --needed ${pkgs[*]}" ;;
            zypper) echo "  sudo zypper --non-interactive install ${pkgs[*]}" ;;
            apk)    echo "  sudo apk add --no-cache ${pkgs[*]}" ;;
        esac
    fi
}

# ---------------------------------------------------------------------------
# 2. C3 compiler (project-local, no root)
# ---------------------------------------------------------------------------
install_c3c() {
    if xenos_have c3c || [ -x "$XENOS_BIN/c3c" ]; then
        say "c3c already available: ${HOST_PATH:-$XENOS_BIN/c3c}"
        return 0
    fi
    # Pin the same release CI uses.
    local ver="${C3C_VERSION:-0.8.3}"
    say "installing c3c $ver into $XENOS_BIN ..."
    command -v curl >/dev/null 2>&1 || die "curl is required to fetch c3c; install it first."
    local url="https://github.com/c3lang/c3c/releases/download/v${ver}/c3-linux.tar.gz"
    local tmp; tmp="$(mktemp -d)"
    curl -fsSL "$url" | tar -xz -C "$tmp"
    # The archive contains a top-level dir with c3c inside (c3-linux/...).
    find "$tmp" -type f -name c3c -exec install -Dm755 {} "$XENOS_BIN/c3c" \; 2>/dev/null \
        && [ -x "$XENOS_BIN/c3c" ] || { warn "could not locate c3c binary in release tarball; set C3C_VERSION or install manually"; rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    say "c3c installed: $("$XENOS_BIN/c3c" --version 2>/dev/null | head -1 || true)"
}

# ---------------------------------------------------------------------------
# 3. Cross-MUSL sysroot (userspace deps) — heavy; only on explicit request.
# ---------------------------------------------------------------------------
provision_sysroot() {
    local pkg="${1:-all}"
    say "cross-build userspace sysroot @ $XENOS_CROSSROOT (this takes a while) ..."
    xenos_require musl-gcc "musl dev package (musl-tools/musl/musl-gcc)"
    xenos_require meson pkg-config ninja autotools
    bash scripts/crossbuild_deps.sh "$pkg"
    bash scripts/crossbuild_shared.sh all
    say "sysroot provisioned."
}

case "$MODE" in
    doctor)     doctor ;;
    host|tools) install_host; install_c3c ;;
    sysroot)    install_c3c; provision_sysroot "${2:-all}" ;;
    all)        install_host; install_c3c; provision_sysroot "${2:-all}" ;;
    *) die "unknown mode: $MODE (use: host | sysroot | all | doctor)" ;;
esac

say "done."
say "next:  ./build.sh   (or  ./run.sh after a successful build)"