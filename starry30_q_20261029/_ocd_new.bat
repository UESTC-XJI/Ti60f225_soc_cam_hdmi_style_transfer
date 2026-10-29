@echo off
cd /d "C:\Users\36040\Downloads\Ti60F225_DemoBoard_v4\rowpipe_keys"
"D:\Efinity\2026.1\debugger\openocd\bin\openocd.exe" -f "software/bsp/EfxSapphireSoc/openocd/ftdi_ti.cfg" -f "software/bsp/EfxSapphireSoc/openocd/debug_ti.cfg"
