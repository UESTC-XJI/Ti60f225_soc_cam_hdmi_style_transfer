@echo off
REM 配 bit（重建 FPGA 配置）。默认烧 _bit_frozen/ 里的冻结副本，而不是 outflow 里
REM 随时会被下次构建覆盖的最新产物。
REM
REM 为什么不再写死 FTDI URL：板子换个 USB 口，bus:device 就变（实测 3:3 -> 1:4），
REM 写死会报 "could not be matched to any connected USB targets"。现在由 Python
REM 工具每次重新发现。
cd /d "%~dp0"
python tools\flash_bit.py %*
