#ifndef SOC_H
#define SOC_H

// =============================================================================
//  soc.h  —  MMIO register definitions and drivers for PicoRV32 SoC
//
//  Memory map:
//    0x0000_0000   BRAM (instruction + data)
//    0x4000_0000   UART
//    0x4001_0000   PWM / Timer
//    0x9000_0000   Testbench PASS/FAIL signal
// =============================================================================

#include <stdint.h>

// ----------------------------------------------------------------------------
// Testbench control
// ----------------------------------------------------------------------------
#define TB_RESULT   (*(volatile uint32_t*)0x90000000)  // 0=PASS, else=FAIL code

// ----------------------------------------------------------------------------
// UART registers
// ----------------------------------------------------------------------------
#define UART_BASE       0x40000000UL
#define UART_CTRL       (*(volatile uint32_t*)(UART_BASE + 0x00))
#define UART_STATUS     (*(volatile uint32_t*)(UART_BASE + 0x04))
#define UART_TXDATA     (*(volatile uint32_t*)(UART_BASE + 0x08))
#define UART_RXDATA     (*(volatile uint32_t*)(UART_BASE + 0x0C))

// CTRL bits
#define UART_TX_EN      (1 << 0)
#define UART_RX_EN      (1 << 1)
#define UART_BAUD_SHIFT 16          // baud_div field starts at bit 16

// STATUS bits
#define UART_TX_BUSY    (1 << 0)
#define UART_TX_FULL    (1 << 1)
#define UART_RX_READY   (1 << 2)
#define UART_RX_OVF     (1 << 3)
#define UART_FRAME_ERR  (1 << 4)

// Baud divider: CLK_FREQ / BAUD_RATE
// Testbench runs at 100MHz, UART at 115200 baud → div ≈ 868
#define UART_BAUD_DIV   868

// ----------------------------------------------------------------------------
// UART driver functions
// ----------------------------------------------------------------------------
static inline void uart_init(void) {
    UART_CTRL = UART_TX_EN | UART_RX_EN |
                ((uint32_t)UART_BAUD_DIV << UART_BAUD_SHIFT);
}

static inline void uart_putc(char c) {
    // Wait until TX is not busy and buffer is empty
    while (UART_STATUS & (UART_TX_BUSY | UART_TX_FULL));
    UART_TXDATA = (uint32_t)c;
}

static inline void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

static inline int uart_rx_ready(void) {
    return (UART_STATUS & UART_RX_READY) ? 1 : 0;
}

static inline char uart_getc(void) {
    while (!uart_rx_ready());
    return (char)(UART_RXDATA & 0xFF);
}

// Non-blocking receive — returns -1 if no byte available
static inline int uart_getc_nb(void) {
    if (uart_rx_ready())
        return (int)(UART_RXDATA & 0xFF);
    return -1;
}

// ----------------------------------------------------------------------------
// PWM / Timer registers
// ----------------------------------------------------------------------------
#define PWM_BASE        0x40010000UL
#define PWM_CTRL        (*(volatile uint32_t*)(PWM_BASE + 0x00))
#define PWM_STATUS      (*(volatile uint32_t*)(PWM_BASE + 0x04))
#define PWM_COUNTER     (*(volatile uint32_t*)(PWM_BASE + 0x08))
#define PWM_PERIOD      (*(volatile uint32_t*)(PWM_BASE + 0x0C))
#define PWM_CH0_CMP     (*(volatile uint32_t*)(PWM_BASE + 0x10))
#define PWM_CH1_CMP     (*(volatile uint32_t*)(PWM_BASE + 0x14))
#define PWM_CH2_CMP     (*(volatile uint32_t*)(PWM_BASE + 0x18))
#define PWM_CH3_CMP     (*(volatile uint32_t*)(PWM_BASE + 0x1C))

// CTRL bits
#define PWM_TIMER_EN    (1 << 0)
#define PWM_AUTO_RELOAD (1 << 1)
#define PWM_OUT_EN      (1 << 2)
#define PWM_OV_IRQ_EN   (1 << 3)

// STATUS bits
#define PWM_OVERFLOW    (1 << 0)
#define PWM_CH0_MATCH   (1 << 1)
#define PWM_CH1_MATCH   (1 << 2)
#define PWM_CH2_MATCH   (1 << 3)
#define PWM_CH3_MATCH   (1 << 4)

// ----------------------------------------------------------------------------
// PWM / Timer driver functions
// ----------------------------------------------------------------------------

// Start free-running timer (counts 0 → period → 0 → ...)
static inline void timer_start(uint32_t period) {
    PWM_CTRL    = 0;                          // stop first
    PWM_COUNTER = 0;
    PWM_PERIOD  = period;
    PWM_CTRL    = PWM_TIMER_EN | PWM_AUTO_RELOAD;
}

// Read current counter value
static inline uint32_t timer_read(void) {
    return PWM_COUNTER;
}

// Busy-wait until overflow flag set, then clear it
static inline void timer_wait_overflow(void) {
    while (!(PWM_STATUS & PWM_OVERFLOW));
    PWM_STATUS = PWM_OVERFLOW;  // write 1 to clear
}

// Setup PWM: period in counts, duty in counts (duty < period)
// 4 channels — pass compare values for each channel
static inline void pwm_init(uint32_t period,
                             uint32_t duty0, uint32_t duty1,
                             uint32_t duty2, uint32_t duty3) {
    PWM_CTRL    = 0;
    PWM_COUNTER = 0;
    PWM_PERIOD  = period;
    PWM_CH0_CMP = duty0;
    PWM_CH1_CMP = duty1;
    PWM_CH2_CMP = duty2;
    PWM_CH3_CMP = duty3;
    PWM_CTRL    = PWM_TIMER_EN | PWM_AUTO_RELOAD | PWM_OUT_EN;
}

// Change duty cycle on one channel without stopping timer
static inline void pwm_set_duty(int channel, uint32_t duty) {
    volatile uint32_t *cmp = &PWM_CH0_CMP + channel;
    *cmp = duty;
}

#endif // SOC_H
