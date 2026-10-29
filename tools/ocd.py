#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""健壮的 OpenOCD telnet 助手（解决 mpsse_flush 卡死 + 大块读分块）"""
import os
import socket
import sys
import time


class OCD:
    def __init__(self, host='127.0.0.1', port=4444):
        self.s = socket.create_connection((host, port), timeout=15)
        self.s.settimeout(0.5)
        time.sleep(1.2)
        self._drain()

    def _drain(self, wait=0.35):
        buf = b''
        t0 = time.time()
        while time.time() - t0 < wait:
            try:
                d = self.s.recv(65536)
                if not d:
                    break
                buf += d
            except OSError:
                break
        return buf

    def cmd(self, c, wait=0.6):
        self.s.sendall((c + '\n').encode())
        time.sleep(wait)
        return self._drain().decode('ascii', 'replace').replace('\r', '')

    def read_words(self, addr, n):
        """读 n 个字，返回 list[int]"""
        out = self.cmd('mdw 0x%08X %d' % (addr, n), 0.6 + n * 0.002)
        vals = []
        for line in out.splitlines():
            if ':' in line:
                for tok in line.split(':', 1)[1].split():
                    try:
                        vals.append(int(tok, 16))
                    except ValueError:
                        pass
        return vals

    def dump(self, name, addr, nbytes, chunk=0x8000):
        """分块 dump（避免 mpsse_flush 在大块读上卡死）"""
        p = os.path.abspath(name).replace('\\', '/')
        if os.path.exists(name):
            os.remove(name)
        off = 0
        with open(name, 'wb') as fh:
            while off < nbytes:
                n = min(chunk, nbytes - off)
                tmp = p + '.part'
                if os.path.exists(tmp):
                    os.remove(tmp)
                self.cmd('dump_image {%s} 0x%08X 0x%X' % (tmp, addr + off, n),
                         2.0 + n / 8000.0)
                if not os.path.exists(tmp):
                    raise RuntimeError('chunk @0x%X 失败' % (addr + off))
                with open(tmp, 'rb') as g:
                    fh.write(g.read())
                os.remove(tmp)
                off += n
        return os.path.getsize(name)

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


if __name__ == '__main__':
    o = OCD()
    what = sys.argv[1] if len(sys.argv) > 1 else 'status'
    if what == 'status':
        print(o.cmd('adapter speed')[:80])
        print('L11 bias:', ['0x%08X' % v for v in o.read_words(0x06F037A0, 3)])
        print('M[0]    :', ['0x%08X' % v for v in o.read_words(0x06F037E0, 1)])
    elif what == 'dump':
        name, addr, n = sys.argv[2], int(sys.argv[3], 0), int(sys.argv[4], 0)
        o.cmd('halt', 1.0)
        print('  dumped %d B -> %s' % (o.dump(name, addr, n), name))
        o.cmd('resume', 0.5)
    o.close()
