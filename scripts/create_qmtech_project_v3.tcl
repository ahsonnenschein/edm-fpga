# create_qmtech_project_v3.tcl
# QMTech ZYJZGW Zynq-7010 EDM controller with AD9226 ADC
#
# Architecture: PS7 + AXI interconnect + EDM all inside one block design.
# DDR/FIXED_IO handled by apply_bd_automation (PS-dedicated pins).
# BD wrapper is the top module — no separate Verilog top needed.
#
# Usage: vivado -mode batch -source scripts/create_qmtech_project_v3.tcl

set proj_dir /home/sonnensn/qmtech_vivado
set proj_name edm_qmtech
set rtl_dir /home/sonnensn/edm-fpga/rtl

file delete -force $proj_dir/$proj_name
create_project $proj_name $proj_dir/$proj_name -part xc7z010clg400-1

# Add EDM RTL sources
add_files -norecurse [list \
    $rtl_dir/edm_top_qmtech.v \
    $rtl_dir/ad9226_capture.v \
    $rtl_dir/axi_edm_regs.v \
    $rtl_dir/edm_pulse_ctrl.v \
    $rtl_dir/waveform_capture.v \
]
update_compile_order -fileset sources_1

# ── Block design ────────────────────────────────────────────
create_bd_design "ps7_bd"

# PS7 with DDR config set BEFORE apply_bd_automation
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
set_property -dict [list \
    CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ {33.333333} \
    CONFIG.PCW_UIPARAM_DDR_MEMORY_TYPE {DDR 3} \
    CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41K256M16 RE-125} \
    CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH {16 Bit} \
    CONFIG.PCW_UIPARAM_DDR_DRAM_WIDTH {16 Bits} \
    CONFIG.PCW_UIPARAM_DDR_DEVICE_CAPACITY {4096 MBits} \
    CONFIG.PCW_UIPARAM_DDR_SPEED_BIN {DDR3_1066F} \
    CONFIG.PCW_UIPARAM_DDR_FREQ_MHZ {533.33333} \
    CONFIG.PCW_UIPARAM_DDR_ROW_ADDR_COUNT {15} \
    CONFIG.PCW_UIPARAM_DDR_COL_ADDR_COUNT {10} \
    CONFIG.PCW_UIPARAM_DDR_CWL {6} \
    CONFIG.PCW_UIPARAM_DDR_T_RCD {7} \
    CONFIG.PCW_UIPARAM_DDR_T_RP {7} \
    CONFIG.PCW_UIPARAM_DDR_T_RC {48.75} \
    CONFIG.PCW_UIPARAM_DDR_T_RAS_MIN {35.0} \
    CONFIG.PCW_UIPARAM_DDR_T_FAW {40.0} \
    CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY0 {0.25} \
    CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY1 {0.25} \
    CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY2 {0.25} \
    CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY3 {0.25} \
    CONFIG.PCW_DM_WIDTH {2} \
    CONFIG.PCW_DQS_WIDTH {2} \
    CONFIG.PCW_DQ_WIDTH {16} \
    CONFIG.PCW_EN_DDR {1} \
    CONFIG.PCW_APU_PERIPHERAL_FREQMHZ {666.666666} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_FPGA_FCLK0_ENABLE {1} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_EN_RST0_PORT {0} \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_UART0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_UART0_UART0_IO {MIO 14 .. 15} \
    CONFIG.PCW_EN_UART0 {1} \
    CONFIG.PCW_EN_SDIO0 {1} \
    CONFIG.PCW_SD0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_SD0_SD0_IO {MIO 40 .. 45} \
    CONFIG.PCW_SD0_GRP_CD_ENABLE {1} \
    CONFIG.PCW_SD0_GRP_CD_IO {MIO 47} \
    CONFIG.PCW_EN_USB0 {1} \
    CONFIG.PCW_USB0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_USB0_USB0_IO {MIO 28 .. 39} \
    CONFIG.PCW_USB0_RESET_ENABLE {1} \
    CONFIG.PCW_USB0_RESET_IO {MIO 46} \
    CONFIG.PCW_EN_I2C1 {1} \
    CONFIG.PCW_I2C1_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_I2C1_I2C1_IO {MIO 52 .. 53} \
    CONFIG.PCW_EN_SPI0 {1} \
    CONFIG.PCW_SPI0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_SPI0_SPI0_IO {MIO 16 .. 21} \
    CONFIG.PCW_EN_SPI1 {1} \
    CONFIG.PCW_SPI1_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_SPI1_SPI1_IO {MIO 22 .. 27} \
    CONFIG.PCW_ENET0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_ENET0_ENET0_IO {EMIO} \
    CONFIG.PCW_ENET0_GRP_MDIO_ENABLE {1} \
    CONFIG.PCW_ENET0_GRP_MDIO_IO {EMIO} \
    CONFIG.PCW_ENET0_PERIPHERAL_CLKSRC {External} \
    CONFIG.PCW_ENET0_PERIPHERAL_FREQMHZ {100 Mbps} \
    CONFIG.PCW_ENET0_RESET_ENABLE {0} \
    CONFIG.PCW_EN_ENET0 {1} \
    CONFIG.PCW_EN_EMIO_ENET0 {1} \
] $ps7

# DDR/FIXED_IO — handled as PS-dedicated pins
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" Master "Disable" Slave "Disable"} $ps7

# GP0 clock
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/M_AXI_GP0_ACLK]

# ── Ethernet EMIO with MII 4↔8 bit adaptation ──────────────
# External ports are 4-bit MII; internal PS7 is 8-bit GMII
create_bd_port -dir I -type clk ENET0_GMII_RX_CLK
create_bd_port -dir I -type clk ENET0_GMII_TX_CLK
create_bd_port -dir I ENET0_GMII_RX_DV
create_bd_port -dir O ENET0_GMII_TX_EN
create_bd_port -dir I -from 3 -to 0 ENET0_RXD
create_bd_port -dir O -from 3 -to 0 ENET0_TXD
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:mdio_rtl:1.0 MDIO_ETHERNET_0

# TX: PS GMII TXD[7:0] → xlslice takes [3:0] → external 4-bit MII
set txd_slice [create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 txd_slice]
set_property -dict [list CONFIG.DIN_WIDTH {8} CONFIG.DIN_FROM {3} CONFIG.DIN_TO {0} CONFIG.DOUT_WIDTH {4}] $txd_slice
connect_bd_net [get_bd_pins ps7/ENET0_GMII_TXD] [get_bd_pins txd_slice/Din]
connect_bd_net [get_bd_pins txd_slice/Dout] [get_bd_ports ENET0_TXD]

# RX: external 4-bit MII → xlconcat pads to 8-bit → PS GMII RXD[7:0]
set rxd_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 rxd_concat]
set_property -dict [list CONFIG.IN0_WIDTH {4} CONFIG.IN1_WIDTH {4} CONFIG.NUM_PORTS {2}] $rxd_concat
set const_zero_4 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_zero_4]
set_property -dict [list CONFIG.CONST_WIDTH {4} CONFIG.CONST_VAL {0}] $const_zero_4
connect_bd_net [get_bd_ports ENET0_RXD] [get_bd_pins rxd_concat/In0]
connect_bd_net [get_bd_pins const_zero_4/dout] [get_bd_pins rxd_concat/In1]
connect_bd_net [get_bd_pins rxd_concat/dout] [get_bd_pins ps7/ENET0_GMII_RXD]

# Other Ethernet signals
connect_bd_net [get_bd_ports ENET0_GMII_RX_CLK] [get_bd_pins ps7/ENET0_GMII_RX_CLK]
connect_bd_net [get_bd_ports ENET0_GMII_TX_CLK] [get_bd_pins ps7/ENET0_GMII_TX_CLK]
connect_bd_net [get_bd_ports ENET0_GMII_RX_DV] [get_bd_pins ps7/ENET0_GMII_RX_DV]
connect_bd_net [get_bd_pins ps7/ENET0_GMII_TX_EN] [get_bd_ports ENET0_GMII_TX_EN]
connect_bd_intf_net [get_bd_intf_ports MDIO_ETHERNET_0] [get_bd_intf_pins ps7/MDIO_ETHERNET_0]

# ── AXI interconnect + EDM IP ───────────────────────────────
create_bd_cell -type module -reference edm_top_qmtech edm_0

set axi_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic]
set_property CONFIG.NUM_MI {1} $axi_ic

# AXI path: PS GP0 → interconnect → EDM (protocol conversion handled)
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins axi_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic/M00_AXI] [get_bd_intf_pins edm_0/S_AXI]

# Clocks for interconnect + EDM
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi_ic/ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi_ic/S00_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi_ic/M00_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins edm_0/S_AXI_ACLK]

# Resets — use proc_sys_reset to generate clean reset from FCLK
# This works even if FCLK_RESET0_N isn't enabled in PS7 config
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_0]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins rst_0/slowest_sync_clk]
# Tie ext_reset_in high (always run) — proc_sys_reset generates its own power-on reset
set const_1 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_rst]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] $const_1
connect_bd_net [get_bd_pins const_rst/dout] [get_bd_pins rst_0/ext_reset_in]
connect_bd_net [get_bd_pins rst_0/interconnect_aresetn] [get_bd_pins axi_ic/ARESETN]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins axi_ic/S00_ARESETN]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins axi_ic/M00_ARESETN]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins edm_0/S_AXI_ARESETN]

# ── EDM external ports ──────────────────────────────────────
create_bd_port -dir I -from 11 -to 0 adc_a_data
create_bd_port -dir I adc_a_otr
create_bd_port -dir I -from 11 -to 0 adc_b_data
create_bd_port -dir I adc_b_otr
create_bd_port -dir O adc_clk
create_bd_port -dir I hv_enable
create_bd_port -dir O pulse_out
create_bd_port -dir O lamp_green
create_bd_port -dir O lamp_orange
create_bd_port -dir O lamp_red

connect_bd_net [get_bd_ports adc_a_data] [get_bd_pins edm_0/adc_a_data]
connect_bd_net [get_bd_ports adc_a_otr] [get_bd_pins edm_0/adc_a_otr]
connect_bd_net [get_bd_ports adc_b_data] [get_bd_pins edm_0/adc_b_data]
connect_bd_net [get_bd_ports adc_b_otr] [get_bd_pins edm_0/adc_b_otr]
connect_bd_net [get_bd_pins edm_0/adc_clk] [get_bd_ports adc_clk]
connect_bd_net [get_bd_ports hv_enable] [get_bd_pins edm_0/hv_enable]
connect_bd_net [get_bd_pins edm_0/pulse_out] [get_bd_ports pulse_out]
connect_bd_net [get_bd_pins edm_0/lamp_green] [get_bd_ports lamp_green]
connect_bd_net [get_bd_pins edm_0/lamp_orange] [get_bd_ports lamp_orange]
connect_bd_net [get_bd_pins edm_0/lamp_red] [get_bd_ports lamp_red]

# Tie off AXI-Stream
set tready_c [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 tready_c]
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] $tready_c
connect_bd_net [get_bd_pins tready_c/dout] [get_bd_pins edm_0/m_axis_tready]

# Address map
assign_bd_address -target_address_space /ps7/Data [get_bd_addr_segs edm_0/S_AXI/reg0]
set_property offset 0x43C00000 [get_bd_addr_segs ps7/Data/SEG_edm_0_reg0]
set_property range 4K [get_bd_addr_segs ps7/Data/SEG_edm_0_reg0]

validate_bd_design
save_bd_design

# ── Generate wrapper (BD wrapper is the top module) ─────────
generate_target all [get_files ps7_bd.bd]
make_wrapper -files [get_files ps7_bd.bd] -top
add_files -norecurse $proj_dir/$proj_name/$proj_name.gen/sources_1/bd/ps7_bd/hdl/ps7_bd_wrapper.v
set_property top ps7_bd_wrapper [current_fileset]

# ── Constraints ─────────────────────────────────────────────
set xdc_file $proj_dir/$proj_name/$proj_name.srcs/constrs_1/new/qmtech.xdc
file mkdir [file dirname $xdc_file]
set fp [open $xdc_file w]
puts $fp "# QMTech ZYJZGW Zynq-7010 — Pin Constraints"
puts $fp ""
puts $fp "# MII Ethernet (IP101GA, BANK35)"
puts $fp "set_property -dict {PACKAGE_PIN D20 IOSTANDARD LVCMOS33} \[get_ports ENET0_GMII_TX_EN\]"
puts $fp "set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVCMOS33} \[get_ports {ENET0_TXD\[0\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN G19 IOSTANDARD LVCMOS33} \[get_ports {ENET0_TXD\[1\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN F20 IOSTANDARD LVCMOS33} \[get_ports {ENET0_TXD\[2\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS33} \[get_ports {ENET0_TXD\[3\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} \[get_ports ENET0_GMII_RX_DV\]"
puts $fp "set_property -dict {PACKAGE_PIN L20 IOSTANDARD LVCMOS33} \[get_ports {ENET0_RXD\[0\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN L19 IOSTANDARD LVCMOS33} \[get_ports {ENET0_RXD\[1\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN H20 IOSTANDARD LVCMOS33} \[get_ports {ENET0_RXD\[2\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN J20 IOSTANDARD LVCMOS33} \[get_ports {ENET0_RXD\[3\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS33} \[get_ports ENET0_GMII_RX_CLK\]"
puts $fp "set_property -dict {PACKAGE_PIN H18 IOSTANDARD LVCMOS33} \[get_ports ENET0_GMII_TX_CLK\]"
puts $fp "set_property -dict {PACKAGE_PIN M19 IOSTANDARD LVCMOS33} \[get_ports MDIO_ETHERNET_0_mdio_io\]"
puts $fp "set_property -dict {PACKAGE_PIN M20 IOSTANDARD LVCMOS33} \[get_ports MDIO_ETHERNET_0_mdc\]"
puts $fp ""
puts $fp "# AD9226 ADC (BANK34, JP2)"
puts $fp "set_property -dict {PACKAGE_PIN P20 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[0\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[1\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN T19 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[2\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN T20 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[3\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN U20 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[4\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN V20 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[5\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN W20 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[6\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[7\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN P19 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[8\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[9\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[10\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN N18 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[11\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} \[get_ports adc_a_otr\]"
puts $fp "set_property -dict {PACKAGE_PIN T17 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[0\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[1\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[2\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN Y16 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[3\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[4\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN W15 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[5\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[6\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN Y19 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[7\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[8\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[9\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[10\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[11\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN Y14 IOSTANDARD LVCMOS33} \[get_ports adc_b_otr\]"
puts $fp "set_property -dict {PACKAGE_PIN N20 IOSTANDARD LVCMOS33} \[get_ports adc_clk\]"
puts $fp ""
puts $fp "# EDM I/O (BANK35, JP5)"
puts $fp "set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVCMOS33} \[get_ports pulse_out\]"
puts $fp "set_property -dict {PACKAGE_PIN L16 IOSTANDARD LVCMOS33 PULLUP true} \[get_ports hv_enable\]"
puts $fp "set_property -dict {PACKAGE_PIN L15 IOSTANDARD LVCMOS33} \[get_ports lamp_green\]"
puts $fp "set_property -dict {PACKAGE_PIN L14 IOSTANDARD LVCMOS33} \[get_ports lamp_orange\]"
puts $fp "set_property -dict {PACKAGE_PIN K18 IOSTANDARD LVCMOS33} \[get_ports lamp_red\]"
close $fp
add_files -fileset constrs_1 -norecurse $xdc_file

# ── Build ───────────────────────────────────────────────────
update_compile_order -fileset sources_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

write_hw_platform -fixed -include_bit -force $proj_dir/edm_qmtech.xsa
puts "XSA exported to: $proj_dir/edm_qmtech.xsa"
