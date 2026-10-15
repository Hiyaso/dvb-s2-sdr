# build_vitis.tcl -- Vitis (classic, 2020.2 .. 2023.1) bare-metal application for the
# DVB-S2 loopback, built from the XSA exported by z7020/vivado/build.tcl.
#   xsct build_vitis.tcl
# Result: vitis/ws/dvbs2_demo/Debug/dvbs2_demo.elf  (+ platform dvbs2_platform)
set here [file normalize [file dirname [info script]]]
set root [file normalize "$here/.."]
set xsa  "$root/vivado/build/dvbs2_z7020.xsa"
set ws   "$here/ws"
if { ![file exists $xsa] } { error "XSA not found: $xsa (run the Vivado build first)" }

file delete -force $ws
file mkdir $ws
setws $ws

# platform + standalone domain on CPU0
platform create -name dvbs2_platform -hw $xsa -proc ps7_cortexa9_0 -os standalone -out $ws
platform write
platform generate
catch { puts "INFO: platform generated, domains: [domain list]" }

# application
set tmpl "Empty Application(C)"
if { [catch { app create -name dvbs2_demo -platform dvbs2_platform -domain standalone_domain -lang c -template $tmpl } err] } {
    puts "INFO: retry app create ($err)"
    app create -name dvbs2_demo -platform dvbs2_platform -lang c -template "Empty Application"
}
importsources -name dvbs2_demo -path "$root/sw/dvbs2_demo.c"
app config -name dvbs2_demo -add libraries m
app config -name dvbs2_demo build-config release
app build -name dvbs2_demo

set elf [glob -nocomplain "$ws/dvbs2_demo/Release/*.elf"]
if { $elf eq "" } { error "application build failed (no ELF)" }
file mkdir "$root/out"
file copy -force [lindex $elf 0] "$root/out/dvbs2_demo.elf"
puts "INFO: ELF -> $root/out/dvbs2_demo.elf"
