#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
flash_bit.py —— 配 bit（重建 FPGA 配置），自动发现 FTDI URL

为什么需要它：
  1. **FTDI URL 会变**。`_flash_new.bat` 里写死了 `ftdi://0x0403:0x6011:3:3/2`，
     板子换个 USB 口就变成 `:1:4/2`，programmer 报
     "Specified FTDI URL could not be matched to any connected USB targets"。
     今天因为这条浪费了一轮。
  2. **位流文件会被覆盖**。配 bit 默认读 `outflow/ti60f225_oob.bit`，而那个文件
     每次 `_b.bat` 构建都会变。测固件期间必须用冻结副本，否则"恢复"会烧到别人
     刚构建的位流。

行为：
  1. 跑 `ftdi_program.py -l` 拿到本机实际的 URL 列表
  2. 依次尝试可用接口（优先 /2，这是本板 JTAG 用的那路）
  3. 用**冻结位流**（`_bit_frozen/ti60f225_oob.bit`）烧录；没有冻结副本时才退回 outflow

用法：
  python tools/flash_bit.py                    # 烧冻结位流（推荐）
  python tools/flash_bit.py --outflow          # 烧 outflow/ 里最新的构建
  python tools/flash_bit.py --file x.bit       # 烧指定文件
  python tools/flash_bit.py --list             # 只列出可用 FTDI URL，不烧
"""

import argparse
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EFINITY = os.environ.get("EFINITY_ROOT", r"D:\Efinity\2026.1")
PROG = os.path.join(EFINITY, r"pgm\bin\efx_pgm\ftdi_program.py")
SETUP = os.path.join(EFINITY, r"bin\setup.bat")

FROZEN = os.path.join(ROOT, "_bit_frozen", "ti60f225_oob.bit")
OUTFLOW = os.path.join(ROOT, "outflow", "ti60f225_oob.bit")


def _env():
    e = dict(os.environ)
    e["EFINITY_USER_DIR"] = r"C:/Users/36040/.efinity"
    e["EFINITY_USER_DIR_INI"] = r"C:/Users/36040/AppData/Local/Efinity/user_dir.ini"
    e["PYTHONPATH"] = os.path.join(EFINITY, "debugger", "bin") + ";" + os.path.join(EFINITY, "pgm", "bin")
    return e


def run(args, timeout=120):
    """在 cmd 里跑（需要 setup.bat 的环境），返回 (rc, 合并输出)。

    ⚠ 不要用 `cmd /c "call x.bat && python ..."` —— 引号与 && 的组合在这个环境
      下不可靠：实测 `-l` 返回空输出，误判成"没有 FTDI 目标"。
      生成临时 .bat 是唯一稳定可靠的方式。
    """
    bat = os.path.join(ROOT, "_flash_tmp.bat")
    with open(bat, "w", encoding="ascii", newline="\r\n") as fh:
        fh.write('@echo off\r\n')
        fh.write('call "%s"\r\n' % SETUP)
        fh.write('set EFINITY_USER_DIR=C:/Users/36040/.efinity\r\n')
        fh.write('set EFINITY_USER_DIR_INI=C:/Users/36040/AppData/Local/Efinity/user_dir.ini\r\n')
        fh.write('set PYTHONPATH=%s;%s\r\n' % (os.path.join(EFINITY, "debugger", "bin"),
                                                os.path.join(EFINITY, "pgm", "bin")))
        fh.write('cd /d "%s"\r\n' % ROOT)
        fh.write('python "%s" %s\r\n' % (PROG, args))
    try:
        p = subprocess.run(["cmd", "/c", bat], cwd=ROOT,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        return p.returncode, p.stdout.decode("utf-8", "replace")
    finally:
        try:
            os.remove(bat)
        except OSError:
            pass


def discover_urls():
    rc, out = run("-l")
    urls = re.findall(r"url\[\d\]:\s*(ftdi://\S+)", out)
    return urls, out


def main(argv=None):
    ap = argparse.ArgumentParser(description="配 bit，自动发现 FTDI URL")
    ap.add_argument("--file", help="要烧的 .bit")
    ap.add_argument("--outflow", action="store_true", help="烧 outflow/ 里最新的构建而不是冻结副本")
    ap.add_argument("--list", action="store_true", help="只列出可用 FTDI URL")
    ap.add_argument("--clock", default="1000000", help="JTAG 时钟（Hz），默认 1 MHz")
    args = ap.parse_args(argv)

    if not os.path.exists(PROG):
        print("找不到 ftdi_program.py：%s" % PROG)
        print("可用环境变量 EFINITY_ROOT 指向 Efinity 安装根目录")
        return 2

    urls, raw = discover_urls()
    if not urls:
        print("** 没发现可用的 FTDI 目标 **")
        print("  · 板子电源/USB 线是否插好？")
        print("  · Windows 设备管理器里有没有 VID_0403&PID_6011？")
        print("--- programmer 原始输出 ---")
        print(raw.strip()[:600])
        return 1

    print("发现 %d 个可用 URL：" % len(urls))
    for u in urls:
        print("  " + u)

    if args.list:
        return 0

    # 选文件
    if args.file:
        bit = args.file
    elif args.outflow:
        bit = OUTFLOW
    elif os.path.exists(FROZEN):
        bit = FROZEN
    else:
        bit = OUTFLOW
    bit = os.path.abspath(bit)
    if not os.path.exists(bit):
        print("找不到位流文件：%s" % bit)
        return 2
    tag = "冻结副本" if bit == os.path.abspath(FROZEN) else "outflow 最新构建"
    print("\n位流：%s  [%s]  %d B" % (bit, tag, os.path.getsize(bit)))

    # 优先 /2（本板 JTAG 走那一路），再依次试其余
    ordered = sorted(urls, key=lambda u: (0 if u.rstrip().endswith("/2") else 1, u))
    for url in ordered:
        print("\n尝试 %s ..." % url)
        rc, out = run('-m jtag -u "%s" --jtag_clock_freq %s "%s"' % (url, args.clock, bit), timeout=240)
        if "finished with JTAG programming" in out or "Programming '" in out and "ERROR" not in out:
            print("  ✅ 烧录成功")
            for line in out.strip().splitlines()[-4:]:
                print("     " + line.strip())
            return 0
        print("  ✗ 失败")
        for line in out.strip().splitlines()[-3:]:
            print("     " + line.strip())

    print("\n所有 URL 都尝试失败。")
    print("提示：板子断电重插后 USB 会重新枚举，URL 会变；本工具每次都会重新发现。")
    return 1


if __name__ == "__main__":
    sys.exit(main())
