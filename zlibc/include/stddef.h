#ifndef _STDDEF_H
#define _STDDEF_H

#ifndef NULL
#define NULL ((void *)0)
#endif

typedef unsigned long size_t;
typedef long          ssize_t;
typedef long          ptrdiff_t;
typedef unsigned long uintptr_t;
typedef long          intptr_t;

#define offsetof(type, member) __builtin_offsetof(type, member)

typedef int wchar_t;

#endif /* _STDDEF_H */
