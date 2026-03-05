// =============================================================================
//  axi_interconnect.v  —  PicoRV32 Memory Router + AXI4-Lite Bridge
//
//  BRAM timing:
//    bram_rdata is a COMBINATORIAL wire: assign bram_rdata = bram[bram_addr]
//    This eliminates all non-blocking assignment races.
//    Read latency = 2 cycles (S_IDLE -> S_BRAM_LATCH -> S_IDLE + mem_ready)
//    Writes complete in 1 cycle (no readback needed).
//
//  Memory Map:
//    0x0000_0000 – 0x0001_FFFF   BRAM  128KB
//    0x4000_0000 – 0x4000_00FF   UART  AXI4-Lite
//    0x4001_0000 – 0x4001_00FF   PWM   AXI4-Lite
// =============================================================================
`timescale 1ns/1ps

module axi_interconnect (
    input  wire        clk,
    input  wire        resetn,

    // PicoRV32
    input  wire        mem_valid,
    output reg         mem_ready,
    input  wire        mem_instr,
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [ 3:0] mem_wstrb,
    output reg  [31:0] mem_rdata,

    // BRAM — combinatorial addr/en, combinatorial read data
    output wire        bram_en,
    output wire [ 3:0] bram_we,
    output wire [14:0] bram_addr,
    output wire [31:0] bram_wdata,
    input  wire [31:0] bram_rdata,   // MUST be a wire (comb) in the testbench

    // UART AXI4-Lite
    output reg  [31:0] uart_awaddr,  output reg  uart_awvalid, input wire uart_awready,
    output reg  [31:0] uart_wdata,   output reg  [ 3:0] uart_wstrb,
    output reg         uart_wvalid,  input wire  uart_wready,
    input  wire [ 1:0] uart_bresp,   input wire  uart_bvalid,  output reg  uart_bready,
    output reg  [31:0] uart_araddr,  output reg  uart_arvalid, input wire  uart_arready,
    input  wire [31:0] uart_rdata,   input wire  [ 1:0] uart_rresp,
    input  wire        uart_rvalid,  output reg  uart_rready,

    // PWM AXI4-Lite
    output reg  [31:0] pwm_awaddr,   output reg  pwm_awvalid,  input wire pwm_awready,
    output reg  [31:0] pwm_wdata,    output reg  [ 3:0] pwm_wstrb,
    output reg         pwm_wvalid,   input wire  pwm_wready,
    input  wire [ 1:0] pwm_bresp,    input wire  pwm_bvalid,   output reg  pwm_bready,
    output reg  [31:0] pwm_araddr,   output reg  pwm_arvalid,  input wire  pwm_arready,
    input  wire [31:0] pwm_rdata,    input wire  [ 1:0] pwm_rresp,
    input  wire        pwm_rvalid,   output reg  pwm_rready
);

    // -------------------------------------------------------------------------
    // Address decode
    // -------------------------------------------------------------------------
    wire sel_bram = (mem_addr[31:17] == 15'h0);
    wire sel_uart = (mem_addr[31:8]  == 24'h40_0000);
    wire sel_pwm  = (mem_addr[31:8]  == 24'h40_0100);
    wire is_write = (mem_wstrb != 4'b0);

    // -------------------------------------------------------------------------
    // BRAM signals — all combinatorial
    // bram_rdata must be a wire in the testbench:
    //   wire [31:0] bram_rdata;
    //   assign bram_rdata = bram[bram_addr_w];
    // -------------------------------------------------------------------------
    localparam S_IDLE      = 3'd0;
    localparam S_BRAM_LATCH= 3'd1;  // addr presented, comb read valid
    localparam S_AXI_ADDR  = 3'd2;
    localparam S_AXI_RESP  = 3'd3;
    localparam S_AXI_READ  = 3'd4;

    reg [2:0] state;
    reg sel_uart_r;

    // bram_en: high during S_BRAM_LATCH (write) or whenever we need write strobe
    // For reads: bram_rdata is combinatorial so just present addr in S_BRAM_LATCH
    // For writes: also fire in S_IDLE on the same cycle we issue mem_ready
    assign bram_en    = mem_valid && !mem_ready && sel_bram &&
                        ((state == S_IDLE && is_write) || state == S_BRAM_LATCH);
    assign bram_we    = is_write ? mem_wstrb : 4'b0;
    assign bram_addr  = mem_addr[16:2];
    assign bram_wdata = mem_wdata;

    always @(posedge clk) begin
        if (!resetn) begin
            state        <= S_IDLE;
            mem_ready    <= 1'b0;
            mem_rdata    <= 32'h0;
            sel_uart_r   <= 1'b0;
            uart_awvalid <= 0; uart_wvalid  <= 0; uart_bready  <= 0;
            uart_arvalid <= 0; uart_rready  <= 0;
            pwm_awvalid  <= 0; pwm_wvalid   <= 0; pwm_bready   <= 0;
            pwm_arvalid  <= 0; pwm_rready   <= 0;
        end else begin
            mem_ready <= 1'b0;

            case (state)

                S_IDLE: begin
                    if (mem_valid && !mem_ready) begin
                        if (sel_bram) begin
                            if (is_write) begin
                                // bram_en fires combinatorially this cycle
                                mem_ready <= 1'b1;
                                mem_rdata <= 32'h0;
                                // stay S_IDLE
                            end else begin
                                // Move to latch state — bram_rdata (wire) will
                                // reflect bram[addr] immediately next cycle
                                state <= S_BRAM_LATCH;
                            end
                        end

                        else if (sel_uart || sel_pwm) begin
                            sel_uart_r <= sel_uart;
                            if (is_write) begin
                                if (sel_uart) begin
                                    uart_awaddr  <= mem_addr;
                                    uart_awvalid <= 1'b1;
                                    uart_wdata   <= mem_wdata;
                                    uart_wstrb   <= mem_wstrb;
                                    uart_wvalid  <= 1'b1;
                                end else begin
                                    pwm_awaddr   <= mem_addr;
                                    pwm_awvalid  <= 1'b1;
                                    pwm_wdata    <= mem_wdata;
                                    pwm_wstrb    <= mem_wstrb;
                                    pwm_wvalid   <= 1'b1;
                                end
                                state <= S_AXI_ADDR;
                            end else begin
                                if (sel_uart) begin
                                    uart_araddr  <= mem_addr;
                                    uart_arvalid <= 1'b1;
                                    uart_rready  <= 1'b1;
                                end else begin
                                    pwm_araddr   <= mem_addr;
                                    pwm_arvalid  <= 1'b1;
                                    pwm_rready   <= 1'b1;
                                end
                                state <= S_AXI_READ;
                            end
                        end

                        else begin
                            mem_ready <= 1'b1;
                            mem_rdata <= 32'hDEAD_BEEF;
                        end
                    end
                end

                // bram_rdata = bram[bram_addr] is a WIRE — valid right now
                S_BRAM_LATCH: begin
                    mem_ready <= 1'b1;
                    mem_rdata <= bram_rdata;   // combinatorial, no race
                    state     <= S_IDLE;
                end

                S_AXI_ADDR: begin
                    if (sel_uart_r) begin
                        if (uart_awready) uart_awvalid <= 1'b0;
                        if (uart_wready)  uart_wvalid  <= 1'b0;
                        if ((uart_awready || !uart_awvalid) &&
                            (uart_wready  || !uart_wvalid)) begin
                            uart_bready <= 1'b1;
                            state       <= S_AXI_RESP;
                        end
                    end else begin
                        if (pwm_awready)  pwm_awvalid  <= 1'b0;
                        if (pwm_wready)   pwm_wvalid   <= 1'b0;
                        if ((pwm_awready || !pwm_awvalid) &&
                            (pwm_wready  || !pwm_wvalid)) begin
                            pwm_bready <= 1'b1;
                            state      <= S_AXI_RESP;
                        end
                    end
                end

                S_AXI_RESP: begin
                    if (sel_uart_r && uart_bvalid) begin
                        uart_bready <= 1'b0;
                        mem_ready   <= 1'b1;
                        mem_rdata   <= 32'h0;
                        state       <= S_IDLE;
                    end else if (!sel_uart_r && pwm_bvalid) begin
                        pwm_bready  <= 1'b0;
                        mem_ready   <= 1'b1;
                        mem_rdata   <= 32'h0;
                        state       <= S_IDLE;
                    end
                end

                S_AXI_READ: begin
                    if (sel_uart_r) begin
                        if (uart_arready) uart_arvalid <= 1'b0;
                        if (uart_rvalid) begin
                            uart_rready <= 1'b0;
                            mem_ready   <= 1'b1;
                            mem_rdata   <= uart_rdata;
                            state       <= S_IDLE;
                        end
                    end else begin
                        if (pwm_arready) pwm_arvalid <= 1'b0;
                        if (pwm_rvalid) begin
                            pwm_rready <= 1'b0;
                            mem_ready  <= 1'b1;
                            mem_rdata  <= pwm_rdata;
                            state      <= S_IDLE;
                        end
                    end
                end

            endcase
        end
    end

endmodule
