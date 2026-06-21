#ifndef _STDLIB_H
#define _STDLIB_H

#ifndef NULL
#define NULL ((void *)0)
#endif

typedef unsigned long size_t;

/* Memory */
void *malloc(size_t n);
void *calloc(size_t nmemb, size_t size);
void *realloc(void *ptr, size_t new_size);
void  free(void *p);

/* Process */
void exit(int code) __attribute__((noreturn));
void abort(void) __attribute__((noreturn));
int  atexit(void (*func)(void));

/* Integer arithmetic */
int  abs(int x);
long labs(long x);

/* String → number */
int       atoi(const char *s);
long      atol(const char *s);
long      strtol(const char *s, char **endptr, int base);
unsigned long strtoul(const char *s, char **endptr, int base);
long long strtoll(const char *s, char **endptr, int base);

#endif /* _STDLIB_H */
