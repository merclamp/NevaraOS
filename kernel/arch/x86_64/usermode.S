/* usermode.S — ring 3 entry/exit and the SYSCALL handler.
 *
 * Multi-process model: every user process runs on its own kernel thread, so the
 * ring-0 syscall stack (kernel_rsp) is re-pointed by the scheduler on each
 * context switch. The SYSCALL handler saves a full trap frame and returns to
 * ring 3 via iretq, which also lets fork() resume a child from a copied frame.
 */

.section .bss
.align 16
.global kernel_rsp
kernel_rsp:        .quad 0   /* ring-0 syscall stack top of the running thread */
.global user_rsp
user_rsp:          .quad 0   /* scratch: user rsp during syscall entry         */

.section .text

/* Trap frame layout, low -> high address (matches usermode.zig TrapFrame):
 *   r15 r14 r13 r12 r11 r10 r9 r8 rbp rdi rsi rdx rcx rbx rax
 *   rip cs rflags rsp ss            (the iretq frame)                       */

.global syscall_entry
.type syscall_entry, @function
syscall_entry:
    movq %rsp, user_rsp(%rip)
    movq kernel_rsp(%rip), %rsp
    cld                        /* kernel string ops assume DF=0 */

    /* Build the iretq return frame from the SYSCALL-saved state. */
    pushq $0x1B                /* SS  = user data           */
    pushq user_rsp(%rip)       /* RSP = user stack          */
    pushq %r11                 /* RFLAGS (saved by syscall) */
    pushq $0x23                /* CS  = user code           */
    pushq %rcx                 /* RIP (saved by syscall)    */

    /* General-purpose register file (rax first => highest address). */
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

    movq %rsp, %rdi            /* arg0 = &TrapFrame */
    call syscall_from_user
    /* fall through to the return path */

/* Restore a trap frame from the current rsp and return to ring 3. */
.global trap_return
.type trap_return, @function
trap_return:
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
    iretq

/* void user_return(TrapFrame *tf /rdi/) noreturn — used by fork()'s child to
 * resume at the parent's syscall site with its own (rax=0) frame. */
.global user_return
.type user_return, @function
user_return:
    movq %rdi, %rsp
    jmp trap_return

/* void enter_user(uint64_t entry /rdi/, uint64_t user_stack_top /rsi/) noreturn
 * Drop to ring 3 at a fresh entry point (exec / first program start). */
.global enter_user
.type enter_user, @function
enter_user:
    movw $0x1B, %ax    /* user data selector (RPL 3) */
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %fs
    movw %ax, %gs

    pushq $0x1B        /* SS  = user data  */
    pushq %rsi         /* RSP = user stack */
    pushq $0x202       /* RFLAGS (IF set)  */
    pushq $0x23        /* CS  = user code  */
    pushq %rdi         /* RIP = entry      */
    iretq
