#ifndef _SETJMP_H
#define _SETJMP_H

/* jmp_buf: save rbx, rbp, r12-r15, rsp, rip (8 regs × 8 bytes = 64 bytes). */
typedef unsigned long jmp_buf[8];

/* Save caller state. Returns 0 directly, non-zero when resumed via longjmp. */
int  setjmp(jmp_buf env);

/* Restore state saved by setjmp; val becomes the return value (1 if val==0). */
void longjmp(jmp_buf env, int val) __attribute__((noreturn));

#endif /* _SETJMP_H */
