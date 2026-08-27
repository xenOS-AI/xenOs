#!/usr/bin/env python3
"""xenOS disk-image assembler (build-time host tool).

Concatenates stage1 + stage2 + kernel into a bootable raw disk image and
patches the kernel's LBA + sector count into stage1's patch area.
Layout:
  LBA 0            : stage1 boot sector (512 B, 0xaa55 sig)
  LBA 1 ..         : stage2 (60 reserved sectors)
  LBA 61 ..        : kernel (patched sector count)
BootInfo is written by stage1 itself; nothing extra is needed here.
"""
import struct
import sys

SECTOR = 512
STAGE2_LBA = 1
STAGE2_SECTORS = 60
PATCH_LBA = 0x1E0
PATCH_SECTORS = 0x1E4

def align_up(n, a):
    return (n + a - 1) // a * a

def main():
    if len(sys.argv) != 5:
        print("usage: mkdisk.py stage1.bin stage2.bin kernel.bin out.img", file=sys.stderr)
        return 1
    s1 = open(sys.argv[1], 'rb').read()
    s2 = open(sys.argv[2], 'rb').read()
    k  = open(sys.argv[3], 'rb').read()

    assert len(s1) == SECTOR, "stage1 must be exactly one sector"
    assert s1[510:512] == b'\x55\xaa', "stage1 missing boot signature"

    # stage2 must fit in its reserved budget
    assert len(s2) <= STAGE2_SECTORS * SECTOR, "stage2 too big for its budget"
    # kernel size -> sector count
    ksize = align_up(len(k), SECTOR)
    ksect = ksize // SECTOR
    klba = STAGE2_LBA + STAGE2_SECTORS

    img = bytearray()
    img += s1
    img += s2 + bytes(STAGE2_SECTORS * SECTOR - len(s2))
    img += k + bytes(ksize - len(k))

    # patch stage1 fields
    struct.pack_into('<I', img, PATCH_LBA, klba)
    struct.pack_into('<I', img, PATCH_SECTORS, ksect)

    with open(sys.argv[4], 'wb') as f:
        f.write(bytes(img))
    print(f"mkdisk: kernel_lba={klba} sectors={ksect} image={len(img)}B")
    return 0

if __name__ == '__main__':
    sys.exit(main())