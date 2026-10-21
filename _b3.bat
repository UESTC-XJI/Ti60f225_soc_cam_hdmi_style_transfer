@echo off
call "D:\Efinity\2026.1\bin\setup.bat"
cd /d "C:\Users\36040\Downloads\Ti60F225_DemoBoard_v4\Ti60f225_soc_cam_hdmi_style_transfer-feature-resource_optimize"
D:\Efinity\2026.1\bin\efx_run.bat ti60f225_cam_hdmi --prj -f compile --output_dir outflow_v3 > build_v3.log 2>&1
