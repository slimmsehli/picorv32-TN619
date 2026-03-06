// =============================================================================
//  iomux_axi.v  —  Runtime-configurable IO Multiplexer
//
//  Allows the C firmware to route any peripheral signal to any GPIO pin
//  at runtime by writing to AXI-mapped registers.
//
//  Architecture:
//    - Each GPIO pin has one 32-bit register: IOMUX_GPIO[n]
//    - The register value selects which peripheral signal drives that pin
//    - Signal encoding is defined in iomux.h (shared with C firmware)
//
//  Register Map (base = 0x400F_0000):
//    0x00        IOMUX_ID      [31:0]  read-only: 0x10MUXSOC (identity)
//    0x04        IOMUX_NGPIO   [31:0]  read-only: number of GPIO pins
//    0x08        IOMUX_NSIG    [31:0]  read-only: number of routable signals
//    0x0C        reserved
//    0x40+n*4    IOMUX_GPIO[n] [7:0]   R/W: signal ID mapped to GPIO n
//                                      0x00 = Hi-Z (disconnected)
//
//  Signal ID encoding (matches iomux.h):
//    0x00  HI_Z        — pin floats (input only, no drive)
//    0x01  UART0_TX
//    0x02  UART0_RX
//    0x03  UART1_TX
//    0x04  UART1_RX
//    0x05  SPI0_SCK
//    0x06  SPI0_MOSI
//    0x07  SPI0_MISO
//    0x08  SPI0_CS0
//    0x09  SPI0_CS1
//    0x0A  SPI1_SCK
//    0x0B  SPI1_MOSI
//    0x0C  SPI1_MISO
//    0x0D  SPI1_CS0
//    0x0E  I2C0_SCL
//    0x0F  I2C0_SDA
//    0x10  I2C1_SCL
//    0x11  I2C1_SDA
//    0x12  PWM_CH0
//    0x13  PWM_CH1
//    0x14  PWM_CH2
//    0x15  PWM_CH3
//    0x16  CAN0_TX
//    0x17  CAN0_RX
//    0x18  GPIO_OUT    — general purpose output (driven by IOMUX_GPODATA reg)
//    0x19  GPIO_IN     — general purpose input  (read via  IOMUX_GPIDATA reg)
//
//  Extra registers for GPIO_OUT/IN mode:
//    0x00C0  IOMUX_GPODATA  [GPIO_COUNT-1:0]  R/W  output values
//    0x00C4  IOMUX_GPIDATA  [GPIO_COUNT-1:0]  R    input  values (sampled)
//
//  Bus: AXI4-Lite, 32-bit, accepts AW+W in same cycle
// =============================================================================

`timescale 1ns/1ps

module iomux_axi #(
    parameter GPIO_COUNT = 16   // number of physical GPIO pads
)(
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,

    // AXI4-Lite Write Address
    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,

    // AXI4-Lite Write Data
    input  wire [31:0] s_axi_wdata,
    input  wire [ 3:0] s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,

    // AXI4-Lite Write Response
    output reg  [ 1:0] s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,

    // AXI4-Lite Read Address
    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,

    // AXI4-Lite Read Data
    output reg  [31:0] s_axi_rdata,
    output reg  [ 1:0] s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    // ── Peripheral signal inputs (from peripheral modules) ──────────────────
    input  wire        uart0_tx_i,   // UART0 TX output from peripheral
    output wire        uart0_rx_o,   // UART0 RX input  to   peripheral
    input  wire        uart1_tx_i,
    output wire        uart1_rx_o,
    input  wire        spi0_sck_i,
    input  wire        spi0_mosi_i,
    output wire        spi0_miso_o,
    input  wire        spi0_cs0_i,
    input  wire        spi0_cs1_i,
    input  wire        spi1_sck_i,
    input  wire        spi1_mosi_i,
    output wire        spi1_miso_o,
    input  wire        spi1_cs0_i,
    inout  wire        i2c0_scl_io,  // open-drain — tristated externally
    inout  wire        i2c0_sda_io,
    inout  wire        i2c1_scl_io,
    inout  wire        i2c1_sda_io,
    input  wire        pwm_ch0_i,
    input  wire        pwm_ch1_i,
    input  wire        pwm_ch2_i,
    input  wire        pwm_ch3_i,
    input  wire        can0_tx_i,
    output wire        can0_rx_o,

    // ── Physical GPIO pads ───────────────────────────────────────────────────
    // Each pad: pad_out drives the pin when pad_oe=1, pad_in reads the pin
    output reg  [GPIO_COUNT-1:0] pad_out,  // output data to pad driver
    output reg  [GPIO_COUNT-1:0] pad_oe,   // output enable  (1 = drive)
    input  wire [GPIO_COUNT-1:0] pad_in    // input  data from pad
);

    // -------------------------------------------------------------------------
    // Signal ID constants — must match iomux.h
    // -------------------------------------------------------------------------
    localparam [7:0]
        SIG_HIZ      = 8'h00,
        SIG_UART0_TX = 8'h01,
        SIG_UART0_RX = 8'h02,
        SIG_UART1_TX = 8'h03,
        SIG_UART1_RX = 8'h04,
        SIG_SPI0_SCK = 8'h05,
        SIG_SPI0_MOSI= 8'h06,
        SIG_SPI0_MISO= 8'h07,
        SIG_SPI0_CS0 = 8'h08,
        SIG_SPI0_CS1 = 8'h09,
        SIG_SPI1_SCK = 8'h0A,
        SIG_SPI1_MOSI= 8'h0B,
        SIG_SPI1_MISO= 8'h0C,
        SIG_SPI1_CS0 = 8'h0D,
        SIG_I2C0_SCL = 8'h0E,
        SIG_I2C0_SDA = 8'h0F,
        SIG_I2C1_SCL = 8'h10,
        SIG_I2C1_SDA = 8'h11,
        SIG_PWM_CH0  = 8'h12,
        SIG_PWM_CH1  = 8'h13,
        SIG_PWM_CH2  = 8'h14,
        SIG_PWM_CH3  = 8'h15,
        SIG_CAN0_TX  = 8'h16,
        SIG_CAN0_RX  = 8'h17,
        SIG_GPIO_OUT = 8'h18,
        SIG_GPIO_IN  = 8'h19,
        SIG_MAX      = 8'h19;

    // -------------------------------------------------------------------------
    // IOMUX configuration registers
    //   mux_reg[n] = signal ID assigned to GPIO pad n
    // -------------------------------------------------------------------------
    reg [7:0] mux_reg [0:GPIO_COUNT-1];

    // Software-driven GPIO data registers
    reg [GPIO_COUNT-1:0] gpo_data;  // output values when SIG_GPIO_OUT
    reg [GPIO_COUNT-1:0] gpi_sync;  // synchronised input snapshot

    integer init_i;
    initial begin
        for (init_i = 0; init_i < GPIO_COUNT; init_i = init_i + 1)
            mux_reg[init_i] = SIG_HIZ;
        gpo_data = {GPIO_COUNT{1'b0}};
    end

    // -------------------------------------------------------------------------
    // AXI4-Lite Write
    // -------------------------------------------------------------------------
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 0; s_axi_wready <= 0;
            s_axi_bvalid  <= 0; s_axi_bresp  <= 0;
            gpo_data <= {GPIO_COUNT{1'b0}};
        end else begin
            s_axi_awready <= 0;
            s_axi_wready  <= 0;

            if (s_axi_awvalid && s_axi_wvalid &&
                !s_axi_awready && !s_axi_wready) begin

                s_axi_awready <= 1;
                s_axi_wready  <= 1;

                // IOMUX_GPIO[n] registers: offset 0x40 + n*4
                if (s_axi_awaddr[9:8] == 2'b01) begin
                    // offset 0x40..0x40+GPIO_COUNT*4
                    // index = (addr - 0x40) / 4
                    begin : wr_mux
                        integer n;
                        n = (s_axi_awaddr[7:2]);  // word index from bit 2
                        // subtract 0x10 (0x40 >> 2 = 0x10)
                        if ((n >= 8'h10) && (n < (8'h10 + GPIO_COUNT))) begin
                            if (s_axi_wstrb[0])
                                mux_reg[n - 8'h10] <= s_axi_wdata[7:0];
                        end
                    end
                end

                // GPO data register: offset 0x00C0
                if (s_axi_awaddr[9:2] == 8'h30) begin
                    if (s_axi_wstrb[0]) gpo_data[ 7: 0] <= s_axi_wdata[ 7: 0];
                    if (s_axi_wstrb[1]) gpo_data[15: 8] <= s_axi_wdata[15: 8];
                end

                if (!s_axi_bvalid) begin
                    s_axi_bvalid <= 1;
                    s_axi_bresp  <= 2'b00;
                end
            end

            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 0;
        end
    end

    // -------------------------------------------------------------------------
    // AXI4-Lite Read
    // -------------------------------------------------------------------------
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 0;
            s_axi_rvalid  <= 0;
            s_axi_rdata   <= 0;
            s_axi_rresp   <= 0;
        end else begin
            s_axi_arready <= 0;

            if (s_axi_arvalid && !s_axi_arready) begin
                s_axi_arready <= 1;
                s_axi_rvalid  <= 1;
                s_axi_rresp   <= 2'b00;

                casez (s_axi_araddr[9:2])
                    // Identity / info registers (offset 0x00–0x0C)
                    8'h00: s_axi_rdata <= 32'h10CECA51; // IOMUX identity
                    8'h01: s_axi_rdata <= GPIO_COUNT;
                    8'h02: s_axi_rdata <= {24'h0, SIG_MAX};
                    8'h03: s_axi_rdata <= 32'h0;

                    // GPO data  offset 0xC0
                    8'h30: s_axi_rdata <= {{(32-GPIO_COUNT){1'b0}}, gpo_data};
                    // GPI data  offset 0xC4
                    8'h31: s_axi_rdata <= {{(32-GPIO_COUNT){1'b0}}, gpi_sync};

                    // IOMUX_GPIO[n] at offset 0x40 + n*4  → word index 0x10..
                    default: begin
                        begin : rd_mux
                            integer n;
                            n = s_axi_araddr[7:2];
                            if ((n >= 8'h10) && (n < (8'h10 + GPIO_COUNT)))
                                s_axi_rdata <= {24'h0, mux_reg[n - 8'h10]};
                            else
                                s_axi_rdata <= 32'hDEADBEEF;
                        end
                    end
                endcase
            end

            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 0;
        end
    end

    // -------------------------------------------------------------------------
    // Input synchroniser  (2-FF for metastability)
    // -------------------------------------------------------------------------
    reg [GPIO_COUNT-1:0] pad_in_sync1;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            pad_in_sync1 <= 0;
            gpi_sync     <= 0;
        end else begin
            pad_in_sync1 <= pad_in;
            gpi_sync     <= pad_in_sync1;
        end
    end

    // -------------------------------------------------------------------------
    // Output MUX — combinatorial
    //   For each GPIO pad, select pad_out and pad_oe based on mux_reg[n]
    // -------------------------------------------------------------------------

    // Helper: which pad (if any) is an INPUT signal routed to?
    // For input signals (UART_RX, SPI_MISO, CAN_RX, I2C, GPI)
    // we sample gpi_sync[n] when that signal is connected.

    // Route input signals back to peripherals:
    // Each input signal is OR-reduced over all pads assigned to it.
    // (Only one pad should be assigned; OR is safe for single assignment.)
    function automatic find_input_sig;
        input [7:0] sig_id;
        integer     k;
        reg         found;
        begin
            found = 1'b1; // default high (UART idle = 1, SPI MISO = don't-care)
            // scan all pads for the one assigned this signal
            begin : scan
                integer m;
                for (m = 0; m < GPIO_COUNT; m = m + 1) begin
                    if (mux_reg[m] == sig_id)
                        found = gpi_sync[m];
                end
            end
            find_input_sig = found;
        end
    endfunction

    // Route peripheral inputs — driven combinatorially from gpi_sync
    assign uart0_rx_o  = find_input_sig(SIG_UART0_RX);
    assign uart1_rx_o  = find_input_sig(SIG_UART1_RX);
    assign spi0_miso_o = find_input_sig(SIG_SPI0_MISO);
    assign spi1_miso_o = find_input_sig(SIG_SPI1_MISO);
    assign can0_rx_o   = find_input_sig(SIG_CAN0_RX);

    // I2C open-drain: drive low when peripheral pulls low, else Hi-Z
    assign i2c0_scl_io = 1'bz; // actual drive controlled by I2C peripheral
    assign i2c0_sda_io = 1'bz;
    assign i2c1_scl_io = 1'bz;
    assign i2c1_sda_io = 1'bz;

    // ── Per-pad output MUX ────────────────────────────────────────────────────
    integer n;
    always @(*) begin
        for (n = 0; n < GPIO_COUNT; n = n + 1) begin
            case (mux_reg[n])
                SIG_HIZ:      begin pad_out[n] = 1'b0; pad_oe[n] = 1'b0; end
                SIG_UART0_TX: begin pad_out[n] = uart0_tx_i; pad_oe[n] = 1'b1; end
                SIG_UART0_RX: begin pad_out[n] = 1'b0;       pad_oe[n] = 1'b0; end // input
                SIG_UART1_TX: begin pad_out[n] = uart1_tx_i; pad_oe[n] = 1'b1; end
                SIG_UART1_RX: begin pad_out[n] = 1'b0;       pad_oe[n] = 1'b0; end
                SIG_SPI0_SCK: begin pad_out[n] = spi0_sck_i; pad_oe[n] = 1'b1; end
                SIG_SPI0_MOSI:begin pad_out[n] = spi0_mosi_i;pad_oe[n] = 1'b1; end
                SIG_SPI0_MISO:begin pad_out[n] = 1'b0;       pad_oe[n] = 1'b0; end
                SIG_SPI0_CS0: begin pad_out[n] = spi0_cs0_i; pad_oe[n] = 1'b1; end
                SIG_SPI0_CS1: begin pad_out[n] = spi0_cs1_i; pad_oe[n] = 1'b1; end
                SIG_SPI1_SCK: begin pad_out[n] = spi1_sck_i; pad_oe[n] = 1'b1; end
                SIG_SPI1_MOSI:begin pad_out[n] = spi1_mosi_i;pad_oe[n] = 1'b1; end
                SIG_SPI1_MISO:begin pad_out[n] = 1'b0;       pad_oe[n] = 1'b0; end
                SIG_SPI1_CS0: begin pad_out[n] = spi1_cs0_i; pad_oe[n] = 1'b1; end
                SIG_I2C0_SCL: begin pad_out[n] = i2c0_scl_io;pad_oe[n] = ~i2c0_scl_io; end
                SIG_I2C0_SDA: begin pad_out[n] = i2c0_sda_io;pad_oe[n] = ~i2c0_sda_io; end
                SIG_I2C1_SCL: begin pad_out[n] = i2c1_scl_io;pad_oe[n] = ~i2c1_scl_io; end
                SIG_I2C1_SDA: begin pad_out[n] = i2c1_sda_io;pad_oe[n] = ~i2c1_sda_io; end
                SIG_PWM_CH0:  begin pad_out[n] = pwm_ch0_i;  pad_oe[n] = 1'b1; end
                SIG_PWM_CH1:  begin pad_out[n] = pwm_ch1_i;  pad_oe[n] = 1'b1; end
                SIG_PWM_CH2:  begin pad_out[n] = pwm_ch2_i;  pad_oe[n] = 1'b1; end
                SIG_PWM_CH3:  begin pad_out[n] = pwm_ch3_i;  pad_oe[n] = 1'b1; end
                SIG_CAN0_TX:  begin pad_out[n] = can0_tx_i;  pad_oe[n] = 1'b1; end
                SIG_CAN0_RX:  begin pad_out[n] = 1'b0;       pad_oe[n] = 1'b0; end
                SIG_GPIO_OUT: begin pad_out[n] = gpo_data[n]; pad_oe[n] = 1'b1; end
                SIG_GPIO_IN:  begin pad_out[n] = 1'b0;        pad_oe[n] = 1'b0; end
                default:      begin pad_out[n] = 1'b0;        pad_oe[n] = 1'b0; end
            endcase
        end
    end

endmodule
