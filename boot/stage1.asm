;==============================================================================
; xenOS - Stage 1 bootloader (hand-written real-mode boot sector)
; Runs in real mode at 0x7C00.  512 bytes, 0xAA55 terminator.
;
;  1. init COM1 & trace to serial (debug)
;  2. set a VESA linear-framebuffer mode (1024x768x32, fallback 800x600x32)
;  3. write BootInfo @ phys 0x7000
;  4. load Stage2 (LBA 1..60) -> 0x8000, kernel (patched LBA) -> 0x100000
;  5. jump to stage2 (real mode)
;
; Patch area (filled by build tool):
;   0x1E0 dd KERNEL_LBA ; 0x1E4 dd KERNEL_SECTORS
;==============================================================================
[org 0x7c00]
[bits 16]

STAGE2_LBA     equ 1
STAGE2_SECTORS equ 60
STAGE2_ADDR    equ 0x8000
BOOTINFO       equ 0x7000
VBEBUF         equ 0x2000
COM1           equ 0x3f8
BI_FB_ADDR equ 0x7000 + 0x00
BI_WIDTH   equ 0x7000 + 0x08
BI_HEIGHT  equ 0x7000 + 0x0c
BI_PITCH   equ 0x7000 + 0x10
BI_BPP     equ 0x7000 + 0x14
BI_MEM_MB  equ 0x7000 + 0x18
BI_DRIVE   equ 0x7000 + 0x1c

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7c00
    mov [drive], dl
    call serial_init
    mov si, t_st
    call serial_puts

    call vbe_set_mode
    mov si, t_vbe
    call serial_puts

    ; ---- load stage2 (which pulls the kernel itself via its ATA driver) ----
    mov si, dap
    mov dword [dap+DAP_LBA], STAGE2_LBA
    mov dword [dap+DAP_COUNT], STAGE2_SECTORS
    mov word  [dap+DAP_OFF], STAGE2_ADDR
    mov word  [dap+DAP_SEG], 0x0000
    call load_file
    mov si, t_s2
    call serial_puts

    mov eax, [drive]
    mov [BI_DRIVE], eax

    mov si, t_jmp
    call serial_puts
    sti
    mov dl, [drive]
    jmp 0x0000:STAGE2_ADDR

;------------------------------------------------------------------------------
load_file:              ; int13h AH=42 LBA read via [dap]
;------------------------------------------------------------------------------
    mov ah, 0x42
    mov dl, [drive]
    int 0x13
    jnc .ok
    mov si, msg_err
    call print
    jmp hung
.ok: ret

;------------------------------------------------------------------------------
vbe_set_mode:           ; set 1024x768x32 LFB via the Bochs VBE IO interface
;------------------------------------------------------------------------------
    pushad
    ; zero bootinfo block
    mov edi, BOOTINFO
    xor eax, eax
    mov ecx, 8
    rep stosd

    ; VBE_DISPI registers via index port 0x1CE / data port 0x1CF
    ; 1) disable
    mov dx, 0x1CE
    mov ax, 0x0004
    out dx, ax
    mov dx, 0x1CF
    mov ax, 0x0000
    out dx, ax
    ; 2) X resolution
    mov dx, 0x1CE
    mov ax, 0x0001
    out dx, ax
    mov dx, 0x1CF
    mov ax, 800
    out dx, ax
    ; 3) Y resolution
    mov dx, 0x1CE
    mov ax, 0x0002
    out dx, ax
    mov dx, 0x1CF
    mov ax, 600
    out dx, ax
    ; 4) bits per pixel
    mov dx, 0x1CE
    mov ax, 0x0003
    out dx, ax
    mov dx, 0x1CF
    mov ax, 32
    out dx, ax
    ; 5) enable + linear framebuffer (bit0 enable, bit6 LFB)
    mov dx, 0x1CE
    mov ax, 0x0004
    out dx, ax
    mov dx, 0x1CF
    mov ax, 0x0041
    out dx, ax

    ; bootinfo (QEMU `-vga std` LFB at 0xFD000000; 800x600x32, pitch = width*4)
    mov dword [BI_FB_ADDR], 0xFD000000
    mov dword [BI_WIDTH], 800
    mov dword [BI_HEIGHT], 600
    mov dword [BI_PITCH], 3200
    mov dword [BI_BPP], 32
    mov dword [BI_MEM_MB], 96
    movzx eax, byte [drive]
    mov [BI_DRIVE], eax

    mov si, msg_vbe
    call print
    popad
    ret

;------------------------------------------------------------------------------
print:                  ; BIOS teletype, SI = NUL-terminated
;------------------------------------------------------------------------------
    pusha
.loop:
    lodsb
    test al, al
    jz .done
    mov ah, 0x0e
    mov bx, 0x0007
    int 0x10
    jmp .loop
.done: popa
    ret

hung:
    hlt
    jmp hung

;------------------------------------------------------------------------------
serial_init:            ; minimal COM1 init (QEMU ignores divisor)
;------------------------------------------------------------------------------
    pusha
    mov dx, COM1+1;      mov al, 0;   out dx, al
    mov dx, COM1+3;      mov al, 0x80;out dx, al
    mov dx, COM1+0;      mov al, 0x01;out dx, al
    mov dx, COM1+1;      mov al, 0x00;out dx, al
    mov dx, COM1+3;      mov al, 0x03;out dx, al
    mov dx, COM1+2;      mov al, 0xC7;out dx, al
    popa
    ret

serial_putc:
    push ax
    mov dx, COM1+5
.waittx:
    in al, dx
    test al, 0x20
    jz .waittx
    pop ax
    mov dx, COM1
    out dx, al
    ret

serial_puts:
    pusha
.loop:
    lodsb
    test al, al
    jz .done
    call serial_putc
    jmp .loop
.done: popa
    ret

;------------------------------------------------------------------------------
msg_vbe:   db "VESA OK",0
msg_novbe: db "NO VESA",0
msg_err:   db "DISK ERR",0
drive:     db 0

; stage-1 debug trace (short)
t_st:  db "[A]",0
t_vbe: db "[B]",0
t_s2:  db "[C]",0
t_k:   db "[D]",0
t_jmp: db "[E]",0

align 4
DAP_SIZE equ 0x10
DAP_COUNT equ 2
DAP_OFF   equ 4
DAP_SEG   equ 6
DAP_LBA   equ 8
dap:
    db 0x10, 0x00, 0,0, 0,0, 0,0,  0,0,0,0,0,0,0,0

; patch area @ 0x1E0
times 0x1e0-($-$$) db 0
kernel_lba:     dd 0
kernel_sectors: dd 0
times 0x1ec-($-$$) db 0
resv:           dd 0

times 510-($-$$) db 0
dw 0xaa55