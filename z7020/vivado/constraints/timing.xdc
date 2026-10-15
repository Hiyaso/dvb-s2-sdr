# The PL runs entirely on FCLK_CLK0 (100 MHz), constrained by the PS7 IP.
# LEDs are static indicators.
set_false_path -to [get_ports {led[*]}]
