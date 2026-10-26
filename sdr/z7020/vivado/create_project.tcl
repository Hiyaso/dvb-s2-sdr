# create_project.tcl -- DVB-S2 loopback on Zynq-7020 (xc7z020clg400-1)
#
# Usage (from this directory):
#   vivado -mode batch -source create_project.tcl -tclargs [board]
#   board: pynq-z2 (default) | zybo-z7-20 | generic
#
# Creates ./build/dvbs2_z7020/dvbs2_z7020.xpr with the RTL, the block design
# (PS7 + AXI-Lite + dvbs2_loopback_top) and the board LED constraints.
set board "pynq-z2"
if { $argc > 0 } { set board [lindex $argv 0] }

set here    [file normalize [file dirname [info script]]]
set zroot   [file normalize "$here/.."]
set root    [file normalize "$here/../../.."]
set projdir [file normalize "$here/build"]
set projname dvbs2_z7020
set part    xc7z020clg400-1

# board files shipped with the project (PYNQ-Z2 from Xilinx/XilinxBoardStore), in addition to
# the ones installed in Vivado / the XHub store
set_param board.repoPaths [concat [list "$here/boards"] [get_param board.repoPaths]]

create_project $projname "$projdir/$projname" -part $part -force

# board part (needs the board files installed, see README)
set bp ""
switch -- $board {
    "pynq-z2"    { set bp [lindex [get_board_parts -quiet -latest_file_version "*pynq-z2*"] 0] }
    "zybo-z7-20" { set bp [lindex [get_board_parts -quiet -latest_file_version "*zybo-z7-20*"] 0] }
    default      { set bp "" }
}
if { $bp ne "" } {
    set_property board_part $bp [current_project]
    puts "INFO: using board part $bp"
} else {
    puts "WARNING: board files for '$board' not found - using bare part $part and a generic PS7 configuration."
    puts "WARNING: DDR settings of the generic configuration must be checked before running software."
}
set_property target_language Verilog [current_project]
set_property simulator_language Verilog [current_project]

# ---------------------------------------------------------------- RTL sources
set rtl_files [concat \
    [glob -nocomplain "$root/rtl/gen/*.v"] \
    [glob -nocomplain "$root/rtl/common/*.v"] \
    [glob -nocomplain "$root/rtl/tx/*.v"] \
    [glob -nocomplain "$root/rtl/rx/*.v"] \
    [glob -nocomplain "$zroot/rtl/*.v"]]
add_files -norecurse -fileset sources_1 $rtl_files
update_compile_order -fileset sources_1

# ---------------------------------------------------------------- simulation sources
add_files -norecurse -fileset sim_1 [list "$root/sim/tb/tb_sys.v" "$zroot/sim/tb_top.v"]
set_property top tb_sys [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {all} -objects [get_filesets sim_1]

# ---------------------------------------------------------------- block design
source "$here/bd_system.tcl"
create_dvbs2_bd $board $bp

# ---------------------------------------------------------------- constraints
switch -- $board {
    "pynq-z2"    { add_files -fileset constrs_1 -norecurse "$here/constraints/pynq_z2.xdc" }
    "zybo-z7-20" { add_files -fileset constrs_1 -norecurse "$here/constraints/zybo_z7_20.xdc" }
    default      { add_files -fileset constrs_1 -norecurse "$here/constraints/generic.xdc" }
}
add_files -fileset constrs_1 -norecurse "$here/constraints/timing.xdc"

# ---------------------------------------------------------------- run settings
set_property strategy Flow_PerfOptimized_high [get_runs synth_1]
# register retiming: option name differs between Vivado releases (-retiming / -global_retiming)
if { [catch { set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1] }] } {
    catch { set_property STEPS.SYNTH_DESIGN.ARGS.GLOBAL_RETIMING on [get_runs synth_1] }
}
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]

puts "INFO: project created: $projdir/$projname/$projname.xpr"
puts "INFO: build with:  vivado -mode batch -source build.tcl"
