#ifndef _STRINGS_H
#define _STRINGS_H

/* BSD-compat: case-insensitive string compare (already in string.h too) */
int strcasecmp(const char *a, const char *b);
int strncasecmp(const char *a, const char *b, unsigned long n);

/* bzero / bcopy / bcmp (deprecated but used by some old code) */
void bzero(void *s, unsigned long n);
void bcopy(const void *src, void *dst, unsigned long n);
int  bcmp(const void *a, const void *b, unsigned long n);

#endif /* _STRINGS_H */
