;==============================================================================
; xenOS - low-level assembly runtime (hand-written).
; Exposes C3-callable helpers for things that C3 inline asm cannot express.
; x86_64 System V ABI: int args in rdi,rsi,rdx; integer return in rax/eax/al.
;==============================================================================
[BITS 64]
default rel
global xk_outb, xk_inb, xk_io_wait, xk_outl, xk_inl
global xk_cli, xk_sti, xk_hlt, xk_pause
global xk_lgdt, xk_lidt, xk_ltr
global xk_read_cr2, xk_read_cr3
global xk_rdtsc

section .text

; void xk_outb(uint port, char val)        port=rdi, val=sil
xk_outb:
    mov dx, di
    mov al, sil
    out dx, al
    ret

; char xk_inb(uint port) -> al
xk_inb:
    mov dx, di
    in al, dx
    ret

; ushort xk_inw(uint port) -> ax (16-bit read; used for ATA data transfers)
global xk_inw
xk_inw:
    mov dx, di
    in ax, dx
    ret

; void xk_outl(uint port, uint val)
xk_outl:
    mov dx, di
    mov eax, esi
    out dx, eax
    ret

; uint xk_inl(uint port)
xk_inl:
    mov dx, di
    in eax, dx
    ret

; void xk_io_wait(void)  -- brief dummy write to port 0x80
xk_io_wait:
    mov al, 0
    out 0x80, al
    ret

xk_cli:
    cli
    ret

xk_sti:
    sti
    ret

xk_hlt:
    hlt
    ret

xk_pause:
    pause
    ret

; void xk_lgdt(ulong base, ushort limit)
xk_lgdt:
    mov rax, rdi
    mov word [.gdt_lim], si
    mov qword [.gdt_base], rax
.lgdt:
    lgdt [.gdt]
    ret
section .data
align 16
.gdt:
    .gdt_lim: dw 0
    .gdt_base: dq 0
section .text

; void xk_lidt(ulong base, ushort limit)
xk_lidt:
    mov rax, rdi
    mov word [.idt_lim], si
    mov qword [.idt_base], rax
.lidt:
    lidt [.idt]
    ret
section .data
align 16
.idt:
    .idt_lim: dw 0
    .idt_base: dq 0
section .text

; void xk_ltr(ushort selector)
xk_ltr:
    mov ax, di
    ltr ax
    ret

; ulong xk_read_cr2(void)
xk_read_cr2:
    mov rax, cr2
    ret

; ulong xk_read_cr3(void)
xk_read_cr3:
    mov rax, cr3
    ret

; void xk_set_cr3(ulong value)   -- load CR3 (switch address space) + flush TLB
global xk_set_cr3
xk_set_cr3:
    mov cr3, rdi
    ret

; ulong xk_rdtsc(void)
xk_rdtsc:
    rdtsc
    shl rdx, 32
    or rax, rdx
    ret

; ulong xk_get_ticks(void)
; Returns the kernel tick counter (g_ticks). Read through a real asm call so that
; busy-loop code cannot have the C3 compiler hoist the load as a loop-invariant
; (the value is updated from an ISR at any moment).
extern xk.g_ticks
global xk_get_ticks
xk_get_ticks:
    mov rax, [rel xk.g_ticks]
    ret

; uint xk_mmio_read32(ulong addr) / void xk_mmio_write32(ulong addr, uint val)
; Memory-mapped I/O (device registers). Done in asm so device-status reads in a
; busy-wait cannot be hoisted out of the loop by the C3 compiler.
global xk_mmio_read32
xk_mmio_read32:
    mov eax, [rdi]
    ret
global xk_mmio_write32
xk_mmio_write32:
    mov [rdi], esi
    ret

;==============================================================================
; Interrupt Service Routines (hand-written).
; Each vector has a stub that arranges [vector][error_code] on the stack and
; jumps to isr_common, which saves the GPR set, calls the C handler
; xk_handle_isr(IntFrame*), restores, and iretq.
;==============================================================================
extern xk_handle_isr
extern xk_linux_dispatch

%macro ISR_NOERR 1
global isr_stub_%1
isr_stub_%1:
    push qword 0            ; dummy error code
    push qword %1           ; vector number
    jmp isr_common
%endmacro

%macro ISR_ERR 1            ; CPU already pushed a real error code
global isr_stub_%1
isr_stub_%1:
    push qword %1           ; vector number sits on top of the error code
    jmp isr_common
%endmacro

section .text
global isr_common
isr_common:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    mov rdi, rsp            ; frame ptr
    call xk_handle_isr

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    add rsp, 16             ; drop vector + error code
    iretq

; Emit stubs for vectors 0..47 (exceptions 0-31, IRQs 32-47).
%assign vec 0
%rep 48
    %if vec = 8 || vec = 10 || vec = 11 || vec = 12 || vec = 13 || vec = 14 || vec = 17 || vec = 30
        ISR_ERR vec
    %else
        ISR_NOERR vec
    %endif
%assign vec vec+1
%endrep

; System-call gate: INT 0x80 (vector 128).
global isr_stub_128
isr_stub_128:
    push qword 0
    push qword 128
    jmp isr_common

; Stub address table so C3 can build the IDT.
section .data
align 16
global stub_table
stub_table:
%assign vec 0
%rep 48
    dq isr_stub_%+vec
%assign vec vec+1
%endrep
    dq isr_stub_128       ; vector 128 (INT 0x80) -> table index 48

section .text
; ulong* xk_get_stub_table(void)
global xk_get_stub_table
xk_get_stub_table:
    mov rax, stub_table
    ret

; ulong xk_get_bss_start(void) / ulong xk_get_bss_end(void)
extern __bss_start, __bss_end
global xk_get_bss_start, xk_get_bss_end
xk_get_bss_start:
    mov rax, __bss_start
    ret
xk_get_bss_end:
    mov rax, __bss_end
    ret

;==============================================================================
; Cooperative context switch.  void xk_switch(ulong* cur_slot, ulong new_sp)
; rdi = address of a slot to save the CURRENT rsp into.
; rsi = stack pointer value of the task to resume.
; Saves callee-saved regs on the current stack, swaps rsp, restores callee-saved,
; then ret (jumps to wherever the resumed task was switched out, or to a crafted
; initial frame).  The popped frame layout (stack grows down) is:
;   [0]=r15 [1]=r14 [2]=r13 [3]=r12 [4]=rbp [5]=rbx [6]=return address
;==============================================================================
global xk_switch
xk_switch:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov [rdi], rsp          ; save current task's stack pointer into *cur_slot
    mov rsp, rsi            ; load the next task's stack pointer
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; ulong xk_syscall(ulong n, ulong a, ulong b, ulong c)
; ABI into INT 0x80: rax=n, rbx=a, rcx=b, rdx=c; result back in rax.
; rbx is CALLEE-SAVED, so save/restore the caller's value (the asm gate only
; restores the value we set, not the caller's).
global xk_syscall
xk_syscall:
    push rbx              ; preserve the caller's rbx
    mov rax, rdi          ; n
    mov rbx, rsi          ; a
    mov r9,  rdx          ; save b
    mov rdx, rcx          ; c -> rdx
    mov rcx, r9           ; b -> rcx
    int 0x80
    pop rbx               ; restore the caller's rbx
    ret

;==============================================================================
; void xk_enter_ring3(ulong entry, ulong user_sp)
; iretq from ring 0 to ring 3, dropping into `entry` with user stack `user_sp`.
; Segment selectors: 0x2B = user code64 (idx5)|3, 0x33 = user data64 (idx6)|3.
global xk_enter_ring3
xk_enter_ring3:
    mov rax, rdi          ; entry (rip)
    mov rcx, rsi          ; user stack pointer (rsp)
    mov r11, 0x202        ; rflags: IF on, reserved bits
    push 0x33             ; SS  (user data, RPL3) -- deepest
    push rcx              ; RSP (user stack)
    push r11              ; RFLAGS
    push 0x2B             ; CS  (user code, RPL3)
    push rax              ; RIP (entry) -- top
    iretq
    hlt                   ; never reached

; Flush the entire TLB by reloading CR3.
global xk_reload_cr3
xk_reload_cr3:
    mov rax, cr3
    mov cr3, rax
    ret

; void xk_iret_ring0(ulong target)
; Build a clean same-privilege ring-0 iretq frame (RIP,CS=0x18,RFLAGS) and
; iretq into `target` on the current (kernel) stack. NEVER returns.
global xk_iret_ring0
xk_iret_ring0:
    mov rax, rdi          ; target (rip)
    push 0x202            ; rflags (IF on) -- deepest
    push 0x18             ; ring-0 code64 cs
    push rax              ; rip -- top
    iretq
    hlt                   ; never reached

; void xk_set_ssdata(void)
; Force SS to the flat kernel DATA selector (0x20). The desktop loop is entered
; from the ring-3 SYS_EXIT path without a proper ring-0 iretq, which can leave a
; NULL SS; a valid SS is required so that iretq (in xk_preempt) treats the return
; as same-ring (3-word frame) instead of attempting a privilege change.
global xk_set_ssdata
xk_set_ssdata:
    mov ax, 0x20
    mov ss, ax
    ret

;==============================================================================
;==============================================================================
; Linux syscall ABI entry point for the SYSCALL instruction (MSR LSTAR).
; A ring-3 Linux userland binary does `syscall` with Linux syscall numbers.
; On entry the CPU has: RAX=nr, RDI/RSI/RDX/R10/R8/R9=args, RCX=return RIP,
; R11=return RFLAGS. SYSCALL does NOT switch the stack, so we save the user
; RSP, switch to a dedicated kernel syscall stack, dispatch to the C handler
; xk_linux_dispatch, then return via sysretq (which uses RCX/R11).
;==============================================================================
section .bss
align 16
syscall_kstack:
    resb 16384
global syscall_kstack_top
syscall_kstack_top:
section .data
align 16
global xk_syscall_user_rsp
xk_syscall_user_rsp: dq 0
section .text

global syscall_entry
syscall_entry:
    mov [rel xk_syscall_user_rsp], rsp    ; stash the user stack
    lea rsp, [rel syscall_kstack_top]     ; switch to the kernel syscall stack
    push r11                              ; return RFLAGS (deepest)
    push rcx                              ; return RIP
    push r9                               ; a6
    push r8                               ; a5
    push r10                              ; a4
    push rdx                              ; a3
    push rsi                              ; a2
    push rdi                              ; a1
    ; rsp -> [a1][a2][a3][a4][a5][a6][rcx][r11]
    mov rdi, rax                          ; arg1 = syscall number
    mov rsi, rsp                          ; arg2 = pointer to the arg block
    call xk_linux_dispatch                ; ulong xk_linux_dispatch(nr, ulong* a)
    add rsp, 48                           ; pop a1..a6 (6*8)
    pop rcx                               ; return RIP
    pop r11                               ; return RFLAGS
    ; Return to ring 3 with a crafted iretq frame (same mechanism as
    ; xk_enter_ring3, proven reliable on QEMU). QEMU 11's `sysret` does not
    ; reliably land at RCX, so we avoid it.
    push 0x33                             ; SS  (user data, RPL3)
    push qword [rel xk_syscall_user_rsp]  ; RSP (user stack)
    push r11                              ; RFLAGS
    push 0x2B                             ; CS  (user code, RPL3)
    push rcx                              ; RIP
    iretq
    hlt

; void xk_linux_syscall_init(void)
; Program the MSRs so the SYSCALL/SYSRET pairing works from ring 3.
;   EFER.SCE=1, STAR, LSTAR=syscall_entry, SFMASK=mask IF in kernel.
; xenOS selectors: kernel code64=0x18, kernel data64=0x20,
; user code64=0x28, user data64=0x30.
global xk_linux_syscall_init
xk_linux_syscall_init:
    mov ecx, 0xC0000080                    ; EFER
    rdmsr
    or eax, 1                              ; SCE
    wrmsr
    mov ecx, 0xC0000081                    ; STAR
    mov eax, 0x00000000
    mov edx, 0x00180028                    ; [63:48]=kernel cs 0x18, [47:32]=user cs 0x28
    wrmsr
    mov ecx, 0xC0000082                    ; LSTAR
    lea rax, [rel syscall_entry]
    mov rdx, 0
    wrmsr
    mov ecx, 0xC0000084                    ; SFMASK
    mov eax, 0x200                         ; mask IF while in the kernel
    mov edx, 0
    wrmsr
    ret

; ulong xk_rdmsr(uint msr)
global xk_rdmsr
xk_rdmsr:
    mov ecx, edi
    rdmsr
    shl rdx, 32
    or rax, rdx
    ret

; void xk_wrmsr(uint msr, ulong value)
global xk_wrmsr
xk_wrmsr:
    mov ecx, edi
    mov rax, rsi
    mov rdx, rsi
    shr rdx, 32
    wrmsr
    ret

; void xk_enable_sse(void)
; Let ring-3 Linux binaries use SSE/SSE2 (musl's stdio/memcpy rely on it).
; Reset leaves CR4.OSFXSR=0, so every SSE instruction #UDs until the OS sets it.
; Set CR4.OSFXSR (bit9) + OSXMMEXCPT (bit10). CR0 is left as the boot value.
global xk_enable_sse
xk_enable_sse:
    mov rax, cr4
    or  rax, ((1 << 9) | (1 << 10))   ; OSFXSR | OSXMMEXCPT
    mov cr4, rax
    ret

; Resume a task from its OWN real interrupt frame (created by isr_common on a
; genuine timer interrupt). This is exactly the tail of isr_common: load rsp
; to point at the frame's GPR region, pop the 15 GPRs, skip vector+error, then
; iretq back to the point where the task was interrupted. Because the frame was
; produced by the CPU on a real ring-0 interrupt, this same-ring iretq behaves
; correctly under QEMU (unlike a hand-crafted frame, which QEMU 11's iretq
; rejects). Never returns.
;   void xk_preempt_resume(ulong frame)   -- frame in rdi
;==============================================================================
global xk_preempt_resume
xk_preempt_resume:
    mov rsp, rdi          ; point at the frame's [r15] slot
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    add rsp, 16           ; skip vector + error_code
    iretq