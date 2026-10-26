# Generic board: assign the LED pins of your board here, e.g.
# set_property -dict { PACKAGE_PIN <pin> IOSTANDARD LVCMOS33 } [get_ports {led[0]}]
# Without pin constraints the LEDs are left unplaced; to build anyway:
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
