#ifndef _MATH_H
#define _MATH_H

/*
 * ZLibc math.h — intentionally minimal.
 * The kernel is compiled with soft_float and compiler-rt is not linked, so
 * floating-point runtime helpers (__adddf3, __muldf3, etc.) are unavailable.
 * Float/double functions are therefore not implemented in ZLibc.
 * Use integer arithmetic, fixed-point, or link your own soft-float library.
 */

#endif /* _MATH_H */
