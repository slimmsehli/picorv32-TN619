

#/home/slim/rv/toolchain/riscv/bin/riscv32-unknown-elf-gcc -Os -mabi=ilp32 -march=rv32imc -ffreestanding -nostdlib -o firmware/firmware.elf -Wl,--build-id=none,-Bstatic,-T,firmware/sections.lds,-Map,firmware/firmware.map,--strip-debug  firmware/start.o firmware/irq.o firmware/print.o firmware/hello.o firmware/sieve.o firmware/multest.o firmware/stats.o tests/add.o tests/addi.o tests/and.o tests/andi.o tests/auipc.o tests/beq.o tests/bge.o tests/bgeu.o tests/blt.o tests/bltu.o tests/bne.o tests/div.o tests/divu.o tests/j.o tests/jal.o tests/jalr.o tests/lb.o tests/lbu.o tests/lh.o tests/lhu.o tests/lui.o tests/lw.o tests/mul.o tests/mulh.o tests/mulhsu.o tests/mulhu.o tests/or.o tests/ori.o tests/rem.o tests/remu.o tests/sb.o tests/sh.o tests/simple.o tests/sll.o tests/slli.o tests/slt.o tests/slti.o tests/sra.o tests/srai.o tests/srl.o tests/srli.o tests/sub.o tests/sw.o tests/xor.o tests/xori.o -lgcc
#chmod -x firmware/firmware.elf
#/home/slim/rv/toolchain/riscv/bin/riscv32-unknown-elf-objcopy -O binary firmware/firmware.elf firmware/firmware.bin
#chmod -x firmware/firmware.bin
#python3 firmware/makehex.py firmware/firmware.bin 32768 > firmware/firmware.hex


#!/bin/bash -f

TOP_DIR=${PWD}

echo "\n\n\n Cleaning ... \n\n\n"
	rm -rf simdir *.log *.vcd *.hex

echo "\n\n\n Compiling ... \n\n\n"
#verilator --cc --exe -Wno-lint -trace --top-module picorv32_wrapper \
#	$TOP_DIR/testbench.v $TOP_DIR/picorv32.v $TOP_DIR/testbench.cc \
#  -DCOMPRESSED_ISA --Mdir simdir -o simv
#make -C ./simdir -f Vpicorv32_wrapper.mk


verilator --binary -j 0 --trace -Wall \
	$TOP_DIR/picorv32.v $TOP_DIR/tb.v \
	--top tb_picorv32  +define+old --Mdir simdir -o simv \
	-Wno-UNDRIVEN -Wno-UNUSEDSIGNAL -Wno-WIDTHEXPAND -Wno-IMPLICIT -Wno-PINCONNECTEMPTY -Wno-DECLFILENAME -Wno-BLKSEQ \
	-Wno-UNUSEDPARAM -Wno-WIDTHTRUNC -Wno-VARHIDDEN -Wno-REDEFMACRO -Wno-PINMISSING -Wno-GENUNNAMED \
	|& tee ./simdir/compile.log 

echo "\n\n\n Simulation ... \n\n\n"
./simdir/simv +vcd |& tee ./simdir/simulation.log 

echo "\n\n\n Openining Waves ... \n\n\n"
#gtkwave waves.vcd &




#verilator --binary -j 0 --trace -Wall --top-module picorv32_wrapper \
#	testbench.v picorv32.v testbench.cc \
#	-DCOMPRESSED_ISA --Mdir testbench_verilator_dir -Wno-BLKSEQ -Wno-UNUSEDSIGNAL

#./testbench_verilator_dir/Vpicorv32_wrapper




