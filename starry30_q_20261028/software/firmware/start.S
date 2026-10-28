/* Single-hart runtime with external interrupt return; DDR must be calibrated. */
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
    addi sp, sp, -128
    sw ra, 0(sp)
    sw t0, 4(sp)
    sw t1, 8(sp)
    sw t2, 12(sp)
    sw a0, 16(sp)
    sw a1, 20(sp)
    sw a2, 24(sp)
    sw a3, 28(sp)
    sw a4, 32(sp)
    sw a5, 36(sp)
    sw a6, 40(sp)
    sw a7, 44(sp)
    sw t3, 48(sp)
    sw t4, 52(sp)
    sw t5, 56(sp)
    sw t6, 60(sp)
    csrr t0, mcause
    li t1, 0x8000000b
    bne t0, t1, trap_record
    call firmware_interrupt_handler
    lw ra, 0(sp)
    lw t0, 4(sp)
    lw t1, 8(sp)
    lw t2, 12(sp)
    lw a0, 16(sp)
    lw a1, 20(sp)
    lw a2, 24(sp)
    lw a3, 28(sp)
    lw a4, 32(sp)
    lw a5, 36(sp)
    lw a6, 40(sp)
    lw a7, 44(sp)
    lw t3, 48(sp)
    lw t4, 52(sp)
    lw t5, 56(sp)
    lw t6, 60(sp)
    addi sp, sp, 128
    mret
trap_record:
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
