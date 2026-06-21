#ifndef _STDIO_H
#define _STDIO_H

#ifndef NULL
#define NULL ((void *)0)
#endif

typedef unsigned long size_t;

/* stdio uses FILE* only as fd-carrying pointers (1=stdout, 2=stderr). */
typedef void FILE;

#define stdin  ((FILE *)0)
#define stdout ((FILE *)1)
#define stderr ((FILE *)2)

#define EOF (-1)

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
