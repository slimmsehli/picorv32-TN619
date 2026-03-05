# crt0.S — PicoRV32 SoC startup
# Execution: set SP → zero .bss → call main → ebreak

.section .text.start
.global  _start

_start:
    # 1. Stack pointer — auipc+addi to get _stack_top PC-relative
    la    sp, _stack_top

    # 2. Zero .bss section
    la    t0, _bss_start       # t0 = first word to zero (lower address)
    la    t1, _bss_end         # t1 = first word past bss (higher address)
_bss_loop:
    bge   t0, t1, _bss_done   # done when t0 >= t1
    sw    zero, 0(t0)
    addi  t0, t0, 4
    j     _bss_loop
_bss_done:

    # 3. Call main
    call  main

    # 4. Halt — main() must not return
_halt:
    ebreak
    j     _halt
