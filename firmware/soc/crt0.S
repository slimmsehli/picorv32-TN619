.section .text.start
.global _start

_start:
    la   sp, _stack_top

    la   t0, _bss_start
    la   t1, _bss_end
_bss_loop:
    bge  t0, t1, _bss_done
    sw   zero, 0(t0)
    addi t0, t0, 4
    j    _bss_loop
_bss_done:

    call main

_halt:
    ebreak
    j    _halt
