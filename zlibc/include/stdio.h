#ifndef _STDIO_H
#define _STDIO_H

#ifndef NULL
#define NULL ((void *)0)
#endif

typedef unsigned long size_t;
#ifndef __ssize_t_defined
typedef long ssize_t;
#define __ssize_t_defined
#endif


/* stdio uses FILE* for fd-carrying pointers (1=stdout, 2=stderr) or fopen'd files. */
typedef struct { int _fd; int _eof; } FILE;


#define stdin  ((FILE *)0)
#define stdout ((FILE *)1)
#define stderr ((FILE *)2)
#define EOF (-1)

/* File open/close */
FILE *fopen(const char *path, const char *mode);
int   fclose(FILE *stream);

/* Line I/O */
char   *fgets(char *s, int size, FILE *stream);
ssize_t getline(char **lineptr, size_t *n, FILE *stream);


/* Character I/O */
int putchar(int c);
int getchar(void);
int fputc(int c, FILE *stream);
int fputs(const char *s, FILE *stream);
int puts(const char *s);
int fflush(FILE *stream);

/* Formatted output */
int printf(const char *fmt, ...);
int fprintf(FILE *stream, const char *fmt, ...);
int sprintf(char *buf, const char *fmt, ...);
int snprintf(char *buf, size_t size, const char *fmt, ...);

/* va_list variants — caller must #include <stdarg.h> for va_list */
int vprintf(const char *fmt, void *ap);
int vsprintf(char *buf, const char *fmt, void *ap);
int vsnprintf(char *buf, size_t size, const char *fmt, void *ap);

/* Formatted input */
int scanf(const char *fmt, ...);
int sscanf(const char *str, const char *fmt, ...);

#endif /* _STDIO_H */
