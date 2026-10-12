set pagination off
set confirm off
set mem inaccessible-by-default off
set arch riscv:rv32
set riscv use-compressed-breakpoints no
set remotetimeout 250
target extended-remote 127.0.0.1:23333
printf "RESET_STATUS_BEFORE_LOAD\n"
x/wx 0xf8100160
monitor reset halt
load
set $pc = _start
tbreak *main
continue
printf "REACHED_MAIN\n"
info registers pc sp
detach
quit
