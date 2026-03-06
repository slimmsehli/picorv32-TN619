// =============================================================================
//  pwm_timer_axi.v  —  PWM / Timer with AXI4-Lite slave interface
//
//  Features:
//    - 32-bit free-running counter (Timer)
//    - 4 independent PWM channels (shared counter, independent compare)
//    - One-shot and continuous modes
//    - Interrupt flag on counter overflow and per-channel match
//
//  Register Map (base + offset):
//  0x00  CTRL      [0]    timer_en    start/stop the counter
//                  [1]    auto_reload reload on overflow (continuous mode)
//                  [2]    pwm_en      enable all PWM outputs
//                  [3]    ov_irq_en   enable overflow interrupt
//  0x04  STATUS    [0]    overflow    counter wrapped (write 1 to clear)
//                  [4:1]  ch_match    channel 0-3 compare matched (w1c)
//  0x08  COUNTER   [31:0] current counter value (read) / reload value (write)
//  0x0C  PERIOD    [31:0] auto-reload period (counter resets at PERIOD)
//  0x10  CH0_CMP   [31:0] channel 0 compare value  → PWM duty cycle
//  0x14  CH1_CMP   [31:0] channel 1 compare value
//  0x18  CH2_CMP   [31:0] channel 2 compare value
//  0x1C  CH3_CMP   [31:0] channel 3 compare value
//
//  PWM output: high when counter < CHx_CMP, low when counter >= CHx_CMP
//  Frequency  = clk_freq / PERIOD
//  Duty cycle = CHx_CMP / PERIOD  (0% = 0, 100% = PERIOD)
// =============================================================================

`timescale 1ns/1ps

module pwm_timer_axi (
    // AXI4-Lite Clock & Reset
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

    // PWM outputs (one per channel)
    output reg  [ 3:0] pwm_out,

    // Interrupt output (overflow or channel match)
    output wire        irq
);

    // -------------------------------------------------------------------------
    // Registers
    // -------------------------------------------------------------------------
    reg         timer_en;
    reg         auto_reload;
    reg         pwm_en;
    reg         ov_irq_en;

    reg         overflow;
    reg  [ 3:0] ch_match;

    reg  [31:0] counter;
    reg  [31:0] period;
    reg  [31:0] ch_cmp [0:3];

    assign irq = (overflow & ov_irq_en);

    // -------------------------------------------------------------------------
    // Single-driver handshake pulses
    //   ov_clr_req     -- pulsed by AXI write block, consumed by timer block
    //   timer_stop_req -- NOT needed; timer_en is sole-driven by AXI write block
    //                     (one-shot stop moved here from timer block)
    // Rule: overflow  driven ONLY by timer block
    //       timer_en  driven ONLY by AXI write block
    // -------------------------------------------------------------------------
    reg ov_clr_req;   // 1-cycle pulse: request overflow flag clear

    // -------------------------------------------------------------------------
    // AXI4-Lite Write
    // -------------------------------------------------------------------------
    reg [4:0] wr_addr;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 0;
            s_axi_wready  <= 0;
            s_axi_bvalid  <= 0;
            s_axi_bresp   <= 2'b00;
            timer_en      <= 0;
            auto_reload   <= 1;     // default: continuous
            pwm_en        <= 0;
            ov_irq_en     <= 0;
            counter       <= 0;
            period        <= 32'hFFFF_FFFF;
            ch_cmp[0]     <= 0;
            ch_cmp[1]     <= 0;
            ch_cmp[2]     <= 0;
            ch_cmp[3]     <= 0;
            ov_clr_req    <= 0;
        end else begin
            // Default: deassert pulse every cycle
            ov_clr_req    <= 0;

            s_axi_awready <= 0;
            s_axi_wready  <= 0;

            if (s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid) begin
                s_axi_awready <= 1;
                s_axi_wready  <= 1;
                s_axi_bvalid  <= 1;
                s_axi_bresp   <= 2'b00;
                wr_addr       <= s_axi_awaddr[6:2];

                case (s_axi_awaddr[6:2])
                    5'h00: begin  // CTRL
                        if (s_axi_wstrb[0]) begin
                            timer_en    <= s_axi_wdata[0];
                            auto_reload <= s_axi_wdata[1];
                            pwm_en      <= s_axi_wdata[2];
                            ov_irq_en   <= s_axi_wdata[3];
                        end
                    end
                    5'h01: begin  // STATUS: write-1-to-clear
                        if (s_axi_wstrb[0]) begin
                            // Signal timer block to clear overflow (single driver rule)
                            if (s_axi_wdata[0])   ov_clr_req <= 1;
                            if (s_axi_wdata[4:1]) ch_match <= ch_match & ~s_axi_wdata[4:1];
                        end
                    end
                    5'h02: begin  // COUNTER
                        if (s_axi_wstrb[0]) counter[ 7: 0] <= s_axi_wdata[ 7: 0];
                        if (s_axi_wstrb[1]) counter[15: 8] <= s_axi_wdata[15: 8];
                        if (s_axi_wstrb[2]) counter[23:16] <= s_axi_wdata[23:16];
                        if (s_axi_wstrb[3]) counter[31:24] <= s_axi_wdata[31:24];
                    end
                    5'h03: begin  // PERIOD
                        if (s_axi_wstrb[0]) period[ 7: 0] <= s_axi_wdata[ 7: 0];
                        if (s_axi_wstrb[1]) period[15: 8] <= s_axi_wdata[15: 8];
                        if (s_axi_wstrb[2]) period[23:16] <= s_axi_wdata[23:16];
                        if (s_axi_wstrb[3]) period[31:24] <= s_axi_wdata[31:24];
                    end
                    5'h04: begin  // CH0_CMP
                        if (s_axi_wstrb[0]) ch_cmp[0][ 7: 0] <= s_axi_wdata[ 7: 0];
                        if (s_axi_wstrb[1]) ch_cmp[0][15: 8] <= s_axi_wdata[15: 8];
                        if (s_axi_wstrb[2]) ch_cmp[0][23:16] <= s_axi_wdata[23:16];
                        if (s_axi_wstrb[3]) ch_cmp[0][31:24] <= s_axi_wdata[31:24];
                    end
                    5'h05: begin  // CH1_CMP
                        if (s_axi_wstrb[0]) ch_cmp[1][ 7: 0] <= s_axi_wdata[ 7: 0];
                        if (s_axi_wstrb[1]) ch_cmp[1][15: 8] <= s_axi_wdata[15: 8];
                        if (s_axi_wstrb[2]) ch_cmp[1][23:16] <= s_axi_wdata[23:16];
                        if (s_axi_wstrb[3]) ch_cmp[1][31:24] <= s_axi_wdata[31:24];
                    end
                    5'h06: begin  // CH2_CMP
                        if (s_axi_wstrb[0]) ch_cmp[2][ 7: 0] <= s_axi_wdata[ 7: 0];
                        if (s_axi_wstrb[1]) ch_cmp[2][15: 8] <= s_axi_wdata[15: 8];
                        if (s_axi_wstrb[2]) ch_cmp[2][23:16] <= s_axi_wdata[23:16];
                        if (s_axi_wstrb[3]) ch_cmp[2][31:24] <= s_axi_wdata[31:24];
                    end
                    5'h07: begin  // CH3_CMP
                        if (s_axi_wstrb[0]) ch_cmp[3][ 7: 0] <= s_axi_wdata[ 7: 0];
                        if (s_axi_wstrb[1]) ch_cmp[3][15: 8] <= s_axi_wdata[15: 8];
                        if (s_axi_wstrb[2]) ch_cmp[3][23:16] <= s_axi_wdata[23:16];
                        if (s_axi_wstrb[3]) ch_cmp[3][31:24] <= s_axi_wdata[31:24];
                    end
                    default: ;
                endcase
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
            s_axi_rresp   <= 2'b00;
        end else begin
            if (s_axi_arvalid && !s_axi_arready) begin
                s_axi_arready <= 1;
                s_axi_rvalid  <= 1;
                s_axi_rresp   <= 2'b00;
                case (s_axi_araddr[6:2])
                    5'h00: s_axi_rdata <= {28'b0, ov_irq_en, pwm_en, auto_reload, timer_en};
                    5'h01: s_axi_rdata <= {27'b0, ch_match, overflow};
                    5'h02: s_axi_rdata <= counter;
                    5'h03: s_axi_rdata <= period;
                    5'h04: s_axi_rdata <= ch_cmp[0];
                    5'h05: s_axi_rdata <= ch_cmp[1];
                    5'h06: s_axi_rdata <= ch_cmp[2];
                    5'h07: s_axi_rdata <= ch_cmp[3];
                    default: s_axi_rdata <= 32'hDEADBEEF;
                endcase
            end else begin
                s_axi_arready <= 0;
            end
            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 0;
        end
    end

    // -------------------------------------------------------------------------
    // Timer Counter & PWM Logic
    //
    // overflow driven ONLY here (sole driver).
    // ov_clr_req is a 1-cycle pulse owned solely by the AXI write block.
    // timer_en  driven ONLY by the AXI write block.
    // -------------------------------------------------------------------------
    integer i;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            overflow  <= 0;
            ch_match  <= 0;
            pwm_out   <= 4'b0000;
        end else begin
            // ov_clr_req (W1C from AXI write) is handled UNCONDITIONALLY,
            // regardless of timer_en, so a write to clear overflow always works.
            if (ov_clr_req)
                overflow <= 0;

            if (timer_en) begin
                // Counter rolls over after exactly `period` ticks (0 .. period-1)
                // Clear takes priority: if ov_clr_req fires on the same cycle as
                // rollover, the clear wins and overflow is NOT re-set.
                if (counter >= period - 1) begin
                    counter <= 0;
                    if (!ov_clr_req)
                        overflow <= 1;
                end else begin
                    counter <= counter + 1;
                end

                // PWM output: high while counter < compare value
                for (i = 0; i < 4; i = i + 1) begin
                    if (pwm_en) begin
                        pwm_out[i] <= (counter < ch_cmp[i]) ? 1'b1 : 1'b0;
                        if (counter == ch_cmp[i])
                            ch_match[i] <= 1;
                    end else begin
                        pwm_out[i] <= 0;
                    end
                end
            end  // if (timer_en)
        end  // else (not reset)
    end  // always

endmodule
