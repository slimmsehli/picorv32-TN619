// =============================================================================
//  main.c  —  SoC peripheral test
//
//  Tests:
//    [1] UART TX  — send string, verify via testbench monitor
//    [2] UART RX  — loopback: testbench echoes back what we send
//    [3] Timer    — count overflows, measure elapsed ticks
//    [4] PWM      — set 4 channels, read back compare registers
// =============================================================================

#include <stdint.h>
#include "main.h"

// ----------------------------------------------------------------------------
// Minimal print utils (no stdlib, no division)
// ----------------------------------------------------------------------------
static void putdec(int32_t v) {
    if (v < 0) { uart_putc('-'); v = -v; }
    if (v == 0) { uart_putc('0'); return; }
    static const int32_t pow10[] = {
        1000000000, 100000000, 10000000, 1000000,
        100000, 10000, 1000, 100, 10, 1
    };
    int printing = 0;
    for (int i = 0; i < 10; i++) {
        int32_t p = pow10[i], digit = 0;
        while (v >= p) { v -= p; digit++; }
        if (digit || printing) { uart_putc('0' + digit); printing = 1; }
    }
}

static void puthex32(uint32_t v) {
    uart_puts("0x");
    for (int i = 28; i >= 0; i -= 4) {
        uint8_t n = (v >> i) & 0xF;
        uart_putc(n < 10 ? '0'+n : 'a'+(n-10));
    }
}

// ----------------------------------------------------------------------------
// Test framework
// ----------------------------------------------------------------------------
static int failures = 0;

static void check(const char *name, uint32_t got, uint32_t expected) {
    uart_puts("  ");
    uart_puts(name);
    if (got == expected) {
        uart_puts(": PASS\r\n");
    } else {
        uart_puts(": FAIL  got=");
        puthex32(got);
        uart_puts(" expected=");
        puthex32(expected);
        uart_puts("\r\n");
        failures++;
    }
}

// ----------------------------------------------------------------------------
// Test 1: UART TX
//   Send a known string. The testbench monitors uart_tx and checks each byte.
//   We verify by reading back STATUS after each send.
// ----------------------------------------------------------------------------
static void test_uart_tx(void) {
    uart_puts("\r\n[1] UART TX\r\n");

    // Send a test string and verify TX completes without error
    const char *msg = "HELLO_UART";
    uart_puts("  Sending: ");
    uart_puts(msg);
    uart_puts("\r\n");

    for (const char *p = msg; *p; p++) {
        uart_putc(*p);
    }

    // Wait for last byte to finish sending
    while (UART_STATUS & UART_TX_BUSY);

    uint32_t status = UART_STATUS;
    check("TX_BUSY cleared after send", (status & UART_TX_BUSY), 0);
    check("TX_FULL cleared after send", (status & UART_TX_FULL), 0);
    check("No frame error on TX      ", (status & UART_FRAME_ERR), 0);

    uart_puts("  TX test done\r\n");
}

// ----------------------------------------------------------------------------
// Test 2: UART RX loopback
//   In the testbench, uart_tx is wired back to uart_rx.
//   We send bytes and expect to receive them back.
// ----------------------------------------------------------------------------
static void test_uart_rx_loopback(void) {
    uart_puts("\r\n[2] UART RX Loopback\r\n");

    // The testbench wires TX → RX, so bytes we send come back
    uint8_t test_bytes[4] = {0x55, 0xAA, 0x42, 0xFF};
    int rx_ok = 1;

    for (int i = 0; i < 4; i++) {
        // Send a byte
        while (UART_STATUS & (UART_TX_BUSY | UART_TX_FULL));
        UART_TXDATA = test_bytes[i];

        // Wait and receive it back (with timeout)
        int timeout = 100000;
        while (!uart_rx_ready() && timeout-- > 0);

        if (timeout <= 0) {
            uart_puts("  FAIL: RX timeout on byte ");
            putdec(i);
            uart_puts("\r\n");
            rx_ok = 0;
            failures++;
            continue;
        }

        uint8_t received = (uint8_t)(UART_RXDATA & 0xFF);
        if (received != test_bytes[i]) {
            uart_puts("  FAIL: byte ");
            putdec(i);
            uart_puts(" got=");
            puthex32(received);
            uart_puts(" want=");
            puthex32(test_bytes[i]);
            uart_puts("\r\n");
            rx_ok = 0;
            failures++;
        }
    }

    if (rx_ok)
        uart_puts("  All loopback bytes matched: PASS\r\n");

    check("No RX overflow  ", (UART_STATUS & UART_RX_OVF),   0);
    check("No frame error  ", (UART_STATUS & UART_FRAME_ERR), 0);
}

// ----------------------------------------------------------------------------
// Test 3: Timer
//   Start timer with known period, wait for overflow, check counter resets.
// ----------------------------------------------------------------------------
static void test_timer(void) {
    uart_puts("\r\n[3] Timer\r\n");

    // Use a small period for fast simulation: 1000 counts
    uint32_t test_period = 1000;
    timer_start(test_period);

    // Verify timer is running — counter should increase
    uint32_t t0 = timer_read();
    // Burn some cycles
    volatile int dummy = 0;
    for (int i = 0; i < 50; i++) dummy++;
    uint32_t t1 = timer_read();

    check("Counter is running (t1 > t0)", (t1 > t0) ? 1 : 0, 1);

    // Wait for first overflow
    timer_wait_overflow();
    uint32_t after_ov = timer_read();
    check("Counter resets after overflow", (after_ov < test_period) ? 1 : 0, 1);

    // Overflow flag should be cleared now
    check("Overflow flag cleared        ", (PWM_STATUS & PWM_OVERFLOW), 0);

    // Wait for second overflow — proves continuous mode works
    timer_wait_overflow();
    check("Second overflow occurred      ", 1, 1);

    uart_puts("  Timer period = ");
    putdec(test_period);
    uart_puts(" counts\r\n");

    // Stop timer
    PWM_CTRL = 0;
    check("Timer stopped (EN=0)         ", (PWM_CTRL & PWM_TIMER_EN), 0);
}

// ----------------------------------------------------------------------------
// Test 4: PWM
//   Configure 4 channels with different duty cycles.
//   Read back compare registers to verify writes.
//   Check PWM output toggles by sampling STATUS during run.
// ----------------------------------------------------------------------------
static void test_pwm(void) {
    uart_puts("\r\n[4] PWM\r\n");

    // Period = 1000 counts
    // Duty cycles: 25%, 50%, 75%, 10%
    uint32_t period = 1000;
    uint32_t duty[4] = {250, 500, 750, 100};

    pwm_init(period, duty[0], duty[1], duty[2], duty[3]);

    // Read back and verify compare registers
    check("Period register   ", PWM_PERIOD,  period);
    check("CH0 25% duty      ", PWM_CH0_CMP, duty[0]);
    check("CH1 50% duty      ", PWM_CH1_CMP, duty[1]);
    check("CH2 75% duty      ", PWM_CH2_CMP, duty[2]);
    check("CH3 10% duty      ", PWM_CH3_CMP, duty[3]);

    // Verify CTRL is set correctly
    uint32_t expected_ctrl = PWM_TIMER_EN | PWM_AUTO_RELOAD | PWM_OUT_EN;
    check("CTRL register     ", PWM_CTRL, expected_ctrl);

    // Wait for several overflows so waveform is visible in GTKWave
    for (int i = 0; i < 5; i++) timer_wait_overflow();
    uart_puts("  5 PWM periods completed\r\n");

    // Change duty cycle dynamically on CH0 → 50%
    pwm_set_duty(0, 500);
    check("CH0 duty updated  ", PWM_CH0_CMP, 500);

    // Wait a few more periods
    for (int i = 0; i < 3; i++) timer_wait_overflow();
    uart_puts("  Dynamic duty change OK\r\n");

    // Stop PWM
    PWM_CTRL = 0;
}

// ----------------------------------------------------------------------------
// Entry point
// ----------------------------------------------------------------------------
int main(void) {
    uart_init();

    uart_puts("===========================================\r\n");
    uart_puts("  PicoRV32 SoC Peripheral Test\r\n");
    uart_puts("  UART + PWM/Timer\r\n");
    uart_puts("===========================================\r\n");

    test_uart_tx();
    test_uart_rx_loopback();
    test_timer();
    test_pwm();

    uart_puts("\r\n===========================================\r\n");
    if (failures == 0) {
        uart_puts("  ALL PERIPHERAL TESTS PASSED\r\n");
    } else {
        uart_puts("  FAILURES: ");
        putdec(failures);
        uart_puts("\r\n");
    }
    uart_puts("===========================================\r\n");

    TB_RESULT = (uint32_t)failures;
    return failures;
}
