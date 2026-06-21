#ifndef _ASSERT_H
#define _ASSERT_H

#ifdef NDEBUG
#  define assert(expr) ((void)0)
#else
#  define assert(expr) \
     ((expr) ? (void)0 : __assert_fail(#expr, __FILE__, __LINE__))
void __assert_fail(const char *expr, const char *file, int line);
#endif

#endif /* _ASSERT_H */
