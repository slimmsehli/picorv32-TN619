// =============================================================================
//  firmware/main.c  -  PicoRV32 CPU Test (RV32I only - no mul/div)
// =============================================================================

#include <stdint.h>

#define UART_TX     (*(volatile uint32_t*)0x10000000)
#define TEST_RESULT (*(volatile uint32_t*)0x90000000)

// ----------------------------------------------------------------------------
// UART helpers
// ----------------------------------------------------------------------------
static void putc_(char c)        { UART_TX = (uint32_t)c; }
static void puts_(const char *s) { while (*s) putc_(*s++); }

// No % or / — subtract powers of 10 instead
static void putdec(int32_t v) {
    if (v < 0) { putc_('-'); v = -v; }
    if (v == 0) { putc_('0'); return; }
    static const int32_t pow10[] = {
        1000000000, 100000000, 10000000, 1000000,
        100000, 10000, 1000, 100, 10, 1
    };
    int printing = 0;
    for (int i = 0; i < 10; i++) {
        int32_t p = pow10[i];
        int digit = 0;
        while (v >= p) { v -= p; digit++; }
        if (digit || printing) { putc_('0' + digit); printing = 1; }
    }
}

// ----------------------------------------------------------------------------
// Test helper
// ----------------------------------------------------------------------------
int failures = 0;

static void check(const char *name, int32_t got, int32_t expected) {
    puts_(name);
    puts_(": ");
    if (got == expected) {
        puts_("PASS\r\n");
    } else {
        puts_("FAIL (got=");
        putdec(got);
        puts_(" expected=");
        putdec(expected);
        puts_(")\r\n");
        failures++;
    }
}

// ----------------------------------------------------------------------------
// 1. Arithmetic  (no mul — use shift+add instead)
// ----------------------------------------------------------------------------
static void test_arithmetic(void) {
    puts_("\r\n[1] Arithmetic\r\n");
    check("  add        ", 3 + 4,                    7);
    check("  sub        ", 10 - 3,                   7);
    check("  neg        ", -5 + 3,                  -2);
    check("  shift mul6 ", (6 << 2) + (6 << 1),     36);   // 6*6 via shifts
    check("  large add  ", (int32_t)(0x7FFFFF00 + 0xFF), (int32_t)0x7FFFFFFF);
    volatile int32_t big = 0x7FFFFFFF;
    check("  overflow   ", big + 1, (int32_t)0x80000000);
}

// ----------------------------------------------------------------------------
// 2. Logic & Shifts
// ----------------------------------------------------------------------------
static void test_logic(void) {
    puts_("\r\n[2] Logic & Shifts\r\n");
    check("  AND  ", 0xFF & 0x0F,            0x0F);
    check("  OR   ", 0xF0 | 0x0F,            0xFF);
    check("  XOR  ", 0xFF ^ 0xFF,            0x00);
    check("  SHL  ", 1 << 8,                  256);
    check("  SHR  ", 256 >> 4,                 16);
    check("  SAR  ", ((int32_t)(-16)) >> 2,    -4);
    check("  NOT  ", (int32_t)(~0x00000000), (int32_t)0xFFFFFFFF);
}

// ----------------------------------------------------------------------------
// 3. Branches & Comparisons
// ----------------------------------------------------------------------------
static void test_branches(void) {
    puts_("\r\n[3] Branches\r\n");
    int a = 5, b = 10;
    check("  a < b     ", a < b,                          1);
    check("  a > b     ", a > b,                          0);
    check("  a == b    ", a == b,                         0);
    check("  a != b    ", a != b,                         1);
    check("  unsigned  ", (uint32_t)0xFFFFFFFF > (uint32_t)1, 1);
    check("  signed    ", (int32_t)0xFFFFFFFF < (int32_t)1,   1);
}

// ----------------------------------------------------------------------------
// 4. Memory: load / store
// ----------------------------------------------------------------------------
static void test_memory(void) {
    puts_("\r\n[4] Memory\r\n");
    volatile uint32_t word;
    volatile uint16_t half;
    volatile uint8_t  byte_;

    word  = 0xDEADBEEF;
    check("  sw/lw  ", (int32_t)word,  (int32_t)0xDEADBEEF);

    half  = 0xCAFE;
    check("  sh/lh  ", (int32_t)half,  0xCAFE);

    byte_ = 0xAB;
    check("  sb/lb  ", (int32_t)byte_, 0xAB);

    volatile uint8_t arr[4];
    arr[0] = 0x11; arr[1] = 0x22; arr[2] = 0x33; arr[3] = 0x44;
    uint32_t packed = *(volatile uint32_t*)arr;
    check("  endian ", (int32_t)(packed & 0xFF), 0x11);
}

// ----------------------------------------------------------------------------
// 5. Loops
// ----------------------------------------------------------------------------
static void test_loops(void) {
    puts_("\r\n[5] Loops\r\n");

    // sum 0..99 = 4950  (addition only, no mul)
    int32_t sum = 0;
    for (int i = 0; i < 100; i++) sum += i;
    check("  for sum  ", sum, 4950);

    int32_t n = 10, count = 0;
    while (n > 0) { n--; count++; }
    check("  while    ", count, 10);

    int32_t x = 0;
    do { x++; } while (x < 5);
    check("  do-while ", x, 5);
}

// ----------------------------------------------------------------------------
// 6. Recursion & Stack  (fibonacci - only uses addition)
// ----------------------------------------------------------------------------
static int32_t fibonacci(int32_t n) {
    if (n <= 1) return n;
    return fibonacci(n - 1) + fibonacci(n - 2);
}

static void test_functions(void) {
    puts_("\r\n[6] Recursion & Stack\r\n");
    check("  fib(0)  ",  fibonacci(0),   0);
    check("  fib(1)  ",  fibonacci(1),   1);
    check("  fib(5)  ",  fibonacci(5),   5);
    check("  fib(10) ",  fibonacci(10), 55);
    check("  fib(12) ",  fibonacci(12), 144);
}

// ----------------------------------------------------------------------------
// 7. Pointers
// ----------------------------------------------------------------------------
static void test_pointers(void) {
    puts_("\r\n[7] Pointers\r\n");
    int32_t arr[5] = {10, 20, 30, 40, 50};
    int32_t *p = arr;

    check("  p[0]   ", p[0],   10);
    check("  p[4]   ", p[4],   50);
    check("  *(p+2) ", *(p+2), 30);

    int32_t total = 0;
    for (int i = 0; i < 5; i++) total += *p++;
    check("  ptr walk", total, 150);
}

// ----------------------------------------------------------------------------
// 8. Structs
// ----------------------------------------------------------------------------
typedef struct {
    uint8_t  id;
    uint16_t value;
    uint32_t timestamp;
} sensor_t;

static void test_structs(void) {
    puts_("\r\n[8] Structs\r\n");
    sensor_t s;
    s.id        = 0x42;
    s.value     = 1234;
    s.timestamp = 0xDEAD0000;

    check("  id        ", s.id,         0x42);
    check("  value     ", s.value,      1234);
    check("  timestamp ", (int32_t)s.timestamp, (int32_t)0xDEAD0000);
}

// ----------------------------------------------------------------------------
// Entry point
// ----------------------------------------------------------------------------
int main(void) {
    puts_("===========================================\r\n");
    puts_("  PicoRV32 CPU Test (RV32I)\r\n");
    puts_("===========================================\r\n");

    test_arithmetic();
    test_logic();
    test_branches();
    test_memory();
    test_loops();
    test_functions();
    test_pointers();
    test_structs();

    puts_("\r\n===========================================\r\n");
    if (failures == 0) {
        puts_("  ALL TESTS PASSED\r\n");
    } else {
        puts_("  FAILURES: ");
        putdec(failures);
        puts_("\r\n");
    }
    puts_("===========================================\r\n");

    /* debug: print raw failures value */
    puts_("  failures="); putdec(failures); puts_("\r\n");
    TEST_RESULT = (uint32_t)failures;
    return failures;
}
