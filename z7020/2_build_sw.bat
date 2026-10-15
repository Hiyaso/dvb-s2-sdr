@echo off
setlocal
rem ---- tool locations (edit if Vivado/Vitis are installed elsewhere)
if "%XILINX_ROOT%"=="" set XILINX_ROOT=C:\Xilinx
if "%XVER%"=="" set XVER=2021.2
set VIVADO=%XILINX_ROOT%\Vivado\%XVER%\bin\vivado.bat
set XSCT=%XILINX_ROOT%\Vitis\%XVER%\bin\xsct.bat
set ROOT=%~dp0
if not exist "%ROOT%logs" mkdir "%ROOT%logs"
rem ---- Vitis (xsct): platform from the XSA + standalone app dvbs2_demo.elf
echo RUNNING> "%ROOT%logs\status_sw.txt"
cd /d "%ROOT%vitis"
call "%XSCT%" build_vitis.tcl > "%ROOT%logs\vitis_build.log" 2>&1
if errorlevel 1 goto fail
if not exist "%ROOT%out\dvbs2_demo.elf" goto fail
echo DONE> "%ROOT%logs\status_sw.txt"
echo Software build finished: out\dvbs2_demo.elf  (Vitis workspace: vitis\ws)
exit /b 0
:fail
echo FAILED> "%ROOT%logs\status_sw.txt"
echo Software build FAILED - see logs\vitis_build.log
exit /b 1
