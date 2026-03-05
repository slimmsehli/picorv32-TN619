// =============================================================================
//  axi_intercon.v  —  PicoRV32 Memory Router + AXI4-Lite Bridge
//
//  Memory Map:
//  0x0000_0000 – 0x0001_FFFF   BRAM  (128KB)
//  0x4000_0000 – 0x4000_00FF   UART  AXI4-Lite
//  0x4001_0000 – 0x4001_00FF   PWM   AXI4-Lite
// =============================================================================
`timescale 1ns/1ps

module axi_intercon (
    input  wire        clk,
    input  wire        resetn,

    // PicoRV32 port
    input  wire        mem_valid,
    output reg         mem_ready,
    input  wire        mem_instr,
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [ 3:0] mem_wstrb,
    output reg  [31:0] mem_rdata,

    // BRAM
    output reg         bram_en,
    output reg  [ 3:0] bram_we,
    output reg  [16:0] bram_addr,
    output reg  [31:0] bram_wdata,
    input  wire [31:0] bram_rdata,

    // UART AXI4-Lite
    output reg  [31:0] uart_awaddr,  output reg  uart_awvalid, input wire uart_awready,
    output reg  [31:0] uart_wdata,   output reg  [3:0] uart_wstrb,
    output reg         uart_wvalid,  input wire  uart_wready,
    input  wire [ 1:0] uart_bresp,   input wire  uart_bvalid,  output reg uart_bready,
    output reg  [31:0] uart_araddr,  output reg  uart_arvalid, input wire uart_arready,
    input  wire [31:0] uart_rdata,   input wire  [1:0] uart_rresp,
    input  wire        uart_rvalid,  output reg  uart_rready,

    // PWM AXI4-Lite
    output reg  [31:0] pwm_awaddr,   output reg  pwm_awvalid,  input wire pwm_awready,
    output reg  [31:0] pwm_wdata,    output reg  [3:0] pwm_wstrb,
    output reg         pwm_wvalid,   input wire  pwm_wready,
    input  wire [ 1:0] pwm_bresp,    input wire  pwm_bvalid,   output reg pwm_bready,
    output reg  [31:0] pwm_araddr,   output reg  pwm_arvalid,  input wire pwm_arready,
    input  wire [31:0] pwm_rdata,    input wire  [1:0] pwm_rresp,
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
    // FSM states
    // -------------------------------------------------------------------------
    localparam S_IDLE      = 3'd0;
    localparam S_BRAM_WAIT = 3'd1;   // wait one cycle for BRAM read data
    localparam S_AXI_ADDR  = 3'd2;   // AXI write: wait addr+data accepted
    localparam S_AXI_RESP  = 3'd3;   // AXI write: wait BVALID
    localparam S_AXI_READ  = 3'd4;   // AXI read:  wait RVALID

    reg [2:0] state;
    reg       active_uart;   // 1=uart, 0=pwm (which peripheral is active)

    // -------------------------------------------------------------------------
    // Single unified always block — one driver for mem_ready / mem_rdata
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!resetn) begin
            state        <= S_IDLE;
            mem_ready    <= 0;
            mem_rdata    <= 0;
            bram_en      <= 0;
            bram_we      <= 0;
            uart_awvalid <= 0; uart_wvalid  <= 0; uart_bready  <= 0;
            uart_arvalid <= 0; uart_rready  <= 0;
            pwm_awvalid  <= 0; pwm_wvalid   <= 0; pwm_bready   <= 0;
            pwm_arvalid  <= 0; pwm_rready   <= 0;
            active_uart  <= 0;
        end else begin

            // Default: deassert strobes after one cycle
            mem_ready <= 0;
            bram_en   <= 0;

            case (state)

                // ----------------------------------------------------------
                S_IDLE: begin
                    if (mem_valid) begin

                        // --- BRAM ---
                        if (sel_bram) begin
                            bram_en    <= 1;
                            bram_we    <= is_write ? mem_wstrb : 4'b0;
                            bram_addr  <= mem_addr[18:2];
                            bram_wdata <= mem_wdata;
                            if (is_write) begin
                                // Writes complete immediately (no read-back needed)
                                mem_ready <= 1;
                                mem_rdata <= 0;
                                state     <= S_IDLE;
                            end else begin
                                state <= S_BRAM_WAIT;
                            end
                        end

                        // --- UART ---
                        else if (sel_uart) begin
                            active_uart <= 1;
                            if (is_write) begin
                                uart_awaddr  <= mem_addr;
                                uart_awvalid <= 1;
                                uart_wdata   <= mem_wdata;
                                uart_wstrb   <= mem_wstrb;
                                uart_wvalid  <= 1;
                                state        <= S_AXI_ADDR;
                            end else begin
                                uart_araddr  <= mem_addr;
                                uart_arvalid <= 1;
                                uart_rready  <= 1;
                                state        <= S_AXI_READ;
                            end
                        end

                        // --- PWM ---
                        else if (sel_pwm) begin
                            active_uart <= 0;
                            if (is_write) begin
                                pwm_awaddr  <= mem_addr;
                                pwm_awvalid <= 1;
                                pwm_wdata   <= mem_wdata;
                                pwm_wstrb   <= mem_wstrb;
                                pwm_wvalid  <= 1;
                                state       <= S_AXI_ADDR;
                            end else begin
                                pwm_araddr  <= mem_addr;
                                pwm_arvalid <= 1;
                                pwm_rready  <= 1;
                                state       <= S_AXI_READ;
                            end
                        end

                        // --- Unmapped: return 0, don't stall core ---
                        else begin
                            mem_ready <= 1;
                            mem_rdata <= 32'hDEAD_BEEF;
                        end
                    end
                end

                // ----------------------------------------------------------
                S_BRAM_WAIT: begin
                    // BRAM data is valid this cycle (1-cycle registered read)
                    mem_ready <= 1;
                    mem_rdata <= bram_rdata;
                    state     <= S_IDLE;
                end

                // ----------------------------------------------------------
                S_AXI_ADDR: begin
                    // Deassert AW/W once accepted
                    if (active_uart) begin
                        if (uart_awready) uart_awvalid <= 0;
                        if (uart_wready)  uart_wvalid  <= 0;
                        if (!uart_awvalid && !uart_wvalid) begin
                            uart_bready <= 1;
                            state       <= S_AXI_RESP;
                        end
                    end else begin
                        if (pwm_awready) pwm_awvalid <= 0;
                        if (pwm_wready)  pwm_wvalid  <= 0;
                        if (!pwm_awvalid && !pwm_wvalid) begin
                            pwm_bready <= 1;
                            state      <= S_AXI_RESP;
                        end
                    end
                end

                // ----------------------------------------------------------
                S_AXI_RESP: begin
                    if (active_uart && uart_bvalid) begin
                        uart_bready <= 0;
                        mem_ready   <= 1;
                        mem_rdata   <= 0;
                        state       <= S_IDLE;
                    end else if (!active_uart && pwm_bvalid) begin
                        pwm_bready  <= 0;
                        mem_ready   <= 1;
                        mem_rdata   <= 0;
                        state       <= S_IDLE;
                    end
                end

                // ----------------------------------------------------------
                S_AXI_READ: begin
                    if (active_uart) begin
                        if (uart_arready) uart_arvalid <= 0;
                        if (uart_rvalid) begin
                            uart_rready <= 0;
                            mem_ready   <= 1;
                            mem_rdata   <= uart_rdata;
                            state       <= S_IDLE;
                        end
                    end else begin
                        if (pwm_arready) pwm_arvalid <= 0;
                        if (pwm_rvalid) begin
                            pwm_rready <= 0;
                            mem_ready  <= 1;
                            mem_rdata  <= pwm_rdata;
                            state      <= S_IDLE;
                        end
                    end
                end

            endcase
        end
    end

endmodule
