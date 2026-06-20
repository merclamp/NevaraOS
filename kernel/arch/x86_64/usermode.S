/* usermode.S — ring 3 entry/exit and the SYSCALL instruction handler.
 *
 * Single-task model for now: one kernel syscall stack, saved kernel context for
 * returning to the kernel when the user program exits.
 */

.section .bss
.align 16
.global kernel_rsp
kernel_rsp:        .quad 0   /* kernel stack used while servicing a syscall */
.global user_rsp
user_rsp:          .quad 0   /* scratch: user rsp saved across a syscall      */
.global kernel_saved_rsp
kernel_saved_rsp:  .quad 0   /* kernel context to resume when the user exits  */
.align 16
syscall_stack:     .skip 16384
.global syscall_stack_top
syscall_stack_top:

.section .text

/* SYSCALL entry. On entry: rax=number, rdi/rsi/rdx/r10=args, rcx=return rip,
 * r11=saved rflags. The CPU does NOT switch stacks, so we do it manually. */
.global syscall_entry
.type syscall_entry, @function
syscall_entry:
    movq %rsp, user_rsp(%rip)
    movq kernel_rsp(%rip), %rsp

    /* Preserve the registers the Linux syscall ABI keeps across a syscall
     * (everything except rax/rcx/r11), plus rcx/r11 for sysret. */
    pushq %rcx
    pushq %r11
    pushq %rdi
    pushq %rsi
    pushq %rdx
    pushq %r10
    pushq %r8
    pushq %r9

    /* Reorder into the SysV C arguments of syscall_dispatch(num,a1,a2,a3):
     *   rdi=num(rax), rsi=a1(rdi), rdx=a2(rsi), rcx=a3(rdx). */
    movq %rdx, %rcx
    movq %rsi, %rdx
    movq %rdi, %rsi
    movq %rax, %rdi
    call syscall_dispatch     /* return value (isize) in rax */

    popq %r9
    popq %r8
    popq %r10
    popq %rdx
    popq %rsi
    popq %rdi
    popq %r11
    popq %rcx
    movq user_rsp(%rip), %rsp
    sysretq

/* void enter_user(uint64_t entry /rdi/, uint64_t user_stack_top /rsi/);
 * Saves the kernel context so the exit path can return here, then iretq's to
 * ring 3. */
.global enter_user
.type enter_user, @function
enter_user:
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq %rsp, kernel_saved_rsp(%rip)

    movw $0x1B, %ax    /* user data selector (RPL 3) */
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs

    pushq $0x1B        /* SS  = user data    */
    pushq %rsi         /* RSP = user stack   */
    pushq $0x202       /* RFLAGS (IF set)    */
    pushq $0x23        /* CS  = user code    */
    pushq %rdi         /* RIP = entry        */
    iretq

/* void return_to_kernel(int code /rdi/) — restore the kernel context saved by
 * enter_user and return to its caller. Invoked from the exit syscall. */
.global return_to_kernel
.type return_to_kernel, @function
return_to_kernel:
    movq kernel_saved_rsp(%rip), %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    ret
