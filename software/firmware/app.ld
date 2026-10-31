OUTPUT_ARCH(riscv)
ENTRY(_start)
/* 0x1000 is DDR. The separate 4 KiB on-chip RAM is at 0xf9000000. */
/* 2026-10-31: 权重档位表放在 DDR app 区（不占 FPGA XLR）。124K -> 4M；
 * 20 档约 290 KB，70 档约 1.1 MB，仍在 4 MB 内。栈在 app_ddr 顶端。 */
MEMORY { app_ddr (rwx) : ORIGIN = 0x00001000, LENGTH = 4M }
PHDRS { code PT_LOAD FLAGS(5); data PT_LOAD FLAGS(6); }
SECTIONS
{
    .init : { KEEP(*(.init)) } > app_ddr :code
    .text : { *(.text .text.*) } > app_ddr :code
    .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } > app_ddr :code
    .data : ALIGN(4) {
        _data = .;
        *(.data .data.*)
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
        . = ALIGN(4);
        _edata = .;
    } > app_ddr :data
    _data_lma = LOADADDR(.data);
    .bss (NOLOAD) : ALIGN(4) {
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > app_ddr :data
    _end = .;
    _sp = ORIGIN(app_ddr) + LENGTH(app_ddr);
    __stack_bottom = _sp - 4096;
    _heap_end = __stack_bottom;
    ASSERT(_end <= __stack_bottom, "Application overlaps 4 KiB stack")
    /DISCARD/ : { *(.comment .note.GNU-stack) }
}
