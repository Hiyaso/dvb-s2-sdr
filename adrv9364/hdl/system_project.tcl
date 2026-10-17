## system_project.tcl -- ADRV9364-Z7020 + DVB-S2 modem (see system_bd.tcl).
## Built by adrv9364/build_fpga.sh (make in <adi-hdl>/projects/adrv9364z7020/dvbs2).

source ../../../scripts/adi_env.tcl
source $ad_hdl_dir/projects/scripts/adi_project_xilinx.tcl
source $ad_hdl_dir/projects/scripts/adi_board.tcl
set ADI_POST_ROUTE_SCRIPT [file normalize $ad_hdl_dir/projects/scripts/auto_timing_fix_xilinx.tcl]

adi_project_create adrv9364z7020_dvbs2 0 {} "xc7z020clg400-1"
adi_project_files adrv9364z7020_dvbs2 [list \
  "$ad_hdl_dir/library/common/ad_iobuf.v" \
  "../common/adrv9364z7020_constr.xdc" \
  "../common/adrv9364z7020_constr_lvds.xdc" \
  "dvbs2_adrv.xdc" \
  "system_top.v" ]
# the CDC constraints refer to cells of the synthesized design
set_property USED_IN_SYNTHESIS false [get_files dvbs2_adrv.xdc]

# 100 MHz at ~95 % slice use: retiming in the modem synthesis, timing-driven implementation
if {[get_runs -quiet system_dvbs2_0_synth_1] ne ""} {
  set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs system_dvbs2_0_synth_1]
}
set_property strategy Performance_ExplorePostRoutePhysOpt [get_runs impl_1]

adi_project_run adrv9364z7020_dvbs2
source $ad_hdl_dir/library/axi_ad9361/axi_ad9361_delay.tcl
