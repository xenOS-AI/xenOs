; xenOS El Torito no-emulation ISO boot loader.
; SeaBIOS loads the boot image at 0x7C00 and jumps to it with CS=0,EIP=0x7C00.
; We use DS=0 (flat) with [org 0x7C00] so labels == linear addresses, copy the
; embedded kernel to 0x100000, and enter long mode via flat code segments.
[bits 16]
[org 0x7C00]
KOFF       equ 0x400        ; kernel file offset within the boot image
HDRKLEN    equ 0x3F0        ; KLEN header file offset within the boot image
KERN_SRC   equ 0x8000       ; 0x7C00 + KOFF
KLEN_ADDR  equ 0x7FF0       ; 0x7C00 + HDRKLEN
GDTTGT     equ 0x78000
GDTSIZE    equ 40
PML4       equ 0x80000
PDPT       equ 0x81000
PD0        equ 0x82000
PD1        equ 0x83000
PD2        equ 0x84000
PD3        equ 0x85000
KERN_ENTRY equ 0x100000
KERN_STACK equ 0x90000

_start:
    cli
    xor ax, ax
    mov ds, ax               ; DS=0, flat: labels (=linear) resolve via DS
    mov es, ax
    in al, 0x92              ; A20
    or al, 0x02
    out 0x92, al
    ; copy GDT (at label gdt_table) to GDTTGT
    mov si, gdt_table
    mov ax, (GDTTGT >> 4)
    mov es, ax
    xor di, di
    mov cx, GDTSIZE / 2
    rep movsw
    lgdt [gdtr]
    ; protected mode (direct far jump: no memory operand, works with old CS)
    mov eax, cr0
    or eax, 0x1
    mov cr0, eax
    jmp 0x08:pmode
[bits 32]
pmode:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax
    ; identity-map 0-4GB with 2MB superpages
    mov dword [PML4], PDPT | 0x03
    mov dword [PDPT + 0x00], PD0 | 0x03
    mov dword [PDPT + 0x08], PD1 | 0x03
    mov dword [PDPT + 0x10], PD2 | 0x03
    mov dword [PDPT + 0x18], PD3 | 0x03
    mov ebx, PD0
    mov eax, 0x00000083
    mov ecx, 2048
.fill:
    mov [ebx], eax
    mov [ebx + 4], dword 0
    add eax, 0x200000
    add ebx, 8
    loop .fill

    mov esi, m_p0
    call sprint32

    ; copy the kernel (at KERN_SRC) to 0x100000; length at KLEN_ADDR
    mov esi, KERN_SRC
    mov edi, KERN_ENTRY
    mov edx, KLEN_ADDR
    mov ecx, [edx]
    rep movsb
    mov esi, m_p1
    call sprint32
    ; PAE, CR3, EFER.LME, CR0.PG
    mov eax, cr4
    or eax, 0x20
    mov cr4, eax
    mov eax, PML4
    mov cr3, eax
    mov ecx, 0xC0000080
    rdmsr
    or eax, 0x100
    wrmsr
    mov eax, cr0
    or eax, 0x80000000
    mov cr0, eax
    mov esi, m_p2
    call sprint32
    jmp 0x18:lmode

sprint32:                    ; esi = linear string address (ds flat)
    push eax
    push edx
.lp:
    mov al, [esi]
    test al, al
    jz .done
    mov edx, 0x3FD
.wt:
    in al, dx
    test al, 0x20
    jz .wt
    mov edx, 0x3F8
    mov al, [esi]
    out dx, al
    inc esi
    jmp .lp
.done:
    pop edx
    pop eax
    ret

[bits 64]
lmode:
    mov ax, 0x20
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax
    xor rax, rax
    xor rbx, rbx
    xor rcx, rcx
    xor rdx, rdx
    xor rsi, rsi
    xor rdi, rdi
    xor rbp, rbp
    mov rsp, KERN_STACK
    call KERN_ENTRY
.hang:
    hlt
    jmp .hang

; ---- data ----
gdt_table:
    dq 0
    db 0xff, 0xff, 0x00, 0x00, 0x00, 0x9a, 0xcf, 0x00 ; 0x08 code32
    db 0xff, 0xff, 0x00, 0x00, 0x00, 0x92, 0xcf, 0x00 ; 0x10 data32
    db 0x00, 0x00, 0x00, 0x00, 0x00, 0x9a, 0x20, 0x00 ; 0x18 code64
    db 0x00, 0x00, 0x00, 0x00, 0x00, 0x92, 0x00, 0x00 ; 0x20 data64

align 2
gdtr:
    dw GDTSIZE - 1
    dd GDTTGT

m_p0: db "[P0] ptab",13,10,0
m_p1: db "[P1] cpy",13,10,0
m_p2: db "[P2] lmode",13,10,0

; fixed header: [KLEN:dd][pad:dd] patched by the ISO tool
times HDRKLEN - ($ - $$) db 0
klen_hdr: dd 0xCAFEBABE
dd 0
times KOFF - ($ - $$) db 0