@echo off
setlocal
rem ---- tool locations (edit if Vivado/Vitis are installed elsewhere)
if "%XILINX_ROOT%"=="" set XILINX_ROOT=C:\Xilinx
if "%XVER%"=="" set XVER=2021.2
set VIVADO=%XILINX_ROOT%\Vivado\%XVER%\bin\vivado.bat
set XSCT=%XILINX_ROOT%\Vitis\%XVER%\bin\xsct.bat
set ROOT=%~dp0
if not exist "%ROOT%logs" mkdir "%ROOT%logs"
rem ---- JTAG: program the PYNQ-Z2 (boot jumper on JTAG), run dvbs2_demo.elf
rem      open a serial terminal on the board's USB-UART COM port at 115200 8N1 first
cd /d "%ROOT%vitis"
call "%XSCT%" run_on_board.tcl > "%ROOT%logs\run_on_board.log" 2>&1
type "%ROOT%logs\run_on_board.log"
pause
