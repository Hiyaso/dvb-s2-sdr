####################################################################################
## ADRV9364-Z7020 + DVB-S2 modem (ADI HDL make flow; copied into
## <adi-hdl>/projects/adrv9364z7020/dvbs2/ by sdr/adrv9364/build_fpga.sh)
####################################################################################

PROJECT_NAME := adrv9364z7020_dvbs2

M_DEPS += ../common/ccbob_bd.tcl
M_DEPS += ../common/adrv9364z7020_constr_lvds.xdc
M_DEPS += ../common/adrv9364z7020_constr.xdc
M_DEPS += ../common/adrv9364z7020_bd.tcl
M_DEPS += ../../scripts/adi_pd.tcl
M_DEPS += ../../../library/common/ad_iobuf.v
M_DEPS += ../../../library/axi_ad9361/axi_ad9361_delay.tcl
M_DEPS += dvbs2_adrv.xdc
M_DEPS += $(wildcard rtl/*.v)

LIB_DEPS += axi_ad9361
LIB_DEPS += axi_dmac
LIB_DEPS += axi_gpreg
LIB_DEPS += axi_sysid
LIB_DEPS += sysid_rom
LIB_DEPS += util_pack/util_cpack2
LIB_DEPS += util_pack/util_upack2
LIB_DEPS += util_rfifo
LIB_DEPS += util_tdd_sync
LIB_DEPS += util_wfifo
LIB_DEPS += xilinx/util_clkdiv

include ../../scripts/project-xilinx.mk
