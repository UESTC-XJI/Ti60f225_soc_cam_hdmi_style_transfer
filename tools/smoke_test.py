#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
smoke_test.py —— 烧录后的三行冒烟测试

为什么需要：2026-10-28 发生过「构建全绿 + 时序全正 + 面积更低，但板子起不来」——
build_check.py 的判据（阶段 PASS + slack 符号 + 面积）必要但不充分。
那次 CPU PC 停在 0、APB 全返同一值，只有上板才能发现。

三条检查：
  ① resume 后 2 秒 reg pc != 0            —— CPU 在跑
  ② CORE_ID 读回正确                        —— 两个 IP 核活着
  ③ mdw 0x1000 == ELF 首字                  —— DDR 读写正确（最关键，暴露裕量问题）

用法：python tools/smoke_test.py [--elf software/firmware/build/soc_video_app.elf]
退出码：0 全过 / 1 有失败
"""
import argparse, os, socket, struct, sys, time

VIDEO_ID = 0x4F534431   # "1DSO"
STYLE_ID = 0x3154534E   # "NST1"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--elf', default='software/firmware/build/soc_video_app.elf')
    ap.add_argument('--host', default='127.0.0.1')
    ap.add_argument('--port', type=int, default=4444)
    a = ap.parse_args()

    try:
        s = socket.create_connection((a.host, a.port), timeout=10)
    except OSError as e:
        print("✗ 连不上 OpenOCD %s:%d —— %s" % (a.host, a.port, e))
        return 1
    s.settimeout(0.8); time.sleep(1.0)
    try:
        while s.recv(65536):
            pass
    except OSError:
        pass

    def cmd(c, t=15.0):
        s.sendall((c + '\n').encode()); buf = b''; t0 = time.time()
        while time.time() - t0 < t:
            try:
                d = s.recv(65536)
                if d:
                    buf += d
                    if buf.rstrip().endswith(b'>'):
                        break
            except OSError:
                pass
            time.sleep(0.02)
        return buf.decode('ascii', 'replace').replace('\r', '').strip()

    def rd(addr):
        o = cmd('mdw 0x%08X 1' % addr)
        for line in o.splitlines():
            if ':' in line:
                return int(line.split(':')[1].strip().split()[0], 16)
        return None

    ok = True

    # ① CPU 在跑
    cmd('resume', 6); time.sleep(2); cmd('halt', 12)
    out = cmd('reg pc', 10)
    pc = 0
    for tok in out.replace('\n', ' ').split():
        if tok.startswith('0x'):
            try:
                pc = int(tok, 16); break
            except ValueError:
                pass
    print("  ① PC 跑 2 秒后 = 0x%08x : %s" % (pc, "OK" if pc != 0 else "**NG（CPU 没起来）**"))
    ok &= (pc != 0)

    # ② CORE_ID
    v = rd(0xF8100000); t = rd(0xF8100200)
    g1 = (v == VIDEO_ID); g2 = (t == STYLE_ID)
    print("  ② video CORE_ID = 0x%08x %s / style CORE_ID = 0x%08x %s"
          % (v or 0, "OK" if g1 else "**NG**", t or 0, "OK" if g2 else "**NG**"))
    ok &= g1 and g2

    # ③ DDR 读回与 ELF 首字一致
    if os.path.exists(a.elf):
        with open(a.elf, 'rb') as fh:
            hdr = fh.read(64)
        # ELF32 LE: e_phoff @28, e_phentsize @42, e_phnum @44
        phoff = struct.unpack_from('<I', hdr, 28)[0]
        phentsize = struct.unpack_from('<H', hdr, 42)[0]
        phnum = struct.unpack_from('<H', hdr, 44)[0]
        seg = None
        with open(a.elf, 'rb') as fh:
            for i in range(phnum):
                fh.seek(phoff + i * phentsize)
                ph = fh.read(phentsize)
                p_type, p_offset, p_vaddr, _, p_filesz, p_memsz = struct.unpack_from('<IIIIII', ph, 0)
                if p_type == 1 and p_filesz and 0x1000 <= p_vaddr < 0x200000:
                    seg = (p_offset, p_vaddr, p_filesz); break
        if seg:
            off, vaddr, size = seg
            with open(a.elf, 'rb') as fh:
                fh.seek(off); want = struct.unpack('<I', fh.read(4))[0]
            got = rd(vaddr)
            g3 = (got == want)
            print("  ③ DDR 0x%04x 读回 0x%08x，ELF 期望 0x%08x : %s"
                  % (vaddr, got or 0, want, "OK" if g3 else "**NG（DDR 裕量可疑）**"))
            ok &= g3
        else:
            print("  ③ 跳过：ELF 里找不到 0x1000 段")
    else:
        print("  ③ 跳过：找不到 %s" % a.elf)

    cmd('resume', 6)
    s.close()
    print()
    print("=" * 56)
    print("裁决：" + ("全过 ✓" if ok else "**有失败 —— 不要继续，先回退**"))
    print("=" * 56)
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
