/* switch.S — cooperative kernel-thread context switch.
 *
 * void context_switch(uint64_t *old_rsp, uint64_t new_rsp);
 *   rdi = address where the outgoing thread's stack pointer is saved
 *   rsi = the incoming thread's saved stack pointer
 *
 * Only the SysV callee-saved registers need preserving across a call; the
 * return address on the stack carries the resume point (rip).
 */

.section .text
.global context_switch
.type context_switch, @function
context_switch:
    pushfq              /* save RFLAGS (incl. IF) so it is per-thread */
    pushq %rbx
    pushq %rbp
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15

    movq %rsp, (%rdi)   /* save current stack pointer into *old_rsp */
    movq %rsi, %rsp     /* load the new thread's stack pointer        */

    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbp
    popq %rbx
    popfq               /* restore RFLAGS */
    ret                 /* resume the new thread at its saved rip */
