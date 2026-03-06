// =============================================================================
//  uart_axi.v  —  UART with AXI4-Lite slave interface
//
//  Register Map (base + offset):
//  0x00  CTRL   [0]    tx_en
//               [1]    rx_en
//               [31:16] baud_div  (clk_freq / baud_rate)
//  0x04  STATUS [0]    tx_busy
//               [1]    tx_full
//               [2]    rx_ready
//               [3]    rx_overflow
//               [4]    frame_err
//  0x08  TXDATA [7:0]  write byte to transmit
//  0x0C  RXDATA [7:0]  read received byte (clears rx_ready)
//
//  AXI4-Lite slave: accepts AW+W simultaneously, responds in 1 cycle
// =============================================================================
`timescale 1ns/1ps

module uart_axi #(
    parameter CLK_FREQ  = 50_000_000,
    parameter BAUD_RATE = 115200
)(
    input  wire        s_axi_aclk,
    input  wire        s_axi_aresetn,

    input  wire [31:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,

    input  wire [31:0] s_axi_wdata,
    input  wire [ 3:0] s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,

    output reg  [ 1:0] s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,

    input  wire [31:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,

    output reg  [31:0] s_axi_rdata,
    output reg  [ 1:0] s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready,

    output reg         uart_tx = 1'b1,
    input  wire        uart_rx
);
    localparam integer DEFAULT_DIV = CLK_FREQ / BAUD_RATE;

    // Registers
    reg         tx_en,  rx_en;
    reg  [15:0] baud_div;
    reg  [ 7:0] tx_data;
    reg         tx_full, tx_busy;
    reg  [ 9:0] tx_shift;
    reg  [ 3:0] tx_bit_cnt;
    reg  [15:0] tx_baud_cnt;
    reg  [ 7:0] rx_data;
    reg         rx_ready, rx_overflow, frame_err, rx_busy;
    reg  [ 3:0] rx_bit_cnt;
    reg  [15:0] rx_baud_cnt;
    reg  [ 1:0] rx_sync;

    // -------------------------------------------------------------------------
    // AXI Write — accept AW and W simultaneously
    // -------------------------------------------------------------------------
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_awready <= 0; s_axi_wready <= 0;
            s_axi_bvalid  <= 0; s_axi_bresp  <= 0;
            tx_en <= 0; rx_en <= 0;
            baud_div <= DEFAULT_DIV[15:0];
            tx_data  <= 0; tx_full <= 0;
        end else begin
            // Default deassert
            s_axi_awready <= 0;
            s_axi_wready  <= 0;

            // Accept write when both AW and W are valid together
            if (s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid) begin
                s_axi_awready <= 1;
                s_axi_wready  <= 1;
                s_axi_bvalid  <= 1;
                s_axi_bresp   <= 2'b00;

                case (s_axi_awaddr[3:2])
                    2'h0: begin  // CTRL
                        if (s_axi_wstrb[0]) {rx_en, tx_en} <= s_axi_wdata[1:0];
                        if (s_axi_wstrb[2]) baud_div[7:0]  <= s_axi_wdata[23:16];
                        if (s_axi_wstrb[3]) baud_div[15:8] <= s_axi_wdata[31:24];
                    end
                    2'h2: begin  // TXDATA
                        if (s_axi_wstrb[0] && !tx_full && tx_en) begin
                            tx_data <= s_axi_wdata[7:0];
                            tx_full <= 1;
                        end
                    end
                    default: ;
                endcase
            end

            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 0;
        end
    end

    // -------------------------------------------------------------------------
    // AXI Read
    // -------------------------------------------------------------------------
    reg rx_rd_pulse;
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            s_axi_arready <= 0; s_axi_rvalid <= 0;
            s_axi_rdata   <= 0; s_axi_rresp  <= 0;
            rx_rd_pulse   <= 0;
        end else begin
            s_axi_arready <= 0;
            rx_rd_pulse   <= 0;

            if (s_axi_arvalid && !s_axi_rvalid) begin
                s_axi_arready <= 1;
                s_axi_rvalid  <= 1;
                s_axi_rresp   <= 2'b00;
                case (s_axi_araddr[3:2])
                    2'h0: s_axi_rdata <= {baud_div, 14'b0, rx_en, tx_en};
                    2'h1: s_axi_rdata <= {27'b0, frame_err, rx_overflow,
                                          rx_ready, tx_full, tx_busy};
                    2'h2: s_axi_rdata <= 32'h0;
                    2'h3: begin
                        s_axi_rdata <= {24'b0, rx_data};
                        rx_rd_pulse <= 1;  // clear rx_ready after read
                    end
                    default: s_axi_rdata <= 32'hDEADBEEF;
                endcase
            end

            if (s_axi_rvalid && s_axi_rready)
                s_axi_rvalid <= 0;
        end
    end

    // -------------------------------------------------------------------------
    // TX  8N1
    // -------------------------------------------------------------------------
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            uart_tx <= 1; tx_busy <= 0; tx_bit_cnt <= 0; tx_baud_cnt <= 0;
        end else if (!tx_busy && tx_full && tx_en) begin
            tx_shift <= {1'b1, tx_data, 1'b0};
            tx_busy  <= 1; tx_full <= 0; tx_bit_cnt <= 0; tx_baud_cnt <= 0;
        end else if (tx_busy) begin
            if (tx_baud_cnt == baud_div - 1) begin
                tx_baud_cnt <= 0;
                uart_tx     <= tx_shift[0];
                tx_shift    <= {1'b1, tx_shift[9:1]};
                if (tx_bit_cnt == 9) begin tx_busy <= 0; uart_tx <= 1; end
                else tx_bit_cnt <= tx_bit_cnt + 1;
            end else tx_baud_cnt <= tx_baud_cnt + 1;
        end
    end

    // -------------------------------------------------------------------------
    // RX  8N1  (mid-bit sampling)
    // -------------------------------------------------------------------------
    always @(posedge s_axi_aclk) begin
        if (!s_axi_aresetn) begin
            rx_sync <= 2'b11; rx_busy <= 0; rx_ready <= 0;
            rx_overflow <= 0; frame_err <= 0; rx_data <= 0;
            rx_bit_cnt <= 0; rx_baud_cnt <= 0;
        end else begin
            rx_sync <= {rx_sync[0], uart_rx};

            if (rx_rd_pulse) begin
                rx_ready <= 0; rx_overflow <= 0; frame_err <= 0;
            end

            if (rx_en) begin
                if (!rx_busy) begin
                    if (!rx_sync[1]) begin
                        rx_busy <= 1; rx_bit_cnt <= 0;
                        rx_baud_cnt <= baud_div >> 1;
                    end
                end else begin
                    if (rx_baud_cnt == baud_div - 1) begin
                        rx_baud_cnt <= 0;
                        if (rx_bit_cnt == 0) begin
                            if (rx_sync[1]) rx_busy <= 0;
                            else rx_bit_cnt <= 1;
                        end else if (rx_bit_cnt <= 8) begin
                            rx_data    <= {rx_sync[1], rx_data[7:1]};
                            rx_bit_cnt <= rx_bit_cnt + 1;
                        end else begin
                            rx_busy <= 0;
                            if (rx_sync[1]) begin
                                if (rx_ready) rx_overflow <= 1;
                                rx_ready <= 1;
                            end else frame_err <= 1;
                        end
                    end else rx_baud_cnt <= rx_baud_cnt + 1;
                end
            end
        end
    end

endmodule
