@echo off
setlocal
rem ---- tool locations (edit if Vivado/Vitis are installed elsewhere)
if "%XILINX_ROOT%"=="" set XILINX_ROOT=C:\Xilinx
if "%XVER%"=="" set XVER=2021.2
set VIVADO=%XILINX_ROOT%\Vivado\%XVER%\bin\vivado.bat
set XSCT=%XILINX_ROOT%\Vitis\%XVER%\bin\xsct.bat
set ROOT=%~dp0
if not exist "%ROOT%logs" mkdir "%ROOT%logs"
rem ---- Vivado: project + block design, synthesis, implementation, bitstream, XSA
echo RUNNING> "%ROOT%logs\status_hw.txt"
cd /d "%ROOT%vivado"
call "%VIVADO%" -mode batch -notrace -log "%ROOT%logs\vivado_create.log" -journal "%ROOT%logs\vivado_create.jou" -source create_project.tcl -tclargs pynq-z2
if errorlevel 1 goto fail
call "%VIVADO%" -mode batch -notrace -log "%ROOT%logs\vivado_build.log" -journal "%ROOT%logs\vivado_build.jou" -source build.tcl -tclargs 4
if errorlevel 1 goto fail
if not exist "%ROOT%out\dvbs2_z7020.xsa" goto fail
echo DONE> "%ROOT%logs\status_hw.txt"
echo Hardware build finished: out\dvbs2_z7020.bit / .hwh / .xsa
exit /b 0
:fail
echo FAILED> "%ROOT%logs\status_hw.txt"
echo Hardware build FAILED - see logs\vivado_*.log
exit /b 1
