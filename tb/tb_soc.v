`timescale 1ns/1ps
// =============================================================================
//  tb_soc.v  —  TN619 SoC Testbench
//
//  The DUT is TN619_top.  No hardware modules are instantiated here.
//
//  GPIO pad model:
//    TN619_top exposes three buses: gpio_pad_out[15:0], gpio_pad_oe[15:0],
//    gpio_pad_in[15:0].  The testbench builds the physical inout wire:
//
//        gpio_pad[n] = gpio_pad_oe[n] ? gpio_pad_out[n] : 1'bz
//        gpio_pad_in  = gpio_pad  (plus TB stimulus injection)
//
//  UART loopback:
//    When firmware routes UART0_TX → GPIO1 and UART0_RX → GPIO2,
//    the testbench drives GPIO2 pad_in with whatever GPIO1 is outputting.
//    This makes the loopback test work end-to-end through the real pad bus.
//
//  UART monitor:
//    Reads from gpio_pad_out[TX_PAD] directly — the real serial waveform.
//
//  Compile:
//    iverilog -o sim.vvp tb_soc.v TN619_top.v axi_interconnect.v \
//             uart_axi.v pwm_timer_axi.v iomux_axi.v picorv32.v
//    vvp sim.vvp +MEM_FILE=firmware.hex +VCD_FILE=waves.vcd
// =============================================================================

module tb_soc;

    parameter CLK_PERIOD = 10;
    parameter MAX_CYCLES = 500_000_000;
    parameter GPIO_COUNT = 16;
    parameter MEM_WORDS  = 32768;
    parameter VERBOSE    = 0;

    // Bit periods at 115200 baud / 100 MHz clock
    localparam UART_HALF = 434;
    localparam UART_FULL = 868;

    // Pad numbers matching the firmware routing
    localparam TX_PAD = 0;   // UART0_TX → GPIO0
    localparam RX_PAD = 1;   // UART0_RX → GPIO1

    // =========================================================================
    // Firmware / VCD paths
    // =========================================================================
    reg [512*8-1:0] mem_file_padded;
    reg [512*8-1:0] vcd_file_padded;
    reg [255:0]     mem_file;
    reg [255:0]     vcd_file;

    initial begin
        if (!$value$plusargs("MEM_FILE=%s", mem_file_padded))
            mem_file_padded = "firmware.hex";
        if (!$value$plusargs("VCD_FILE=%s", vcd_file_padded))
            vcd_file_padded = "waves.vcd";
        mem_file = mem_file_padded[255:0];
        vcd_file = vcd_file_padded[255:0];
    end

    // =========================================================================
    // Clock & Reset
    // =========================================================================
    reg clk    = 0;
    reg resetn = 0;
    always #(CLK_PERIOD/2) clk = ~clk;
    initial begin repeat(8) @(posedge clk); resetn = 1; end

    // =========================================================================
    // DUT interface
    // =========================================================================
    wire        trap;
    wire [3:0]  pwm_out;

    wire [GPIO_COUNT-1:0] gpio_pad_out;   // from IOMUX: drive value
    wire [GPIO_COUNT-1:0] gpio_pad_oe;    // from IOMUX: output enable
    wire [GPIO_COUNT-1:0] gpio_pad_in;    // to   IOMUX: sampled pin value

    // ── Physical pad wires ────────────────────────────────────────────────────
    // Each pad is Hi-Z when oe=0, driven by IOMUX when oe=1.
    wire [GPIO_COUNT-1:0] gpio_pad;

    genvar gi;
    generate
        for (gi = 0; gi < GPIO_COUNT; gi = gi + 1) begin : g_pad
            assign gpio_pad[gi] = gpio_pad_oe[gi] ? gpio_pad_out[gi] : 1'bz;
        end
    endgenerate

    // ── TB stimulus: drive input pads from testbench ──────────────────────────
    // tb_inject[n]=1 means the TB is driving pad n via tb_value[n].
    // All other pads read back from gpio_pad (which reflects IOMUX output).
    reg [GPIO_COUNT-1:0] tb_inject = {GPIO_COUNT{1'b0}};
    reg [GPIO_COUNT-1:0] tb_value  = {GPIO_COUNT{1'b1}};  // idle high

    // Combine IOMUX output and TB injection into pad_in seen by the IOMUX
    assign gpio_pad_in = (tb_inject & tb_value)
                       | (~tb_inject & gpio_pad);

    // ── UART loopback: GPIO1 (TX) → GPIO2 (RX) ───────────────────────────────
    // The TX pad is an output (gpio_pad[TX_PAD] follows gpio_pad_out[TX_PAD]).
    // The RX pad is an input (gpio_pad[RX_PAD] = 1'bz, TB drives it).
    // We enable the loopback a few cycles after reset so IOMUX has been init'd.
    initial begin
        @(posedge resetn);
        repeat(20) @(posedge clk);
        tb_inject[RX_PAD] = 1'b1;   // TB now drives the RX pad
    end

    // Continuously copy TX pad value to RX pad
    always @(*) begin
        if (tb_inject[RX_PAD])
            // If TX pad is being driven by IOMUX use its value; else use idle (1)
            tb_value[RX_PAD] = gpio_pad_oe[TX_PAD] ? gpio_pad_out[TX_PAD] : 1'b1;
        else
            tb_value[RX_PAD] = 1'b1;
    end

    // =========================================================================
    // DUT: TN619_top
    // =========================================================================
    TN619_top #(
        .CLK_FREQ  (100_000_000),
        .BAUD_RATE (115_200),
        .GPIO_COUNT(GPIO_COUNT),
        .MEM_WORDS (MEM_WORDS)
    ) dut (
        .clk         (clk),
        .resetn      (resetn),
        .trap        (trap),
        .pwm_out     (pwm_out),
        .gpio_pad_out(gpio_pad_out),
        .gpio_pad_oe (gpio_pad_oe),
        .gpio_pad_in (gpio_pad_in)
    );

    // =========================================================================
    // Firmware loader
    // =========================================================================
    integer fw_i;
    initial begin
        for (fw_i = 0; fw_i < MEM_WORDS; fw_i = fw_i + 1)
            dut.bram[fw_i] = 32'h0000_0013;
        #1;
        $readmemh(mem_file, dut.bram);
        $display("[TB] Firmware: %s", mem_file);
    end

    // =========================================================================
    // UART TX monitor — decodes serial from the real TX pad
    //   gpio_pad_out[TX_PAD] is the actual waveform driven by uart_axi via IOMUX.
    //   Before IOMUX is configured, pad_oe=0 so uart_pad_tx stays 1 (idle).
    // =========================================================================
    wire uart_pad_tx = gpio_pad_oe[TX_PAD] ? gpio_pad_out[TX_PAD] : 1'b1;

    integer uart_state = 0;
    integer uart_cnt   = 0;
    integer uart_bit   = 0;
    reg [7:0] uart_byte = 0;

    always @(posedge clk) begin
        case (uart_state)
            0: if (uart_pad_tx == 1'b0) begin
                uart_state <= 1;
                uart_cnt   <= UART_HALF;
            end
            1: if (uart_cnt == 0) begin
                uart_state <= 2;
                uart_cnt   <= UART_FULL;
                uart_bit   <= 0;
            end else uart_cnt <= uart_cnt - 1;
            2: if (uart_cnt == 0) begin
                uart_cnt <= UART_FULL;
                if (uart_bit < 8) begin
                    uart_byte <= {uart_pad_tx, uart_byte[7:1]};
                    uart_bit  <= uart_bit + 1;
                end else begin
                    $write("%c", uart_byte);
                    uart_state <= 0;
                end
            end else uart_cnt <= uart_cnt - 1;
        endcase
    end

    // =========================================================================
    // IOMUX routing monitor
    // =========================================================================
    always @(posedge clk) begin
        if (resetn
                && dut.mem_valid && dut.mem_ready
                && dut.mem_wstrb != 4'h0
                && dut.mem_addr[31:12] == 20'h400F0
                && dut.mem_addr[9:8]   == 2'b01) begin
            $display("[IOMUX] GPIO%-2d → sig=0x%02X @ cycle %0d",
                     (dut.mem_addr[7:2] - 6'h10),
                     dut.mem_wdata[7:0], cycles);
        end
    end

    // =========================================================================
    // Pad direction monitor — shows when a pad switches between input/output
    // =========================================================================
    reg [GPIO_COUNT-1:0] oe_prev = {GPIO_COUNT{1'b0}};
    always @(posedge clk) begin : pad_dir_mon
        integer k;
        oe_prev <= gpio_pad_oe;
        for (k = 0; k < GPIO_COUNT; k = k + 1) begin
            if (gpio_pad_oe[k] && !oe_prev[k])
                $display("[PAD]  GPIO%0d → OUTPUT  @ cycle %0d", k, cycles);
            if (!gpio_pad_oe[k] && oe_prev[k])
                $display("[PAD]  GPIO%0d → INPUT   @ cycle %0d", k, cycles);
        end
    end

    // =========================================================================
    // Memory monitor (VERBOSE)
    // =========================================================================
    always @(posedge clk) begin
        if (VERBOSE && resetn && dut.mem_valid && dut.mem_ready) begin
            if (dut.mem_wstrb != 4'h0)
                $display("[MEM] WR 0x%08X = 0x%08X strb=%04b cyc=%0d",
                         dut.mem_addr, dut.mem_wdata, dut.mem_wstrb, cycles);
            else
                $display("[MEM] RD 0x%08X → 0x%08X instr=%b cyc=%0d",
                         dut.mem_addr, dut.mem_rdata, dut.mem_instr, cycles);
        end
    end

    always @(posedge clk) begin
        if (resetn && dut.mem_valid && dut.mem_ready
                && !dut.mem_wstrb && dut.mem_rdata === 32'hDEAD_BEEF)
            $display("[TB] WARNING unmapped READ 0x%08X cyc=%0d",
                     dut.mem_addr, cycles);
    end

    // =========================================================================
    // PASS / FAIL intercept
    // =========================================================================
    reg test_done = 0;
    always @(posedge clk) begin
        if (dut.mem_valid && dut.mem_ready
                && dut.mem_wstrb != 4'h0
                && dut.mem_addr == 32'h9000_0000) begin
            test_done <= 1;
            if (dut.mem_wdata == 0)
                $display("\n[TB] *** ALL TESTS PASSED ***");
            else
                $display("\n[TB] *** FAILED: %0d ***", dut.mem_wdata);
        end
    end

    // =========================================================================
    // Watchdog, trap, finish
    // =========================================================================
    integer cycles = 0;
    always @(posedge clk) begin
        cycles <= cycles + 1;
        if (cycles >= MAX_CYCLES) begin
            $display("[TB] TIMEOUT %0d cycles", MAX_CYCLES); $finish;
        end
        if (resetn && trap) begin
            $display("[TB] TRAP cyc=%0d pc=0x%08X sp=0x%08X",
                     cycles, dut.cpu.reg_pc, dut.cpu.cpuregs[2]);
            #(CLK_PERIOD*5); $finish;
        end
        if (test_done) begin
            $display("[TB] Done %0d cycles", cycles);
            #(CLK_PERIOD*5); $finish;
        end
    end

    // =========================================================================
    // VCD
    // =========================================================================
    initial begin
        #1;
        $dumpfile(vcd_file);
        $dumpvars(0, tb_soc);
        $display("=================================================");
        $display("  TN619 SoC Testbench @ 100 MHz");
        $display("  Firmware : %s", mem_file);
        $display("  Waveform : %s", vcd_file);
        $display("  TX pad   : GPIO%0d", TX_PAD);
        $display("  RX pad   : GPIO%0d", RX_PAD);
        $display("=================================================");
    end

endmodule
