/* user_payload.S — a tiny ring-3 program (raw, position-independent).
 *
 * Stored in the kernel image; copied into a user page and executed in ring 3.
 * All memory references are rip-relative, so it runs wherever it is copied.
 * It performs write(1), getpid(), then exit(0) via the SYSCALL instruction.
 */

.section .rodata.user, "a", @progbits
.global user_payload_start
.global user_payload_end

user_payload_start:
    /* write(1, msg, msg_end - msg) */
    movq $1, %rax
    movq $1, %rdi
    leaq msg(%rip), %rsi
    movq $(msg_end - msg), %rdx
    syscall

    /* getpid() */
    movq $39, %rax
    syscall

    /* exit(0) */
    movq $60, %rax
    xorq %rdi, %rdi
    syscall

1:  jmp 1b            /* should never be reached */

msg:
    .ascii "  [user] hello from ring 3 via the syscall instruction!\n"
msg_end:
user_payload_end:
