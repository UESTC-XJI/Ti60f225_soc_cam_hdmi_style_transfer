# Pass build/soc_video_app.elf on the GDB command line, with OpenOCD running.
set pagination off
set mem inaccessible-by-default off
set arch riscv:rv32
set remotetimeout 250
target remote localhost:3333
monitor halt
load
set $pc = _start
tbreak main
continue
