#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
style_probe.py —— rowpipe 板侧量测/调试工具（走 OpenOCD telnet，不需要重烧固件）

为什么有这个工具：
  调风格、调量化参数、调相机增益，全都可以在板子运行时直接改寄存器/内存完成。
  改固件→编译→烧录→重配 bit 要 4 分钟，而且每次重烧 ELF 都会锁存采集故障；
  而直接写 DDR / APB 只要 2~20 秒，且完全不碰采集链。

用法（先确保 OpenOCD 在跑，默认 telnet 127.0.0.1:4444）：
  python style_probe.py stats                 # 量风格帧：σ/均值/B-R/平坦率/贴轨率
  python style_probe.py stats --rows 240      # 只 dump 前 240 行（快，约 83 秒）
  python style_probe.py slots                 # 探测 6 个 slot 里哪个是活风格帧
  python style_probe.py weights <blob.bin>    # 换权重（14,448 B 写到 0x06F00000）
  python style_probe.py l11 --shift 37 --qlo 129 --qhi 127 --bias 3278,8869,14559
  python style_probe.py gains --r 400 --g 256 --b 414
  python style_probe.py raw --addr 0x06F03860 --len 1        # 读寄存器
  python style_probe.py dump --addr 0x05800000 --len 0x60000 --out x.bin

地址表（全部已实测）：
  风格帧  0x05800000 + slot*0x140000   640x480x4，每像素 {B,G,R,X}，R 在低字节，有符号补码
  权重    0x06F00000                   14,448 B = 3,612 word
  L11 bias 0x06F037A0 / A4 / A8        int32，R/G/B
  L11 Q   0x06F03860                   {qhi[21:14], qlo[13:6], shift[5:0]}
  相机增益 0xF8100040 / 44 / 48         Q8.8；写 0xF8100050=1 生效

依赖：numpy（可选，stats 用；没有也能跑其余命令）
"""

import argparse
import os
import socket
import struct
import sys
import time

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 4444

FRAME_BASE = 0x05800000
SLOT_STRIDE = 0x140000
SLOT_COUNT = 6
FRAME_W, FRAME_H = 640, 480
FRAME_BYTES = FRAME_W * FRAME_H * 4

WEIGHT_ADDR = 0x06F00000
WEIGHT_BYTES = 14448

L11_BIAS_ADDR = [0x06F037A0, 0x06F037A4, 0x06F037A8]
L11_Q_ADDR = 0x06F03860

GAIN_ADDR = [0xF8100040, 0xF8100044, 0xF8100048]   # R,G,B
GAIN_APPLY = 0xF8100050

DUMP_BYTES_PER_SEC = 7400.0     # 实测约 7.4 KB/s


class Ocd:
    """极简 OpenOCD telnet 客户端（只用 mww / mdw / dump_image / halt / resume）。"""

    def __init__(self, host=DEFAULT_HOST, port=DEFAULT_PORT, quiet=False):
        self.quiet = quiet
        self.sock = socket.create_connection((host, port), timeout=10)
        self.sock.settimeout(0.4)
        time.sleep(0.8)
        try:
            self.sock.recv(65536)
        except socket.timeout:
            pass

    def cmd(self, text, timeout=60.0):
        self.sock.sendall((text + "\n").encode())
        buf = b""
        t0 = time.time()
        while time.time() - t0 < timeout:
            try:
                d = self.sock.recv(65536)
                if d:
                    buf += d
                    if buf.rstrip().endswith(b">"):
                        break
            except socket.timeout:
                pass
            time.sleep(0.01)
        return buf.decode("ascii", "replace").replace("\r", "")

    def mww(self, addr, value):
        return self.cmd("mww 0x%08X 0x%08X" % (addr, value & 0xFFFFFFFF), timeout=10)

    def mdw(self, addr, count=1):
        out = self.cmd("mdw 0x%08X %d" % (addr, count), timeout=20)
        vals = []
        for line in out.splitlines():
            if ":" in line:
                try:
                    vals.append(int(line.split(":", 1)[1].strip().split()[0], 16))
                except (ValueError, IndexError):
                    pass
        return vals

    def dump(self, addr, nbytes, path):
        if os.path.exists(path):
            os.remove(path)
        # 分段 dump：单次过大会超时
        chunk = 0x10000
        done = 0
        with open(path, "wb") as fh:
            while done < nbytes:
                n = min(chunk, nbytes - done)
                tmp = path + ".part"
                if os.path.exists(tmp):
                    os.remove(tmp)
                self.cmd('dump_image {%s} 0x%08X 0x%X' % (tmp.replace(os.sep, "/"), addr + done, n),
                         timeout=120 + n / 1000.0)
                if not os.path.exists(tmp):
                    raise RuntimeError("dump 失败于 0x%08X +%d" % (addr, done))
                fh.write(open(tmp, "rb").read())
                os.remove(tmp)
                done += n
        return path

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def signed_byte_view(arr):
    """DDR 里是补码；“有符号”解释要手工做（numpy 的 uint8.view(int8) 在切片后不可靠）"""
    return arr.astype("int16").astype("float64") - 256.0 * (arr.astype("int16") >= 128)


def cmd_stats(ocd, rows=None, keep=None):
    import numpy as np

    nbytes = FRAME_BYTES if rows is None else min(FRAME_BYTES, rows * FRAME_W * 4)
    slot, path = _grab_live_slot(ocd, nbytes)
    if slot is None:
        print("找不到有效风格帧（6 个 slot 全是空数据）——采集是否停了？")
        return 1
    d = np.fromfile(path, dtype=np.uint8)
    n = (len(d) // (FRAME_W * 4)) * (FRAME_W * 4)
    img = d[:n].reshape(-1, FRAME_W, 4)
    q = np.stack([signed_byte_view(img[:, :, i]) for i in range(3)], axis=2)

    print("槽位 slot%d，%d 行（%.0f KB）" % (slot, img.shape[0], len(d) / 1024.0))
    print("%-4s %8s %8s %6s %6s %8s" % ("通道", "mean", "sigma", "min", "max", "q==0"))
    for i, c in enumerate("RGB"):
        ch = q[:, :, i]
        print("%-4s %+8.1f %8.1f %+6.0f %+6.0f %7.1f%%" % (c, ch.mean(), ch.std(), ch.min(), ch.max(),
                                                           (ch == 0).mean() * 100))
    flat = ((q[:, :, 0] == 0) & (q[:, :, 1] == 0) & (q[:, :, 2] == 0)).mean() * 100
    clip = ((q <= -127) | (q >= 127)).mean() * 100
    print("B-R = %+.1f    三通道同时=0 %.1f%%    贴轨 %.1f%%" % (
        q[:, :, 2].mean() - q[:, :, 0].mean(), flat, clip))
    print()
    print("判读：σ>40 正常 / 15~40 偏平 / <10 发灰；三通道同时=0 高说明末层被 ReLU（检查 qlo）")
    if keep:
        os.replace(path, keep)
        print("原始数据已保存: %s" % keep)
    else:
        os.remove(path)
    return 0


def _probe_slot(ocd, slot, nbytes_probe=0x1000):
    """返回 (是否像风格帧, 临时文件路径)。风格帧的特征：X 字节恒 0，且非零占比 50%~90%。"""
    import numpy as np
    addr = FRAME_BASE + slot * SLOT_STRIDE
    p = "_probe_slot.bin"
    try:
        ocd.dump(addr, nbytes_probe, p)
    except RuntimeError:
        return False, p
    d = np.fromfile(p, dtype=np.uint8)
    if len(d) < nbytes_probe:
        return False, p
    x_zero = (d[3::4] == 0).mean() > 0.99
    nz = (d != 0).mean()
    return (x_zero and 0.3 < nz < 0.98), p


def cmd_slots(ocd):
    print("探测 6 个 slot（步长 0x%X）：" % SLOT_STRIDE)
    for s in range(SLOT_COUNT):
        ok, p = _probe_slot(ocd, s)
        if os.path.exists(p):
            os.remove(p)
        print("  slot%d @0x%08X  %s" % (s, FRAME_BASE + s * SLOT_STRIDE,
                                        "像风格帧" if ok else "不是（源帧/未初始化）"))
    return 0


def _grab_live_slot(ocd, nbytes):
    """风格帧在 6 个 slot 之间轮转，APB 没有寄存器能报当前 slot ⇒ 只能探测。

    ⚠ **必须先 halt 再 dump**：CPU 跑着的时候 dump_image 会让 OpenOCD 连接被
      强制关闭（实测 WinError 10054），过去误以为是"OpenOCD 自己不稳定"。
    """
    ocd.cmd("halt", timeout=10)          # 先停 CPU，全程只在结尾 resume
    try:
        for s in range(SLOT_COUNT):
            ok, p = _probe_slot(ocd, s)
            if os.path.exists(p):
                os.remove(p)
            if ok:
                out = "_frame_slot%d.bin" % s
                ocd.dump(FRAME_BASE + s * SLOT_STRIDE, nbytes, out)
                return s, out
        return None, None
    finally:
        ocd.cmd("resume", timeout=5)


def cmd_weights(ocd, path):
    if not os.path.exists(path):
        print("找不到 %s" % path)
        return 1
    n = os.path.getsize(path)
    print("写权重 %s (%d B) → 0x%08X" % (os.path.basename(path), n, WEIGHT_ADDR))
    ocd.cmd("halt", timeout=10)
    out = ocd.cmd('load_image {%s} 0x%08X bin' % (path.replace(os.sep, "/"), WEIGHT_ADDR), timeout=40)
    ocd.cmd("resume", timeout=5)
    if "downloaded" in out or "bytes" in out:
        print("完成。网络下一帧即用新权重（XOR 自检只在开机跑，直写会绕过它）")
        return 0
    print("可疑：%s" % out.strip()[:200])
    return 1


def cmd_l11(ocd, shift, qlo, qhi, bias):
    print("L11 量化头 → shift=%d qlo=%d qhi=%d" % (shift, qlo, qhi))
    word = ((qhi & 0xFF) << 14) | ((qlo & 0xFF) << 6) | (shift & 0x3F)
    ocd.cmd("halt", timeout=10)
    if bias:
        vals = [int(x, 0) for x in bias.split(",")]
        if len(vals) != 3:
            print("bias 需要三个值，例如 --bias 3278,8869,14559")
            ocd.cmd("resume", timeout=5)
            return 1
        for k, v in enumerate(vals):
            ocd.mww(L11_BIAS_ADDR[k], v)
        print("  bias = %s" % vals)
    ocd.mww(L11_Q_ADDR, word)
    ocd.cmd("resume", timeout=5)
    print("  Q 头 = 0x%08X  （写的是 DDR，掉电即恢复权重文件里的值）" % word)
    return 0


def cmd_gains(ocd, r, g, b):
    ocd.cmd("halt", timeout=10)
    for addr, val in zip(GAIN_ADDR, (r, g, b)):
        ocd.mww(addr, val)
    ocd.mww(GAIN_APPLY, 1)
    ocd.cmd("resume", timeout=5)
    print("相机增益 → R %d / G %d / B %d（Q8.8）" % (r, g, b))
    return 0


def cmd_raw(ocd, addr, length):
    vals = ocd.mdw(addr, length)
    for i, v in enumerate(vals):
        print("  0x%08X : 0x%08X  (%d)" % (addr + 4 * i, v, v))
    if not vals:
        print("  读失败（OpenOCD 在跑吗？）")
        return 1
    return 0


def cmd_dump(ocd, addr, length, out):
    ocd.cmd("halt", timeout=10)
    ocd.dump(addr, length, out)
    ocd.cmd("resume", timeout=5)
    print("已 dump 0x%08X 共 %d B → %s" % (addr, length, out))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="rowpipe 板侧量测/调试工具")
    ap.add_argument("--host", default=DEFAULT_HOST)
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("stats", help="量风格帧统计")
    p.add_argument("--rows", type=int, default=None, help="只 dump 前 N 行（默认整帧 480 行）")
    p.add_argument("--keep", default=None, help="保留原始 bin 到这个路径")

    sub.add_parser("slots", help="探测活 slot")

    p = sub.add_parser("weights", help="换权重 blob")
    p.add_argument("path")

    p = sub.add_parser("l11", help="改 L11 量化头/偏置")
    p.add_argument("--shift", type=int, required=True)
    p.add_argument("--qlo", type=int, default=129)
    p.add_argument("--qhi", type=int, default=127)
    p.add_argument("--bias", default=None, help="三个 int32，逗号分隔，可省略")

    p = sub.add_parser("gains", help="改相机增益")
    p.add_argument("--r", type=int, required=True)
    p.add_argument("--g", type=int, required=True)
    p.add_argument("--b", type=int, required=True)

    p = sub.add_parser("raw", help="读寄存器")
    p.add_argument("--addr", type=lambda s: int(s, 0), required=True)
    p.add_argument("--len", type=int, default=1)

    p = sub.add_parser("dump", help="任意区间 dump")
    p.add_argument("--addr", type=lambda s: int(s, 0), required=True)
    p.add_argument("--len", type=lambda s: int(s, 0), required=True)
    p.add_argument("--out", required=True)

    args = ap.parse_args(argv)

    try:
        ocd = Ocd(args.host, args.port)
    except OSError as e:
        print("连不上 OpenOCD (%s:%d)：%s" % (args.host, args.port, e))
        print("先起一个：openocd -f software/bsp/EfxSapphireSoc/openocd/ftdi_ti.cfg "
              "-f software/bsp/EfxSapphireSoc/openocd/debug_ti.cfg")
        return 2

    try:
        if args.cmd == "stats":
            return cmd_stats(ocd, args.rows, args.keep)
        if args.cmd == "slots":
            return cmd_slots(ocd)
        if args.cmd == "weights":
            return cmd_weights(ocd, args.path)
        if args.cmd == "l11":
            return cmd_l11(ocd, args.shift, args.qlo, args.qhi, args.bias)
        if args.cmd == "gains":
            return cmd_gains(ocd, args.r, args.g, args.b)
        if args.cmd == "raw":
            return cmd_raw(ocd, args.addr, args.len)
        if args.cmd == "dump":
            return cmd_dump(ocd, args.addr, args.len, args.out)
    finally:
        ocd.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
