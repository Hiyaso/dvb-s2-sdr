## dvbs2_adrv.xdc -- clock-domain crossings inside the DVB-S2 modem (dvbs2_adrv) between
## sys_cpu_clk (100 MHz) and the AD9364 interface clock (axi_ad9361 l_clk):
##   *_cdc0_reg   first synchroniser stage (gray FIFO pointers, enables, event toggles)
##   dout_cdc_reg FIFO output register, reading memory written in the other domain
##                (guarded by the synchronised pointers)

set dvbs2_cdc [get_cells -hier -filter {NAME =~ *system_i/dvbs2/* && IS_SEQUENTIAL && (NAME =~ *_cdc0_reg* || NAME =~ *dout_cdc_reg*)}]
set_max_delay -datapath_only -from [all_clocks] -to $dvbs2_cdc 8.000

## control registers (r_ctrl, r_txcfg, r_agc, r_tim, r_fs, r_fll, r_fec): written by the ARM
## only while the modem is held in reset (or to switch it on / off); 4 clocks to settle
set dvbs2_cfg {}
foreach r {r_ctrl r_txcfg r_agc r_tim r_fs r_fll r_fec} {
  set dvbs2_cfg [concat $dvbs2_cfg [get_cells -hier -filter "NAME =~ *system_i/dvbs2/inst/${r}_reg* && IS_SEQUENTIAL"]]
}
set_multicycle_path 4 -setup -from $dvbs2_cfg
set_multicycle_path 3 -hold  -from $dvbs2_cfg
