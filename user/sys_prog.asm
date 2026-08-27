; ============================================================================
; xenOS ring-3 user program (assembled to a flat binary, embedded in the
; kernel, copied to a user-mapped page at load). Runs at CPL 3 and talks to
; the kernel only through INT 0x80 syscalls.
;   rax=10 -> SYS_UMSG    (kernel prints a "from ring 3" line)
;   rax=99 -> SYS_UNKNOWN (kernel MUST reject; demonstrates protection)
;   rax=12 -> SYS_EXIT    (return to ring-0 and resume the desktop)
; After the syscalls it deliberately writes to the kernel image page at
; 0x100000, which ring-3 is not allowed to touch -> #PF -> the kernel
; terminates the program (memory-protection demo).
; ============================================================================
[BITS 64]
_start:
    mov rax, 10             ; syscall #1: SYS_UMSG
    int 0x80
    mov rax, 99             ; attempt an unknown syscall (kernel rejects it)
    int 0x80
    mov rax, 10             ; syscall #2: SYS_UMSG
    int 0x80

    ; ---- memory-protection demo: write to a kernel (supervisor) page ----
    mov rax, 0x100000       ; kernel image start (supervisor in user page tables)
    mov byte [rax], 0xEE    ; CPL3 cannot -> #PF -> kernel terminates the program

    mov rax, 12             ; SYS_EXIT (unreachable if the write #PFs)
    int 0x80
    jmp _start