;==============================================================================
; xenOS - Stage 2 bootloader  (hand-written long-mode trampoline)
; Loaded at 0x8000, entered from real mode. 
;
; Jobs:
;   1. Enable the A20 line.
;   2. Build a 0..4GiB identity map (2 MiB pages) at 0x9000.
;   3. Set up a GDT (32-bit + 64-bit selectors) at 0xE000.
;   4. Enable protected mode -> PAE -> long mode.
;   5. Jump to the C3 kernel entry: xk_main @ 0x100000.
;==============================================================================
[org 0x8000]
[bits 16]

PML4     equ 0x9000
PDPT     equ 0xA000
PD0      equ 0xB000
PD1      equ 0xC000
PD2      equ 0xD000
PD3      equ 0xE000
KERN_STACK equ 0x90000
KERN_ENTRY equ 0x100000

; The GDT lives just above the page tables, at 0xF000 (PD3 leaves 0xE000..0xEFFF).
GDTTGT  equ 0xF000
GDTSIZE equ 40              ; 5 selectors * 8 bytes

stage2:
    cli
    mov si, t_a
    call sprint
    ; ---- enable A20 ----
    in al, 0x92
    or al, 0x02
    out 0x92, al
    mov ax, 0x2401
    int 0x15
    ; (ignore errors; QEMU has A20 on by default)

    ; ---- build page tables: identity-map 0..4GiB over 2MiB pages ----
    ; PML4[0] -> PDPT
    mov dword [PML4], PDPT | 0x3
    ; PDPT[0..3] -> PD0..PD3
    mov dword [PDPT + 0x00], PD0 | 0x3
    mov dword [PDPT + 0x08], PD1 | 0x3
    mov dword [PDPT + 0x10], PD2 | 0x3
    mov dword [PDPT + 0x18], PD3 | 0x3
    ; fill the four PD tables with 2 MiB present|rw|ps entries
    mov ebx, PD0
    mov eax, 0x00000083          ; phys 0 | P|RW|PS
    mov ecx, 2048
.fill:
    mov [ebx], eax
    mov [ebx+4], dword 0
    add eax, 0x200000
    add ebx, 8
    loop .fill

    ; ---- build the GDT directly at 0xF000 (null, code32, data32, code64, data64) ----
    xor eax, eax
    mov dword [0xF000 + 0x00], eax          ; null
    mov dword [0xF000 + 0x04], eax
    mov dword [0xF000 + 0x08], 0x0000FFFF    ; 0x08 code32
    mov dword [0xF000 + 0x0c], 0x00CF9A00
    mov dword [0xF000 + 0x10], 0x0000FFFF    ; 0x10 data32
    mov dword [0xF000 + 0x14], 0x00CF9200
    mov dword [0xF000 + 0x18], 0x00000000    ; 0x18 code64
    mov dword [0xF000 + 0x1c], 0x00209A00
    mov dword [0xF000 + 0x20], 0x00000000    ; 0x20 data64
    mov dword [0xF000 + 0x24], 0x00009200

    ; trace
    mov si, t_b
    call sprint

    ; ---- load GDTR ----
    lgdt [gdtr]
    mov si, t_lg
    call sprint

    ; ---- enable protected mode ----
    mov eax, cr0
    or eax, 0x1
    mov cr0, eax
    mov si, t_pe
    call sprint
    jmp 0x08:pmode

[bits 32]
pmode:
    ; CRITICAL: set up flat data/stack segments FIRST. Before this, DS/SS
    ; still hold real-mode values (0 = null selector) and any memory or
    ; stack access (including a `call`) would #GP.
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax

    mov si, t_pm
    call sprint

    ; ---- load the kernel from disk straight to 0x100000 using our own
    ;      ATA PIO driver (no BIOS, no low-memory staging). ----
    mov eax, [0x7DE0]      ; kernel_lba  (patched by build tool into boot sector)
    mov ecx, [0x7DE4]      ; kernel_sectors
    mov edi, 0x100000
    call ata_read

    ; trace
    mov si, t_copy
    call sprint

    ; ---- enable PAE ----
    mov eax, cr4
    or eax, 0x20
    mov cr4, eax

    ; ---- load CR3 ----
    mov eax, PML4
    mov cr3, eax

    ; ---- enable EFER.LME for long mode ----
    mov ecx, 0xC0000080
    rdmsr
    or eax, 0x100
    wrmsr

    ; ---- enable paging -> long mode (still in 32-bit compat) ----
    mov eax, cr0
    or eax, 0x80000000
    mov cr0, eax

    ; far jump to 64-bit code segment
    jmp 0x18:lmode

;------------------------------------------------------------------------------
; ata_read - native PIO read of `ecx` 512-byte sectors starting at LBA `eax`
; into [ES:EDI].  Clobbers eax,ebx,ecx,esi,edi,dx.  Runs in protected mode.
;   ATA primary channel, master drive (0x1F0 base).
;------------------------------------------------------------------------------
[bits 32]
ata_read:
    ; eax = start LBA, ecx = sector count, edi = destination
    mov [.lba], eax
    mov [.count], ecx
    test ecx, ecx
    jz .err
    xor esi, esi
.outer:
    ; ---- program a single-sector 28-bit LBA read ----
.bsy0:
    mov dx, 0x1F7
    in al, dx
    test al, 0x80
    jnz .bsy0

    ; drive/head reg: 0xE0 | (LBA[27:24]&0xF)
    mov eax, [.lba]
    shr eax, 24
    and eax, 0x0F
    or eax, 0xE0
    mov dx, 0x1F6
    out dx, al
    ; sector count = 1
    mov al, 1
    mov dx, 0x1F2
    out dx, al
    ; LBA low 24 bits
    mov eax, [.lba]
    mov dx, 0x1F3
    out dx, al
    shr eax, 8
    mov dx, 0x1F4
    out dx, al
    shr eax, 8
    mov dx, 0x1F5
    out dx, al
    ; command = read sectors with retry (0x20)
    mov al, 0x20
    mov dx, 0x1F7
    out dx, al

    ; ---- wait for data ready ----
.wbsy:
    mov dx, 0x1F7
    in al, dx
    test al, 0x01
    jnz .err
    test al, 0x80
    jnz .wbsy
    test al, 0x08
    jz .wbsy

    ; ---- read one sector (256 words) ----
    mov ecx, 256
    mov dx, 0x1F0
    rep insw

    ; advance
    inc dword [.lba]
    inc esi
    cmp esi, [.count]
    jb .outer
    ret
.err:
    ; hang (trace-less) - serial not guaranteed here
.fail:
    hlt
    jmp .fail
section .data
align 4
.lba:   dd 0
.count: dd 0
section .text
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
    xor r8,  r8
    xor r9,  r9
    xor r10, r10
    xor r11, r11
    xor r12, r12
    xor r13, r13
    xor r14, r14
    xor r15, r15

    mov rsp, KERN_STACK
    mov si, t_lm
    call sprint
    call KERN_ENTRY            ; xk_main()

.hang:
    hlt
    jmp .hang

;==============================================================================
;==============================================================================
sprint:      ; print NUL-terminated string in SI to COM1.
; Works in real / protected / long mode (uses only mode-independent encodings).
; Clobbers: AH, AL, DX, SI.
;==============================================================================
.loop:
    lodsb                  ; AL = char, SI++
    test al, al
    jz .done
    mov ah, al             ; stash char
    xor dx, dx
    mov dh, 0x03
    mov dl, 0xFD           ; LSR 0x3FD
.wt:
    in al, dx
    test al, 0x20
    jz .wt
    mov al, ah
    xor dx, dx
    mov dh, 0x03
    mov dl, 0xF8           ; THR 0x3F8
    out dx, al
    jmp .loop
.done:
    ret

t_a: db "[2a]",0
t_b: db "[2b]",0
t_lg: db "[2c]",0
t_pe: db "[2d]",0
t_pm: db "[2e]",0
t_copy: db "[2f]",0
t_lm: db "[2g]",0

gdt_table:   ; copied to GDTTGT (0xF000) at boot
    dq 0x0000000000000000           ; 0x00 null
    dw 0xffff, 0x0000, 0x00, 0x9a, 0xcf, 0x00 ; 0x08 code32
    dw 0xffff, 0x0000, 0x00, 0x92, 0xcf, 0x00 ; 0x10 data32
    dw 0x0000, 0x0000, 0x00, 0x9a, 0x20, 0x00 ; 0x18 code64
    dw 0x0000, 0x0000, 0x00, 0x92, 0x00, 0x00 ; 0x20 data64

align 2
gdtr:
    dw GDTSIZE - 1
    dd GDTTGT

;==============================================================================
times 10000-($-$$) db 0       ; pad so stage2 fits its reserved sector budget