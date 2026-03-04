# =============================================================================
#  Makefile — Build firmware + run PicoRV32 simulation
#
#  Requirements:
#    - riscv32-unknown-elf-gcc  (RISC-V toolchain)
#    - iverilog + vvp           (Icarus Verilog simulator)
#    - gtkwave                  (optional, for waveforms)
#
#  Install toolchain (Ubuntu/Debian):
#    sudo apt install gcc-riscv64-unknown-elf
#    sudo apt install iverilog gtkwave
#
#  Usage:
#    make          — build firmware + run simulation
#    make firmware — build firmware only
#    make sim      — run simulation only (firmware must exist)
#    make wave     — open waveform in GTKWave
#    make disasm   — disassemble firmware (useful for debugging)
#    make clean    — remove all build outputs
# =============================================================================
CC      = riscv32-unknown-elf-gcc
OBJCOPY = riscv32-unknown-elf-objcopy
OBJDUMP = riscv32-unknown-elf-objdump

CFLAGS  = -march=rv32i -mabi=ilp32 -nostdlib -O1 -Wall

SRCS     = ./firmware/crt0.S ./firmware/main.c
LDSCRIPT = ./firmware/link.ld
ELF      = ./firmware/firmware.elf
HEX_RAW  = ./firmware/firmware_raw.hex   # objcopy byte-addressed output
HEX      = ./firmware/firmware.hex        # word-addressed for $readmemh

TB      = ./tb/tb_picorv32.v
CORE    = ./rtl/picorv32.v
SIMOUT  = ./simulation/sim.vvp
VCD     = ./simulation/waves.vcd
HEX_CONV = ./scripts/hex_convert.py

.PHONY: all firmware sim wave disasm clean

all: firmware sim

firmware: $(HEX)

$(ELF): $(SRCS) $(LDSCRIPT)
	$(CC) $(CFLAGS) -T $(LDSCRIPT) $(SRCS) -o $(ELF)

$(HEX_RAW): $(ELF)
	$(OBJCOPY) -O verilog $(ELF) $(HEX_RAW)

$(HEX): $(HEX_RAW)
	python3 $(HEX_CONV) $(HEX_RAW) $(HEX)

$(SIMOUT): $(TB) $(CORE)
	iverilog -g2012 -o $(SIMOUT) $(TB) $(CORE)

sim: $(SIMOUT) $(HEX)
	vvp $(SIMOUT) +MEM_FILE=$(HEX)

wave: $(VCD)
	gtkwave $(VCD) &

disasm: $(ELF)
	$(OBJDUMP) -d $(ELF)

clean:
	rm -f ./simulation/* ./firmware/*.hex ./firmware/*.elf 
	
	
