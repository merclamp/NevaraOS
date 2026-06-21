#ifndef _SYS_WAIT_H
#define _SYS_WAIT_H

#define WNOHANG    1
#define WUNTRACED  2

#define WIFEXITED(s)    (((s) & 0x7f) == 0)
#define WEXITSTATUS(s)  (((s) >> 8) & 0xff)
#define WIFSIGNALED(s)  (((s) & 0x7f) != 0x7f && ((s) & 0x7f) != 0)
#define WTERMSIG(s)     ((s) & 0x7f)
#define WIFSTOPPED(s)   (((s) & 0xff) == 0x7f)
#define WSTOPSIG(s)     (((s) >> 8) & 0xff)

int waitpid(int pid, int *status, int options);
int wait(int *status);

#endif /* _SYS_WAIT_H */
