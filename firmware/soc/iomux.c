// =============================================================================
//  iomux_example.c  —  Firmware examples for the IOMUX peripheral
//
//  Shows how a user can configure any pin routing from C code at runtime.
//  Include iomux.h and main.h in your project, then call these patterns.
// =============================================================================

#include "main.h"   // UART helpers, PWM registers
#include "iomux.h"  // IOMUX driver

// ----------------------------------------------------------------------------
// Example 1: Minimal — UART0 on fixed pins, that's it
// ----------------------------------------------------------------------------
void example_uart_only(void) {
    // Probe that IOMUX is present
    if (!iomux_probe()) {
        // IOMUX peripheral not found — halt or fallback
        while (1);
    }

    // Start clean
    iomux_reset_all(IOMUX_NGPIO);

    // Route UART0 to GPIO 0 (TX) and GPIO 1 (RX)
    iomux_connect(0, SIG_UART0_TX);
    iomux_connect(1, SIG_UART0_RX);

    // Now UART works on those pins
    uart_init();
    uart_puts("UART0 on GPIO0=TX, GPIO1=RX\r\n");
}

// ----------------------------------------------------------------------------
// Example 2: UART0 + SPI0 on separate pin banks
// ----------------------------------------------------------------------------
void example_uart_and_spi(void) {
    iomux_reset_all(IOMUX_NGPIO);

    // UART0 on low pins
    iomux_preset_uart0(0, 1);         // GPIO0=TX, GPIO1=RX

    // SPI0 on next 4 pins
    iomux_preset_spi0(2);             // GPIO2=SCK, GPIO3=MOSI, GPIO4=MISO, GPIO5=CS0
    iomux_connect(6, SIG_SPI0_CS1);  // extra CS1 on GPIO6

    uart_init();
    uart_puts("UART0: GPIO0/1   SPI0: GPIO2-6\r\n");
}

// ----------------------------------------------------------------------------
// Example 3: UART0 + I2C0 + PWM channels
// ----------------------------------------------------------------------------
void example_mixed_peripherals(void) {
    iomux_reset_all(IOMUX_NGPIO);

    // UART0 debug console
    iomux_preset_uart0(0, 1);

    // I2C0 sensor bus
    iomux_preset_i2c0(2, 3);          // GPIO2=SCL, GPIO3=SDA

    // PWM motor/LED outputs
    iomux_preset_pwm(4);              // GPIO4-7 = CH0-CH3

    // CAN bus on high pins
    iomux_preset_can0(8, 9);          // GPIO8=TX, GPIO9=RX

    // Two software GPIOs for LEDs
    iomux_connect(10, SIG_GPIO_OUT);
    iomux_connect(11, SIG_GPIO_OUT);

    // One software GPIO for a button input
    iomux_connect(12, SIG_GPIO_IN);

    uart_init();
    uart_puts("Mixed peripheral routing done\r\n");

    // Toggle LED on GPIO10
    iomux_gpio_write(10, 1);
    iomux_gpio_write(11, 0);

    // Read button
    uint32_t btn = iomux_gpio_read(12);
    uart_puts(btn ? "Button pressed\r\n" : "Button released\r\n");
}

// ----------------------------------------------------------------------------
// Example 4: Runtime rerouting — swap SPI from one bank to another
//   Useful when sharing a bus between two devices on different connectors.
// ----------------------------------------------------------------------------
void example_runtime_reroute(void) {
    iomux_reset_all(IOMUX_NGPIO);
    iomux_preset_uart0(0, 1);
    uart_init();

    uart_puts("SPI0 on bank A (GPIO 2-5)\r\n");
    iomux_preset_spi0(2);
    // ... use SPI here ...

    uart_puts("Moving SPI0 to bank B (GPIO 8-11)\r\n");
    // Disconnect old bank first
    iomux_disconnect(2);
    iomux_disconnect(3);
    iomux_disconnect(4);
    iomux_disconnect(5);
    // Connect new bank
    iomux_preset_spi0(8);
    // ... use SPI on new pins ...

    uart_puts("Reroute complete\r\n");
}

// ----------------------------------------------------------------------------
// Example 5: Read back and verify routing (self-test)
// ----------------------------------------------------------------------------
void example_verify_routing(void) {
    iomux_reset_all(IOMUX_NGPIO);
    iomux_preset_uart0(0, 1);
    iomux_preset_spi0(2);
    uart_init();

    uart_puts("Verifying IOMUX routing...\r\n");

    // Table of expected assignments
    struct { uint32_t pin; iomux_signal_t expected; const char *name; } checks[] = {
        {0, SIG_UART0_TX,  "GPIO0=UART0_TX "},
        {1, SIG_UART0_RX,  "GPIO1=UART0_RX "},
        {2, SIG_SPI0_SCK,  "GPIO2=SPI0_SCK "},
        {3, SIG_SPI0_MOSI, "GPIO3=SPI0_MOSI"},
        {4, SIG_SPI0_MISO, "GPIO4=SPI0_MISO"},
        {5, SIG_SPI0_CS0,  "GPIO5=SPI0_CS0 "},
        {6, SIG_HIZ,       "GPIO6=HIZ      "},
    };

    int n = sizeof(checks) / sizeof(checks[0]);
    int pass = 1;

    for (int i = 0; i < n; i++) {
        iomux_signal_t got = iomux_get(checks[i].pin);
        uart_puts("  ");
        uart_puts(checks[i].name);
        if (got == checks[i].expected) {
            uart_puts(": PASS\r\n");
        } else {
            uart_puts(": FAIL\r\n");
            pass = 0;
        }
    }

    uart_puts(pass ? "All routing checks PASSED\r\n"
                   : "ROUTING CHECK FAILED\r\n");
}

// ----------------------------------------------------------------------------
// Entry point — pick one example to run
// ----------------------------------------------------------------------------
int main(void) {
    example_mixed_peripherals();
    // example_uart_and_spi();
    // example_runtime_reroute();
    // example_verify_routing();

    TB_RESULT = 0;  // PASS
    return 0;
}
