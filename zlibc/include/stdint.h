#ifndef _STDINT_H
#define _STDINT_H

typedef unsigned char      uint8_t;
typedef unsigned short     uint16_t;
typedef unsigned int       uint32_t;
typedef unsigned long long uint64_t;
typedef signed char        int8_t;
typedef signed short       int16_t;
typedef signed int         int32_t;
typedef signed long long   int64_t;
typedef unsigned long      uintptr_t;
typedef long               intptr_t;
typedef long               ptrdiff_t;
typedef unsigned long      size_t;
typedef long               ssize_t;

#define INT8_MIN    (-128)
#define INT16_MIN   (-32768)
#define INT32_MIN   (-2147483647-1)
#define INT64_MIN   (-9223372036854775807LL-1)
#define INT8_MAX    127
#define INT16_MAX   32767
#define INT32_MAX   2147483647
#define INT64_MAX   9223372036854775807LL
#define UINT8_MAX   255U
#define UINT16_MAX  65535U
#define UINT32_MAX  4294967295U
#define UINT64_MAX  18446744073709551615ULL
#define SIZE_MAX    (~(unsigned long)0)
#define INTPTR_MAX  INT64_MAX
#define UINTPTR_MAX UINT64_MAX

#define INT8_C(x)   (x)
#define INT16_C(x)  (x)
#define INT32_C(x)  (x)
#define INT64_C(x)  (x##LL)
#define UINT8_C(x)  (x##U)
#define UINT16_C(x) (x##U)
#define UINT32_C(x) (x##U)
#define UINT64_C(x) (x##ULL)

#endif /* _STDINT_H */
