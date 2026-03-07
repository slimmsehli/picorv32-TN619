// =============================================================================
//  TN619_top.v  —  TN619 SoC Top-Level
//
//  Signal flow for GPIO-muxed peripherals:
//
//    UART TX:   uart_axi.uart_tx ──→ iomux.uart0_tx_i
//                                         │  mux_reg[n]=UART0_TX
//                                         ↓
//                                    pad_out[n] / pad_oe[n]=1  ──→ gpio_pad[n]
//
//    UART RX:   gpio_pad[m] ──→ pad_in[m] ──→ iomux (2FF sync) ──→ gpi_sync[m]
//                                         │  mux_reg[m]=UART0_RX
//                                         ↓
//                                    iomux.uart0_rx_o ──→ uart_axi.uart_rx
//
//  All 16 GPIO pads are exposed as separate out/oe/in buses.
//  The testbench builds the actual tri-state wire and injects stimulus.
//
//  Memory Map:
//    0x0000_0000 – 0x0001_FFFF   BRAM   128 KB
//    0x4000_0000 – 0x4000_00FF   UART0  AXI4-Lite
//    0x4001_0000 – 0x4001_00FF   PWM    AXI4-Lite
//    0x400F_0000 – 0x400F_0FFF   IOMUX  AXI4-Lite
//    0x9000_0000                 TB_RESULT (testbench intercept)
// =============================================================================

`timescale 1ns/1ps

module TN619_top #(
    parameter CLK_FREQ   = 100_000_000,
    parameter BAUD_RATE  = 115_200,
    parameter GPIO_COUNT = 16,
    parameter MEM_WORDS  = 32768
)(
    input  wire                  clk,
    input  wire                  resetn,

    // ── GPIO pad interface — all 16 pads exposed as 3 buses ─────────────────
    // The testbench (or FPGA pad cell) connects these to actual inout wires.
    output wire [GPIO_COUNT-1:0] gpio_pad_out,  // drive value
    output wire [GPIO_COUNT-1:0] gpio_pad_oe,   // 1=drive  0=hi-z
    input  wire [GPIO_COUNT-1:0] gpio_pad_in,   // sampled pin value

    // ── PWM outputs (also available via IOMUX pads) ──────────────────────────
    output wire [3:0]            pwm_out,

    // ── CPU status ───────────────────────────────────────────────────────────
    output wire                  trap
);

    // =========================================================================
    // BRAM  — loaded by testbench via hierarchical reference: dut.bram
    // =========================================================================
    reg  [31:0] bram [0:MEM_WORDS-1];

    wire        bram_en;
    wire [ 3:0] bram_we;
    wire [14:0] bram_addr;
    wire [31:0] bram_wdata;
    wire [31:0] bram_rdata = bram[bram_addr];   // combinatorial

    always @(posedge clk) begin
        if (bram_en && |bram_we) begin
            if (bram_we[0]) bram[bram_addr][ 7: 0] <= bram_wdata[ 7: 0];
            if (bram_we[1]) bram[bram_addr][15: 8] <= bram_wdata[15: 8];
            if (bram_we[2]) bram[bram_addr][23:16] <= bram_wdata[23:16];
            if (bram_we[3]) bram[bram_addr][31:24] <= bram_wdata[31:24];
        end
    end

    // =========================================================================
    // CPU memory bus
    // =========================================================================
    wire        mem_valid, mem_instr;
    wire [31:0] mem_addr,  mem_wdata;
    wire [ 3:0] mem_wstrb;
    wire [31:0] mem_rdata;
    wire        mem_ready;

    // =========================================================================
    // UART0 internal wires — both go through IOMUX, NOT top-level ports
    //   uart_tx_int : uart_axi output  →  iomux uart0_tx_i  →  pad
    //   uart_rx_int : pad  →  iomux uart0_rx_o  →  uart_axi input
    // =========================================================================
    wire uart_tx_int;
    wire uart_rx_int;
    wire pwm_irq;

    // =========================================================================
    // AXI4-Lite buses
    // =========================================================================
    // UART0
    wire [31:0] u_awaddr;  wire u_awvalid; wire u_awready;
    wire [31:0] u_wdata;   wire [3:0] u_wstrb;
    wire        u_wvalid;  wire u_wready;
    wire [1:0]  u_bresp;   wire u_bvalid;  wire u_bready;
    wire [31:0] u_araddr;  wire u_arvalid; wire u_arready;
    wire [31:0] u_rdata;   wire [1:0] u_rresp;
    wire        u_rvalid;  wire u_rready;

    // PWM
    wire [31:0] p_awaddr;  wire p_awvalid; wire p_awready;
    wire [31:0] p_wdata;   wire [3:0] p_wstrb;
    wire        p_wvalid;  wire p_wready;
    wire [1:0]  p_bresp;   wire p_bvalid;  wire p_bready;
    wire [31:0] p_araddr;  wire p_arvalid; wire p_arready;
    wire [31:0] p_rdata;   wire [1:0] p_rresp;
    wire        p_rvalid;  wire p_rready;

    // IOMUX
    wire [31:0] mx_awaddr; wire mx_awvalid; wire mx_awready;
    wire [31:0] mx_wdata;  wire [3:0] mx_wstrb;
    wire        mx_wvalid; wire mx_wready;
    wire [1:0]  mx_bresp;  wire mx_bvalid;  wire mx_bready;
    wire [31:0] mx_araddr; wire mx_arvalid; wire mx_arready;
    wire [31:0] mx_rdata;  wire [1:0] mx_rresp;
    wire        mx_rvalid; wire mx_rready;

    // =========================================================================
    // PicoRV32
    // =========================================================================
    picorv32 #(
        .ENABLE_COUNTERS     (1),
        .ENABLE_REGS_16_31   (1),
        .ENABLE_REGS_DUALPORT(1),
        .COMPRESSED_ISA      (0),
        .ENABLE_MUL          (0),
        .ENABLE_DIV          (0),
        .ENABLE_IRQ          (0),
        .PROGADDR_RESET      (32'h0000_0000),
        .STACKADDR           (32'h0001_FFFC)
    ) cpu (
        .clk(clk), .resetn(resetn), .trap(trap),
        .mem_valid(mem_valid), .mem_instr(mem_instr),
        .mem_ready(mem_ready), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .mem_la_read(), .mem_la_write(), .mem_la_addr(),
        .pcpi_wr(1'b0), .pcpi_rd(32'h0),
        .pcpi_wait(1'b0), .pcpi_ready(1'b0),
        .irq(32'h0), .trace_valid(), .trace_data()
    );

    // =========================================================================
    // AXI Interconnect
    // =========================================================================
    axi_interconnect intercon (
        .clk(clk), .resetn(resetn),
        .mem_valid(mem_valid), .mem_ready(mem_ready),
        .mem_instr(mem_instr), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .bram_en(bram_en), .bram_we(bram_we),
        .bram_addr(bram_addr), .bram_wdata(bram_wdata),
        .bram_rdata(bram_rdata),
        .uart_awaddr(u_awaddr),   .uart_awvalid(u_awvalid), .uart_awready(u_awready),
        .uart_wdata(u_wdata),     .uart_wstrb(u_wstrb),
        .uart_wvalid(u_wvalid),   .uart_wready(u_wready),
        .uart_bresp(u_bresp),     .uart_bvalid(u_bvalid),   .uart_bready(u_bready),
        .uart_araddr(u_araddr),   .uart_arvalid(u_arvalid), .uart_arready(u_arready),
        .uart_rdata(u_rdata),     .uart_rresp(u_rresp),
        .uart_rvalid(u_rvalid),   .uart_rready(u_rready),
        .pwm_awaddr(p_awaddr),    .pwm_awvalid(p_awvalid),  .pwm_awready(p_awready),
        .pwm_wdata(p_wdata),      .pwm_wstrb(p_wstrb),
        .pwm_wvalid(p_wvalid),    .pwm_wready(p_wready),
        .pwm_bresp(p_bresp),      .pwm_bvalid(p_bvalid),    .pwm_bready(p_bready),
        .pwm_araddr(p_araddr),    .pwm_arvalid(p_arvalid),  .pwm_arready(p_arready),
        .pwm_rdata(p_rdata),      .pwm_rresp(p_rresp),
        .pwm_rvalid(p_rvalid),    .pwm_rready(p_rready),
        .iomux_awaddr(mx_awaddr),  .iomux_awvalid(mx_awvalid), .iomux_awready(mx_awready),
        .iomux_wdata(mx_wdata),    .iomux_wstrb(mx_wstrb),
        .iomux_wvalid(mx_wvalid),  .iomux_wready(mx_wready),
        .iomux_bresp(mx_bresp),    .iomux_bvalid(mx_bvalid),   .iomux_bready(mx_bready),
        .iomux_araddr(mx_araddr),  .iomux_arvalid(mx_arvalid), .iomux_arready(mx_arready),
        .iomux_rdata(mx_rdata),    .iomux_rresp(mx_rresp),
        .iomux_rvalid(mx_rvalid),  .iomux_rready(mx_rready)
    );

    // =========================================================================
    // UART0
    //   Both uart_tx and uart_rx are INTERNAL wires — not top-level ports.
    //   All traffic flows through the IOMUX pad bus.
    // =========================================================================
    uart_axi #(
        .CLK_FREQ(CLK_FREQ), .BAUD_RATE(BAUD_RATE)
    ) uart0 (
        .s_axi_aclk(clk), .s_axi_aresetn(resetn),
        .s_axi_awaddr(u_awaddr),   .s_axi_awvalid(u_awvalid), .s_axi_awready(u_awready),
        .s_axi_wdata(u_wdata),     .s_axi_wstrb(u_wstrb),
        .s_axi_wvalid(u_wvalid),   .s_axi_wready(u_wready),
        .s_axi_bresp(u_bresp),     .s_axi_bvalid(u_bvalid),   .s_axi_bready(u_bready),
        .s_axi_araddr(u_araddr),   .s_axi_arvalid(u_arvalid), .s_axi_arready(u_arready),
        .s_axi_rdata(u_rdata),     .s_axi_rresp(u_rresp),
        .s_axi_rvalid(u_rvalid),   .s_axi_rready(u_rready),
        .uart_tx(uart_tx_int),   // → iomux.uart0_tx_i → pad_out[n]
        .uart_rx(uart_rx_int)    // ← iomux.uart0_rx_o ← pad_in[m]
    );

    // =========================================================================
    // PWM / Timer
    // =========================================================================
    pwm_timer_axi pwm0 (
        .s_axi_aclk(clk), .s_axi_aresetn(resetn),
        .s_axi_awaddr(p_awaddr),   .s_axi_awvalid(p_awvalid), .s_axi_awready(p_awready),
        .s_axi_wdata(p_wdata),     .s_axi_wstrb(p_wstrb),
        .s_axi_wvalid(p_wvalid),   .s_axi_wready(p_wready),
        .s_axi_bresp(p_bresp),     .s_axi_bvalid(p_bvalid),   .s_axi_bready(p_bready),
        .s_axi_araddr(p_araddr),   .s_axi_arvalid(p_arvalid), .s_axi_arready(p_arready),
        .s_axi_rdata(p_rdata),     .s_axi_rresp(p_rresp),
        .s_axi_rvalid(p_rvalid),   .s_axi_rready(p_rready),
        .pwm_out(pwm_out), .irq(pwm_irq)
    );

    // =========================================================================
    // IOMUX
    //   uart0_tx_i  ← uart_tx_int   (UART output comes in here)
    //   uart0_rx_o  → uart_rx_int   (sampled pad value goes to UART input)
    //   pad_out / pad_oe → gpio_pad_out / gpio_pad_oe  (to top-level ports)
    //   pad_in           ← gpio_pad_in                 (from top-level port)
    // =========================================================================
    iomux_axi #(.GPIO_COUNT(GPIO_COUNT)) iomux0 (
        .s_axi_aclk(clk), .s_axi_aresetn(resetn),
        .s_axi_awaddr(mx_awaddr),  .s_axi_awvalid(mx_awvalid), .s_axi_awready(mx_awready),
        .s_axi_wdata(mx_wdata),    .s_axi_wstrb(mx_wstrb),
        .s_axi_wvalid(mx_wvalid),  .s_axi_wready(mx_wready),
        .s_axi_bresp(mx_bresp),    .s_axi_bvalid(mx_bvalid),   .s_axi_bready(mx_bready),
        .s_axi_araddr(mx_araddr),  .s_axi_arvalid(mx_arvalid), .s_axi_arready(mx_arready),
        .s_axi_rdata(mx_rdata),    .s_axi_rresp(mx_rresp),
        .s_axi_rvalid(mx_rvalid),  .s_axi_rready(mx_rready),
        // UART0 — fully through IOMUX
        .uart0_tx_i(uart_tx_int),
        .uart0_rx_o(uart_rx_int),
        // UART1 — not instantiated
        .uart1_tx_i(1'b1), .uart1_rx_o(),
        // SPI — not instantiated
        .spi0_sck_i(1'b0), .spi0_mosi_i(1'b0), .spi0_miso_o(),
        .spi0_cs0_i(1'b1), .spi0_cs1_i(1'b1),
        .spi1_sck_i(1'b0), .spi1_mosi_i(1'b0), .spi1_miso_o(),
        .spi1_cs0_i(1'b1),
        // I2C — not instantiated
        .i2c0_scl_io(), .i2c0_sda_io(),
        .i2c1_scl_io(), .i2c1_sda_io(),
        // PWM — from pwm_timer_axi
        .pwm_ch0_i(pwm_out[0]), .pwm_ch1_i(pwm_out[1]),
        .pwm_ch2_i(pwm_out[2]), .pwm_ch3_i(pwm_out[3]),
        // CAN — not instantiated
        .can0_tx_i(1'b1), .can0_rx_o(),
        // Pad bus
        .pad_out(gpio_pad_out),
        .pad_oe (gpio_pad_oe),
        .pad_in (gpio_pad_in)
    );

endmodule
