`timescale 1ns/1ps
// =============================================================================
//  tb_soc.v  —  Full SoC Testbench
//  PicoRV32 + UART AXI + PWM Timer AXI + BRAM
// =============================================================================
module tb_soc;

    // -------------------------------------------------------------------------
    // Parameters (overridable via +define or plusargs)
    // -------------------------------------------------------------------------
    parameter MEM_WORDS  = 32768;
    parameter CLK_PERIOD = 10;           // 10ns = 100MHz
    parameter MAX_CYCLES = 50_000_000;

    // Plusarg overrides
    reg [255:0] mem_file_arg;
    reg [255:0] vcd_file_arg;
    initial begin
        if (!$value$plusargs("MEM_FILE=%s", mem_file_arg))
            mem_file_arg = "firmware.hex";
        if (!$value$plusargs("VCD_FILE=%s", vcd_file_arg))
            vcd_file_arg = "waves.vcd";
    end

    // -------------------------------------------------------------------------
    // Clock & Reset
    // -------------------------------------------------------------------------
    reg clk    = 0;
    reg resetn = 0;
    always #(CLK_PERIOD/2) clk = ~clk;
    initial begin repeat(8) @(posedge clk); resetn = 1; end

    // -------------------------------------------------------------------------
    // PicoRV32 signals
    // -------------------------------------------------------------------------
    wire        trap;
    wire        mem_valid, mem_instr;
    wire [31:0] mem_addr, mem_wdata;
    wire [ 3:0] mem_wstrb;
    wire [31:0] mem_rdata;
    wire        mem_ready;

    // -------------------------------------------------------------------------
    // BRAM
    // -------------------------------------------------------------------------
    reg  [31:0] bram [0:MEM_WORDS-1];
    wire        bram_en;
    wire [ 3:0] bram_we;
    wire [16:0] bram_addr_w;
    wire [31:0] bram_wdata_w;
    reg  [31:0] bram_rdata;

    always @(posedge clk) begin
        if (bram_en) begin
            if (bram_we[0]) bram[bram_addr_w][ 7: 0] <= bram_wdata_w[ 7: 0];
            if (bram_we[1]) bram[bram_addr_w][15: 8] <= bram_wdata_w[15: 8];
            if (bram_we[2]) bram[bram_addr_w][23:16] <= bram_wdata_w[23:16];
            if (bram_we[3]) bram[bram_addr_w][31:24] <= bram_wdata_w[31:24];
            bram_rdata <= bram[bram_addr_w];
        end
    end

    initial begin
        integer i;
        for (i = 0; i < MEM_WORDS; i = i+1) bram[i] = 32'h0000_0013;
        $readmemh(mem_file_arg, bram);
        $display("[TB] Loaded firmware from: %s", mem_file_arg);
    end

    // -------------------------------------------------------------------------
    // AXI wires: UART
    // -------------------------------------------------------------------------
    wire [31:0] u_awaddr; wire u_awvalid; wire u_awready;
    wire [31:0] u_wdata;  wire [3:0] u_wstrb;
    wire        u_wvalid; wire u_wready;
    wire [1:0]  u_bresp;  wire u_bvalid; wire u_bready;
    wire [31:0] u_araddr; wire u_arvalid; wire u_arready;
    wire [31:0] u_rdata;  wire [1:0] u_rresp;
    wire        u_rvalid; wire u_rready;
    wire        uart_tx_pin;
    wire        uart_rx_pin = uart_tx_pin;   // loopback

    // -------------------------------------------------------------------------
    // AXI wires: PWM
    // -------------------------------------------------------------------------
    wire [31:0] p_awaddr; wire p_awvalid; wire p_awready;
    wire [31:0] p_wdata;  wire [3:0] p_wstrb;
    wire        p_wvalid; wire p_wready;
    wire [1:0]  p_bresp;  wire p_bvalid; wire p_bready;
    wire [31:0] p_araddr; wire p_arvalid; wire p_arready;
    wire [31:0] p_rdata;  wire [1:0] p_rresp;
    wire        p_rvalid; wire p_rready;
    wire [3:0]  pwm_out;
    wire        pwm_irq;

    // -------------------------------------------------------------------------
    // PicoRV32
    // -------------------------------------------------------------------------
    picorv32 #(
        .ENABLE_COUNTERS    (1),
        .ENABLE_REGS_16_31  (1),
        .ENABLE_REGS_DUALPORT(1),
        .COMPRESSED_ISA     (0),
        .ENABLE_MUL         (0),
        .ENABLE_DIV         (0),
        .ENABLE_IRQ         (0),
        .PROGADDR_RESET     (32'h0000_0000),
        .STACKADDR          (32'h0002_0000)
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

    // -------------------------------------------------------------------------
    // Interconnect
    // -------------------------------------------------------------------------
    axi_intercon intercon (
        .clk(clk), .resetn(resetn),
        .mem_valid(mem_valid), .mem_ready(mem_ready),
        .mem_instr(mem_instr), .mem_addr(mem_addr),
        .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .bram_en(bram_en), .bram_we(bram_we),
        .bram_addr(bram_addr_w), .bram_wdata(bram_wdata_w),
        .bram_rdata(bram_rdata),
        .uart_awaddr(u_awaddr), .uart_awvalid(u_awvalid), .uart_awready(u_awready),
        .uart_wdata(u_wdata),   .uart_wstrb(u_wstrb),
        .uart_wvalid(u_wvalid), .uart_wready(u_wready),
        .uart_bresp(u_bresp),   .uart_bvalid(u_bvalid),   .uart_bready(u_bready),
        .uart_araddr(u_araddr), .uart_arvalid(u_arvalid), .uart_arready(u_arready),
        .uart_rdata(u_rdata),   .uart_rresp(u_rresp),
        .uart_rvalid(u_rvalid), .uart_rready(u_rready),
        .pwm_awaddr(p_awaddr),  .pwm_awvalid(p_awvalid),  .pwm_awready(p_awready),
        .pwm_wdata(p_wdata),    .pwm_wstrb(p_wstrb),
        .pwm_wvalid(p_wvalid),  .pwm_wready(p_wready),
        .pwm_bresp(p_bresp),    .pwm_bvalid(p_bvalid),    .pwm_bready(p_bready),
        .pwm_araddr(p_araddr),  .pwm_arvalid(p_arvalid),  .pwm_arready(p_arready),
        .pwm_rdata(p_rdata),    .pwm_rresp(p_rresp),
        .pwm_rvalid(p_rvalid),  .pwm_rready(p_rready)
    );

    // -------------------------------------------------------------------------
    // UART IP
    // -------------------------------------------------------------------------
    uart_axi #(.CLK_FREQ(100_000_000), .BAUD_RATE(115200)) uart0 (
        .s_axi_aclk(clk), .s_axi_aresetn(resetn),
        .s_axi_awaddr(u_awaddr),  .s_axi_awvalid(u_awvalid), .s_axi_awready(u_awready),
        .s_axi_wdata(u_wdata),    .s_axi_wstrb(u_wstrb),
        .s_axi_wvalid(u_wvalid),  .s_axi_wready(u_wready),
        .s_axi_bresp(u_bresp),    .s_axi_bvalid(u_bvalid),   .s_axi_bready(u_bready),
        .s_axi_araddr(u_araddr),  .s_axi_arvalid(u_arvalid), .s_axi_arready(u_arready),
        .s_axi_rdata(u_rdata),    .s_axi_rresp(u_rresp),
        .s_axi_rvalid(u_rvalid),  .s_axi_rready(u_rready),
        .uart_tx(uart_tx_pin), .uart_rx(uart_rx_pin)
    );

    // -------------------------------------------------------------------------
    // PWM/Timer IP
    // -------------------------------------------------------------------------
    pwm_timer_axi pwm0 (
        .s_axi_aclk(clk), .s_axi_aresetn(resetn),
        .s_axi_awaddr(p_awaddr),  .s_axi_awvalid(p_awvalid), .s_axi_awready(p_awready),
        .s_axi_wdata(p_wdata),    .s_axi_wstrb(p_wstrb),
        .s_axi_wvalid(p_wvalid),  .s_axi_wready(p_wready),
        .s_axi_bresp(p_bresp),    .s_axi_bvalid(p_bvalid),   .s_axi_bready(p_bready),
        .s_axi_araddr(p_araddr),  .s_axi_arvalid(p_arvalid), .s_axi_arready(p_arready),
        .s_axi_rdata(p_rdata),    .s_axi_rresp(p_rresp),
        .s_axi_rvalid(p_rvalid),  .s_axi_rready(p_rready),
        .pwm_out(pwm_out), .irq(pwm_irq)
    );

    // -------------------------------------------------------------------------
    // UART TX monitor — decode serial bits and print to console
    // -------------------------------------------------------------------------
    integer uart_state = 0, uart_cnt = 0, uart_bit = 0;
    reg [7:0] uart_byte = 0;
    always @(posedge clk) begin
        case (uart_state)
            0: if (uart_tx_pin == 0) begin
                   uart_state <= 1;
                   uart_cnt   <= 434;   // half-bit @ 100MHz/115200
                   uart_bit   <= 0;
                   uart_byte  <= 0;
               end
            1: if (uart_cnt == 0) begin
                   uart_cnt <= 867;
                   if (uart_bit < 8) begin
                       uart_byte <= {uart_tx_pin, uart_byte[7:1]};
                       uart_bit  <= uart_bit + 1;
                   end else begin
                       $write("%c", uart_byte);
                       uart_state <= 0;
                   end
               end else uart_cnt <= uart_cnt - 1;
        endcase
    end

    // -------------------------------------------------------------------------
    // PASS/FAIL intercept at 0x9000_0000
    // -------------------------------------------------------------------------
    reg test_done = 0;
    always @(posedge clk) begin
        if (mem_valid && mem_ready && mem_wstrb != 4'h0
                && mem_addr == 32'h9000_0000) begin
            test_done <= 1;
            if (mem_wdata == 0)
                $display("\n[TB] *** ALL TESTS PASSED ***");
            else
                $display("\n[TB] *** FAILED: %0d test(s) failed ***", mem_wdata);
        end
    end

    // -------------------------------------------------------------------------
    // Cycle counter + watchdog + trap
    // -------------------------------------------------------------------------
    integer cycles = 0;
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (cycles >= MAX_CYCLES) begin
            $display("[TB] TIMEOUT after %0d cycles", MAX_CYCLES);
            $finish;
        end
        if (resetn && trap) begin
            $display("[TB] TRAP at cycle %0d  pc=0x%08X", cycles, cpu.reg_pc);
            #(CLK_PERIOD*5); $finish;
        end
        if (test_done) begin
            $display("[TB] Finished in %0d cycles", cycles);
            #(CLK_PERIOD*5); $finish;
        end
    end

    // -------------------------------------------------------------------------
    // VCD dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile(vcd_file_arg);
        $dumpvars(0, tb_soc);
        $display("=================================================");
        $display("  PicoRV32 SoC Testbench");
        $display("  UART + PWM/Timer @ 100MHz");
        $display("=================================================");
    end

endmodule
