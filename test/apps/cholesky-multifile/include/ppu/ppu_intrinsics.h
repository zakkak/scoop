/* Copyright (C) 2006 Sony Computer Entertainment Inc.

   This file is free software; you can redistribute it and/or modify it under
   the terms of the GNU General Public License as published by the Free
   Software Foundation; either version 2 of the License, or (at your option)
   any later version.

   This file is distributed in the hope that it will be useful, but WITHOUT
   ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
   FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
   for more details.

   You should have received a copy of the GNU General Public License
   along with this file; see the file COPYING.  If not, write to the Free
   Software Foundation, 51 Franklin Street, Fifth Floor, Boston, MA
   02110-1301, USA.  */

/* As a special exception, if you include this header file into source files
   compiled by GCC, this header file does not by itself cause  the resulting
   executable to be covered by the GNU General Public License.  This exception
   does not however invalidate any other reasons why the executable file might
   be covered by the GNU General Public License.  */

/*  TODO:
    misc ops (traps)
    supervisor/hypervisor mode ops.  */

#ifndef  _PPU_INTRINSICS_H
#define _PPU_INTRINSICS_H

#if !defined(__PPU__) && !defined(__ppc__) && !defined(__ppc64__) \
    && !defined(__GNUC__)
  #error ppu_intrinsics.h included on wrong platform/compiler
#endif

#ifdef __cplusplus
extern "C" {
#endif 

typedef int __V4SI __attribute__((vector_size(16)));

#define __cntlzw(v) __builtin_clz(v)
#define __cntlzd(v) __builtin_clzll(v)

#define __mulhw(a,b) __extension__ \
  ({int result;			   \
  __asm__ ("mulhw %0,%1,%2"	   \
	   : "=r" (result)	   \
	   : "r" ((int) (a)),	   \
	     "r" ((int) (b)));	   \
  result; })

#define __mulhwu(a,b) __extension__	\
  ({unsigned int result;		\
  __asm__ ("mulhwu %0,%1,%2"		\
	   : "=r" (result)		\
	   : "r" ((unsigned int) (a)),	\
	     "r" ((unsigned int) (b))); \
  result; })

#ifdef __powerpc64__
#define __mulhd(a,b) __extension__   \
  ({ long long result;		     \
  __asm__ ("mulhd %0,%1,%2"	     \
	   : "=r" (result)	     \
	   : "r" ((long long) (a)),  \
	     "r" ((long long) (b))); \
  result; })

#define __mulhdu(a,b) __extension__	      \
  ({unsigned long long result;		      \
  __asm__ ("mulhdu %0,%1,%2"		      \
	   : "=r" (result)		      \
	   : "r" ((unsigned long long) (a)),  \
	     "r" ((unsigned long long) (b))); \
  result; })
#endif /* __powerpc64__ */

#define __sync() __asm__ volatile ("sync" : : : "memory")
#define __isync() __asm__ volatile ("isync" : : : "memory")
#define __lwsync() __asm__ volatile ("lwsync" : : : "memory")
#define __eieio() __asm__ volatile ("eieio" : : : "memory")

#define __nop() __asm__ volatile ("ori 0,0,0" : : : "memory")
#define __cctpl() __asm__ volatile ("or 1,1,1" : : : "memory")
#define __cctpm() __asm__ volatile ("or 2,2,2" : : : "memory")
#define __cctph() __asm__ volatile ("or 3,3,3" : : : "memory")
#define __db8cyc() __asm__ volatile ("or 28,28,28" : : : "memory")
#define __db10cyc() __asm__ volatile ("or 29,29,29" : : : "memory")
#define __db12cyc() __asm__ volatile ("or 30,30,30" : : : "memory")
#define __db16cyc() __asm__ volatile ("or 31,31,31" : : : "memory")

#ifdef __powerpc64__
#define __mtspr(spr, value) \
  __asm__ volatile ("mtspr %0,%1" : : "n" (spr), "r" (value))
  
#define __mfspr(spr) __extension__				\
  ({ unsigned long long result;					\
  __asm__ volatile ("mfspr %0,%1" : "=r" (result) : "n" (spr)); \
  result; })
#endif /* __powerpc64__ */

#ifdef __powerpc64__
#define __mftb() __extension__			\
  ({ unsigned long long result;			\
  __asm__ volatile ("mftb %0" : "=r" (result));	\
  result; })
#else
#define __mftb() __extension__			\
  ({ unsigned long long result;			\
  unsigned long t;				\
  __asm__ volatile ("1:\n"			\
		    "\tmftbu %0\n"		\
		    "\tmftb %L0\n"		\
		    "\tmftbu %1\n"		\
		    "\tcmpw %0,%1\n"		\
		    "\tbne 1b"			\
		    : "=r" (result), "=r" (t));	\
  result; })
#endif /* __powerpc64__ */

#define __dcbf(base) \
  __asm__ volatile ("dcbf %y0" : "=Z" (*(__V4SI*) (base)) : : "memory")
  
#define __dcbz(base) \
  __asm__ volatile ("dcbz %y0" : "=Z" (*(__V4SI*) (base)) : : "memory")

#define __dcbst(base) \
  __asm__ volatile ("dcbst %y0" : "=Z" (*(__V4SI*) (base)) : : "memory")

#define __dcbtst(base) \
  __asm__ volatile ("dcbtst %y0" : "=Z" (*(__V4SI*) (base)) : : "memory")

#define __dcbt(base) \
  __asm__ volatile ("dcbt %y0" : "=Z" (*(__V4SI*) (base)) : : "memory")

#define __icbi(base) \
  __asm__ volatile ("icbi %y0" : "=Z" (*(__V4SI*) (base)) : : "memory")
  
#define __dcbt_TH1000(EATRUNC, D, UG, ID)				\
  __asm__ volatile ("dcbt %y0,8"					\
	   : "=Z" (*(__V4SI*) ((((unsigned long long) EATRUNC) & ~0x7F)	\
	   		       | (((D & 1) << 6)			\
	   		       | ((UG & 1) << 5)			\
	   		       | (ID & 0xF)))) : : "memory")

#define __dcbt_TH1010(GO, S, UNITCNT, T, U, ID)			     \
  __asm__ volatile ("dcbt %y0,10"				     \
	   : "=Z" (*(__V4SI*) ((((unsigned long long) GO & 1) << 31) \
	   		       | ((S & 0x3) << 29)		     \
	   		       | ((UNITCNT & 0x3FF) << 7)	     \
	   		       | ((T & 1) << 6)			     \
	   		       | ((U & 1) << 5)			     \
	   		       | (ID & 0xF))) : : "memory")

#define __protected_unlimited_stream_set(DIRECTION, ADDR, ID) \
  __dcbt_TH1000 ((ADDR), ((DIRECTION) >> 1), 1, (ID))

#define __protected_stream_set(DIRECTION, ADDR, ID) \
  __dcbt_TH1000 ((ADDR), ((DIRECTION) >> 1), 0, (ID))

#define __protected_stream_stop_all() \
  __dcbt_TH1010 (0, 3, 0, 0, 0, 0)

#define __protected_stream_stop(ID) \
  __dcbt_TH1010 (0, 2, 0, 0, 0, (ID))

#define __protected_stream_count(COUNT, ID) \
  __dcbt_TH1010 (0, 0, (COUNT), 0, 0, (ID))

#define __protected_stream_go() \
  __dcbt_TH1010 (1, 0, 0, 0, 0, 0)

#define __lhbrx(base) __extension__		\
  ({unsigned short result;	       		\
    typedef  struct {char a[2];} halfwordsize;	\
    halfwordsize *ptrp = (halfwordsize*)(base);	\
  __asm__ ("lhbrx %0,%y1"			\
	   : "=r" (result)			\
	   : "Z" (*ptrp));			\
  result; })

#define __lwbrx(base) __extension__		\
  ({unsigned int result;	       		\
    typedef  struct {char a[4];} wordsize;	\
    wordsize *ptrp = (wordsize*)(base);		\
  __asm__ ("lwbrx %0,%y1"			\
	   : "=r" (result)			\
	   : "Z" (*ptrp));			\
  result; })


#ifdef __powerpc64__
#define __ldbrx(base) __extension__			\
  ({unsigned long long result;	       			\
    typedef  struct {char a[8];} doublewordsize;	\
    doublewordsize *ptrp = (doublewordsize*)(base);	\
  __asm__ ("ldbrx %0,%y1"				\
	   : "=r" (result)				\
	   : "Z" (*ptrp));				\
  result; })
#else
#define __ldbrx(base) __extension__			\
  ({unsigned long long result;	       			\
    typedef  struct {char a[8];} doublewordsize;	\
    doublewordsize *ptrp = (doublewordsize*)(base);	\
  __asm__ ("lwbrx %L0,%y1\n"				\
	   "\tlwbrx %0,%y2"				\
	   : "=&r" (result)				\
	   : "Z" (*ptrp), "Z" (*((char *) ptrp + 4)));	\
  result; })
#endif /* __powerpc64__ */


#define __sthbrx(base, value) do {			\
    typedef  struct {char a[2];} halfwordsize;		\
    halfwordsize *ptrp = (halfwordsize*)(base);		\
    __asm__ ("sthbrx %1,%y0"				\
	   : "=Z" (*ptrp)				\
	   : "r" (value));				\
   } while (0)

#define __stwbrx(base, value) do {		\
    typedef  struct {char a[4];} wordsize;	\
    wordsize *ptrp = (wordsize*)(base);		\
    __asm__ ("stwbrx %1,%y0"			\
	   : "=Z" (*ptrp)			\
	   : "r" (value));			\
   } while (0)

#ifdef __powerpc64__
#define __stdbrx(base, value) do {			\
    typedef  struct {char a[8];} doublewordsize;	\
    doublewordsize *ptrp = (doublewordsize*)(base);	\
    __asm__ ("stdbrx %1,%y0"				\
	   : "=Z" (*ptrp)				\
	   : "r" (value));				\
   } while (0)
#else
#define __stdbrx(base, value) do {			\
    typedef  struct {char a[8];} doublewordsize;	\
    doublewordsize *ptrp = (doublewordsize*)(base);	\
    __asm__ ("stwbrx %L2,%y0\n"				\
	     "\tstwbrx %2,%y1"				\
	   : "=Z" (*ptrp), "=Z" (*((char *) ptrp + 4))	\
	   : "r" (value));				\
   } while (0)
#endif /* __powerpc64__ */


#define __lwarx(base) __extension__		\
  ({unsigned int result;	       		\
    typedef  struct {char a[4];} wordsize;	\
    wordsize *ptrp = (wordsize*)(base);		\
  __asm__ volatile ("lwarx %0,%y1"		\
	   : "=r" (result)			\
	   : "Z" (*ptrp));			\
  result; })

#ifdef __powerpc64__
#define __ldarx(base) __extension__			\
  ({unsigned long long result;	       			\
    typedef  struct {char a[8];} doublewordsize;	\
    doublewordsize *ptrp = (doublewordsize*)(base);	\
  __asm__ volatile ("ldarx %0,%y1"		       	\
	   : "=r" (result)				\
	   : "Z" (*ptrp));				\
  result; })
#endif /* __powerpc64__ */

#define __stwcx(base, value) __extension__	\
  ({unsigned int result;			\
    typedef  struct {char a[4];} wordsize;	\
    wordsize *ptrp = (wordsize*)(base);		\
  __asm__ volatile ("stwcx. %2,%y1\n"		\
	   "\tmfocrf %0,0x80"			\
	   : "=r" (result),			\
	     "=Z" (*ptrp)			\
	   : "r" (value));			\
  ((result & 0x20000000) >> 29); })


#ifdef __powerpc64__
#define __stdcx(base, value) __extension__		\
  ({unsigned long long result;				\
    typedef  struct {char a[8];} doublewordsize;	\
    doublewordsize *ptrp = (doublewordsize*)(base);	\
  __asm__ volatile ("stdcx. %2,%y1\n"			\
	   "\tmfocrf %0,0x80"				\
	   : "=r" (result),				\
	     "=Z" (*ptrp)				\
	   : "r" (value));				\
  ((result & 0x20000000) >> 29); })
#endif /* __powerpc64__ */

#define __mffs() __extension__			\
  ({double result;				\
  __asm__ volatile ("mffs %0" : "=f" (result)); \
  result; })

#define __mtfsf(mask,value) \
  __asm__ volatile ("mtfsf %0,%1" : : "n" (mask), "f" ((double) (value)))
  
#define __mtfsfi(bits,field) \
  __asm__ volatile ("mtfsfi %0,%1" : : "n" (bits), "n" (field))

#define __mtfsb0(bit) __asm__ volatile ("mtfsb0 %0" : : "n" (bit))
#define __mtfsb1(bit) __asm__ volatile ("mtfsb1 %0" : : "n" (bit))

#define __setflm(v) __extension__	      \
  ({double result;			      \
  __asm__ volatile ("mffs %0\n\tmtfsf 255,%1" \
		    : "=&f" (result)	      \
		    : "f" ((double) (v)));    \
  result; })

/* __builtin_fabs may perform unnecessary rounding.  */

/* Rename __fabs and __fabsf to work around internal prototypes defined 
   in bits/mathcalls.h with some glibc versions.  */ 
#define __fabs __ppu_fabs 
#define __fabsf __ppu_fabsf 

static __inline__ double __fabs(double x) __attribute__((always_inline));
static __inline__ double
__fabs(double x)
{
  double r;
  __asm__("fabs %0,%1" : "=f"(r) : "f"(x));
  return r;
}

static __inline__ float __fabsf(float x) __attribute__((always_inline));
static __inline__ float
__fabsf(float x)
{
  float r;
  __asm__("fabs %0,%1" : "=f"(r) : "f"(x));
  return r;
}

static __inline__ double __fnabs(double x) __attribute__((always_inline));
static __inline__ double
__fnabs(double x)
{
  double r;
  __asm__("fnabs %0,%1" : "=f"(r) : "f"(x));
  return r;
}

static __inline__ float __fnabsf(float x) __attribute__((always_inline));
static __inline__ float
__fnabsf(float x)
{
  float r;
  __asm__("fnabs %0,%1" : "=f"(r) : "f"(x));
  return r;
}

static __inline__ double __fmadd(double x, double y, double z)
  __attribute__((always_inline));
static __inline__ double
__fmadd(double x, double y, double z)
{
  double r;
  __asm__("fmadd %0,%1,%2,%3" : "=f"(r) : "f"(x),"f"(y),"f"(z));
  return r;
}

static __inline__ double __fmsub(double x, double y, double z)
  __attribute__((always_inline));
static __inline__ double
__fmsub(double x, double y, double z)
{
  double r;
  __asm__("fmsub %0,%1,%2,%3" : "=f"(r) : "f"(x),"f"(y),"f"(z));
  return r;
}

static __inline__ double __fnmadd(double x, double y, double z)
  __attribute__((always_inline));
static __inline__ double
__fnmadd(double x, double y, double z)
{
  double r;
  __asm__("fnmadd %0,%1,%2,%3" : "=f"(r) : "f"(x),"f"(y),"f"(z));
  return r;
}

static __inline__ double __fnmsub(double x, double y, double z)
  __attribute__((always_inline));
static __inline__ double
__fnmsub(double x, double y, double z)
{
  double r;
  __asm__("fnmsub %0,%1,%2,%3" : "=f"(r) : "f"(x),"f"(y),"f"(z));
  return r;
}

static __inline__ float __fmadds(float x, float y, float z)
  __attribute__((always_inline));
static __inline__ float
__fmadds(float x, float y, float z)
{
  float r;
  __asm__("fmadds %0,%1,%2,%3" : "=f"(r) : "f"(x),"f"(y),"f"(z));
  return r;
}

static __inline__ float __fmsubs(float x, float y, float z)
  __attribute__((always_inline));
static __inline__ float
__fmsubs(float x, float y, float z)
{
  float r;
  __asm__("fmsubs %0,%1,%2,%3" : "=f"(r) : "f"(x),"f"(y),"f"(z));
  return r;
}

static __inline__ float __fnmadds(float x, float y, float z)
  __attribute__((always_inline));
static __inline__ float
__fnmadds(float x, float y, float z)
{
  float r;
  __asm__("fnmadds %0,%1,%2,%3" : "=f"(r) : "f"(x),"f"(y),"f"(z));
  return r;
}

static __inline__ float __fnmsubs(float x, float y, float z)
  __attribute__((always_inline));
static __inline__ float
__fnmsubs(float x, float y, float z)
{
  float r;
  __asm__("fnmsubs %0,%1,%2,%3" : "=f"(r) : "f"(x),"f"(y),"f"(z));
  return r;
}

static __inline__ double __fsel(double x, double y, double z)
  __attribute__((always_inline));
static __inline__ double
__fsel(double x, double y, double z)
{
  double r;
  __asm__("fsel %0,%1,%2,%3" : "=f"(r) : "f"(x),"f"(y),"f"(z));
  return r;
}

static __inline__ float __fsels(float x, float y, float z)
  __attribute__((always_inline));
static __inline__ float
__fsels(float x, float y, float z)
{
  float r;
  __asm__("fsel %0,%1,%2,%3" : "=f"(r) : "f"(x),"f"(y),"f"(z));
  return r;
}

static __inline__ double __frsqrte(double x) __attribute__((always_inline));
static __inline__ double
__frsqrte(double x)
{
  double r;
  __asm__("frsqrte %0,%1" : "=f" (r) : "f" (x));
  return r;
}

static __inline__ float __fres(float x) __attribute__((always_inline));
static __inline__ float
__fres(float x)
{
  float r;
  __asm__("fres %0,%1" : "=f"(r) : "f"(x));
  return r;
}

static __inline__ double __fsqrt(double x) __attribute__((always_inline));
static __inline__ double
__fsqrt(double x)
{
  double r;
  __asm__("fsqrt %0,%1" : "=f"(r) : "f"(x));
  return r;
}

static __inline__ float __fsqrts(float x) __attribute__((always_inline));
static __inline__ float
__fsqrts(float x)
{
  float r;
  __asm__("fsqrts %0,%1" : "=f"(r) : "f"(x));
  return r;
}

static __inline__ double __fmul (double a, double b) __attribute__ ((always_inline));
static __inline__ double
__fmul(double a, double b)
{
  double d;
  __asm__ ("fmul %0,%1,%2" : "=f" (d) : "f" (a), "f" (b));
  return d;
}

static __inline__ float __fmuls (float a, float b) __attribute__ ((always_inline));
static __inline__ float
__fmuls (float a, float b)
{
  float d;
  __asm__ ("fmuls %0,%1,%2" : "=f" (d) : "f" (a), "f" (b));
  return d;
}

static __inline__ float __frsp (float a) __attribute__ ((always_inline));
static __inline__ float
__frsp (float a)
{
  float d;
  __asm__ ("frsp %0,%1" : "=f" (d) : "f" (a));
  return d;
}

static __inline__ double __fcfid (long long a) __attribute__ ((always_inline));
static __inline__ double
__fcfid (long long a)
{
  double d;
  __asm__ ("fcfid %0,%1" : "=f" (d) : "f" (a));
  return d;
}

static __inline__ long long __fctid (double a) __attribute__ ((always_inline));
static __inline__ long long
__fctid (double a)
{
  long long d;
  __asm__ ("fctid %0,%1" : "=f" (d) : "f" (a));
  return d;
}

static __inline__ long long __fctidz (double a) __attribute__ ((always_inline));
static __inline__ long long
__fctidz (double a)
{
  long long d;
  __asm__ ("fctidz %0,%1" : "=f" (d) : "f" (a));
  return d;
}

static __inline__ int __fctiw (double a) __attribute__ ((always_inline));
static __inline__ int
__fctiw (double a)
{
  unsigned long long d;
  __asm__ ("fctiw %0,%1" : "=f" (d) : "f" (a));
  return (int) d;
}

static __inline__ int __fctiwz (double a) __attribute__ ((always_inline));
static __inline__ int
__fctiwz (double a)
{
  long long d;
  __asm__ ("fctiwz %0,%1" : "=f" (d) : "f" (a));
  return (int) d;
}

#ifdef __powerpc64__
#define __rldcl(a,b,mb) __extension__ \
  ({ \
    unsigned long long d; \
    __asm__ ("rldcl %0,%1,%2,%3" : "=r" (d) : "r" (a), "r" (b), "i" (mb)); \
    d; \
  })

#define __rldcr(a,b,me) __extension__ \
  ({ \
    unsigned long long d; \
    __asm__ ("rldcr %0,%1,%2,%3" : "=r" (d) : "r" (a), "r" (b), "i" (me)); \
    d; \
  })

#define __rldic(a,sh,mb) __extension__ \
  ({ \
    unsigned long long d; \
    __asm__ ("rldic %0,%1,%2,%3" : "=r" (d) : "r" (a), "i" (sh), "i" (mb)); \
    d; \
  })

#define __rldicl(a,sh,mb) __extension__ \
  ({ \
    unsigned long long d; \
    __asm__ ("rldicl %0,%1,%2,%3" : "=r" (d) : "r" (a), "i" (sh), "i" (mb)); \
    d; \
  })

#define __rldicr(a,sh,me) __extension__ \
  ({ \
    unsigned long long d; \
    __asm__ ("rldicr %0,%1,%2,%3" : "=r" (d) : "r" (a), "i" (sh), "i" (me)); \
    d; \
  })

#define __rldimi(a,b,sh,mb) __extension__ \
  ({ \
    unsigned long long d; \
    __asm__ ("rldimi %0,%1,%2,%3" : "=r" (d) : "r" (b), "i" (sh), "i" (mb), "0" (a)); \
    d; \
  })
#endif /* __powerpc64__ */

#define __rlwimi(a,b,sh,mb,me) __extension__ \
  ({ \
    unsigned int d; \
    __asm__ ("rlwimi %0,%1,%2,%3,%4" : "=r" (d) : "r" (b), "i" (sh), "i" (mb), "i" (me), "0" (a)); \
    d; \
  })

#define __rlwinm(a,sh,mb,me) __extension__ \
  ({ \
    unsigned int d; \
    __asm__ ("rlwinm %0,%1,%2,%3,%4" : "=r" (d) : "r" (a), "i" (sh), "i" (mb), "i" (me)); \
    d; \
  })

#define __rlwnm(a,b,mb,me) __extension__ \
  ({ \
    unsigned int d; \
    __asm__ ("rlwnm %0,%1,%2,%3,%4" : "=r" (d) : "r" (a), "r" (b), "i" (mb), "i" (me)); \
    d; \
  })

#ifdef __cplusplus
}
#endif

#endif /* _PPU_INTRINSICS_H */