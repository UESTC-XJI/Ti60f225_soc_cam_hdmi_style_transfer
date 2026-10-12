set pagination off
set confirm off
set mem inaccessible-by-default off
set arch riscv:rv32
set riscv use-compressed-breakpoints no
set remotetimeout 250
target extended-remote 127.0.0.1:23333
printf "HALT_CPU_ONLY_FPGA_STREAM_CONTINUES\n"
info registers pc
x/9wx 0xf8100140
x/7uw 0xf8100238
x/wx 0xf8100204
disconnect
quit
