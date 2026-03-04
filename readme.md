
# Project : TN619 MCU based on RICV core picorv32
Forked from : https://github.com/YosysHQ/picorv32

Thsi is a 32bit MCU based on the picorv32 core with additional IPs

This is running using verilator verilog simulator


# INstall verilator alongside the needed tools 
	sudo apt update
	sudo apt install -y git autoconf automake autotools-dev curl python3 \
		libmpc-dev libmpfr-dev libgmp-dev gawk build-essential bison flex \
		texinfo gperf libtool patchutils bc zlib1g-dev libexpat-dev ninja-build \
		cmake verilator
	
	verilator --version

# Download and install riscv toolchaine 
	* You can donwload the prebuild one, or you can download the source and compile it locally
	official link: https://github.com/riscv-collab/riscv-gnu-toolchain/releases

	wget https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/2024.04.12/riscv32-elf-ubuntu-22.04-gcc-nightly-2024.04.12-nightly.tar.gz

	tar -xzf riscv32-elf-ubuntu-22.04-gcc-nightly-2024.04.12-nightly.tar.gz

	* Add riscv toolchaine path to the environement 

	export PATH=$PWD/toolchain/riscv/bin/:$PATH

	echo 'export PATH=$PWD/toolchain/riscv/bin/:$PATH' >> ~/.bashrc

	riscv32-unknown-elf-gcc --version

# Download picovrv32 
	git clone https://github.com/YosysHQ/picorv32.git
	In this step only the main core is needed here and you can copy it to the rtl directory

# Running main test
	using the Makefile you can generate a main program and run the simulation to test the core
	this will make sure that the compiler toolchain, the rtl and the setup are correct
	use:
	make clean
	make firemware
	make comp
	make run
	make wave

	If everything is working correctly this message should be shown at the end of the simulation
	===========================================
	ALL TESTS PASSED
	===========================================




