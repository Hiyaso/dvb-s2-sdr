@echo off
rem Builds everything: Vivado hardware (about 30-60 min) then the Vitis application.
call "%~dp01_build_hw.bat" || goto end
call "%~dp02_build_sw.bat"
:end
echo.
echo Finished. Press any key to close.
pause > nul
