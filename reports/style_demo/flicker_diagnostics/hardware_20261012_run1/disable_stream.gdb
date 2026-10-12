set pagination off
set confirm off
set mem inaccessible-by-default off
set arch riscv:rv32
set riscv use-compressed-breakpoints no
set remotetimeout 250
target extended-remote 127.0.0.1:23333
printf "DISABLE_CAPTURE_AND_NEW_NN_KEEP_DISPLAY\n"
x/wx 0xf8100204
set *(unsigned int *)0xf8100204 = 0
x/wx 0xf8100204
x/7uw 0xf8100238
x/9wx 0xf8100140
monitor resume
detach
quit
