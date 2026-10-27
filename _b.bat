@echo off
call "D:\Efinity\2026.1\bin\setup.bat"
cd /d "C:\Users\36040\Downloads\Ti60F225_DemoBoard_v4\rowpipe_keys"
D:\Efinity\2026.1\bin\efx_run.bat ti60f225_cam_hdmi --prj -f compile --output_dir outflow > build.log 2>&1
