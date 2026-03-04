#!/usr/bin/env python3
# Converts objcopy -O verilog hex output (byte-addressed)
# to $readmemh word-addressed format for Verilog testbenches
#
# Usage: python3 hex_convert.py firmware.hex firmware_word.hex

import sys

def convert(infile, outfile):
    mem = {}
    current_addr = 0  # byte address

    with open(infile) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith('@'):
                # objcopy gives byte address — store as-is
                current_addr = int(line[1:], 16)
            else:
                for byte_str in line.split():
                    mem[current_addr] = int(byte_str, 16)
                    current_addr += 1

    # Find address range
    if not mem:
        print("ERROR: empty hex file")
        sys.exit(1)

    max_addr = max(mem.keys())
    # Round up to next word boundary
    num_words = (max_addr // 4) + 1

    with open(outfile, 'w') as f:
        for word_idx in range(num_words):
            base = word_idx * 4
            # little-endian: byte 0 = LSB
            b0 = mem.get(base+0, 0)
            b1 = mem.get(base+1, 0)
            b2 = mem.get(base+2, 0)
            b3 = mem.get(base+3, 0)
            word = (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
            f.write(f'{word:08x}\n')

    print(f"Converted {len(mem)} bytes → {num_words} words → {outfile}")

if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} input.hex output_word.hex")
        sys.exit(1)
    convert(sys.argv[1], sys.argv[2])
