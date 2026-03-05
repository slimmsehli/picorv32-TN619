// =============================================================================
//  uart_axi.v  —  UART with AXI4-Lite slave interface
//
//  Register Map (base + offset):
//  0x00  CTRL   [0]   tx_en       enable TX
//               [1]   rx_en       enable RX
//               [31:16] baud_div  clock divider = clk_freq / baud_rate
//  0x04  STATUS [0]   tx_busy     TX is sending a byte
//               [1]   tx_full     TX buffer has a byte pending
//               [2]   rx_ready    RX has a byte waiting to be read
//               [3]   rx_overflow RX byte was lost (not read in time)
//               [4]   frame_err   bad stop bit received
//  0x08  TXDATA [7:0] write byte to transmit (clears tx_full when done)
//  0x0C  RXDATA [7:0] read received byte    (clears rx_ready)
//
//  AXI4-Lite:
//    - 32-bit data bus
//    - Write: AWVALID+WVALID → BVALID
//    - Read:  ARVALID        → RVALID
//    - All transactions complete in 1-2 cycles
// =============================================================================

`timescale 1ns/1ps

module uart_axi #(
    parameter CLK_FREQ  = 50_000_000,   // default 50MHz
    parameter BAUD_RATE = 115200
)(
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

    // UART pins
    output reg         uart_tx,
    input  wire        uart_rx
);

    // -------------------------------------------------------------------------
    // Internal registers
    // -------------------------------------------------------------------------
    reg         tx_en;
    reg         rx_en;
    reg  [15:0] baud_div;       // clock divider value

    // TX state
    reg  [ 7:0] tx_data;        // byte to transmit
    reg         tx_full;        // a byte is waiting to be sent
    reg         tx_busy;        // currently shifting out a byte
    reg  [ 9:0] tx_shift;       // shift register {stop, data[7:0], start}
    reg  [ 3:0] tx_bit_cnt;     // which bit we're sending (0-9)
    reg  [15:0] tx_baud_cnt;    // baud rate counter

    // RX state
    reg  [ 7:0] rx_data;        // received byte
    reg         rx_ready;       // byte available to read
    reg         rx_overflow;    // byte was overwritten before read
    reg         frame_err;      // bad stop bit
    reg         rx_busy;        // currently receiving
    reg  [ 3:0] rx_bit_cnt;
    reg  [15:0] rx_baud_cnt;
    reg  [ 1:0] rx_sync;        // 2-stage synchronizer for uart_rx

    // Default baud divider from parameters
    localparam integer DEFAULT_DIV = CLK_FREQ / BAUD_RATE;

    // -------------------------------------------------------------------------
    // AXI4-Lite Write Logic
    // -------------------------------------------------------------------------
    reg [3:0] wr_addr;
    reg       wr_pending;

    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 0;
            s_axi_wready  <= 0;
            s_axi_bvalid  <= 0;
            s_axi_bresp   <= 2'b00;
            wr_pending    <= 0;
            tx_en         <= 0;
            rx_en         <= 0;
            baud_div      <= DEFAULT_DIV[15:0];
            tx_data       <= 0;
            tx_full       <= 0;
        end else begin
            // Latch write address
            if (s_axi_awvalid && !s_axi_awready) begin
                s_axi_awready <= 1;
                wr_addr       <= s_axi_awaddr[5:2];  // word index
            end else begin
                s_axi_awready <= 0;
            end

            // Latch write data and perform register write
            if (s_axi_wvalid && !s_axi_wready) begin
                s_axi_wready <= 1;
                case (wr_addr)
                    4'h0: begin  // CTRL
                        if (s_axi_wstrb[0]) begin
                            tx_en    <= s_axi_wdata[0];
                            rx_en    <= s_axi_wdata[1];
                        end
                        if (s_axi_wstrb[2]) baud_div[7:0]  <= s_axi_wdata[23:16];
                        if (s_axi_wstrb[3]) baud_div[15:8] <= s_axi_wdata[31:24];
                    end
                    4'h2: begin  // TXDATA (offset 0x08)
                        if (s_axi_wstrb[0] && !tx_full && tx_en) begin
                            tx_data <= s_axi_wdata[7:0];
                            tx_full <= 1;
                        end
                    end
                    default: ;
                endcase
            end else begin
                s_axi_wready <= 0;
            end

            // Write response
            if (s_axi_wready && !s_axi_bvalid) begin
                s_axi_bvalid <= 1;
                s_axi_bresp  <= 2'b00;  // OKAY
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // AXI4-Lite Read Logic
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
                case (s_axi_araddr[5:2])
                    4'h0: s_axi_rdata <= {baud_div, 14'b0, rx_en, tx_en};        // CTRL
                    4'h1: s_axi_rdata <= {27'b0, frame_err,                       // STATUS
                                          rx_overflow, rx_ready, tx_full, tx_busy};
                    4'h2: s_axi_rdata <= 32'h0;                                   // TXDATA (write-only)
                    4'h3: begin                                                    // RXDATA
                        s_axi_rdata  <= {24'b0, rx_data};
                        // reading clears rx_ready and error flags
                    end
                    default: s_axi_rdata <= 32'hDEADBEEF;
                endcase
            end else begin
                s_axi_arready <= 0;
            end

            if (s_axi_rvalid && s_axi_rready) begin
                s_axi_rvalid <= 0;
                // Clear rx_ready after RXDATA is read
                if (s_axi_araddr[5:2] == 4'h3) begin
                    // rx_ready cleared in RX logic below
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // TX State Machine  —  8N1
    // -------------------------------------------------------------------------
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            uart_tx      <= 1'b1;   // idle high
            tx_busy      <= 0;
            tx_bit_cnt   <= 0;
            tx_baud_cnt  <= 0;
            tx_shift     <= 10'h3FF;
        end else begin
            if (!tx_busy && tx_full && tx_en) begin
                // Load shift register: stop(1), data[7:0], start(0)
                tx_shift    <= {1'b1, tx_data, 1'b0};
                tx_busy     <= 1;
                tx_full     <= 0;
                tx_bit_cnt  <= 0;
                tx_baud_cnt <= 0;
            end else if (tx_busy) begin
                if (tx_baud_cnt == baud_div - 1) begin
                    tx_baud_cnt <= 0;
                    uart_tx     <= tx_shift[0];
                    tx_shift    <= {1'b1, tx_shift[9:1]};  // shift right
                    if (tx_bit_cnt == 9) begin
                        tx_busy    <= 0;
                        uart_tx    <= 1'b1;                 // return to idle
                    end else begin
                        tx_bit_cnt <= tx_bit_cnt + 1;
                    end
                end else begin
                    tx_baud_cnt <= tx_baud_cnt + 1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // RX State Machine  —  8N1  (samples at mid-bit)
    // -------------------------------------------------------------------------
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            rx_sync      <= 2'b11;
            rx_busy      <= 0;
            rx_ready     <= 0;
            rx_overflow  <= 0;
            frame_err    <= 0;
            rx_data      <= 0;
            rx_bit_cnt   <= 0;
            rx_baud_cnt  <= 0;
        end else begin
            // 2-stage synchronizer to avoid metastability
            rx_sync <= {rx_sync[0], uart_rx};

            // Clear rx_ready when CPU reads RXDATA
            if (s_axi_arvalid && s_axi_arready && s_axi_araddr[5:2] == 4'h3) begin
                rx_ready    <= 0;
                rx_overflow <= 0;
                frame_err   <= 0;
            end

            if (rx_en) begin
                if (!rx_busy) begin
                    // Detect start bit (falling edge on idle line)
                    if (rx_sync[1] == 0) begin
                        rx_busy     <= 1;
                        rx_bit_cnt  <= 0;
                        // Start counter at half-bit to sample in middle
                        rx_baud_cnt <= baud_div >> 1;
                    end
                end else begin
                    if (rx_baud_cnt == baud_div - 1) begin
                        rx_baud_cnt <= 0;
                        if (rx_bit_cnt == 0) begin
                            // Verify start bit is still low
                            if (rx_sync[1] != 0) begin
                                rx_busy <= 0;  // false start, abort
                            end else begin
                                rx_bit_cnt <= 1;
                            end
                        end else if (rx_bit_cnt <= 8) begin
                            // Sample data bits LSB first
                            rx_data    <= {rx_sync[1], rx_data[7:1]};
                            rx_bit_cnt <= rx_bit_cnt + 1;
                        end else begin
                            // Stop bit
                            rx_busy <= 0;
                            if (rx_sync[1] == 1) begin
                                // Valid frame
                                if (rx_ready)
                                    rx_overflow <= 1;   // previous byte not read
                                rx_ready <= 1;
                            end else begin
                                frame_err <= 1;         // bad stop bit
                            end
                        end
                    end else begin
                        rx_baud_cnt <= rx_baud_cnt + 1;
                    end
                end
            end
        end
    end

endmodule
