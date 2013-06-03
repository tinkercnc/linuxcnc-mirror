#ifndef RTAPI_BITOPS_H
#define RTAPI_BITOPS_H

#include "config.h"  // for USE_GCC_ATOMIC_OPS

// the Linux kernel has very nice bitmap handling
// unfortunately it is not available through /usr/include
// therefore replicate from linux/bitops.h and linux/kernel.h
// and prefix with an '_' to roll our own

typedef unsigned long long_bit;

#define _DIV_ROUND_UP(n,d) (((n) + (d) - 1) / (d))
#ifndef _BIT                     // /usr/include/pth.h might bring this in too
#define _BIT(nr)                 (1UL << (nr))
#endif
#define _BITS_PER_BYTE           8
#define _BITS_PER_LONG           (_BITS_PER_BYTE * sizeof(long_bit))
#define _BIT_MASK(nr)            (1UL << ((nr) % _BITS_PER_LONG))
#define _BIT_WORD(nr)            ((nr) / _BITS_PER_LONG)
#define _BITS_TO_LONGS(nr)       _DIV_ROUND_UP(nr, _BITS_PER_LONG)
#define _BIT_SET(a, b)           ((a)[_BIT_WORD(b)] |=   _BIT_MASK(b))
#define _BIT_CLEAR(a, b)         ((a)[_BIT_WORD(b)] &= ~ _BIT_MASK(b))
#define _BIT_TEST(a, b)          ((a)[_BIT_WORD(b)] &    _BIT_MASK(b))

#define _DECLARE_BITMAP(name,bits) long_bit name[_BITS_TO_LONGS(bits)]
#define _ZERO_BITMAP(name,bits)  { memset(name, 0,   _BITS_TO_LONGS(bits) * sizeof(long_bit)); }
#define _SET_BITMAP(name,bits)   { memset(name, 255, _BITS_TO_LONGS(bits) * sizeof(long_bit)); }

/*
 * http://gcc.gnu.org/onlinedocs/gcc-4.7.3/gcc/_005f_005fatomic-Builtins.html#g_t_005f_005fatomic-Builtins
 * http://www.mjmwired.net/kernel/Documentation/atomic_ops.txt
 *
 * clear_bit may not imply a memory barrier
 * http://www.mjmwired.net/kernel/Documentation/atomic_ops.txt#490
 */
#ifndef smp_mb__before_clear_bit
#define smp_mb__before_clear_bit()      __sync_synchronize()
#define smp_mb__after_clear_bit()       __sync_synchronize()
#endif

#if defined(USE_GCC_ATOMIC_OPS)

// http://gcc.gnu.org/wiki/Atomic/GCCMM/AtomicSync
// default: Full barrier in both directions and synchronizes with
// acquire loads and release stores in all threads.
#define _GCCMM_ __ATOMIC_SEQ_CST

#if __clang__
#define USE_ATOMIC __has_builtin(__atomic_fetch_or)
# elif (__GNUC__ > 4) && (__GNUC_MINOR__ >= 7)
#define USE_ATOMIC 1
#else
#define USE_ATOMIC 0
#endif

#if USE_ATOMIC

// http://gcc.gnu.org/wiki/Atomic/GCCMM/AtomicSync
// default: Full barrier in both directions and synchronizes with
// acquire loads and release stores in all threads.
#define MEMORY_MODEL __ATOMIC_SEQ_CST

static inline long_bit test_and_set_bit(int nr, long_bit * const value) {
    return  __atomic_fetch_or(value + _BIT_WORD(nr),
			      _BIT(nr),MEMORY_MODEL) & _BIT(nr);
}

static inline long_bit test_and_clear_bit(int nr, long_bit * const value) {
    return __atomic_fetch_and(value + _BIT_WORD(nr),
			      ~_BIT(nr),
			      MEMORY_MODEL) & _BIT(nr);
}

static inline void set_bit(int nr, long_bit * const value) {
    __atomic_or_fetch(value + _BIT_WORD(nr),
		      _BIT(nr),
		      MEMORY_MODEL);
}

static inline void clear_bit(int nr, long_bit * const value) {
    __atomic_and_fetch(value + _BIT_WORD(nr),
		       ~_BIT(nr),
		       MEMORY_MODEL);
}

#ifdef USE_ATOMIC_TEST_BIT
static inline long_bit test_bit(int nr, long_bit * const value) {
    return  __atomic_fetch_or(value + _BIT_WORD(nr), 0) & _BIT(nr);
}
#endif

#else  // legacy gcc intrinsics
static inline long_bit test_and_set_bit(int nr, long_bit * const value) {
    return  __sync_fetch_and_or(value + _BIT_WORD(nr),
				_BIT(nr)) & _BIT(nr);
}

static inline long_bit test_and_clear_bit(int nr, long_bit * const value) {
    return __sync_fetch_and_and(value + _BIT_WORD(nr),
			      ~_BIT(nr)) & _BIT(nr);
}

static inline void set_bit(int nr, long_bit * const value) {
    __sync_or_and_fetch(value + _BIT_WORD(nr), _BIT(nr));
}

static inline void clear_bit(int nr, long_bit * const value) {
    __sync_and_and_fetch(value + _BIT_WORD(nr), ~_BIT(nr));
}

#ifdef USE_ATOMIC_TEST_BIT
static inline long_bit test_bit(int nr, long_bit * const value) {
    return  __sync_fetch_and_or(value + _BIT_WORD(nr), 0) & _BIT(nr);
}
#endif
#endif

#ifndef USE_ATOMIC_TEST_BIT
#ifndef test_bit

/**
 * test_bit - Determine whether a bit is set
 * @nr: bit number to test
 * @addr: Address to start counting from
 *
 * This routine doesn't need to be atomic.
 * constant bit tests are the most common (if only) use case in LinuxCNC
 */
static  __inline__ int __constant_test_bit(int nr, const volatile unsigned long *addr)
{
        return 1UL & (addr[_BIT_WORD(nr)] >> (nr & (_BITS_PER_LONG-1)));
}


static __inline__ int __test_bit(int nr, volatile void *addr)
{
	int *a = (int *)addr;
	int mask;
	a += nr >> 5;
	mask = 1 << (nr & 0x1f);
	return ((mask & *a) != 0);
}

#define	test_bit(nr,addr) \
    (__builtin_constant_p(nr) ?	    \
     __constant_test_bit((nr),(addr)) :		\
     __test_bit((nr),(addr)))

#endif // test_bit
#endif // USE_ATOMIC_TEST_BIT

#else

#if (defined(__MODULE__) && !defined(SIM))
#include <asm/bitops.h>
#elif defined(__i386__)
/* From <asm/bitops.h>
 * Copyright 1992, Linus Torvalds.
 */

#define LOCK_PREFIX "lock ; "
#define ADDR (*(volatile long *) addr)

/**
 * set_bit - Atomically set a bit in memory
 * @nr: the bit to set
 * @addr: the address to start counting from
 *
 * This function is atomic and may not be reordered.  See __set_bit()
 * if you do not require the atomic guarantees.
 * Note that @nr may be almost arbitrarily large; this function is not
 * restricted to acting on a single-word quantity.
 */
static __inline__ void set_bit(int nr, volatile void * addr)
{
	__asm__ __volatile__( 
		"btsl %1,%0"
		:"=m" (ADDR)
		:"Ir" (nr));
}

#if 0 /* Fool kernel-doc since it doesn't do macros yet */
/**
 * test_bit - Determine whether a bit is set
 * @nr: bit number to test
 * @addr: Address to start counting from
 */
static int test_bit(int nr, const volatile void * addr);
#endif

static __inline__ int constant_test_bit(int nr, const volatile void * addr)
{
	return ((1UL << (nr & 31)) & (((const volatile unsigned int *) addr)[nr >> 5])) != 0;
}

static __inline__ int variable_test_bit(int nr, volatile void * addr)
{
	int oldbit;

	__asm__ __volatile__(
		"btl %2,%1\n\tsbbl %0,%0"
		:"=r" (oldbit)
		:"m" (ADDR),"Ir" (nr));
	return oldbit;
}

#define test_bit(nr,addr) \
(__builtin_constant_p(nr) ? \
 constant_test_bit((nr),(addr)) : \
 variable_test_bit((nr),(addr)))

/**
 * clear_bit - Clears a bit in memory
 * @nr: Bit to clear
 * @addr: Address to start counting from
 *
 * clear_bit() is atomic and may not be reordered.  However, it does
 * not contain a memory barrier, so if it is used for locking purposes,
 * you should call smp_mb__before_clear_bit() and/or smp_mb__after_clear_bit()
 * in order to ensure changes are visible on other processors.
 */
static __inline__ void clear_bit(int nr, volatile void * addr)
{
	__asm__ __volatile__( 
		"btrl %1,%0"
		:"=m" (ADDR)
		:"Ir" (nr));
}

/**
 * test_and_set_bit - Set a bit and return its old value
 * @nr: Bit to set
 * @addr: Address to count from
 *
 * This operation is atomic and cannot be reordered.  
 * It also implies a memory barrier.
 */
static __inline__ int test_and_set_bit(int nr, volatile void * addr)
{
	int oldbit;

	__asm__ __volatile__( LOCK_PREFIX
		"btsl %2,%1\n\tsbbl %0,%0"
		:"=r" (oldbit),"=m" (ADDR)
		:"Ir" (nr) : "memory");
	return oldbit;
}


/**
 * test_and_clear_bit - Clear a bit and return its old value
 * @nr: Bit to set
 * @addr: Address to count from
 *
 * This operation is atomic and cannot be reordered.  
 * It also implies a memory barrier.
 */
static __inline__ int test_and_clear_bit(int nr, volatile void * addr)
{
	int oldbit;

	__asm__ __volatile__( 
		"btrl %2,%1\n\tsbbl %0,%0"
		:"=r" (oldbit),"=m" (ADDR)
		:"Ir" (nr) : "memory");
	return oldbit;
}
#elif defined(__x86_64__)
/*
 * Copyright 1992, Linus Torvalds.
 */


#define LOCK_PREFIX "lock ; "

#define ADDR (*(volatile long *) addr)

/**
 * set_bit - Atomically set a bit in memory
 * @nr: the bit to set
 * @addr: the address to start counting from
 *
 * This function is atomic and may not be reordered.  See __set_bit()
 * if you do not require the atomic guarantees.
 * Note that @nr may be almost arbitrarily large; this function is not
 * restricted to acting on a single-word quantity.
 */
static __inline__ void set_bit(int nr, volatile void * addr)
{
	__asm__ __volatile__( LOCK_PREFIX
		"btsl %1,%0"
		:"=m" (ADDR)
		:"dIr" (nr) : "memory");
}


/**
 * clear_bit - Clears a bit in memory
 * @nr: Bit to clear
 * @addr: Address to start counting from
 *
 * clear_bit() is atomic and may not be reordered.  However, it does
 * not contain a memory barrier, so if it is used for locking purposes,
 * you should call smp_mb__before_clear_bit() and/or smp_mb__after_clear_bit()
 * in order to ensure changes are visible on other processors.
 */
static __inline__ void clear_bit(int nr, volatile void * addr)
{
	__asm__ __volatile__( LOCK_PREFIX
		"btrl %1,%0"
		:"=m" (ADDR)
		:"dIr" (nr));
}


static __inline__ int constant_test_bit(int nr, const volatile void * addr)
{
	return ((1UL << (nr & 31)) & (((const volatile unsigned int *) addr)[nr >> 5])) != 0;
}

static __inline__ int variable_test_bit(int nr, volatile const void * addr)
{
	int oldbit;

	__asm__ __volatile__(
		"btl %2,%1\n\tsbbl %0,%0"
		:"=r" (oldbit)
		:"m" (ADDR),"dIr" (nr));
	return oldbit;
}

#define test_bit(nr,addr) \
(__builtin_constant_p(nr) ? \
 constant_test_bit((nr),(addr)) : \
 variable_test_bit((nr),(addr)))


/**
 * test_and_set_bit - Set a bit and return its old value
 * @nr: Bit to set
 * @addr: Address to count from
 *
 * This operation is atomic and cannot be reordered.  
 * It also implies a memory barrier.
 */
static __inline__ int test_and_set_bit(int nr, volatile void * addr)
{
	int oldbit;

	__asm__ __volatile__( LOCK_PREFIX
		"btsl %2,%1\n\tsbbl %0,%0"
		:"=r" (oldbit),"=m" (ADDR)
		:"dIr" (nr) : "memory");
	return oldbit;
}

/**
 * test_and_clear_bit - Clear a bit and return its old value
 * @nr: Bit to clear
 * @addr: Address to count from
 *
 * This operation is atomic and cannot be reordered.  
 * It also implies a memory barrier.
 */
static __inline__ int test_and_clear_bit(int nr, volatile void * addr)
{
	int oldbit;

	__asm__ __volatile__( LOCK_PREFIX
		"btrl %2,%1\n\tsbbl %0,%0"
		:"=r" (oldbit),"=m" (ADDR)
		:"dIr" (nr) : "memory");
	return oldbit;
}
#undef ADDR
#elif defined(__powerpc__)

#define BITS_PER_LONG 32
#define BITOP_MASK(nr)          (1UL << ((nr) % BITS_PER_LONG))
#define BITOP_WORD(nr)          ((nr) / BITS_PER_LONG)

#ifdef CONFIG_SMP
#define ISYNC_ON_SMP    "\n\tisync\n"
#define LWSYNC_ON_SMP   __stringify(LWSYNC) "\n"
#else
#define ISYNC_ON_SMP
#define LWSYNC_ON_SMP
#endif

static __inline__ int test_and_set_bit(unsigned long nr,
                                       volatile unsigned long *addr)
{
        unsigned long old, t;
        unsigned long mask = BITOP_MASK(nr);
        unsigned long *p = ((unsigned long *)addr) + BITOP_WORD(nr);

        __asm__ __volatile__(
        LWSYNC_ON_SMP
"1:"    "lwarx  %0,0,%3              # test_and_set_bit\n"
        "or     %1,%0,%2 \n"
        "stwcx. %1,0,%3 \n"
        "bne-   1b"
        ISYNC_ON_SMP
        : "=&r" (old), "=&r" (t)
        : "r" (mask), "r" (p)
        : "cc", "memory");

        return (old & mask) != 0;
}

static __inline__ int test_and_clear_bit(unsigned long nr,
                                         volatile unsigned long *addr)
{
        unsigned long old, t;
        unsigned long mask = BITOP_MASK(nr);
        unsigned long *p = ((unsigned long *)addr) + BITOP_WORD(nr);

        __asm__ __volatile__(
        LWSYNC_ON_SMP
"1:"    "lwarx  %0,0,%3              # test_and_clear_bit\n"
        "andc   %1,%0,%2 \n"
        "stwcx. %1,0,%3 \n"
        "bne-   1b"
        ISYNC_ON_SMP
        : "=&r" (old), "=&r" (t)
        : "r" (mask), "r" (p)
        : "cc", "memory");

        return (old & mask) != 0;
}

#else
#error The header file <asm/bitops.h> is not usable and rtapi does not yet have support for your CPU
#endif
#endif // USE_GCC_ATOMIC_OPS
#endif
