# build.tcl -- synthesis, implementation, bitstream, reports and XSA export.
#   vivado -mode batch -source build.tcl [-tclargs <jobs>]
set jobs 4
if { $argc > 0 } { set jobs [lindex $argv 0] }
set here [file normalize [file dirname [info script]]]
open_project "$here/build/dvbs2_z7020/dvbs2_z7020.xpr"

reset_run synth_1
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if { [get_property PROGRESS [get_runs synth_1]] ne "100%" } { error "synthesis failed" }

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if { [get_property PROGRESS [get_runs impl_1]] ne "100%" } { error "implementation failed" }

open_run impl_1
set out "$here/build/reports"
file mkdir $out
report_utilization -hierarchical -hierarchical_depth 4 -file "$out/utilization_hier.rpt"
report_utilization -file "$out/utilization.rpt"
report_timing_summary -max_paths 20 -file "$out/timing_summary.rpt"
report_power -file "$out/power.rpt"

write_hw_platform -fixed -include_bit -force -file "$here/build/dvbs2_z7020.xsa"
set bit [glob -nocomplain "$here/build/dvbs2_z7020/dvbs2_z7020.runs/impl_1/*.bit"]
if { $bit ne "" } { file copy -force [lindex $bit 0] "$here/build/dvbs2_z7020.bit" }
# PYNQ overlay needs the .hwh next to the .bit
set hwh [glob -nocomplain "$here/build/dvbs2_z7020/dvbs2_z7020.gen/sources_1/bd/system/hw_handoff/*.hwh"]
if { $hwh ne "" } { file copy -force [lindex $hwh 0] "$here/build/dvbs2_z7020.hwh" }

# collected outputs: out/ (Vitis, JTAG) and out/pynq/ (PYNQ overlay: .bit + .hwh + driver)
set od [file normalize "$here/../out"]
file mkdir "$od/pynq"
foreach f [list dvbs2_z7020.bit dvbs2_z7020.hwh dvbs2_z7020.xsa] {
    if { [file exists "$here/build/$f"] } { file copy -force "$here/build/$f" "$od/$f" }
}
foreach f [list dvbs2_z7020.bit dvbs2_z7020.hwh] {
    if { [file exists "$here/build/$f"] } { file copy -force "$here/build/$f" "$od/pynq/$f" }
}
file copy -force "$here/../sw/dvbs2_pynq.py" "$od/pynq/dvbs2_pynq.py"

set wns [get_property STATS.WNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
puts "INFO: build finished, WNS = $wns ns, WHS = $whs ns"
if { $wns < 0 || $whs < 0 } {
    puts "CRITICAL WARNING: timing NOT met -- see build/reports/timing_summary.rpt"
}
puts "INFO: outputs: build/dvbs2_z7020.bit, build/dvbs2_z7020.hwh, build/dvbs2_z7020.xsa, build/reports/"
