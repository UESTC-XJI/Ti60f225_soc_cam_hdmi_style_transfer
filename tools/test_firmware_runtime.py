"""Execute the actual RV32 ELF with modeled UART/I2C/OSD/CLINT registers.

Unicorn models RV32 instructions, not the protected Sapphire RTL or caches.
The Sapphire custom cache instruction is intercepted as a model operation.
Install dependencies into work/sim_deps using tools/firmware_sim_requirements.txt.
"""
from pathlib import Path
import os
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'work/sim_deps'))
from unicorn import Uc, UC_ARCH_RISCV, UC_MODE_RISCV32, UC_HOOK_CODE, UC_HOOK_MEM_WRITE
from unicorn.riscv_const import UC_RISCV_REG_PC, UC_RISCV_REG_SP, UC_RISCV_REG_GP
from unicorn.riscv_const import UC_RISCV_REG_MCAUSE, UC_RISCV_REG_MEPC, UC_RISCV_REG_MTVAL
from unicorn.riscv_const import UC_RISCV_REG_MSTATUS, UC_RISCV_REG_MIE, UC_RISCV_REG_MTVEC
from elftools.elf.elffile import ELFFile

ELF = Path(os.environ.get('SOC_FIRMWARE_ELF', ROOT / 'software/firmware/build/soc_video_app.elf'))
with ELF.open('rb') as f:
    elf = ELFFile(f)
    ENTRY = elf.header.e_entry
    SYMBOLS = {s.name: s.entry.st_value for s in elf.get_section_by_name('.symtab').iter_symbols()}
    SEGMENTS = [(s.header.p_vaddr, s.data()) for s in elf.iter_segments() if s.header.p_type == 'PT_LOAD']
    TEXT = [(s.header.sh_addr, s.data()) for s in elf.iter_sections() if s.header.sh_flags & 4]
    assert not [s.name for s in elf.get_section_by_name('.symtab').iter_symbols()
                if s.name and s.entry.st_shndx == 'SHN_UNDEF']

for name in ['_start', 'main', 'camera_init_cpu', 'camera_recover',
             'osd_write_string', 'osd_submit_metrics', 'app_ddr_test', 'trap_entry']:
    assert name in SYMBOLS, name
assert ENTRY == SYMBOLS['_start'] == 0x1000
assert SYMBOLS['_sp'] == 0x20000 and SYMBOLS['_end'] < SYMBOLS['__stack_bottom']

TABLE = [(int(a, 16), int(b, 16)) for a, b in re.findall(
    r'\{0x([0-9a-f]+),0x([0-9a-f]+),[01],\d+\}',
    (ROOT / 'software/firmware/camera_init_table.h').read_text())]

class Machine:
    def __init__(self, scenario):
        self.scenario = scenario
        self.uc = Uc(UC_ARCH_RISCV, UC_MODE_RISCV32)
        self.uc.mem_map(0, 0x20000)
        self.uc.mem_map(0x01000000, 0x100000)
        for addr, data in SEGMENTS: self.uc.mem_write(addr, data)
        self.uc.mem_write(SYMBOLS['__bss_start'], b'\xa5' *
                          (SYMBOLS['__bss_end'] - SYMBOLS['__bss_start']))
        self.clock = 0xffff0000 if scenario == 'timer_wrap' else 0
        self.uart = ''
        self.sensor = {0x3107: 0xcd, 0x3108: 0x6b}
        if scenario == 'id_retry': self.sensor[0x3107] = 0
        self.i2c_phase = 'address'
        self.i2c_ptr = 0
        self.rx_ack = 0x101 if scenario == 'stale_ack' else 0
        self.rx_listen = False
        self.tx_ack_pending = False
        self.i2c_read_byte = False
        self.ack_stalls = 0
        self.i2c_status = 0x600 if scenario == 'bus_recover' else 0
        self.i2c_lines = 4 if scenario == 'bus_recover' else 6
        self.bus_recoveries = 0
        self.camera_writes = []
        self.config = {}
        self.active = 0
        self.ack = 0
        self.pending = None
        self.char_addr = 0
        self.pages = [list(' ' * 80), list(' ' * 80)]
        self.commits = []
        self.commit_times = []
        self.video_ready = 1  # A previous debugger-loaded application left it set.
        self.ready_writes = []
        self.invalidates = 0
        self.main_seen = False
        self.uc.mmio_map(0xf8010000, 0x1000, self.uart_read, None, self.uart_write, None)
        self.uc.mmio_map(0xf8016000, 0x1000, self.i2c_read, None, self.i2c_write, None)
        self.uc.mmio_map(0xf8b00000, 0x10000, self.clint_read, None, self.ignore_write, None)
        self.uc.mmio_map(0xf8100000, 0x1000, self.osd_read, None, self.osd_write, None)
        self.uc.hook_add(UC_HOOK_CODE, self.at_main, begin=SYMBOLS['main'], end=SYMBOLS['main'])
        for base, data in TEXT:
            for i in range(0, len(data), 4):
                if data[i:i+4] == b'\x0f\x50\x00\x00':
                    self.uc.hook_add(UC_HOOK_CODE, self.cache_op, begin=base+i, end=base+i)
        addr = SYMBOLS['app_metrics_updates']
        self.uc.hook_add(UC_HOOK_MEM_WRITE, self.update_done, begin=addr, end=addr+3)

    def at_main(self, uc, addr, size, data):
        self.main_seen = True
        assert uc.reg_read(UC_RISCV_REG_SP) == SYMBOLS['_sp']
        assert uc.reg_read(UC_RISCV_REG_GP) == SYMBOLS['__global_pointer$']
        assert uc.reg_read(UC_RISCV_REG_MSTATUS) & 8 == 0
        assert uc.reg_read(UC_RISCV_REG_MIE) == 0
        assert uc.reg_read(UC_RISCV_REG_MTVEC) == SYMBOLS['trap_entry']
        bss_size = SYMBOLS['__bss_end'] - SYMBOLS['__bss_start']
        assert bytes(uc.mem_read(SYMBOLS['__bss_start'], bss_size)) == bytes(bss_size)

    def cache_op(self, uc, addr, size, data):
        self.invalidates += 1
        if self.scenario == 'ddr_corrupt' and self.invalidates == 2:
            uc.mem_write(0x01000000, b'\x00\x00\x00\x00')
        uc.reg_write(UC_RISCV_REG_PC, addr+4)

    def update_done(self, uc, access, addr, size, value, data):
        if value == 3: uc.emu_stop()

    def uart_read(self, uc, off, size, data):
        return 128 << 16 if off == 4 else 0

    def uart_write(self, uc, off, size, value, data):
        if off != 0:
            self.config[('uart', off)] = value
            return
        self.uart += chr(value & 255)
        if self.scenario == 'id_retry' and 'retry every second\r\n' in self.uart:
            self.sensor[0x3107] = 0xcd
        if self.scenario == 'ddr_corrupt' and 'DDR scratch FAIL\r\n' in self.uart:
            uc.emu_stop()

    def i2c_read(self, uc, off, size, data):
        if off == 8: return self.sensor.get(self.i2c_ptr, 0)
        if off == 4: return 0x100 if self.tx_ack_pending else 0
        if off == 0x40: return self.i2c_status
        if off == 0x44: return self.i2c_lines
        if off == 0x0c:
            value = self.rx_ack
            self.rx_ack &= ~0x100  # Actual Sapphire RTL clears VALID on READ.
            if self.tx_ack_pending: self.complete_i2c_ack()
            return value
        return 0

    def i2c_ack_result(self):
        return 1 if self.i2c_read_byte else 0

    def complete_i2c_ack(self):
        self.tx_ack_pending = False
        if self.rx_listen: self.rx_ack = 0x100 | self.i2c_ack_result()

    def i2c_write(self, uc, off, size, value, data):
        if off == 0x40:
            self.i2c_status &= ~(value & 0xe00)
            if value & 0x10:
                self.i2c_phase = 'address'
                self.i2c_status |= 1
            if value & 0x20:
                # Native STOP is serviced inside an active transfer; issuing
                # it while idle leaves STOP pending without BUSY becoming 1.
                self.i2c_status = 0 if self.i2c_status & 1 else self.i2c_status | 0x20
            if value & 0x40: self.i2c_status = 0
            if value & 0x80:
                self.bus_recoveries += 1
                self.i2c_status = 0  # Native RECOVER already terminates with STOP.
                self.i2c_lines = 6
            if value & (0x20 | 0x40):
                self.rx_listen = False  # STOP/DROP do not clear RX_ACK.VALID.
                self.tx_ack_pending = False
            return
        if off == 0x0c:
            self.rx_listen = bool(value & 0x200)  # LISTEN writes preserve VALID.
            return
        if off == 4:
            if self.rx_listen and self.rx_ack & 0x100:
                self.tx_ack_pending = True
                self.ack_stalls += 1
            else: self.complete_i2c_ack()
            return
        if off != 0:
            self.config[('i2c', off)] = value
            return
        byte = value & 255
        self.i2c_read_byte = self.i2c_phase == 'read'
        if self.i2c_phase == 'address':
            assert byte in (0x60, 0x61), hex(byte)
            self.i2c_phase = 'read' if byte & 1 else 'high'
        elif self.i2c_phase == 'high':
            self.i2c_ptr = byte << 8
            self.i2c_phase = 'low'
        elif self.i2c_phase == 'low':
            self.i2c_ptr |= byte
            self.i2c_phase = 'write'
        elif self.i2c_phase == 'write':
            self.sensor[self.i2c_ptr] = byte
            self.camera_writes.append((self.i2c_ptr, byte))

    def clint_read(self, uc, off, size, data):
        if off == 0xbff8:
            self.clock += 10000  # 0.1 ms per timer sample; checked I2C transactions remain bounded.
            return self.clock & 0xffffffff
        return self.clock >> 32 if off == 0xbffc else 0

    def ignore_write(self, uc, off, size, value, data):
        pass

    def osd_read(self, uc, off, size, data):
        if self.pending and self.scenario != 'no_ack' and self.clock >= self.pending[1]:
            self.active = self.pending[0]
            self.pending = None
            self.ack ^= 1
            self.commits.append(''.join(self.pages[self.active]))
            self.commit_times.append(self.clock)
        if off == 0: return 0x4f534431
        if off == 0x20: return self.ack | self.active << 1 | bool(self.pending) << 2
        if off == 0x24: return (60 << 16) | (30 if len(self.commits) < 2 else 9)
        if off == 0x28: return self.video_ready
        if off == 0x2c: return 30
        if off == 0x30: return 30 if len(self.commits) < 2 else 9
        return 0

    def osd_write(self, uc, off, size, value, data):
        if off == 0x28:
            self.video_ready = value & 1
            self.ready_writes.append(self.video_ready)
            if self.video_ready:
                assert self.ready_writes[0] == 0, 'reload must clear readiness first'
                assert any(self.camera_writes[i:i+len(TABLE)]==TABLE for i in range(len(self.camera_writes)-len(TABLE)+1)), 'camera not initialized'
                assert self.commits and self.pending is None, 'OSD not acknowledged'
        elif off == 0x14: self.char_addr = value
        elif off == 0x18:
            page, pos = self.char_addr >> 7, self.char_addr & 127
            assert page != self.active and pos < 80
            self.pages[page][pos] = chr(value & 255)
        elif off == 0x1c:
            assert self.pending is None
            self.pending = (self.char_addr >> 7, self.clock + 1666667)

    def word(self, name):
        return int.from_bytes(self.uc.mem_read(SYMBOLS[name], 4), 'little')

    def run(self):
        self.uc.emu_start(ENTRY, 0x20000, count=10000000)
        assert self.main_seen
        assert self.word('firmware_trap_cause') == 0
        assert self.ready_writes[0] == 0
        assert self.ack_stalls == 0, 'stale RX_ACK stalled a checked transaction'
        if self.scenario == 'bus_recover': assert self.bus_recoveries == 1
        assert self.video_ready == (0 if self.scenario in ('ddr_corrupt', 'no_ack') else 1)
        if self.scenario == 'ddr_corrupt':
            assert self.word('app_ddr_errors') == 1
            assert not self.camera_writes
            assert 'DDR scratch FAIL' in self.uart
        else:
            assert self.word('app_metrics_updates') == 3
            assert self.word('app_ddr_errors') == 0
            assert self.invalidates == 3  # Startup + two passes at boot; no periodic DDR pause.
            assert self.config[('uart', 8)] == 107
            assert self.config[('i2c', 0x50)] == 500
            assert self.config[('i2c', 0x54)] == 500
            assert 'DDR scratch PASS' in self.uart
            if self.scenario == 'id_retry':
                assert self.camera_writes[0] == (0x100, 0)
                assert self.camera_writes[1:] == TABLE
                assert self.word('app_camera_errors') == 1
                assert 'Camera recovered' in self.uart
            else:
                assert self.camera_writes == TABLE
                assert self.word('app_camera_errors') == 0
            if self.scenario == 'no_ack':
                assert not self.commits and self.word('app_osd_errors') == 1
            else:
                assert len(self.commits) == 3  # Third metrics update has just been submitted asynchronously.
                assert self.commits[0].rstrip() == 'HELLO SOC'
                assert self.word('app_osd_errors') == 0
                for text in self.commits[1:]:
                    assert text.rstrip() + '\r\n' in self.uart
                    assert 'DROP 0 ERR 0' in text
                assert self.commits[-1].rstrip() == 'RAW 30 RESIZE 9 DISP 60 DROP 0 ERR 0'
                assert all(b-a >= 99000000 for a,b in zip(self.commit_times, self.commit_times[1:]))
        print('PASS RV32 ELF:', self.scenario, 'entry, stack/gp/BSS, UART, DDR, camera, OSD/timer')
        return {'scenario': self.scenario, 'uart': self.uart,
                'committed_pages': self.commits, 'commit_ticks': self.commit_times,
                'video_ready_writes': self.ready_writes,
                'cache_operations_modeled': self.invalidates}

if __name__ == '__main__':
    results = [Machine(s).run() for s in ['normal', 'stale_ack', 'bus_recover', 'id_retry', 'no_ack', 'ddr_corrupt', 'timer_wrap']]
    trap = Machine('trap')
    trap.uc.reg_write(UC_RISCV_REG_GP, SYMBOLS['__global_pointer$'])
    trap.uc.reg_write(UC_RISCV_REG_SP, SYMBOLS['_sp'])
    trap.uc.reg_write(UC_RISCV_REG_MCAUSE, 2)
    trap.uc.reg_write(UC_RISCV_REG_MEPC, 0x1234)
    trap.uc.reg_write(UC_RISCV_REG_MTVAL, 0xffffffff)
    trap.uc.emu_start(SYMBOLS['trap_entry'], SYMBOLS['trap_halt'], count=50)
    assert trap.word('firmware_trap_cause') == 2
    assert trap.word('firmware_trap_pc') == 0x1234
    assert trap.word('firmware_trap_value') == 0xffffffff
    print('PASS RV32 trap handler: cause/PC/value captured for IDE inspection')
    out = ROOT / 'reports/simulation'
    out.mkdir(parents=True, exist_ok=True)
    (out / 'firmware_runtime.json').write_text(json.dumps(results, indent=2), encoding='utf-8')
