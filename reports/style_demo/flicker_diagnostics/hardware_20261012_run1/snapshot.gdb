set pagination off
set confirm off
set mem inaccessible-by-default off
set arch riscv:rv32
set riscv use-compressed-breakpoints no
set remotetimeout 250
target extended-remote 127.0.0.1:23333
info registers pc sp
printf "VIDEO_STATUS_140_160\n"
x/9wx 0xf8100140
printf "VIDEO_READY_AND_FPS\n"
x/3uw 0xf8100028
printf "STYLE_STATUS\n"
x/wx 0xf8100208
printf "NN_CYCLES\n"
x/uw 0xf810021c
printf "STYLE_COUNTERS_CAPTURE_DROP_NN_INFERERR_FRAME_DMAERR_AXIERR\n"
x/7uw 0xf8100238
p app_style_errors
p app_style_selftest_errors
p app_style_irqs
p app_metrics_updates
p app_ddr_errors
p app_camera_errors
p app_osd_errors
p /x firmware_trap_cause
p /x firmware_trap_pc
p /x firmware_trap_value
printf "STREAM_CONTROL_AND_PROFILER_FREEZE\n"
x/wx 0xf8100204
x/wx 0xf8100254
printf "LATEST_SOFTWARE_DDR_INTERVAL_RAW_COUNTERS\n"
p app_style_ddr_delta
p app_style_read_cycles
p app_style_compute_cycles
monitor resume
detach
quit
