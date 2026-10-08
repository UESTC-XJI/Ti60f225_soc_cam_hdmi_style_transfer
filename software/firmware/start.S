/* Single-hart polled runtime: download through JTAG after DDR calibration. */
    .section .init,"ax",@progbits
    .balign 4
    .global _start
    .type _start,@function
_start:
    csrci mstatus, 8
    csrw mie, zero
    .option push
    .option norelax
    la gp, __global_pointer$
    la sp, _sp
    .option pop
    la t0, trap_entry
    csrw mtvec, t0
    /* Sapphire's documented data-cache invalidate, then instruction sync. */
    .word 0x0000500f
    fence.i
    la t0, _data_lma
    la t1, _data
    la t2, _edata
    beq t0, t1, clear_bss
copy_data:
    bgeu t1, t2, clear_bss
    lbu t3, 0(t0)
    sb t3, 0(t1)
    addi t0, t0, 1
    addi t1, t1, 1
    j copy_data
clear_bss:
    la t0, __bss_start
    la t1, __bss_end
1:
    bgeu t0, t1, 2f
    sb zero, 0(t0)
    addi t0, t0, 1
    j 1b
2:
    call main
firmware_exit:
    j firmware_exit
    .size _start, .-_start

    .section .text.trap_entry,"ax",@progbits
    .balign 4
    .global trap_entry
trap_entry:
    .option push
    .option norelax
    csrr t0, mcause
    la t1, firmware_trap_cause
    sw t0, 0(t1)
    csrr t0, mepc
    la t1, firmware_trap_pc
    sw t0, 0(t1)
    csrr t0, mtval
    la t1, firmware_trap_value
    sw t0, 0(t1)
    .option pop
trap_halt:
    j trap_halt
