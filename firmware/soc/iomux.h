#ifndef IOMUX_H
#define IOMUX_H

// =============================================================================
//  iomux.h  —  Runtime IO Multiplexer driver for PicoRV32 SoC
//
//  The IOMUX lets firmware route any peripheral signal to any GPIO pad
//  at runtime by writing to AXI-mapped registers.
//
//  Usage example:
//
//    iomux_connect(0, SIG_UART0_TX);   // GPIO0 → UART0 TX
//    iomux_connect(1, SIG_UART0_RX);   // GPIO1 → UART0 RX
//    iomux_connect(2, SIG_SPI0_SCK);   // GPIO2 → SPI0 clock
//    iomux_connect(3, SIG_SPI0_MOSI);  // GPIO3 → SPI0 MOSI
//    iomux_connect(4, SIG_SPI0_MISO);  // GPIO4 → SPI0 MISO
//    iomux_connect(5, SIG_SPI0_CS0);   // GPIO5 → SPI0 CS0
//
//  Memory map (base 0x400F_0000):
//    0x00        IOMUX_ID        read-only: 0x10CECA51
//    0x04        IOMUX_NGPIO     read-only: number of GPIO pads
//    0x08        IOMUX_NSIG      read-only: number of routable signals
//    0x0C        reserved
//    0x40+n*4    IOMUX_GPIO[n]   R/W [7:0]: signal ID for GPIO pad n
//    0xC0        IOMUX_GPODATA   R/W: output values for SIG_GPIO_OUT pins
//    0xC4        IOMUX_GPIDATA   R:   sampled input values for SIG_GPIO_IN pins
// =============================================================================

#include <stdint.h>

// ----------------------------------------------------------------------------
// Base address and register layout
// ----------------------------------------------------------------------------
#define IOMUX_BASE          0x400F0000UL

#define IOMUX_ID            (*(volatile uint32_t*)(IOMUX_BASE + 0x00))
#define IOMUX_NGPIO         (*(volatile uint32_t*)(IOMUX_BASE + 0x04))
#define IOMUX_NSIG          (*(volatile uint32_t*)(IOMUX_BASE + 0x08))

// Per-pin mux register: IOMUX_PIN(n) selects the signal on GPIO pad n
#define IOMUX_PIN(n)        (*(volatile uint32_t*)(IOMUX_BASE + 0x40 + (n)*4))

// Software GPIO data registers (used when pin is set to SIG_GPIO_OUT/IN)
#define IOMUX_GPODATA       (*(volatile uint32_t*)(IOMUX_BASE + 0xC0))
#define IOMUX_GPIDATA       (*(volatile uint32_t*)(IOMUX_BASE + 0xC4))

#define IOMUX_EXPECTED_ID   0x10CECA51UL

// ----------------------------------------------------------------------------
// Signal ID definitions
//   Assign one of these to IOMUX_PIN(n) to route that signal to GPIO pad n.
//   SIG_HIZ = floating input, no drive (default/safe state).
// ----------------------------------------------------------------------------
typedef enum {
    SIG_HIZ       = 0x00,  // Hi-Z: no drive, pin floats
    // UART
    SIG_UART0_TX  = 0x01,
    SIG_UART0_RX  = 0x02,
    SIG_UART1_TX  = 0x03,
    SIG_UART1_RX  = 0x04,
    // SPI
    SIG_SPI0_SCK  = 0x05,
    SIG_SPI0_MOSI = 0x06,
    SIG_SPI0_MISO = 0x07,
    SIG_SPI0_CS0  = 0x08,
    SIG_SPI0_CS1  = 0x09,
    SIG_SPI1_SCK  = 0x0A,
    SIG_SPI1_MOSI = 0x0B,
    SIG_SPI1_MISO = 0x0C,
    SIG_SPI1_CS0  = 0x0D,
    // I2C (open-drain, both directions)
    SIG_I2C0_SCL  = 0x0E,
    SIG_I2C0_SDA  = 0x0F,
    SIG_I2C1_SCL  = 0x10,
    SIG_I2C1_SDA  = 0x11,
    // PWM outputs
    SIG_PWM_CH0   = 0x12,
    SIG_PWM_CH1   = 0x13,
    SIG_PWM_CH2   = 0x14,
    SIG_PWM_CH3   = 0x15,
    // CAN
    SIG_CAN0_TX   = 0x16,
    SIG_CAN0_RX   = 0x17,
    // Software GPIO
    SIG_GPIO_OUT  = 0x18,  // driven by IOMUX_GPODATA bit
    SIG_GPIO_IN   = 0x19,  // sampled into IOMUX_GPIDATA bit
} iomux_signal_t;

// ----------------------------------------------------------------------------
// Driver functions
// ----------------------------------------------------------------------------

// Verify the IOMUX peripheral is present and responding.
// Returns 1 on success, 0 if ID register doesn't match.
static inline int iomux_probe(void) {
    return (IOMUX_ID == IOMUX_EXPECTED_ID) ? 1 : 0;
}

// Route signal `sig` to GPIO pad `pin`.
// Safe to call at any time; change takes effect in the next clock cycle.
static inline void iomux_connect(uint32_t pin, iomux_signal_t sig) {
    IOMUX_PIN(pin) = (uint32_t)sig;
}

// Disconnect a GPIO pad (set to Hi-Z / floating input).
static inline void iomux_disconnect(uint32_t pin) {
    IOMUX_PIN(pin) = SIG_HIZ;
}

// Read back the currently configured signal for a pad.
static inline iomux_signal_t iomux_get(uint32_t pin) {
    return (iomux_signal_t)(IOMUX_PIN(pin) & 0xFF);
}

// Disconnect all pads (reset to safe Hi-Z state).
static inline void iomux_reset_all(uint32_t ngpio) {
    uint32_t i;
    for (i = 0; i < ngpio; i++)
        IOMUX_PIN(i) = SIG_HIZ;
}

// Set output value for a pad configured as SIG_GPIO_OUT.
// `pin` is the pad index, `val` is 0 or 1.
static inline void iomux_gpio_write(uint32_t pin, uint32_t val) {
    if (val)
        IOMUX_GPODATA |=  (1u << pin);
    else
        IOMUX_GPODATA &= ~(1u << pin);
}

// Read sampled input value for a pad configured as SIG_GPIO_IN.
static inline uint32_t iomux_gpio_read(uint32_t pin) {
    return (IOMUX_GPIDATA >> pin) & 1u;
}

// ----------------------------------------------------------------------------
// Preset routing configurations
//   Call one of these to quickly configure a standard pinout.
//   Adjust GPIO numbers to match your board layout.
// ----------------------------------------------------------------------------

// Default UART0 on GPIO 0/1
static inline void iomux_preset_uart0(uint32_t tx_pin, uint32_t rx_pin) {
    iomux_connect(tx_pin, SIG_UART0_TX);
    iomux_connect(rx_pin, SIG_UART0_RX);
}

// SPI0 on 4 consecutive pins starting at `base`
// Order: SCK, MOSI, MISO, CS0
static inline void iomux_preset_spi0(uint32_t base) {
    iomux_connect(base + 0, SIG_SPI0_SCK);
    iomux_connect(base + 1, SIG_SPI0_MOSI);
    iomux_connect(base + 2, SIG_SPI0_MISO);
    iomux_connect(base + 3, SIG_SPI0_CS0);
}

// I2C0 on two pins
static inline void iomux_preset_i2c0(uint32_t scl_pin, uint32_t sda_pin) {
    iomux_connect(scl_pin, SIG_I2C0_SCL);
    iomux_connect(sda_pin, SIG_I2C0_SDA);
}

// PWM: route all 4 channels to 4 consecutive pins starting at `base`
static inline void iomux_preset_pwm(uint32_t base) {
    iomux_connect(base + 0, SIG_PWM_CH0);
    iomux_connect(base + 1, SIG_PWM_CH1);
    iomux_connect(base + 2, SIG_PWM_CH2);
    iomux_connect(base + 3, SIG_PWM_CH3);
}

// CAN0 on two pins
static inline void iomux_preset_can0(uint32_t tx_pin, uint32_t rx_pin) {
    iomux_connect(tx_pin, SIG_CAN0_TX);
    iomux_connect(rx_pin, SIG_CAN0_RX);
}

#endif // IOMUX_H
