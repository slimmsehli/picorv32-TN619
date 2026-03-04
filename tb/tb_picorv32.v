`timescale 1 ns / 1 ps

// =============================================================================
//  PicoRV32 Testbench
//  - Flat memory model (RAM for instructions + data)
//  - Supports $readmemh hex file loading
//  - MMIO: UART output at 0x1000_0000 (prints chars to console)
//  - MMIO: GPIO  output at 0x2000_0000 (prints value to console)
//  - MMIO: PASS/FAIL at 0x9000_0000   (test result signaling)
//  - Detects trap, timeout, and clean exit
// =============================================================================

module tb_picorv32;
    // -------------------------------------------------------------------------
    // Parameters — edit these to match your setup
    // -------------------------------------------------------------------------
    parameter MEM_WORDS     = 32768;            // 128KB memory (32K x 32-bit words)
    //parameter MEM_FILE      = "firmware.hex"; //"/home/slim/rv/firmware/cbuild/firmware.hex";   // path to your $readmemh hex file
    parameter CLK_PERIOD    = 10;               // 10ns = 100MHz
    parameter MAX_CYCLES    = 10_000_000;       // timeout: 10M cycles (~100ms @100MHz)

    // PicoRV32 reset address — must match PROGADDR_RESET parameter below
    parameter PROG_RESET    = 32'h0000_0000;

    // MMIO addresses
    parameter UART_ADDR     = 32'h1000_0000;    // write a byte → print to console
    parameter GPIO_ADDR     = 32'h2000_0000;    // write 32-bit → print GPIO value
    parameter PASS_ADDR     = 32'h9000_0000;    // write 0 → PASS, non-zero → FAIL
		string MEM_FILE;
    // -------------------------------------------------------------------------
    // Clock & Reset
    // -------------------------------------------------------------------------
    reg clk   = 0;
    reg resetn = 0;
		
    always #(CLK_PERIOD/2) clk = ~clk;

    // Hold reset for 5 cycles
    initial begin
        resetn = 0;
        repeat(5) @(posedge clk);
        resetn = 1;
    end

    // -------------------------------------------------------------------------
    // PicoRV32 memory interface wires
    // -------------------------------------------------------------------------
    wire        mem_valid;
    wire        mem_instr;
    reg         mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [ 3:0] mem_wstrb;
    reg  [31:0] mem_rdata;

    wire        trap;

    // -------------------------------------------------------------------------
    // Instantiate PicoRV32 core
    // -------------------------------------------------------------------------
    picorv32 #(
        .ENABLE_COUNTERS    (1),
        .ENABLE_REGS_16_31  (1),
        .ENABLE_REGS_DUALPORT(1),
        .COMPRESSED_ISA     (0),            // set 1 if your code uses RV32C
        .ENABLE_MUL         (0),            // set 1 if your code uses mul/div
        .ENABLE_DIV         (0),
        .ENABLE_IRQ         (0),
        .PROGADDR_RESET     (PROG_RESET),
        .STACKADDR          (MEM_WORDS * 4) // stack at top of memory
    ) uut (
        .clk        (clk),
        .resetn     (resetn),
        .trap       (trap),

        .mem_valid  (mem_valid),
        .mem_instr  (mem_instr),
        .mem_ready  (mem_ready),
        .mem_addr   (mem_addr),
        .mem_wdata  (mem_wdata),
        .mem_wstrb  (mem_wstrb),
        .mem_rdata  (mem_rdata),

        // Look-ahead — unused in testbench
        .mem_la_read  (),
        .mem_la_write (),
        .mem_la_addr  (),

        // PCPI — tie off (not used)
        .pcpi_wr    (1'b0),
        .pcpi_rd    (32'h0),
        .pcpi_wait  (1'b0),
        .pcpi_ready (1'b0),

        // IRQ — tie off
        .irq        (32'h0),

        // Trace — unused
        .trace_valid(),
        .trace_data ()
    );

    // -------------------------------------------------------------------------
    // Memory model — single flat array, byte-addressed via wstrb
    // -------------------------------------------------------------------------
    reg [31:0] mem [0:MEM_WORDS-1];

    // Load firmware at simulation start
    initial begin
        // Zero memory first
        integer i;
        for (i = 0; i < MEM_WORDS; i = i+1)
            mem[i] = 32'h0000_0013;   // fill with NOPs (addi x0,x0,0)

        // Load compiled program
        // Hex file should be word-addressed, 8 hex digits per line
        if ($test$plusargs("MEM_FILE")) begin
        	$value$plusargs("MEM_FILE=%d", MEM_FILE);
        	$readmemh(MEM_FILE, mem);
        	$display("[TB] Loaded firmware from: %s", MEM_FILE);
        end
        else begin
        	$fatal(1, "[TB] Failed to load firmware from");
        end   
         	
    end

    // -------------------------------------------------------------------------
    // Memory + MMIO response logic
    // -------------------------------------------------------------------------
    // We respond in 1 cycle (mem_ready goes high the cycle after mem_valid)
    // This models fast on-chip SRAM

    reg [31:0] mmio_uart_char;   // last UART character written
    reg [31:0] gpio_value;       // last GPIO value written
    reg        test_done;        // set when PASS/FAIL address written
    reg        test_pass;        // 1=PASS, 0=FAIL

    initial begin
        mem_ready       = 0;
        mem_rdata       = 0;
        test_done       = 0;
        test_pass       = 0;
        gpio_value      = 0;
    end

    // One-cycle ready response
    always @(posedge clk) begin
        mem_ready <= 0;
        mem_rdata <= 32'hx;

        if (mem_valid && !mem_ready) begin
            mem_ready <= 1;

            // ------------------------------------------------------------------
            // WRITE path
            // ------------------------------------------------------------------
            if (mem_wstrb != 4'b0000) begin

                // Normal RAM write
                if (mem_addr < MEM_WORDS * 4) begin
                    if (mem_wstrb[0]) mem[mem_addr[31:2]][7:0]   <= mem_wdata[7:0];
                    if (mem_wstrb[1]) mem[mem_addr[31:2]][15:8]  <= mem_wdata[15:8];
                    if (mem_wstrb[2]) mem[mem_addr[31:2]][23:16] <= mem_wdata[23:16];
                    if (mem_wstrb[3]) mem[mem_addr[31:2]][31:24] <= mem_wdata[31:24];
                end

                // MMIO: UART — print character to console
                else if (mem_addr == UART_ADDR) begin
                    $write("%c", mem_wdata[7:0]);   // no newline, just raw char
                end

                // MMIO: GPIO — print value
                else if (mem_addr == GPIO_ADDR) begin
                    gpio_value <= mem_wdata;
                    $display("[GPIO] 0x%08X (%0d)", mem_wdata, mem_wdata);
                end

                // MMIO: PASS/FAIL signal
                else if (mem_addr == PASS_ADDR) begin
                    test_done <= 1;
                    if (mem_wdata == 32'h0) begin
                        test_pass <= 1;
                        $display("\n[TB] *** TEST PASSED ***");
                    end else begin
                        test_pass <= 0;
                        $display("\n[TB] *** TEST FAILED (code=0x%08X) ***", mem_wdata);
                    end
                end

                // Unmapped write — warn but don't crash
                else begin
                    $display("[TB] WARNING: write to unmapped address 0x%08X data=0x%08X",
                             mem_addr, mem_wdata);
                end
            end

            // ------------------------------------------------------------------
            // READ path
            // ------------------------------------------------------------------
            else begin

                // Normal RAM read
                if (mem_addr < MEM_WORDS * 4) begin
                    mem_rdata <= mem[mem_addr[31:2]];
                end

                // MMIO reads return 0 by default (add readable regs here later)
                else begin
                    mem_rdata <= 32'h0;
                    if (mem_instr)
                        $display("[TB] WARNING: instruction fetch from unmapped 0x%08X",
                                 mem_addr);
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Cycle counter & timeout watchdog
    // -------------------------------------------------------------------------
    integer cycle_count;
    initial cycle_count = 0;

    always @(posedge clk) begin
        if (!resetn)
            cycle_count <= 0;
        else
            cycle_count <= cycle_count + 1;

        if (cycle_count >= MAX_CYCLES) begin
            $display("[TB] TIMEOUT after %0d cycles — possible infinite loop or hang",
                     MAX_CYCLES);
            $finish;
        end
    end

    // -------------------------------------------------------------------------
    // Trap detector — core asserts trap on illegal instruction or ebreak
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (trap) begin
            $display("[TB] TRAP detected at cycle %0d — pc=0x%08X",
                     cycle_count, uut.reg_pc);
            $display("[TB] Simulation stopped on TRAP.");
            #(CLK_PERIOD * 2);
            $finish;
        end
    end

    // -------------------------------------------------------------------------
    // PASS/FAIL watchdog — stop cleanly once program signals done
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (test_done) begin
            #(CLK_PERIOD * 4);  // let any trailing output flush
            $display("[TB] Finished in %0d cycles.", cycle_count);
            $finish;
        end
    end

    // -------------------------------------------------------------------------
    // VCD waveform dump — open in GTKWave
    // -------------------------------------------------------------------------
    string VCD_FILE;
    initial begin
        if ($test$plusargs("VCD_FILE")) begin
        	$value$plusargs("VCD_FILE=%d", VCD_FILE);
        end
        else begin
        	VCD_FILE = "waves.vcd";
        end  
        $display("[TB] Dumping waveform to : %s", VCD_FILE); 
        $dumpfile(VCD_FILE);
        $dumpvars(0, tb_picorv32);
    end

    // -------------------------------------------------------------------------
    // Startup banner
    // -------------------------------------------------------------------------
    initial begin
        $display("=================================================");
        $display("  PicoRV32 Testbench");
        $display("  Memory  : %0d KB", MEM_WORDS * 4 / 1024);
        $display("  Firmware: %s", MEM_FILE);
        $display("  Timeout : %0d cycles", MAX_CYCLES);
        $display("=================================================");
    end

endmodule
