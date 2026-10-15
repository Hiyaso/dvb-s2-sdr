# run_on_board.tcl -- program the PYNQ-Z2 over JTAG and start the bare-metal demo.
#   xsct run_on_board.tcl        (board in JTAG boot mode, USB cable connected)
# Watch the output on the board's USB-UART (115200 8N1).
set here [file normalize [file dirname [info script]]]
set root [file normalize "$here/.."]
set bit  "$root/out/dvbs2_z7020.bit"
set elf  "$root/out/dvbs2_demo.elf"
set init [lindex [glob -nocomplain "$here/ws/dvbs2_platform/hw/ps7_init.tcl" \
                                   "$here/ws/dvbs2_platform/export/dvbs2_platform/hw/ps7_init.tcl"] 0]
foreach f [list $bit $elf $init] {
    if { $f eq "" || ![file exists $f] } { error "missing file: $f (build first)" }
}
connect
puts "INFO: JTAG targets:"
puts [targets]
targets -set -nocase -filter {name =~ "APU*"}
rst -system
after 2000
targets -set -nocase -filter {name =~ "xc7z020*"}
fpga -file $bit
targets -set -nocase -filter {name =~ "APU*"}
source $init
ps7_init
ps7_post_config
targets -set -nocase -filter {name =~ "*A9*#0"}
rst -processor
dow $elf
con
puts "INFO: dvbs2_demo running - open the USB-UART at 115200 baud"
