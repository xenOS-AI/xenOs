#!/usr/bin/env bash
# Host-side unit test runner for the freestanding C3 components.
# Reuses the project's C3 self-test executables rather than adding a libc test
# framework; their output is asserted so diagnostics cannot silently pass.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${XENOS_TEST_OUT:-$ROOT/build/tests}"
CC="${C3C:-c3c}"

require_command() {
    command -v "$1" >/dev/null 2>&1 || { echo "error: required command not found: $1" >&2; exit 127; }
}
require_command "$CC"; require_command nasm; require_command ld; require_command mke2fs
rm -rf "$OUT"; mkdir -p "$OUT/hostobj" "$OUT/logs"

build_host_tool() {
    local name="$1" obj
    rm -rf "$OUT/hostobj/obj"
    ( cd "$OUT/hostobj" && "$CC" compile-only --no-entry --use-stdlib=no --x86cpu=baseline --x86vec=none -O2 -g0 "$ROOT/tools/$name.c3" )
    obj="$(find "$OUT/hostobj/obj" -name "$name.o" -print -quit)"
    [[ -n "$obj" ]] || { echo "error: C3 object for $name was not produced" >&2; exit 1; }
    ld -m elf_x86_64 -o "$OUT/$name" "$obj" "$OUT/host_start.o"
}
run_and_require() { local name="$1"; shift; "$@" >"$OUT/logs/$name.log"; }
require_line() {
    local name="$1" expected="$2"
    # Some freestanding tools use explicit byte counts and deliberately do not
    # rely on libc line buffering, so a banner may share a line with a result.
    grep -Fq "$expected" "$OUT/logs/$name.log" || { echo "FAIL: $name did not emit: $expected" >&2; cat "$OUT/logs/$name.log" >&2; exit 1; }
}

echo "[test] assembling the freestanding C3 host runtime"
nasm -f elf64 -o "$OUT/host_start.o" "$ROOT/tools/host_start.asm"
echo "[test] compiling every kernel module (compile-only)"
mkdir -p "$OUT/kernel"
( cd "$OUT/kernel" && "$CC" compile-only --target elf-x64 --no-entry --use-stdlib=no --x86cpu=baseline --x86vec=none -O2 -g0 "$ROOT"/kernel/src/*.c3 )
for tool in sha256_test aesgcm_test p256_test ext4read; do echo "[test] building $tool"; build_host_tool "$tool"; done

echo "[test] SHA-256 known-answer vectors"
run_and_require sha256 "$OUT/sha256_test"
require_line sha256 "empty    = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
require_line sha256 "abc      = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
require_line sha256 "multi    = 248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
require_line sha256 "exactly1 = cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
require_line sha256 "100a     = 2816597888e4a0d3a36b82b83316ab32680eb8f00f8cd3b904d681246d285a0e"
require_line sha256 "59b      = 793594471f7f3a6d6aeb73418ae019ea2dba4c11fe79d911037b97d00e3ce97a"

echo "[test] AES-GCM known-answer vectors"
run_and_require aesgcm "$OUT/aesgcm_test"
require_line aesgcm "EMPTY TAG = 58e2fccefa7e3061367f1d57a4e7455a"
require_line aesgcm "AAD CT = 936da5cd621ef15343db6b813aae7e07"
require_line aesgcm "AAD TAG= 8e9598ce7d287ac83befba4da5ccc3f2"
require_line aesgcm "GFMUL = 50de34673808c92d9c7fdf6543998932"
require_line aesgcm "CT  = 42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091"
require_line aesgcm "TAG = cc15abcc191161501aabab46b8fbac85"

echo "[test] P-256 scalar multiplication and ECDH vectors"
run_and_require p256 "$OUT/p256_test"
require_line p256 "qxpd8cd12ea5c67f2f8a00c1124893edcfa6754c4d6cede6be13bdf2295c810a97f"
require_line p256 "qypa5a89d2d2a360c0ca9a4d6c7c9ed4b28d3e199d6627f2e696d689c310a5b0f48"
require_line p256 "shared_x=65f6f6b376a972fab4440c4ae044b99260a9aeacc537a3ed66961e1f6f713e3b"

echo "[test] ext4 reader fixture"
mkdir -p "$OUT/rootfs/usr/lib"
printf 'hello from ext4 rootfs xenOS\n' > "$OUT/rootfs/MOTD.TXT"
printf 'libwayland bytecheck\0\1\2\n' > "$OUT/rootfs/usr/lib/libwayland.so.0"
ln -s libwayland.so.0 "$OUT/rootfs/usr/lib/libwayland.so"
mke2fs -q -F -t ext4 -b 1024 -O '^has_journal,^metadata_csum,^64bit,^uninit_bg,^flex_bg,^dir_index,^sparse_super,^resize_inode,^extra_isize,^huge_file,^large_file,^ext_attr,^dir_nlink' -d "$OUT/rootfs" "$OUT/rootfs.ext4" 8192
run_and_require ext4 "$OUT/ext4read" "$OUT/rootfs.ext4"
require_line ext4 "MOTD.TXT bytes OK"; require_line ext4 "libwayland.so.0 bytes OK"
require_line ext4 "libwayland.so symlink OK"; require_line ext4 "absent path -> ENOENT"; require_line ext4 "ext4read PASS"
echo "PASS: all host-side C3 unit tests passed"
