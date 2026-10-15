# sim.tcl -- behavioural simulation of the full loopback in Vivado xsim.
#   vivado -mode batch -source sim.tcl [-tclargs <testbench> <generic=value> ...]
#   e.g. -tclargs tb_sys MODCOD=13 NOISE=5033 CFO=12884902 NOK=8
# (The regression scripts in ../../sim use Verilator, which is ~50x faster.)
set here [file normalize [file dirname [info script]]]
# Windows: if NoDefaultCurrentDirectoryInExePath is set (some tools set it), cmd cannot find
# xsim's compile.bat / elaborate.bat in the run directory -> clear it for this Vivado process
catch { unset ::env(NoDefaultCurrentDirectoryInExePath) }
open_project "$here/build/dvbs2_z7020/dvbs2_z7020.xpr"
set tb tb_sys
if { $argc > 0 } { set tb [lindex $argv 0] }
set_property top $tb [get_filesets sim_1]
set gens {}
foreach g [lrange $argv 1 end] { lappend gens $g }
set_property generic $gens [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {0ns} -objects [get_filesets sim_1]
launch_simulation -simset sim_1 -mode behavioral
run all
close_sim
