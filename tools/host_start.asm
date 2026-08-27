; ============================================================================
; xenOS host-tool runtime for the freestanding C3 build tools (no libc).
; Provides:
;   _start        : Linux ELF entry — pulls argc/argv off the initial stack,
;                   calls the C3 xk_host_main(argc, argv), then sys_exit.
;   lx_syscall    : generic Linux syscall helper used by the C3 tool.
; ============================================================================
[BITS 64]
global _start
extern xk_host_main

_start:
    mov rdi, [rsp]      ; argc
    lea rsi, [rsp+8]    ; argv
    xor rdx, rdx
    call xk_host_main
    mov edi, eax        ; exit code
    mov eax, 60         ; sys_exit
    syscall

; long lx_syscall(long n, long a, long b, long c, long d)
; Linux syscall ABI: rax=n, rdi, rsi, rdx, r10, r8, r9.
global lx_syscall
lx_syscall:
    mov rax, rdi        ; n
    mov rdi, rsi        ; a
    mov rsi, rdx        ; b
    mov rdx, rcx        ; c
    mov r10, r8         ; d
    syscall
    ret