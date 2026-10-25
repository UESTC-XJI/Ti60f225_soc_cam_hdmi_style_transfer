"""Execute the actual RV32 DDR logger: coherent snapshots, deltas and wrap."""
from test_firmware_runtime import Machine, SYMBOLS
from unicorn.riscv_const import UC_RISCV_REG_RA, UC_RISCV_REG_SP, UC_RISCV_REG_GP

class DiagnosticMachine(Machine):
    def osd_read(self, uc, off, size, data):
        if off in self.video_status:
            return self.video_status[off]
        return super().osd_read(uc, off, size, data)

m = DiagnosticMachine('ddr_telemetry')
m.video_status = {}
u = m.uc
u.mem_write(SYMBOLS['__bss_start'], bytes(SYMBOLS['__bss_end'] - SYMBOLS['__bss_start']))
u.reg_write(UC_RISCV_REG_SP, SYMBOLS['_sp'])
u.reg_write(UC_RISCV_REG_GP, SYMBOLS['__global_pointer$'])
u.mem_write(SYMBOLS['app_style_read_cycles'], (148500 * 17).to_bytes(4, 'little'))
u.mem_write(SYMBOLS['app_style_compute_cycles'], (148500 * 3).to_bytes(4, 'little'))
u.mem_write(SYMBOLS['app_uart_debug'], (1).to_bytes(4, 'little'))  # log format is only printed when enabled

previous = [0] * 12
snapshots = [
    [1000, 600, 20, 110, 0, 390, 1, 20, 4, 200, 32, 64],
    [3000, 800, 40, 510, 0, 390, 3, 100, 24, 1200, 96, 192],
    [0xfffffff0] * 12,
    [84] * 12,  # Every counter wraps by a delta of 100.
    [84] * 12,  # A zero interval must not divide by zero.
    [85] + [0xffffff00] * 11,  # Large decimal fields after a long paused interval.
]
labels = ['AR', 'DOWN', 'RGAP', 'RBP', 'DBP', 'AW', 'W', 'B', 'IDLE']
# First sample, queue-only loss, independent display starvation, wrap,
# unchanged counters, and full-width fault fields after a long debug pause.
video_samples = [
    (0, 13, 0, 0, 0, 0, 0),
    (0, 29, 0, 0, 0, 0, 0),
    (5, 45, 4, 0, 0, 0, 0),
    (0xfffffff0, 0xfffffff0, 255, 1, 2, 3, 4),
    (4, 8, 255, 1, 2, 3, 4),
    (4, 8, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff, 0xffffffff),
]
previous_underflow = previous_drop = 0
for snapshot, video in zip(snapshots, video_samples):
    uf, drop, fault, csi, dme, ierr, axi = video
    m.video_status.update({0x14c: uf, 0x140: fault, 0x15c: csi, 0x148: axi})
    m.style_regs.update({0x3c: drop, 0x4c: dme, 0x44: ierr})
    m.style_regs.update({0x58 + 4 * i: v for i, v in enumerate(snapshot)})
    start = len(m.uart)
    u.reg_write(UC_RISCV_REG_RA, 0x100)
    u.emu_start(SYMBOLS['style_log_ddr'], 0x100, count=1000000)
    delta = [(a - b) & 0xffffffff for a, b in zip(snapshot, previous)]
    observed = [int.from_bytes(u.mem_read(SYMBOLS['app_style_ddr_delta'] + 4 * i, 4), 'little')
                for i in range(12)]
    assert observed == delta, (observed, delta)
    expected = f'DDR100M T {delta[0]}'
    for label, value in zip(labels, delta[1:10]):
        percentage = (value * 100 // delta[0]) & 0xffffffff if delta[0] else 0
        expected += f' {label} {percentage}'
    expected += f' RB {delta[10]} DRB {delta[11]} RPMS 17 CPMS 3\r\n'
    expected += (f'VIDEO UF {uf} DUF {(uf-previous_underflow)&0xffffffff}'
                 f' DDROP {(drop-previous_drop)&0xffffffff} FAULT {fault}'
                 f' CSI {csi} DME {dme} IERR {ierr} AXI {axi}\r\n')
    assert m.uart[start:] == expected, (m.uart[start:], expected)
    assert m.style_regs[0x54] == 0, 'logger must release freeze'
    previous = snapshot
    previous_underflow, previous_drop = uf, drop
print('PASS actual RV32 DDR/video diagnostics: independent queue drops/underflow/faults, deltas, wrap, zero interval, full-width fields, phase milliseconds, freeze release')
