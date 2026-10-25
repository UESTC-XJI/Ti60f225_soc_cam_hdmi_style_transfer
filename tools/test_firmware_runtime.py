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
sys.path.insert(0, str(ROOT.parent / 'Ti60f225_soc_cam_hdmi_soc_sim/work/sim_deps'))
from unicorn import Uc, UC_ARCH_RISCV, UC_MODE_RISCV32, UC_HOOK_CODE, UC_HOOK_MEM_WRITE
from unicorn.riscv_const import UC_RISCV_REG_PC, UC_RISCV_REG_SP, UC_RISCV_REG_GP
from unicorn.riscv_const import UC_RISCV_REG_MCAUSE, UC_RISCV_REG_MEPC, UC_RISCV_REG_MTVAL
from unicorn.riscv_const import UC_RISCV_REG_MSTATUS, UC_RISCV_REG_MIE, UC_RISCV_REG_MTVEC
from unicorn.riscv_const import UC_RISCV_REG_X1
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
             'osd_write_string', 'style_submit_metrics', 'app_ddr_test', 'trap_entry']:
    assert name in SYMBOLS, name
assert ENTRY == SYMBOLS['_start'] == 0x1000
assert SYMBOLS['_sp'] == 0x20000 and SYMBOLS['_end'] < SYMBOLS['__stack_bottom']

TABLE = [(int(a, 16), int(b, 16)) for a, b in re.findall(
    r'\{0x([0-9a-f]+),0x([0-9a-f]+),[01],\d+\}',
    (ROOT / 'software/firmware/camera_init_table.h').read_text())]

def crc16(data):
    c = 0xffff
    for b in data:
        c ^= b << 8
        for _ in range(8): c = ((c << 1) ^ 0x1021) & 0xffff if c & 0x8000 else (c << 1) & 0xffff
    return c

# Style-result test frame: smooth colour field with edges, R in bits 7:0, G 15:8, B 23:16.
IMG_SLOT = 3
IMG_PIXELS = [((x * 255) // 639, (y * 255) // 479, 255 if (x // 80 + y // 80) & 1 else 40)
              for y in range(480) for x in range(640)]
IMG_SOURCE = b''.join(bytes((r, g, b, 0)) for r, g, b in IMG_PIXELS)

def check_rate(m):
    # No window may carry more than rate * t + one 20-byte burst (plus one byte of rounding).
    rate = int.from_bytes(m.uc.mem_read(SYMBOLS['qse_ble_rate'], 4), 'little')
    t = m.ble_times
    j = 0
    for i in range(len(t)):
        while t[i] - t[j] > 100000000: j += 1
        assert i - j + 1 <= rate * (t[i] - t[j]) / 100000000 + 21, (i, j, rate)
    if len(t) > 200:
        span = (t[-1] - t[0]) / 100000000
        print('  UART1 %d B in %.2f s = %.0f B/s (limit %d)' % (len(t), span, len(t) / span, rate))

def check_snapshot(m):
    import zlib
    assert m.img_end and m.img_header, (m.img_header, m.ble[-80:])
    _, w, h, size, crc, count = m.img_header.split(',')
    w, h, size, count = int(w), int(h), int(size), int(count)
    assert (w, h) == (160, 120) and count == len(m.img_packets) == (size + 127) // 128
    data = b''.join(m.img_packets[i] for i in range(count))
    assert len(data) == size and zlib.crc32(data) == int(crc, 16)
    assert data[:2] == b'\xff\xd8' and data[-2:] == b'\xff\xd9'
    assert m.img_naked and m.word('qse_imgtx_resends') >= 1 and m.word('qse_imgtx_images') == 1
    assert m.stream_writes[-2:] == [0, 16] and m.style_enabled, m.stream_writes  # paused, then resumed
    (ROOT / 'reports/simulation').mkdir(parents=True, exist_ok=True)
    (ROOT / 'reports/simulation/img_snap.jpg').write_bytes(data)
    # Board->browser byte stream, replayed by tools/ble_web/test_ble_proto.js.
    (ROOT / 'reports/simulation/img_snap_stream.bin').write_bytes(m.ble.encode('latin-1'))
    try:
        from PIL import Image
    except ImportError:
        print('NOTE PIL missing: JPEG decoded check skipped'); return
    import io, math
    img = Image.open(io.BytesIO(data)); img.load()
    assert img.size == (160, 120)
    got = img.convert('RGB').tobytes()
    ref = []
    for oy in range(120):
        for ox in range(160):
            px = [IMG_PIXELS[(oy*4+sy)*640+ox*4+sx] for sy in range(4) for sx in range(4)]
            ref += [sum(p[c] for p in px) // 16 for c in range(3)]
    def psnr(pix):
        return 10 * math.log10(255 * 255 * len(ref) / sum((a - b) ** 2 for a, b in zip(pix, ref)))
    # Reference: libjpeg via PIL, same quality and 4:2:0 subsampling.
    b = io.BytesIO(); Image.frombytes('RGB', (160, 120), bytes(ref)).save(b, 'JPEG', quality=70, subsampling=2)
    lib = psnr(Image.open(io.BytesIO(b.getvalue())).convert('RGB').tobytes())
    ours = psnr(got)
    assert ours >= lib - 0.5 and size <= len(b.getvalue()) * 1.1, (ours, lib, size, len(b.getvalue()))
    print('PASS BLE snapshot: %d B JPEG in %d packets, PSNR %.1f dB (libjpeg %.1f dB, %d B)'
          % (size, count, ours, lib, len(b.getvalue())))

class Machine:
    def __init__(self, scenario):
        self.scenario = scenario
        self.uc = Uc(UC_ARCH_RISCV, UC_MODE_RISCV32)
        self.uc.mem_map(0, 0x20000)
        self.uc.mem_map(0x01000000, 0x100000)
        self.uc.mem_map(0x05000000, 0x1000000)  # raw + style result slots
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
        self.style_regs={0:0x3154534e,8:16,0x30:0,0x88:0x80000000|(8|IMG_SLOT if scenario=='img_snap' else 0)}
        self.img_header=None;self.img_packets={};self.img_end=False;self.img_naked=False;self.stream_writes=[]
        if scenario=='img_snap':
            self.uc.mem_write(0x05000000+IMG_SLOT*0x140000+0x800000,IMG_SOURCE)
            self.ble_rx_queue=[b'SNAP,160,70,4\r\n']
        self.initial_coeff_count=6144 if scenario=='style_reload' else 0
        self.style_regs[0x30]=self.initial_coeff_count*0x10001
        self.coeff_addr=0;self.coeff_writes=[];self.style_enabled=False
        self.irq_pending=False;self.irq_claimed=False;self.irq_snapshot=None;self.irq_returns=0
        self.plic={}
        self.expected_coeff=(ROOT/'rtl/style/model/coeff.bin').read_bytes()
        fixture=(ROOT/'software/firmware/style_selftest.h').read_text()
        self.style_input=[int(x,16) for x in re.findall(r'0x([0-9a-f]{8})u',fixture.split('style_test_expected')[0])]
        self.style_output=[int(x,16) for x in re.findall(r'0x([0-9a-f]{8})u',fixture.split('style_test_expected')[1])]
        assert len(self.style_input)==len(self.style_output)==768
        self.uc.mmio_map(0xf8010000, 0x1000, self.uart_read, None, self.uart_write, None)
        self.ble = ''          # UART1 (BLE module) transmit log, kept apart from the UART0 terminal
        self.ble_rx = {'ble_echo':b'KNOB?\r\n','img_snap':b'SNAP,160,70,4\r\n',
                       'ble_ui':b'OSD\r\nVIEW,0\r\nKNOB,2\r\nRATE,800\r\nSTATE\r\n'}.get(scenario,b'')  # phone -> UART1
        self.ble_times = []    # CLINT time of every UART1 byte, for the rate limit check
        self.ui_writes = []    # VIDEO_UI_SHADOW values
        self.osd_enables = []
        self.ble_parsed = 0
        self.gpio = 0          # GPIO0 input {SW2,SW1,KEY1,KEY0}; 0 = knob at 0, keys released
        self.uc.mmio_map(0xf8011000, 0x1000, self.ble_read, None, self.ble_write, None)
        self.uc.mmio_map(0xf8015000, 0x1000, self.gpio_read, None, self.ignore_write, None)
        self.uc.mmio_map(0xf8016000, 0x1000, self.i2c_read, None, self.i2c_write, None)
        self.uc.mmio_map(0xf8b00000, 0x10000, self.clint_read, None, self.ignore_write, None)
        self.uc.mmio_map(0xf8100000, 0x1000, self.osd_read, None, self.osd_write, None)
        self.uc.mmio_map(0xf8c00000, 0x400000, self.plic_read, None, self.plic_write, None)
        self.uc.hook_add(UC_HOOK_CODE,self.interrupt_check)
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

    def ble_read(self, uc, off, size, data):
        if off == 4: return (min(len(self.ble_rx), 255) << 24) | (128 << 16)
        if off == 0 and self.ble_rx:
            b, self.ble_rx = self.ble_rx[0], self.ble_rx[1:]
            return b
        return 0

    def ble_write(self, uc, off, size, value, data):
        if off == 0:
            self.ble += chr(value & 255)
            self.ble_times.append(self.clock)
            if self.scenario == 'img_snap': self.phone()
            # Physical knob moves to position 1 after the KNOB,2 shortcut: the override must end.
            if self.scenario == 'ble_ui' and self.ble.endswith('KNOB,2\r\n'): self.gpio = 4
        else: self.config[('ble', off)] = value

    def phone(self):
        # Model browser: parse IMG header and packets, NAK the first copy of packet 2, ACK the rest.
        while True:
            buf = self.ble[self.ble_parsed:]
            if buf.startswith('\xa5\x5a'):
                if len(buf) < 5: return
                n = ord(buf[4])
                if len(buf) < n + 7: return
                raw = buf[:n+7].encode('latin-1'); self.ble_parsed += n + 7
                seq = raw[2] | raw[3] << 8
                assert crc16(raw[2:5+n]) == raw[5+n] | raw[6+n] << 8, 'packet crc'
                if seq == 2 and not self.img_naked:
                    self.img_naked = True; self.ble_rx += b'NAK,2\r\n'; continue
                self.img_packets[seq] = raw[5:5+n]
                if seq + 1 == len(self.img_packets): self.ble_rx += b'ACK,%d\r\n' % (seq + 1)
                continue
            if '\r\n' not in buf: return
            line = buf[:buf.index('\r\n')]; self.ble_parsed += len(line) + 2
            if line.startswith('IMG,END'): self.img_end = True
            elif line.startswith('IMG,ERR'): raise AssertionError(line)
            elif line.startswith('IMG,'): self.img_header = line

    def gpio_read(self, uc, off, size, data):
        return self.gpio if off == 0 else 0

    def uart_write(self, uc, off, size, value, data):
        if off != 0:
            self.config[('uart', off)] = value
            return
        self.uart += chr(value & 255)
        if self.scenario == 'id_retry' and 'retry every second\r\n' in self.uart:
            self.sensor[0x3107] = 0xcd
        if self.scenario == 'ddr_corrupt' and 'DDR scratch FAIL\r\n' in self.uart:
            uc.emu_stop()
        if self.scenario == 'style_corrupt' and 'STYLE weights/IRQ/RGB self-test FAIL' in self.uart:
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
        if 0x200<=off<0x300:return self.style_regs.get(off-0x200,0)
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
        if 0x200<=off<0x300:
            off-=0x200
            if off==0x28:self.coeff_addr=value
            elif off==0x2c:
                row=self.coeff_addr>>8;word=self.coeff_addr&31
                assert word<24 and row<256
                expect=int.from_bytes(self.expected_coeff[(row*24+word)*4:(row*24+word+1)*4],'little')
                assert value==expect
                self.coeff_writes.append((row,word));n=(len(self.coeff_writes)+self.initial_coeff_count)&65535
                self.style_regs[0x30]=n|(n<<16)
            elif off==8:self.style_regs[8]&=~(value&6)
            elif off==4:
                if value&1:
                    assert len(self.coeff_writes)==6144 and self.style_regs[0x18]==0x00180020
                    assert list(int.from_bytes(uc.mem_read(0x05000000+i*4,4),'little') for i in range(768))==self.style_input
                    raw=b''.join(v.to_bytes(4,'little') for v in self.style_output)
                    if self.scenario=='style_corrupt':raw=bytes([raw[0]^1])+raw[1:]
                    uc.mem_write(0x05800000,raw)
                    self.style_regs[8]|=2;self.irq_pending=True
                self.style_enabled=bool(value&16);self.stream_writes.append(value)
            else:self.style_regs[off]=value
            return
        if off == 0x130: self.ui_writes.append(value)
        if off == 0x04: self.osd_enables.append(value)
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

    def plic_read(self,uc,off,size,data):
        if off==0x200004:
            if self.irq_pending and not self.irq_claimed:
                self.irq_claimed=True;return 16
            return 0
        return self.plic.get(off,0)

    def plic_write(self,uc,off,size,value,data):
        if off==0x200004:
            assert value==16 and self.irq_claimed and not(self.style_regs[8]&6)
            self.irq_pending=False;self.irq_claimed=False
        else:self.plic[off]=value

    def interrupt_check(self,uc,addr,size,data):
        if self.irq_snapshot is not None and addr==self.irq_snapshot[0]:
            assert [uc.reg_read(UC_RISCV_REG_X1+i) for i in range(31)]==self.irq_snapshot[1], 'IRQ register restore'
            assert uc.reg_read(UC_RISCV_REG_MSTATUS)&8
            self.irq_snapshot=None;self.irq_returns+=1
        if self.irq_pending and not self.irq_claimed and uc.reg_read(UC_RISCV_REG_MIE)&(1<<11) and uc.reg_read(UC_RISCV_REG_MSTATUS)&8:
            assert self.plic.get(0x40)==1 and self.plic.get(0x2000,0)&(1<<16)
            self.irq_snapshot=(addr,[uc.reg_read(UC_RISCV_REG_X1+i) for i in range(31)])
            uc.reg_write(UC_RISCV_REG_MEPC,addr);uc.reg_write(UC_RISCV_REG_MCAUSE,0x8000000b)
            status=uc.reg_read(UC_RISCV_REG_MSTATUS)
            uc.reg_write(UC_RISCV_REG_MSTATUS,(status&~8)|128|0x1800)
            uc.reg_write(UC_RISCV_REG_PC,uc.reg_read(UC_RISCV_REG_MTVEC))

    def word(self, name):
        return int.from_bytes(self.uc.mem_read(SYMBOLS[name], 4), 'little')

    def run(self):
        self.uc.emu_start(ENTRY, 0x20000, count=80000000 if self.scenario == 'img_snap' else 10000000)
        assert self.main_seen
        assert self.word('firmware_trap_cause') == 0
        assert self.ready_writes[0] == 0
        assert self.ack_stalls == 0, 'stale RX_ACK stalled a checked transaction'
        if self.scenario == 'bus_recover': assert self.bus_recoveries == 1
        if self.scenario == 'img_snap':
            check_snapshot(self)
        if self.scenario in ('img_snap', 'ble_ui'):
            check_rate(self)
        if self.scenario == 'ble_ui':
            lines = self.ble.split('\r\n')
            want = ['OSD,0', 'VIEW,0', 'KNOB,2', 'RATE,800', 'KNOB,2', 'OSD,0', 'VIEW,0', 'RATE,800', 'KNOB,1']
            assert lines[:len(want)] == want, lines
            assert self.osd_enables[-1] == 0, self.osd_enables
            assert 2 << 1 in self.ui_writes, self.ui_writes          # override: view 0, knob 2
            assert self.ui_writes[-1] == 1 << 1, self.ui_writes      # physical knob 1 took over
            assert self.word('qse_ble_rate') == 800
        if self.scenario == 'ble_echo':
            assert not self.ble_rx and 'KNOB?\r\n' in self.ble, self.ble
            assert self.word('qse_ble_rx_bytes') == 7
        assert self.video_ready == (0 if self.scenario in ('ddr_corrupt', 'style_corrupt', 'no_ack') else 1)
        if self.scenario == 'ddr_corrupt':
            assert self.word('app_ddr_errors') == 1
            assert not self.camera_writes
            assert 'DDR scratch FAIL' in self.uart
        elif self.scenario=='style_corrupt':
            assert self.word('app_style_selftest_errors')==1 and not self.style_enabled
            assert self.irq_returns==1 and self.word('app_style_irqs')==1
            assert not self.camera_writes and self.word('app_style_errors')==1
        else:
            assert self.word('app_metrics_updates') == 3
            assert self.word('app_ddr_errors') == 0
            # Startup + DDR passes + CNN input/output cache operations, + one per BLE snapshot.
            assert self.invalidates == (6 if self.scenario == 'img_snap' else 5)
            assert self.style_enabled and self.irq_returns==1 and self.word('app_style_irqs')==1
            assert self.word('app_style_selftest_errors')==0
            assert self.config[('uart', 8)] == 107
            assert self.config[('i2c', 0x50)] == 500
            assert self.config[('i2c', 0x54)] == 500
            assert self.config[('ble', 8)] == 96  # UART1: 100 MHz / (128000 * 8) - 1
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
                assert self.commits[0].rstrip() == 'MONET VGA'
                assert self.word('app_osd_errors') == 0
                for text in self.commits[1:]:
                    assert 'DROP 0 MS 0 ERR 0' in text
                # app_uart_debug defaults to 0: OSD gets the metrics, UART0 stays quiet after boot.
                assert 'MONET CAP' not in self.uart and 'DDR100M' not in self.uart and '3A state' not in self.uart
                assert self.commits[-1].rstrip() == 'MONET CAP 0 NN 0 DISP 60 DROP 0 MS 0 ERR 0'
                assert all(b-a >= 99000000 for a,b in zip(self.commit_times, self.commit_times[1:]))
        print('PASS RV32 ELF:', self.scenario, 'entry, stack/gp/BSS, UART, DDR, camera, OSD/timer')
        return {'scenario': self.scenario, 'uart': self.uart,
                'committed_pages': self.commits, 'commit_ticks': self.commit_times,
                'video_ready_writes': self.ready_writes,
                'cache_operations_modeled': self.invalidates}

if __name__ == '__main__':
    results = [Machine(s).run() for s in ['normal', 'stale_ack', 'bus_recover', 'id_retry', 'no_ack', 'ddr_corrupt', 'timer_wrap','style_corrupt','style_reload','ble_echo','img_snap','ble_ui']]
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
