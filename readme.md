


# install dependencies
sudo apt update
sudo apt install -y git autoconf automake autotools-dev curl python3 \
  libmpc-dev libmpfr-dev libgmp-dev gawk build-essential bison flex \
  texinfo gperf libtool patchutils bc zlib1g-dev libexpat-dev ninja-build \
  cmake verilator

# check verilator version
verilator --version

# download riscv toolchaine prebuild one 
official link: https://github.com/riscv-collab/riscv-gnu-toolchain/releases
wget https://github.com/riscv-collab/riscv-gnu-toolchain/releases/download/2024.04.12/riscv32-elf-ubuntu-22.04-gcc-nightly-2024.04.12-nightly.tar.gz
tar -xzf riscv32-elf-ubuntu-22.04-gcc-nightly-2024.04.12-nightly.tar.gz

# add riscv toolchaine path to the environement 
export PATH=$PWD/toolchain/riscv/bin/:$PATH
echo 'export PATH=$PWD/toolchain/riscv/bin/:$PATH' >> ~/.bashrc
riscv32-unknown-elf-gcc --version

# download picovrv32 
git clone https://github.com/YosysHQ/picorv32.git
in this step only the main core is needed and you can copy it to the rtl directory


