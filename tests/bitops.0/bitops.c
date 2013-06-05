#include <stdio.h>
#include <assert.h>
#include <rtapi_bitops.h>

// the symbol RTAPI_USE_ATOMIC is #defined only in the
// new version of rtapi_bitops.h and either 0 or 1, but defined

#ifdef RTAPI_USE_ATOMIC
#define ATOMIC_TYPE rtapi_atomic_type

// make any accidential imports vanish
#undef test_and_set_bit
#undef test_and_clear_bit
#undef set_bit
#undef clear_bit
#undef test_bit

#define test_and_set_bit rtapi_test_and_set_bit
#define test_and_clear_bit rtapi_test_and_clear_bit
#define set_bit rtapi_set_bit
#define clear_bit rtapi_clear_bit
#define test_bit rtapi_test_bit

#else
#define ATOMIC_TYPE unsigned long
#endif

int main()
{
    ATOMIC_TYPE x = 1;

    ATOMIC_TYPE y = test_and_set_bit(31, &x);
    assert(!y);
    y = test_and_set_bit(31, &x);
    assert(y);

    printf("all tests passed\n");
    return 0;
}

