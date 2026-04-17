# create_qmtech_project.tcl
# Creates a minimal Vivado project for the QMTech ZYJZGW Zynq-7010 Starter Kit
# Goal: PS7 + MII Ethernet via EMIO → export XSA for PetaLinux boot test
#
# Usage: vivado -mode batch -source scripts/create_qmtech_project.tcl

set proj_dir /home/sonnensn/qmtech_vivado
set proj_name edm_qmtech

# Clean start
file delete -force $proj_dir/$proj_name
create_project $proj_name $proj_dir/$proj_name -part xc7z010clg400-1

# Create block design
create_bd_design "edm_system"

# ── PS7 (from QMTech reference design) ──────────────────────
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]

set_property -dict [list \
    CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ {33.333333} \
    CONFIG.PCW_APU_PERIPHERAL_FREQMHZ {666.666666} \
    CONFIG.PCW_UIPARAM_DDR_MEMORY_TYPE {DDR 3} \
    CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41K256M16 RE-125} \
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
    CONFIG.PCW_EN_DDR {1} \
    CONFIG.PCW_UART0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_UART0_UART0_IO {MIO 14 .. 15} \
    CONFIG.PCW_EN_UART0 {1} \
    CONFIG.PCW_SDIO_PERIPHERAL_FREQMHZ {19} \
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
    CONFIG.PCW_ENET0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_ENET0_ENET0_IO {EMIO} \
    CONFIG.PCW_ENET0_GRP_MDIO_ENABLE {1} \
    CONFIG.PCW_ENET0_GRP_MDIO_IO {EMIO} \
    CONFIG.PCW_ENET0_PERIPHERAL_CLKSRC {External} \
    CONFIG.PCW_ENET0_PERIPHERAL_FREQMHZ {100 Mbps} \
    CONFIG.PCW_ENET0_RESET_ENABLE {0} \
    CONFIG.PCW_EN_ENET0 {1} \
    CONFIG.PCW_EN_EMIO_ENET0 {1} \
    CONFIG.PCW_EN_GPIO {1} \
    CONFIG.PCW_GPIO_MIO_GPIO_ENABLE {1} \
    CONFIG.PCW_GPIO_EMIO_GPIO_ENABLE {1} \
    CONFIG.PCW_GPIO_EMIO_GPIO_IO {1} \
    CONFIG.PCW_GPIO_EMIO_GPIO_WIDTH {1} \
    CONFIG.PCW_EN_SPI0 {1} \
    CONFIG.PCW_EN_SPI1 {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
    CONFIG.PCW_FPGA_FCLK0_ENABLE {1} \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
] $ps7

# ── MII Ethernet external ports ─────────────────────────────
# Clock ports
create_bd_port -dir I -type clk ENET0_GMII_RX_CLK
create_bd_port -dir I -type clk ENET0_GMII_TX_CLK

# MII data/control ports
create_bd_port -dir I ENET0_GMII_RX_DV
create_bd_port -dir O -from 0 -to 0 ENET0_GMII_TX_EN
create_bd_port -dir I -from 3 -to 0 ENET0_RXD
create_bd_port -dir O -from 3 -to 0 ENET0_TXD

# MDIO interface
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:mdio_rtl:1.0 MDIO_ETHERNET_0

# ── xlconcat for MII 4-bit ↔ 8-bit GMII adaptation ─────────
# TX: PS GMII TXD[7:0] → take lower 4 bits → ENET0_TXD[3:0]
set txd_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 txd_concat]
set_property -dict [list CONFIG.IN0_WIDTH {4} CONFIG.NUM_PORTS {1}] $txd_concat

# RX: ENET0_RXD[3:0] → pad to 8 bits → PS GMII RXD[7:0]
set rxd_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 rxd_concat]
set_property -dict [list CONFIG.IN0_WIDTH {4} CONFIG.IN1_WIDTH {4} CONFIG.NUM_PORTS {2}] $rxd_concat

# Constant 0 for upper 4 bits of RXD
set const_zero_4 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_zero_4]
set_property -dict [list CONFIG.CONST_WIDTH {4} CONFIG.CONST_VAL {0}] $const_zero_4

# ── Connections ─────────────────────────────────────────────
# DDR and Fixed IO
create_bd_intf_port -mode Master -vlnv xilinx.com:display_processing_system7:fixedio_rtl:1.0 FIXED_IO
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 DDR
connect_bd_intf_net [get_bd_intf_ports DDR] [get_bd_intf_pins ps7/DDR]
connect_bd_intf_net [get_bd_intf_ports FIXED_IO] [get_bd_intf_pins ps7/FIXED_IO]

# MDIO
connect_bd_intf_net [get_bd_intf_ports MDIO_ETHERNET_0] [get_bd_intf_pins ps7/MDIO_ETHERNET_0]

# Ethernet clocks
connect_bd_net [get_bd_ports ENET0_GMII_RX_CLK] [get_bd_pins ps7/ENET0_GMII_RX_CLK]
connect_bd_net [get_bd_ports ENET0_GMII_TX_CLK] [get_bd_pins ps7/ENET0_GMII_TX_CLK]

# TX path: PS TXD[7:0] → xlconcat extracts [3:0] → external port
connect_bd_net [get_bd_pins ps7/ENET0_GMII_TXD] [get_bd_pins txd_concat/In0]
connect_bd_net [get_bd_pins txd_concat/dout] [get_bd_ports ENET0_TXD]
connect_bd_net [get_bd_pins ps7/ENET0_GMII_TX_EN] [get_bd_ports ENET0_GMII_TX_EN]

# RX path: external RXD[3:0] + const 0 → xlconcat → PS RXD[7:0]
connect_bd_net [get_bd_ports ENET0_RXD] [get_bd_pins rxd_concat/In0]
connect_bd_net [get_bd_pins const_zero_4/dout] [get_bd_pins rxd_concat/In1]
connect_bd_net [get_bd_pins rxd_concat/dout] [get_bd_pins ps7/ENET0_GMII_RXD]
connect_bd_net [get_bd_ports ENET0_GMII_RX_DV] [get_bd_pins ps7/ENET0_GMII_RX_DV]

# FCLK0 → AXI GP0 clock
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/M_AXI_GP0_ACLK]

# ── GPIO (directly from PS7) ────────────────────────────────
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:gpio_rtl:1.0 GPIO_0
connect_bd_intf_net [get_bd_intf_ports GPIO_0] [get_bd_intf_pins ps7/GPIO_0]

# ── Validate and save ───────────────────────────────────────
validate_bd_design
save_bd_design

# ── Generate wrapper ────────────────────────────────────────
make_wrapper -files [get_files $proj_dir/$proj_name/$proj_name.srcs/sources_1/bd/edm_system/edm_system.bd] -top
add_files -norecurse $proj_dir/$proj_name/$proj_name.gen/sources_1/bd/edm_system/hdl/edm_system_wrapper.v

# ── Constraints for MII Ethernet ────────────────────────────
set xdc_file $proj_dir/$proj_name/$proj_name.srcs/constrs_1/new/qmtech.xdc
file mkdir [file dirname $xdc_file]
set fp [open $xdc_file w]
puts $fp "# QMTech ZYJZGW Zynq-7010 — MII Ethernet (IP101GA)"
puts $fp "set_property -dict {PACKAGE_PIN D20 IOSTANDARD LVCMOS33} \[get_ports {ENET0_GMII_TX_EN\[0\]}\]"
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
puts $fp "# PL LED (BANK35 D19)"
puts $fp "set_property -dict {PACKAGE_PIN D19 IOSTANDARD LVCMOS33} \[get_ports {GPIO_0_tri_io\[0\]}\]"
close $fp
add_files -fileset constrs_1 -norecurse $xdc_file

# ── Synthesize, implement, generate bitstream ───────────────
update_compile_order -fileset sources_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

# ── Export XSA for PetaLinux ────────────────────────────────
write_hw_platform -fixed -include_bit -force $proj_dir/edm_qmtech.xsa
puts "XSA exported to: $proj_dir/edm_qmtech.xsa"
