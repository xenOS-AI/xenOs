/* xenOS kernel linker script: place image at 1 MiB, flat identity map.
   Output is objcopy'd to a raw binary and loaded by the bootloader at 0x100000. */
ENTRY(xk_main)

KERNEL_BASE = 0x100000;

SECTIONS
{
    . = KERNEL_BASE;

    .text : ALIGN(0x1000) {
        *(.text*)
    }
    .rodata : ALIGN(0x1000) {
        *(.rodata*)
    }
    .data : ALIGN(0x1000) {
        *(.data*)
    }
    .bss : ALIGN(0x1000) {
        __bss_start = .;
        *(COMMON)
        *(.bss*)
        __bss_end = .;
    }
    . = ALIGN(0x1000);
    __kernel_end = .;
    __kernel_size = __kernel_end - KERNEL_BASE;
}