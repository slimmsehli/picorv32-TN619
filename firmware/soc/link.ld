OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 128K
}

SECTIONS {
    . = 0x00000000;

    .text : {
        *(.text.start)
        *(.text .text.*)
        *(.rodata .rodata.*)
    } > RAM

    . = ALIGN(4);

    .data : {
        *(.data .data.*)
        *(.sdata .sdata.*)
    } > RAM

    . = ALIGN(4);

    .bss : {
        _bss_start = .;          /* lower address */
        *(.bss .bss.*)
        *(.sbss .sbss.*)
        *(COMMON)
        . = ALIGN(4);
        _bss_end = .;            /* higher address */
    } > RAM

    /* Last valid BRAM address: 128KB = 0x20000, sel_bram = addr[31:17]==0
       means max valid address = 0x1FFFF, last aligned word = 0x1FFFC */
    _stack_top = 0x0001FFFC;
}
