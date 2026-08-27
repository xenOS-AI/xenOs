; ============================================================================
; xenOS ring-3 user program (flat binary embedded in the kernel, copied to a
; user-mapped page, run at CPL 3). Talks to the kernel only through INT 0x80.
;   rax=10 -> SYS_UMSG    (kernel prints "from ring 3")
;   rax=99 -> SYS_UNKNOWN (kernel MUST reject; protection demo)
;   rax=20 -> SYS_RESULT  (arg1 = a value the ring-3 program computed)
;   rax=12 -> SYS_EXIT    (return to ring-0 and resume the desktop)
; Then it deliberately writes a kernel page (0x100000), which ring-3 is not
; allowed to touch -> #PF -> the kernel terminates the program.
; ============================================================================
[BITS 64]
_start:
    mov rax, 10             ; SYS_UMSG
    int 0x80
    mov rax, 99             ; unknown syscall -> kernel rejects
    int 0x80
    mov rax, 10             ; SYS_UMSG
    int 0x80

    ; ---- real work at ring 3: sum 1..100 = 5050 ----
    xor rbx, rbx            ; rbx = running sum (also arg1 for SYS_RESULT)
    mov rcx, 1
.sum:
    add rbx, rcx
    inc rcx
    cmp rcx, 100
    jle .sum
    mov rax, 20             ; SYS_RESULT(arg1=rbx) -> kernel prints the value
    int 0x80

    ; ---- memory-protection demo: write a kernel (supervisor) page ----
    mov rax, 0x100000
    mov byte [rax], 0xEE    ; CPL3 cannot -> #PF -> kernel terminates program

    mov rax, 12             ; SYS_EXIT (unreachable if the write #PFs)
    int 0x80
    jmp _start