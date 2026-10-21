"""Actual RV32 telemetry: elapsed-time FPS, repeated display, drops, wraparound."""
from test_firmware_runtime import Machine,SYMBOLS
from unicorn.riscv_const import UC_RISCV_REG_A0,UC_RISCV_REG_A1,UC_RISCV_REG_RA,UC_RISCV_REG_SP,UC_RISCV_REG_GP
m=Machine('telemetry');u=m.uc
u.mem_write(SYMBOLS['__bss_start'],bytes(SYMBOLS['__bss_end']-SYMBOLS['__bss_start']))
u.reg_write(UC_RISCV_REG_SP,SYMBOLS['_sp']);u.reg_write(UC_RISCV_REG_GP,SYMBOLS['__global_pointer$'])
for now,cap,nn,drop,cap_fps,nn_fps in [(100000000,30,16,14,30,16),(250000000,75,40,35,30,16),(350000000,0xfffffffe,0xfffffffe,99,999,999),(450000000,3,3,104,5,5)]:
    m.clock=now;m.style_regs.update({0x38:cap,0x40:nn,0x3c:drop,0x1c:9055350})
    u.mem_write(SYMBOLS['app_style_cycles'],(9055350).to_bytes(4,'little'))
    u.reg_write(UC_RISCV_REG_A0,now&0xffffffff);u.reg_write(UC_RISCV_REG_A1,now>>32)
    u.reg_write(UC_RISCV_REG_RA,0x100)
    u.emu_start(SYMBOLS['style_submit_metrics'],0x100,count=1000000)
    assert u.reg_read(UC_RISCV_REG_A0)==0
    line=''.join(m.pages[m.char_addr>>7]).rstrip()
    assert line==f'MONET CAP {cap_fps} NN {nn_fps} DISP 60 DROP {drop} MS 60 ERR 0',line
print('PASS actual RV32 style telemetry: measured interval, CAP/NN vs repeated 60Hz, cumulative drops, milliseconds, uint32 wrap')
