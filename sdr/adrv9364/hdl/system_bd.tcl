## system_bd.tcl -- ADRV9364-Z7020 SOM on a custom carrier + DVB-S2 modem.
## ADI's adrv9364z7020 reference design (hdl_2026_r1, LVDS) with
##   * the modem (dvbs2_adrv) between axi_ad9361 and ADI's DAC/ADC data path,
##     AXI-Lite slave at 0x44A00000 (0x43C00000 is reserved for MathWorks IP in the Kuiper devicetree)
##   * axi_gpreg kept (Kuiper devicetree compatibility); its IOs stay inside the FPGA
## Copied into <adi-hdl>/projects/adrv9364z7020/dvbs2/ by sdr/adrv9364/build_fpga.sh.

source ../common/adrv9364z7020_bd.tcl
source ../common/ccbob_bd.tcl
source $ad_hdl_dir/projects/scripts/adi_pd.tcl

cfg_ad9361_interface LVDS

set_property CONFIG.ADC_INIT_DELAY 30 [get_bd_cells axi_ad9361]

# area for the modem (the device is nearly full): no DC filter / IQ correction in the core
# (the AD9364 does its own RF/BB DC and quadrature tracking)
set_property CONFIG.ADC_DCFILTER_DISABLE 1 [get_bd_cells axi_ad9361]
set_property CONFIG.ADC_IQCORRECTION_DISABLE 1 [get_bd_cells axi_ad9361]
set_property CONFIG.DAC_IQCORRECTION_DISABLE 1 [get_bd_cells axi_ad9361]

# ---------------------------------------------------------------- DVB-S2 modem
add_files -norecurse [glob ./rtl/*.v]
update_compile_order -fileset sources_1
create_bd_cell -type module -reference dvbs2_adrv dvbs2

ad_connect axi_ad9361/l_clk        dvbs2/s_clk
ad_connect axi_ad9361/rst          dvbs2/s_rst
ad_connect axi_ad9361/adc_valid_i0 dvbs2/adc_valid
ad_connect axi_ad9361/adc_data_i0  dvbs2/adc_data_i
ad_connect axi_ad9361/adc_data_q0  dvbs2/adc_data_q
ad_connect axi_ad9361/dac_valid_i0 dvbs2/dac_valid

# DAC data: DMA FIFO -> modem (multiplexer) -> axi_ad9361
foreach {ch pin} {0 i 1 q} {
  set p [get_bd_pins axi_ad9361/dac_data_${pin}0]
  disconnect_bd_net [get_bd_nets -of_objects $p] $p
  ad_connect axi_ad9361_dac_fifo/dout_data_${ch} dvbs2/dma_data_${pin}
  ad_connect dvbs2/dac_data_${pin} axi_ad9361/dac_data_${pin}0
}

ad_cpu_interconnect 0x44A00000 dvbs2

# ---------------------------------------------------------------- system ID
ad_ip_parameter axi_sysid_0 CONFIG.ROM_ADDR_BITS 9
ad_ip_parameter rom_sys_0 CONFIG.PATH_TO_FILE "$mem_init_sys_file_path/mem_init_sys.txt"
ad_ip_parameter rom_sys_0 CONFIG.ROM_ADDR_BITS 9

sysid_gen_sys_init_file
