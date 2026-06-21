#ifndef _STRING_H
#define _STRING_H

#ifndef NULL
#define NULL ((void *)0)
#endif

typedef unsigned long size_t;

/* Length */
unsigned long strlen(const char *s);
unsigned long strnlen(const char *s, unsigned long maxlen);

/* Copy */
char *strcpy(char *dst, const char *src);
char *strncpy(char *dst, const char *src, unsigned long n);

/* Concatenate */
char *strcat(char *dst, const char *src);
char *strncat(char *dst, const char *src, unsigned long n);

/* Compare */
int strcmp(const char *a, const char *b);
int strncmp(const char *a, const char *b, unsigned long n);
int strcasecmp(const char *a, const char *b);
int strncasecmp(const char *a, const char *b, unsigned long n);

/* Search */
char *strchr(const char *s, int c);
char *strrchr(const char *s, int c);
char *strstr(const char *haystack, const char *needle);

/* Duplicate */
char *strdup(const char *s);

/* Tokenise */
char *strtok(char *str, const char *delim);

/* Memory */
void *memcpy(void *dst, const void *src, unsigned long n);
void *memmove(void *dst, const void *src, unsigned long n);
void *memset(void *dst, int c, unsigned long n);
int   memcmp(const void *a, const void *b, unsigned long n);
void *memchr(const void *s, int c, unsigned long n);

#endif /* _STRING_H */
