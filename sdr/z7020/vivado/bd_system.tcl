# bd_system.tcl -- block design: Zynq PS7 (100 MHz FCLK0, M_AXI_GP0) -> AXI-Lite ->
# dvbs2_loopback_top (module reference).  Called from create_project.tcl.
proc create_dvbs2_bd { board board_part } {
    set design_name system
    create_bd_design $design_name
    current_bd_design $design_name

    # ------------------------------------------------------------ Zynq PS
    set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
    if { $board_part ne "" } {
        apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
            -config {make_external "FIXED_IO, DDR" apply_board_preset "1" Master "Disable" Slave "Disable"} $ps7
    } else {
        # generic Zynq-7020: DDR3 x16 (MT41K256M16 RE-125), UART1 on MIO 48/49
        set_property -dict [list \
            CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41K256M16 RE-125} \
            CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH {16 Bit} \
            CONFIG.PCW_UART1_PERIPHERAL_ENABLE {1} \
            CONFIG.PCW_UART1_UART1_IO {MIO 48 .. 49} \
            CONFIG.PCW_PRESET_BANK1_VOLTAGE {LVCMOS 1.8V} ] $ps7
        apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
            -config {make_external "FIXED_IO, DDR" apply_board_preset "0" Master "Disable" Slave "Disable"} $ps7
    }
    set_property -dict [list \
        CONFIG.PCW_USE_M_AXI_GP0 {1} \
        CONFIG.PCW_EN_CLK0_PORT {1} \
        CONFIG.PCW_EN_RST0_PORT {1} \
        CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} ] $ps7

    # ------------------------------------------------------------ DVB-S2 loopback
    set dvb [create_bd_cell -type module -reference dvbs2_loopback_top dvbs2_0]

    # AXI-Lite from M_AXI_GP0 (creates interconnect + reset block)
    apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
        Clk_master {/ps7/FCLK_CLK0 (100 MHz)} Clk_slave {Auto} Clk_xbar {Auto} \
        Master {/ps7/M_AXI_GP0} Slave {/dvbs2_0/s_axi} ddr_seg {Auto} \
        intc_ip {New AXI Interconnect} master_apm {0}] [get_bd_intf_pins dvbs2_0/s_axi]

    # AXI-Stream ports tied off (PRBS source, decoded data discarded)
    set c0 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_zero8]
    set_property -dict [list CONFIG.CONST_WIDTH {8} CONFIG.CONST_VAL {0}] $c0
    set c1 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_zero1]
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $c1
    set c2 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_one1]
    set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $c2
    connect_bd_net [get_bd_pins const_zero8/dout] [get_bd_pins dvbs2_0/s_axis_tx_tdata]
    connect_bd_net [get_bd_pins const_zero1/dout] [get_bd_pins dvbs2_0/s_axis_tx_tvalid]
    connect_bd_net [get_bd_pins const_one1/dout]  [get_bd_pins dvbs2_0/m_axis_rx_tready]

    # LEDs
    create_bd_port -dir O -from 3 -to 0 led
    connect_bd_net [get_bd_pins dvbs2_0/led] [get_bd_ports led]

    # address map: 4 KB at 0x43C0_0000
    assign_bd_address
    set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps7/Data] -filter {NAME =~ "*dvbs2_0*"}]
    if { $seg ne "" } {
        set_property offset 0x43C00000 $seg
        set_property range 4K $seg
    }

    regenerate_bd_layout
    validate_bd_design
    save_bd_design

    # HDL wrapper as top
    set bdfile [get_files $design_name.bd]
    generate_target all $bdfile
    set wrapper [make_wrapper -files $bdfile -top]
    add_files -norecurse $wrapper
    set_property top ${design_name}_wrapper [current_fileset]
    update_compile_order -fileset sources_1
}
