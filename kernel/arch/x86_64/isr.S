/* isr.S — interrupt service routine stubs for CPU exceptions (vectors 0..31).
 *
 * Each stub normalizes the stack to (error_code, vector) then jumps to a common
 * path that saves all general registers, calls the Zig handler with a pointer to
 * the saved frame, restores, and `iretq`s.
 */

.section .text

/* Stub for vectors that do NOT push a hardware error code. */
.macro ISR_NOERR num
.global isr\num
.type isr\num, @function
isr\num:
    pushq $0          /* dummy error code, keeps frame layout uniform */
    pushq $\num
    jmp isr_common
.endm

/* Stub for vectors that DO push a hardware error code. */
.macro ISR_ERR num
.global isr\num
.type isr\num, @function
isr\num:
    pushq $\num
    jmp isr_common
.endm

/* x86_64 vectors that push an error code: 8,10,11,12,13,14,17,21,29,30 */
ISR_NOERR 0
ISR_NOERR 1
ISR_NOERR 2
ISR_NOERR 3
ISR_NOERR 4
ISR_NOERR 5
ISR_NOERR 6
ISR_NOERR 7
ISR_ERR   8
ISR_NOERR 9
ISR_ERR   10
ISR_ERR   11
ISR_ERR   12
ISR_ERR   13
ISR_ERR   14
ISR_NOERR 15
ISR_NOERR 16
ISR_ERR   17
ISR_NOERR 18
ISR_NOERR 19
ISR_NOERR 20
ISR_ERR   21
ISR_NOERR 22
ISR_NOERR 23
ISR_NOERR 24
ISR_NOERR 25
ISR_NOERR 26
ISR_NOERR 27
ISR_NOERR 28
ISR_ERR   29
ISR_ERR   30
ISR_NOERR 31

isr_common:
    cld
    /* Save general-purpose registers. Pushed last = lowest address, so the
     * struct in Zig lists r15 first. */
    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    /* arg0 = pointer to the interrupt frame (current rsp). */
    movq %rsp, %rdi

    /* 16-byte align the stack for the SysV call. rbp is callee-saved by the
     * Zig handler, and its saved copy is on the stack, so we can use it as a
     * scratch base and restore rsp afterwards. */
    movq %rsp, %rbp
    andq $-16, %rsp
    call isrHandler
    movq %rbp, %rsp

    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rbx
    popq %rax

    addq $16, %rsp    /* drop vector + error code */
    iretq

/* Table of stub addresses so Zig can install them without 32 extern decls. */
.section .rodata
.align 8
.global isr_stub_table
isr_stub_table:
    .quad isr0,  isr1,  isr2,  isr3,  isr4,  isr5,  isr6,  isr7
    .quad isr8,  isr9,  isr10, isr11, isr12, isr13, isr14, isr15
    .quad isr16, isr17, isr18, isr19, isr20, isr21, isr22, isr23
    .quad isr24, isr25, isr26, isr27, isr28, isr29, isr30, isr31
