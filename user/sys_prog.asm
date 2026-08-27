; ============================================================================
; xenOS ring-3 user program (assembled to a flat binary, embedded in the
; kernel, copied to a user-mapped page at load). Runs at CPL 3 and talks to
; the kernel only through INT 0x80 syscalls.
;   rax=10 -> SYS_UMSG   (kernel prints a "from ring 3" line)
;   rax=99 -> SYS_UNKNOWN (kernel MUST reject; demonstrates protection)
;   rax=12 -> SYS_EXIT   (return to ring-0 and resume the desktop)
; ============================================================================
[BITS 64]
_start:
    mov rax, 10             ; syscall #1: SYS_UMSG
    int 0x80
    mov rax, 99             ; attempt an unknown syscall (kernel rejects it)
    int 0x80
    mov rax, 10             ; syscall #2: SYS_UMSG
    int 0x80
    mov rax, 12             ; SYS_EXIT -> back to ring 0, resume the desktop
    int 0x80
    jmp _start              ; unreachable after SYS_EXIT