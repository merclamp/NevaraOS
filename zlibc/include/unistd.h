#ifndef _UNISTD_H
#define _UNISTD_H

typedef long          ssize_t;
typedef unsigned long size_t;
typedef int           pid_t;

#define STDIN_FILENO  0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2

/* File access mode bits for access(). */
#define F_OK 0
#define R_OK 4
#define W_OK 2
#define X_OK 1

/* seek */
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

ssize_t read(int fd, void *buf, size_t count);
ssize_t write(int fd, const void *buf, size_t count);
int     close(int fd);
int     dup(int oldfd);
int     dup2(int oldfd, int newfd);

pid_t   getpid(void);
pid_t   getppid(void);
int     isatty(int fd);
int     access(const char *path, int mode);

char   *getenv(const char *name);

int     chdir(const char *path);
char   *getcwd(char *buf, size_t size);

/* Minimal sleep (seconds, backed by SYS_sleep). */
unsigned int sleep(unsigned int seconds);

/* fork / exec */
pid_t   fork(void);
int     execve(const char *path, char *const argv[], char *const envp[]);
int     execv(const char *path, char *const argv[]);

/* _exit (no atexit handlers) */
void _exit(int status) __attribute__((noreturn));

/* symlink / readlink stubs */
int     symlink(const char *target, const char *linkpath);
ssize_t readlink(const char *path, char *buf, size_t bufsiz);

#endif /* _UNISTD_H */
