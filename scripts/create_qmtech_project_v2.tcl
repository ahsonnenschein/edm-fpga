# create_qmtech_project_v2.tcl
# Uses the vendor's block design as the starting point, then adds EDM IP.
# This ensures PS7/DDR/Ethernet all work exactly as in the vendor's design.
#
# Usage: vivado -mode batch -source scripts/create_qmtech_project_v2.tcl

set proj_dir /home/sonnensn/qmtech_vivado
set proj_name edm_qmtech
set rtl_dir /home/sonnensn/edm-fpga/rtl
set vendor_bd /tmp/design_1_bd_nocheck.tcl

# Clean start
file delete -force $proj_dir/$proj_name
create_project $proj_name $proj_dir/$proj_name -part xc7z010clg400-1

# Add our RTL sources first (so they're available for module reference)
add_files -norecurse [list \
    $rtl_dir/edm_top_qmtech.v \
    $rtl_dir/ad9226_capture.v \
    $rtl_dir/axi_edm_regs.v \
    $rtl_dir/edm_pulse_ctrl.v \
    $rtl_dir/waveform_capture.v \
]
update_compile_order -fileset sources_1

# ── Create block design from scratch ────────────────────────
# Don't use vendor's 2018.3 BD script — create PS7 natively in 2023.2
# with settings copied from vendor's configuration.
create_bd_design "design_1"

# PS7 with vendor's DDR/peripheral config + our modifications
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]

# Apply the vendor's complete PS7 config using preset import
# Key settings from vendor: DDR3 16-bit, 533MHz, MIO for UART/SD/USB/I2C/SPI
# EMIO for Ethernet GEM0, FCLK0 = 100MHz (our change), reset enabled
# Set ALL DDR config BEFORE apply_bd_automation
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
    CONFIG.PCW_EN_DDR {1} \
    CONFIG.PCW_DM_WIDTH {2} \
    CONFIG.PCW_DQS_WIDTH {2} \
    CONFIG.PCW_DQ_WIDTH {16} \
] $ps7

apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 -config {make_external "FIXED_IO, DDR" Master "Disable" Slave "Disable" } $ps7

# Remaining peripheral config (applied after automation)
set_property -dict [list \
    CONFIG.PCW_APU_PERIPHERAL_FREQMHZ {666.666666} \
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
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_FPGA_FCLK0_ENABLE {1} \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_EN_RST0_PORT {1} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
] $ps7

# ── MII Ethernet external ports ─────────────────────────────
create_bd_port -dir I -type clk ENET0_GMII_RX_CLK_0
create_bd_port -dir I -type clk ENET0_GMII_TX_CLK_0
create_bd_port -dir I ENET0_GMII_RX_DV_0
create_bd_port -dir O -from 0 -to 0 ENET0_GMII_TX_EN_0
create_bd_port -dir I -from 3 -to 0 ENET0_RXD
create_bd_port -dir O -from 3 -to 0 ENET0_TXD
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:mdio_rtl:1.0 MDIO_ETHERNET_0_0

# xlconcat for MII 4↔8 bit adaptation
set txd_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 txd_concat]
set_property -dict [list CONFIG.IN0_WIDTH {4} CONFIG.NUM_PORTS {1}] $txd_concat
set rxd_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 rxd_concat]
set_property -dict [list CONFIG.IN0_WIDTH {4} CONFIG.IN1_WIDTH {4} CONFIG.NUM_PORTS {2}] $rxd_concat
set const_zero_4 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_zero_4]
set_property -dict [list CONFIG.CONST_WIDTH {4} CONFIG.CONST_VAL {0}] $const_zero_4

# Ethernet connections
connect_bd_intf_net [get_bd_intf_ports MDIO_ETHERNET_0_0] [get_bd_intf_pins processing_system7_0/MDIO_ETHERNET_0]
connect_bd_net [get_bd_ports ENET0_GMII_RX_CLK_0] [get_bd_pins processing_system7_0/ENET0_GMII_RX_CLK]
connect_bd_net [get_bd_ports ENET0_GMII_TX_CLK_0] [get_bd_pins processing_system7_0/ENET0_GMII_TX_CLK]
connect_bd_net [get_bd_pins processing_system7_0/ENET0_GMII_TXD] [get_bd_pins txd_concat/In0]
connect_bd_net [get_bd_pins txd_concat/dout] [get_bd_ports ENET0_TXD]
connect_bd_net [get_bd_pins processing_system7_0/ENET0_GMII_TX_EN] [get_bd_ports ENET0_GMII_TX_EN_0]
connect_bd_net [get_bd_ports ENET0_RXD] [get_bd_pins rxd_concat/In0]
connect_bd_net [get_bd_pins const_zero_4/dout] [get_bd_pins rxd_concat/In1]
connect_bd_net [get_bd_pins rxd_concat/dout] [get_bd_pins processing_system7_0/ENET0_GMII_RXD]
connect_bd_net [get_bd_ports ENET0_GMII_RX_DV_0] [get_bd_pins processing_system7_0/ENET0_GMII_RX_DV]

# ── Add proc_sys_reset for proper reset synchronization ─────
set rst_0 [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst_0]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins rst_0/slowest_sync_clk]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_pins rst_0/ext_reset_in]

# ── Add AXI interconnect ────────────────────────────────────
set axi_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic]
set_property -dict [list CONFIG.NUM_MI {1}] $axi_ic

# Connect PS GP0 through interconnect
connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] [get_bd_intf_pins axi_ic/S00_AXI]

# Clock for interconnect + GP0
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_ic/ACLK]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_ic/S00_ACLK]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins axi_ic/M00_ACLK]
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK]

# Reset for interconnect
connect_bd_net [get_bd_pins rst_0/interconnect_aresetn] [get_bd_pins axi_ic/ARESETN]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins axi_ic/S00_ARESETN]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins axi_ic/M00_ARESETN]

# ── Add EDM IP ──────────────────────────────────────────────
create_bd_cell -type module -reference edm_top_qmtech edm_0

# Connect AXI
connect_bd_intf_net [get_bd_intf_pins axi_ic/M00_AXI] [get_bd_intf_pins edm_0/S_AXI]

# Clock and reset for EDM
connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_pins edm_0/S_AXI_ACLK]
connect_bd_net [get_bd_pins rst_0/peripheral_aresetn] [get_bd_pins edm_0/S_AXI_ARESETN]

# ── EDM external ports ──────────────────────────────────────
# AD9226 ADC
create_bd_port -dir I -from 11 -to 0 adc_a_data
create_bd_port -dir I adc_a_otr
create_bd_port -dir I -from 11 -to 0 adc_b_data
create_bd_port -dir I adc_b_otr
create_bd_port -dir O adc_clk

connect_bd_net [get_bd_ports adc_a_data] [get_bd_pins edm_0/adc_a_data]
connect_bd_net [get_bd_ports adc_a_otr] [get_bd_pins edm_0/adc_a_otr]
connect_bd_net [get_bd_ports adc_b_data] [get_bd_pins edm_0/adc_b_data]
connect_bd_net [get_bd_ports adc_b_otr] [get_bd_pins edm_0/adc_b_otr]
connect_bd_net [get_bd_pins edm_0/adc_clk] [get_bd_ports adc_clk]

# EDM I/O
create_bd_port -dir I hv_enable
create_bd_port -dir O pulse_out
create_bd_port -dir O lamp_green
create_bd_port -dir O lamp_orange
create_bd_port -dir O lamp_red

connect_bd_net [get_bd_ports hv_enable] [get_bd_pins edm_0/hv_enable]
connect_bd_net [get_bd_pins edm_0/pulse_out] [get_bd_ports pulse_out]
connect_bd_net [get_bd_pins edm_0/lamp_green] [get_bd_ports lamp_green]
connect_bd_net [get_bd_pins edm_0/lamp_orange] [get_bd_ports lamp_orange]
connect_bd_net [get_bd_pins edm_0/lamp_red] [get_bd_ports lamp_red]

# Tie off AXI-Stream tready internally (no external port needed)
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 tready_const
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells tready_const]
connect_bd_net [get_bd_pins tready_const/dout] [get_bd_pins edm_0/m_axis_tready]

# ── Address map ─────────────────────────────────────────────
assign_bd_address -target_address_space /processing_system7_0/Data [get_bd_addr_segs edm_0/S_AXI/reg0]
set_property offset 0x43C00000 [get_bd_addr_segs processing_system7_0/Data/SEG_edm_0_reg0]
set_property range 4K [get_bd_addr_segs processing_system7_0/Data/SEG_edm_0_reg0]

# ── Validate and save ───────────────────────────────────────
validate_bd_design
save_bd_design

# ── Generate wrapper ────────────────────────────────────────
set bd_file [get_files design_1.bd]
make_wrapper -files $bd_file -top
set wrapper_file [file join $proj_dir $proj_name $proj_name.gen sources_1 bd design_1 hdl design_1_wrapper.v]
if {![file exists $wrapper_file]} {
    # Try alternative path
    set wrapper_file [glob -nocomplain $proj_dir/$proj_name/$proj_name.gen/sources_1/bd/design_1/hdl/*.v]
}
add_files -norecurse $wrapper_file

# ── Constraints ─────────────────────────────────────────────
set xdc_file $proj_dir/$proj_name/$proj_name.srcs/constrs_1/new/qmtech.xdc
file mkdir [file dirname $xdc_file]
set fp [open $xdc_file w]

puts $fp "# QMTech ZYJZGW Zynq-7010 — Pin Constraints"
puts $fp ""
puts $fp "# ── MII Ethernet (IP101GA, BANK35) ────────────────────────"
puts $fp "# Port names from vendor BD wrapper (with _0 suffix)"
puts $fp "set_property -dict {PACKAGE_PIN D20 IOSTANDARD LVCMOS33} \[get_ports {ENET0_GMII_TX_EN_0\[0\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVCMOS33} \[get_ports {ENET0_TXD\[0\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN G19 IOSTANDARD LVCMOS33} \[get_ports {ENET0_TXD\[1\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN F20 IOSTANDARD LVCMOS33} \[get_ports {ENET0_TXD\[2\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS33} \[get_ports {ENET0_TXD\[3\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} \[get_ports ENET0_GMII_RX_DV_0\]"
puts $fp "set_property -dict {PACKAGE_PIN L20 IOSTANDARD LVCMOS33} \[get_ports {ENET0_RXD\[0\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN L19 IOSTANDARD LVCMOS33} \[get_ports {ENET0_RXD\[1\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN H20 IOSTANDARD LVCMOS33} \[get_ports {ENET0_RXD\[2\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN J20 IOSTANDARD LVCMOS33} \[get_ports {ENET0_RXD\[3\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS33} \[get_ports ENET0_GMII_RX_CLK_0\]"
puts $fp "set_property -dict {PACKAGE_PIN H18 IOSTANDARD LVCMOS33} \[get_ports ENET0_GMII_TX_CLK_0\]"
puts $fp "set_property -dict {PACKAGE_PIN M19 IOSTANDARD LVCMOS33} \[get_ports MDIO_ETHERNET_0_0_mdio_io\]"
puts $fp "set_property -dict {PACKAGE_PIN M20 IOSTANDARD LVCMOS33} \[get_ports MDIO_ETHERNET_0_0_mdc\]"
puts $fp ""
puts $fp "# ── AD9226 ADC on JP2 (BANK34) ────────────────────────────"
puts $fp "# ADC 2x14 connector → JP2 pins 1-30"
puts $fp "# Row 1 (odd/left):  A1 A3 A5 A7 A9 A11 ORA B1 B3 B5 B7 B9 B11 ORB"
puts $fp "# Row 2 (even/right): ACK A2 A4 A6 A8 A10 A12 BCK B2 B4 B6 B8 B10 B12"
puts $fp ""
puts $fp "# Ch A data (A1=data\[0\] .. A12=data\[11\])"
puts $fp "set_property -dict {PACKAGE_PIN P20 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[0\]}\]  ;# JP2-3  A1"
puts $fp "set_property -dict {PACKAGE_PIN R19 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[1\]}\]  ;# JP2-6  A2"
puts $fp "set_property -dict {PACKAGE_PIN T19 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[2\]}\]  ;# JP2-5  A3"
puts $fp "set_property -dict {PACKAGE_PIN T20 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[3\]}\]  ;# JP2-8  A4"
puts $fp "set_property -dict {PACKAGE_PIN U20 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[4\]}\]  ;# JP2-7  A5"
puts $fp "set_property -dict {PACKAGE_PIN V20 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[5\]}\]  ;# JP2-10 A6"
puts $fp "set_property -dict {PACKAGE_PIN W20 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[6\]}\]  ;# JP2-9  A7"
puts $fp "set_property -dict {PACKAGE_PIN N17 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[7\]}\]  ;# JP2-12 A8"
puts $fp "set_property -dict {PACKAGE_PIN P19 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[8\]}\]  ;# JP2-11 A9"
puts $fp "set_property -dict {PACKAGE_PIN R17 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[9\]}\]  ;# JP2-14 A10"
puts $fp "set_property -dict {PACKAGE_PIN R16 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[10\]}\] ;# JP2-13 A11"
puts $fp "set_property -dict {PACKAGE_PIN N18 IOSTANDARD LVCMOS33} \[get_ports {adc_a_data\[11\]}\] ;# JP2-16 A12"
puts $fp "set_property -dict {PACKAGE_PIN U17 IOSTANDARD LVCMOS33} \[get_ports adc_a_otr\]          ;# JP2-15 ORA"
puts $fp ""
puts $fp "# Ch B data (B1=data\[0\] .. B12=data\[11\])"
puts $fp "set_property -dict {PACKAGE_PIN T17 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[0\]}\]  ;# JP2-17 B1"
puts $fp "set_property -dict {PACKAGE_PIN W16 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[1\]}\]  ;# JP2-20 B2"
puts $fp "set_property -dict {PACKAGE_PIN U18 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[2\]}\]  ;# JP2-19 B3"
puts $fp "set_property -dict {PACKAGE_PIN Y16 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[3\]}\]  ;# JP2-22 B4"
puts $fp "set_property -dict {PACKAGE_PIN W18 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[4\]}\]  ;# JP2-21 B5"
puts $fp "set_property -dict {PACKAGE_PIN W15 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[5\]}\]  ;# JP2-24 B6"
puts $fp "set_property -dict {PACKAGE_PIN W19 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[6\]}\]  ;# JP2-23 B7"
puts $fp "set_property -dict {PACKAGE_PIN Y19 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[7\]}\]  ;# JP2-26 B8"
puts $fp "set_property -dict {PACKAGE_PIN V17 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[8\]}\]  ;# JP2-25 B9"
puts $fp "set_property -dict {PACKAGE_PIN V16 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[9\]}\]  ;# JP2-28 B10"
puts $fp "set_property -dict {PACKAGE_PIN Y18 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[10\]}\] ;# JP2-27 B11"
puts $fp "set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} \[get_ports {adc_b_data\[11\]}\] ;# JP2-30 B12"
puts $fp "set_property -dict {PACKAGE_PIN Y14 IOSTANDARD LVCMOS33} \[get_ports adc_b_otr\]          ;# JP2-29 ORB"
puts $fp ""
puts $fp "# ADC clock output (FPGA → both ADC CLK inputs, bridge ACK↔BCK externally)"
puts $fp "set_property -dict {PACKAGE_PIN N20 IOSTANDARD LVCMOS33} \[get_ports adc_clk\]            ;# JP2-4 ACK"
puts $fp ""
puts $fp "# ── EDM I/O on JP5 (BANK35) ──────────────────────────────"
puts $fp "set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVCMOS33} \[get_ports pulse_out\]          ;# JP5-3"
puts $fp "set_property -dict {PACKAGE_PIN L16 IOSTANDARD LVCMOS33 PULLUP true} \[get_ports hv_enable\] ;# JP5-4"
puts $fp "set_property -dict {PACKAGE_PIN L15 IOSTANDARD LVCMOS33} \[get_ports lamp_green\]         ;# JP5-5"
puts $fp "set_property -dict {PACKAGE_PIN L14 IOSTANDARD LVCMOS33} \[get_ports lamp_orange\]        ;# JP5-6"
puts $fp "set_property -dict {PACKAGE_PIN K18 IOSTANDARD LVCMOS33} \[get_ports lamp_red\]           ;# JP5-7"

close $fp
add_files -fileset constrs_1 -norecurse $xdc_file

# ── Build ───────────────────────────────────────────────────
update_compile_order -fileset sources_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

# ── Export XSA ──────────────────────────────────────────────
write_hw_platform -fixed -include_bit -force $proj_dir/edm_qmtech.xsa
puts "XSA exported to: $proj_dir/edm_qmtech.xsa"
