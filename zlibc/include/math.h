#ifndef _MATH_H
#define _MATH_H

/*
 * ZLibc math.h — integer-only fast path.
 * Float/double functions are intentionally absent: the kernel and userland
 * are compiled with soft_float and compiler-rt is not linked.
 */

/* Integer absolute value (also declared in stdlib.h, mirrored here). */
int       abs(int x);
long      labs(long x);
long long llabs(long long x);

/* Integer power: base^exp (exp >= 0). Overflow is not checked. */
long long ipow(long long base, unsigned int exp);

/* Integer square root (floor). */
unsigned long isqrt(unsigned long n);

/* Greatest common divisor (Euclidean). */
unsigned long gcd(unsigned long a, unsigned long b);

/* Least common multiple. Returns 0 on overflow. */
unsigned long lcm(unsigned long a, unsigned long b);

#endif /* _MATH_H */
