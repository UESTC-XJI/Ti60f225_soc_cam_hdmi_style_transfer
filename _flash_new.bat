@echo off
call "D:\Efinity\2026.1\bin\setup.bat"
set EFINITY_USER_DIR=C:/Users/36040/.efinity
set EFINITY_USER_DIR_INI=C:/Users/36040/AppData/Local/Efinity/user_dir.ini
set PYTHONPATH=D:\Efinity\2026.1\debugger\bin;D:\Efinity\2026.1\pgm\bin
cd /d "C:\Users\36040\Downloads\Ti60F225_DemoBoard_v4\rowpipe_keys"
python "D:\Efinity\2026.1\pgm\bin\efx_pgm\ftdi_program.py" -m jtag -u "ftdi://0x0403:0x6011:3:3/2" --jtag_clock_freq 1000000 outflow/ti60f225_oob.bit
