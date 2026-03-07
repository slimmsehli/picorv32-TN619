// =============================================================================
//  pwm_gpio_demo.c
//
//  Demonstrates runtime IOMUX signal routing with PWM output.
//
//  GPIO pin assignments:
//    GPIO0  — UART0 TX  (monitor this in the testbench / waveform viewer)
//    GPIO1  — UART0 RX  (connect to GPIO0 loopback in testbench)
//    GPIO2  — PWM CH0   (phase 1 output)
//    GPIO4  — PWM CH0   (phase 2 output, after pause)
//
//  Sequence:
//    1. Route UART0_TX → GPIO0 and UART0_RX → GPIO1  (before uart_init)
//    2. Route PWM CH0 → GPIO2, run 5 duty cycle steps (10%→90%)
//       holding each step for 10 full PWM periods so it's visible in waves.
//    3. Stop PWM, disconnect GPIO2 (Hi-Z), pause for 5 timer overflows.
//    4. Route PWM CH0 → GPIO4, restart and repeat the same duty cycle
//       sequence.
//    5. Stop everything, report PASS to testbench.
//
//  PWM setup:
//    CLK = 100 MHz, PERIOD = 1000 counts → PWM freq = 100 kHz
//    Duty cycle = CH0_CMP / PERIOD
//    Steps: 100, 250, 500, 750, 900 counts = 10%, 25%, 50%, 75%, 90%
//
//  IOMUX signal IDs (from iomux_axi.v):
//    SIG_HIZ      = 0x00
//    SIG_UART0_TX = 0x01
//    SIG_UART0_RX = 0x02
//    SIG_PWM_CH0  = 0x12
// =============================================================================

#include "main.h"

// -----------------------------------------------------------------------------
// IOMUX register map  (base 0x400F_0000)
// -----------------------------------------------------------------------------
#define IOMUX_BASE      0x400F0000UL

// Read-only info registers
#define IOMUX_ID        (*(volatile uint32_t*)(IOMUX_BASE + 0x00))
#define IOMUX_NGPIO     (*(volatile uint32_t*)(IOMUX_BASE + 0x04))
#define IOMUX_NSIG      (*(volatile uint32_t*)(IOMUX_BASE + 0x08))

// Per-pin routing registers: IOMUX_PIN(n) at base + 0x40 + n*4
#define IOMUX_PIN(n)    (*(volatile uint32_t*)(IOMUX_BASE + 0x40 + (n)*4))

// Software GPIO data registers
#define IOMUX_GPODATA   (*(volatile uint32_t*)(IOMUX_BASE + 0xC0))
#define IOMUX_GPIDATA   (*(volatile uint32_t*)(IOMUX_BASE + 0xC4))

// Signal IDs — must match iomux_axi.v localparam values
#define SIG_HIZ         0x00u
#define SIG_UART0_TX    0x01u
#define SIG_UART0_RX    0x02u
#define SIG_PWM_CH0     0x12u
#define SIG_PWM_CH1     0x13u
#define SIG_PWM_CH2     0x14u
#define SIG_PWM_CH3     0x15u

// -----------------------------------------------------------------------------
// PWM parameters
// -----------------------------------------------------------------------------
#define PWM_FREQ_PERIOD  1000u          // counts per PWM period (100 kHz @ 100 MHz clk)
#define PERIODS_PER_STEP 10u            // how many full PWM periods to hold each duty cycle

// Duty cycle table: 10%, 25%, 50%, 75%, 90%
static const uint32_t duty_table[] = { 100, 250, 500, 750, 900 };
#define NUM_STEPS (sizeof(duty_table) / sizeof(duty_table[0]))

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

// Route a signal to a GPIO pin
static inline void iomux_connect(int pin, uint32_t sig)
{
    IOMUX_PIN(pin) = sig;
}

// Disconnect a GPIO pin (Hi-Z)
static inline void iomux_disconnect(int pin)
{
    IOMUX_PIN(pin) = SIG_HIZ;
}

// Start PWM CH0 with a given duty cycle, keep timer running
static inline void pwm_start(uint32_t duty)
{
    PWM_CTRL    = 0;                           // stop
    PWM_COUNTER = 0;                           // reset counter
    PWM_PERIOD  = PWM_FREQ_PERIOD;
    PWM_CH0_CMP = duty;
    // Enable timer + auto-reload + PWM output
    PWM_CTRL    = PWM_TIMER_EN | PWM_AUTO_RELOAD | PWM_OUT_EN;
}

// Stop the PWM output and timer completely
static inline void pwm_stop(void)
{
    PWM_CTRL = 0;
}

// Wait for N complete PWM periods (uses overflow flag, clears each time)
static inline void wait_periods(uint32_t n)
{
    // Clear any stale overflow first
    PWM_STATUS = PWM_OVERFLOW;
    for (uint32_t i = 0; i < n; i++)
        timer_wait_overflow();
}

// Busy-wait for N overflows with the timer already running at PWM_FREQ_PERIOD
// (used for the pause — we reuse the same timer in free-run mode)
static inline void pause_overflows(uint32_t n)
{
    // Timer is stopped here; run it in pure timer mode (no PWM out)
    PWM_CTRL    = 0;
    PWM_COUNTER = 0;
    PWM_PERIOD  = PWM_FREQ_PERIOD;
    PWM_CTRL    = PWM_TIMER_EN | PWM_AUTO_RELOAD;   // no PWM_OUT_EN
    PWM_STATUS  = PWM_OVERFLOW;                      // clear stale flag
    for (uint32_t i = 0; i < n; i++)
        timer_wait_overflow();
    PWM_CTRL = 0;
}

// Print a short status line: "PWM duty=NNN/1000 on GPIO N\n"
static void print_step(int gpio, uint32_t duty)
{
    // Duty values are always from the fixed table: 100,250,500,750,900
    // Extract digits without division using repeated subtraction
    uint32_t d = duty;
    char hundreds = '0';
    char tens     = '0';
    char ones     = '0';

    while (d >= 100) { hundreds++; d -= 100; }
    while (d >= 10)  { tens++;     d -= 10;  }
    ones = '0' + d;

    uart_puts("  PWM CH0 duty=");
    uart_putc(hundreds);
    uart_putc(tens);
    uart_putc(ones);
    uart_puts("/1000 on GPIO");
    uart_putc('0' + gpio);
    uart_puts("\n");
}

// Run the full 5-step duty cycle sequence on a given GPIO pin
static void run_duty_sequence(int gpio)
{
    uart_puts("Routing PWM_CH0 -> GPIO");
    uart_putc('0' + gpio);
    uart_puts("\n");

    iomux_connect(gpio, SIG_PWM_CH0);

    for (uint32_t step = 0; step < NUM_STEPS; step++) {
        uint32_t duty = duty_table[step];

        // Update compare register (timer keeps running between steps)
        // First step: start the timer; subsequent steps: just update duty
        if (step == 0) {
            pwm_start(duty);
        } else {
            pwm_set_duty(0, duty);   // CH0 compare update — no timer restart
            // Re-arm overflow flag so wait_periods counts from now
            PWM_STATUS = PWM_OVERFLOW;
        }

        print_step(gpio, duty);
        wait_periods(PERIODS_PER_STEP);
    }

    pwm_stop();
    iomux_disconnect(gpio);
}

// -----------------------------------------------------------------------------
// main
// -----------------------------------------------------------------------------
int main(void)
{
    // ------------------------------------------------------------------
    // Step 1: Route UART signals to GPIO pins BEFORE uart_init().
    // The UART peripheral is already clocked but the physical pins are
    // Hi-Z until we tell the IOMUX where to connect them.
    //   GPIO0 = UART0_TX  ← the testbench monitors this pad
    //   GPIO1 = UART0_RX  ← testbench loopback: connect GPIO1 to GPIO0
    // ------------------------------------------------------------------
    iomux_connect(0, SIG_UART0_TX);
    iomux_connect(1, SIG_UART0_RX);

    uart_init();

    uart_puts("\n=== TN619 PWM IOMUX Demo ===\n");

    // Verify IOMUX is present
    if (IOMUX_ID != 0x10CECA51u) {
        uart_puts("ERROR: IOMUX not found!\n");
        TB_RESULT = 1;
        return 1;
    }
    uart_puts("IOMUX OK\n\n");

    // ------------------------------------------------------------------
    // Phase 1: PWM on GPIO2
    // ------------------------------------------------------------------
    uart_puts("--- Phase 1: GPIO2 ---\n");
    run_duty_sequence(2);

    // ------------------------------------------------------------------
    // Pause: GPIO2 is now Hi-Z, timer off
    // Pause for 5 free-run timer overflows (~5 PWM periods worth of time)
    // so the gap is clearly visible in the waveform.
    // ------------------------------------------------------------------
    uart_puts("\n--- Pause (GPIO2 Hi-Z) ---\n");
    pause_overflows(5);
    uart_puts("Pause done\n\n");

    // ------------------------------------------------------------------
    // Phase 2: same sequence on GPIO4
    // ------------------------------------------------------------------
    uart_puts("--- Phase 2: GPIO4 ---\n");
    run_duty_sequence(4);

    // ------------------------------------------------------------------
    // Done
    // ------------------------------------------------------------------
    uart_puts("\n=== DONE ===\n");
    TB_RESULT = 0;   // signal PASS to testbench
    return 0;
}
