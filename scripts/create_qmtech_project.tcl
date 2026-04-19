# create_qmtech_project.tcl
# Creates a Vivado project for the QMTech ZYJZGW Zynq-7010 Starter Kit
# Uses the vendor's complete PS7 configuration verbatim for DDR/peripheral compatibility.
# Changes from vendor: FCLK0 raised to 100 MHz for EDM logic.
#
# Usage: vivado -mode batch -source scripts/create_qmtech_project.tcl

set proj_dir /home/sonnensn/qmtech_vivado
set proj_name edm_qmtech

# Clean start
file delete -force $proj_dir/$proj_name
create_project $proj_name $proj_dir/$proj_name -part xc7z010clg400-1

# Create block design
create_bd_design "edm_system"

# ── PS7 — use vendor's COMPLETE configuration ───────────────
# Extracted verbatim from QMTech reference design_1_bd.tcl
# Only change: FCLK0 frequency raised to 100 MHz
set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]
set_property -dict [list \
   CONFIG.PCW_ACT_APU_PERIPHERAL_FREQMHZ {666.666687} \
   CONFIG.PCW_ACT_CAN0_PERIPHERAL_FREQMHZ {23.8095} \
   CONFIG.PCW_ACT_CAN1_PERIPHERAL_FREQMHZ {23.8095} \
   CONFIG.PCW_ACT_CAN_PERIPHERAL_FREQMHZ {10.000000} \
   CONFIG.PCW_ACT_DCI_PERIPHERAL_FREQMHZ {10.158730} \
   CONFIG.PCW_ACT_ENET0_PERIPHERAL_FREQMHZ {25.000000} \
   CONFIG.PCW_ACT_ENET1_PERIPHERAL_FREQMHZ {10.000000} \
   CONFIG.PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ {100.000000} \
   CONFIG.PCW_ACT_FPGA1_PERIPHERAL_FREQMHZ {10.000000} \
   CONFIG.PCW_ACT_FPGA2_PERIPHERAL_FREQMHZ {10.000000} \
   CONFIG.PCW_ACT_FPGA3_PERIPHERAL_FREQMHZ {10.000000} \
   CONFIG.PCW_ACT_I2C_PERIPHERAL_FREQMHZ {50} \
   CONFIG.PCW_ACT_PCAP_PERIPHERAL_FREQMHZ {200.000000} \
   CONFIG.PCW_ACT_QSPI_PERIPHERAL_FREQMHZ {10.000000} \
   CONFIG.PCW_ACT_SDIO_PERIPHERAL_FREQMHZ {19.047621} \
   CONFIG.PCW_ACT_SMC_PERIPHERAL_FREQMHZ {10.000000} \
   CONFIG.PCW_ACT_SPI_PERIPHERAL_FREQMHZ {171.428574} \
   CONFIG.PCW_ACT_TPIU_PERIPHERAL_FREQMHZ {200.000000} \
   CONFIG.PCW_ACT_TTC0_CLK0_PERIPHERAL_FREQMHZ {111.111115} \
   CONFIG.PCW_ACT_TTC0_CLK1_PERIPHERAL_FREQMHZ {111.111115} \
   CONFIG.PCW_ACT_TTC0_CLK2_PERIPHERAL_FREQMHZ {111.111115} \
   CONFIG.PCW_ACT_TTC1_CLK0_PERIPHERAL_FREQMHZ {111.111115} \
   CONFIG.PCW_ACT_TTC1_CLK1_PERIPHERAL_FREQMHZ {111.111115} \
   CONFIG.PCW_ACT_TTC1_CLK2_PERIPHERAL_FREQMHZ {111.111115} \
   CONFIG.PCW_ACT_TTC_PERIPHERAL_FREQMHZ {50} \
   CONFIG.PCW_ACT_UART_PERIPHERAL_FREQMHZ {100.000000} \
   CONFIG.PCW_ACT_USB0_PERIPHERAL_FREQMHZ {60} \
   CONFIG.PCW_ACT_USB1_PERIPHERAL_FREQMHZ {60} \
   CONFIG.PCW_ACT_WDT_PERIPHERAL_FREQMHZ {111.111115} \
   CONFIG.PCW_APU_CLK_RATIO_ENABLE {6:2:1} \
   CONFIG.PCW_APU_PERIPHERAL_FREQMHZ {666.666666} \
   CONFIG.PCW_ARMPLL_CTRL_FBDIV {40} \
   CONFIG.PCW_CAN0_PERIPHERAL_ENABLE {0} \
   CONFIG.PCW_CAN1_PERIPHERAL_ENABLE {0} \
   CONFIG.PCW_CAN_PERIPHERAL_VALID {0} \
   CONFIG.PCW_CLK0_FREQ {100000000} \
   CONFIG.PCW_CLK1_FREQ {10000000} \
   CONFIG.PCW_CLK2_FREQ {10000000} \
   CONFIG.PCW_CLK3_FREQ {10000000} \
   CONFIG.PCW_CPU_CPU_6X4X_MAX_RANGE {667} \
   CONFIG.PCW_CPU_CPU_PLL_FREQMHZ {1333.333} \
   CONFIG.PCW_CPU_PERIPHERAL_CLKSRC {ARM PLL} \
   CONFIG.PCW_CPU_PERIPHERAL_DIVISOR0 {2} \
   CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ {33.333333} \
   CONFIG.PCW_DCI_PERIPHERAL_CLKSRC {DDR PLL} \
   CONFIG.PCW_DCI_PERIPHERAL_DIVISOR0 {15} \
   CONFIG.PCW_DCI_PERIPHERAL_DIVISOR1 {7} \
   CONFIG.PCW_DCI_PERIPHERAL_FREQMHZ {10.159} \
   CONFIG.PCW_DDRPLL_CTRL_FBDIV {32} \
   CONFIG.PCW_DDR_DDR_PLL_FREQMHZ {1066.667} \
   CONFIG.PCW_DDR_HPRLPR_QUEUE_PARTITION {HPR(0)/LPR(32)} \
   CONFIG.PCW_DDR_HPR_TO_CRITICAL_PRIORITY_LEVEL {15} \
   CONFIG.PCW_DDR_LPR_TO_CRITICAL_PRIORITY_LEVEL {2} \
   CONFIG.PCW_DDR_PERIPHERAL_CLKSRC {DDR PLL} \
   CONFIG.PCW_DDR_PERIPHERAL_DIVISOR0 {2} \
   CONFIG.PCW_DDR_PORT0_HPR_ENABLE {0} \
   CONFIG.PCW_DDR_PORT1_HPR_ENABLE {0} \
   CONFIG.PCW_DDR_PORT2_HPR_ENABLE {0} \
   CONFIG.PCW_DDR_PORT3_HPR_ENABLE {0} \
   CONFIG.PCW_DDR_RAM_BASEADDR {0x00100000} \
   CONFIG.PCW_DDR_RAM_HIGHADDR {0x1FFFFFFF} \
   CONFIG.PCW_DDR_WRITE_TO_CRITICAL_PRIORITY_LEVEL {2} \
   CONFIG.PCW_DM_WIDTH {2} \
   CONFIG.PCW_DQS_WIDTH {2} \
   CONFIG.PCW_DQ_WIDTH {16} \
   CONFIG.PCW_ENET0_ENET0_IO {EMIO} \
   CONFIG.PCW_ENET0_GRP_MDIO_ENABLE {1} \
   CONFIG.PCW_ENET0_GRP_MDIO_IO {EMIO} \
   CONFIG.PCW_ENET0_PERIPHERAL_CLKSRC {External} \
   CONFIG.PCW_ENET0_PERIPHERAL_DIVISOR0 {1} \
   CONFIG.PCW_ENET0_PERIPHERAL_DIVISOR1 {5} \
   CONFIG.PCW_ENET0_PERIPHERAL_ENABLE {1} \
   CONFIG.PCW_ENET0_PERIPHERAL_FREQMHZ {100 Mbps} \
   CONFIG.PCW_ENET0_RESET_ENABLE {0} \
   CONFIG.PCW_ENET1_PERIPHERAL_ENABLE {0} \
   CONFIG.PCW_ENET_RESET_ENABLE {1} \
   CONFIG.PCW_ENET_RESET_POLARITY {Active Low} \
   CONFIG.PCW_ENET_RESET_SELECT {Share reset pin} \
   CONFIG.PCW_EN_CLK0_PORT {1} \
   CONFIG.PCW_EN_CLK1_PORT {0} \
   CONFIG.PCW_EN_CLK2_PORT {0} \
   CONFIG.PCW_EN_CLK3_PORT {0} \
   CONFIG.PCW_EN_DDR {1} \
   CONFIG.PCW_EN_EMIO_ENET0 {1} \
   CONFIG.PCW_EN_EMIO_GPIO {1} \
   CONFIG.PCW_EN_ENET0 {1} \
   CONFIG.PCW_EN_GPIO {1} \
   CONFIG.PCW_EN_I2C1 {1} \
   CONFIG.PCW_EN_SDIO0 {1} \
   CONFIG.PCW_EN_SPI0 {1} \
   CONFIG.PCW_EN_SPI1 {1} \
   CONFIG.PCW_EN_UART0 {1} \
   CONFIG.PCW_EN_USB0 {1} \
   CONFIG.PCW_FCLK0_PERIPHERAL_CLKSRC {IO PLL} \
   CONFIG.PCW_FCLK0_PERIPHERAL_DIVISOR0 {5} \
   CONFIG.PCW_FCLK0_PERIPHERAL_DIVISOR1 {2} \
   CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100} \
   CONFIG.PCW_FPGA_FCLK0_ENABLE {1} \
   CONFIG.PCW_FPGA_FCLK1_ENABLE {0} \
   CONFIG.PCW_FPGA_FCLK2_ENABLE {0} \
   CONFIG.PCW_FPGA_FCLK3_ENABLE {0} \
   CONFIG.PCW_GPIO_EMIO_GPIO_ENABLE {1} \
   CONFIG.PCW_GPIO_EMIO_GPIO_IO {1} \
   CONFIG.PCW_GPIO_EMIO_GPIO_WIDTH {1} \
   CONFIG.PCW_GPIO_MIO_GPIO_ENABLE {1} \
   CONFIG.PCW_GPIO_MIO_GPIO_IO {MIO} \
   CONFIG.PCW_I2C1_I2C1_IO {MIO 52 .. 53} \
   CONFIG.PCW_I2C1_PERIPHERAL_ENABLE {1} \
   CONFIG.PCW_I2C_PERIPHERAL_FREQMHZ {111.111115} \
   CONFIG.PCW_I2C_RESET_ENABLE {1} \
   CONFIG.PCW_I2C_RESET_POLARITY {Active Low} \
   CONFIG.PCW_I2C_RESET_SELECT {Share reset pin} \
   CONFIG.PCW_IOPLL_CTRL_FBDIV {36} \
   CONFIG.PCW_IO_IO_PLL_FREQMHZ {1200.000} \
   CONFIG.PCW_MIO_0_DIRECTION {inout} \
   CONFIG.PCW_MIO_0_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_0_PULLUP {enabled} \
   CONFIG.PCW_MIO_0_SLEW {slow} \
   CONFIG.PCW_MIO_10_DIRECTION {inout} \
   CONFIG.PCW_MIO_10_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_10_PULLUP {enabled} \
   CONFIG.PCW_MIO_10_SLEW {slow} \
   CONFIG.PCW_MIO_11_DIRECTION {inout} \
   CONFIG.PCW_MIO_11_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_11_PULLUP {enabled} \
   CONFIG.PCW_MIO_11_SLEW {slow} \
   CONFIG.PCW_MIO_12_DIRECTION {inout} \
   CONFIG.PCW_MIO_12_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_12_PULLUP {enabled} \
   CONFIG.PCW_MIO_12_SLEW {slow} \
   CONFIG.PCW_MIO_13_DIRECTION {inout} \
   CONFIG.PCW_MIO_13_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_13_PULLUP {enabled} \
   CONFIG.PCW_MIO_13_SLEW {slow} \
   CONFIG.PCW_MIO_14_DIRECTION {in} \
   CONFIG.PCW_MIO_14_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_14_PULLUP {enabled} \
   CONFIG.PCW_MIO_14_SLEW {slow} \
   CONFIG.PCW_MIO_15_DIRECTION {out} \
   CONFIG.PCW_MIO_15_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_15_PULLUP {enabled} \
   CONFIG.PCW_MIO_15_SLEW {slow} \
   CONFIG.PCW_MIO_16_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_17_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_18_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_19_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_1_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_1_PULLUP {enabled} \
   CONFIG.PCW_MIO_1_SLEW {slow} \
   CONFIG.PCW_MIO_20_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_21_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_22_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_23_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_24_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_25_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_26_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_27_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_28_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_29_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_30_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_31_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_32_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_33_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_34_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_35_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_36_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_37_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_38_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_39_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_40_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_41_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_42_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_43_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_44_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_45_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_46_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_47_DIRECTION {in} \
   CONFIG.PCW_MIO_47_IOTYPE {LVCMOS 3.3V} \
   CONFIG.PCW_MIO_47_PULLUP {enabled} \
   CONFIG.PCW_MIO_48_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_49_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_50_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_51_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_52_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_MIO_53_IOTYPE {LVCMOS 1.8V} \
   CONFIG.PCW_SD0_GRP_CD_ENABLE {1} \
   CONFIG.PCW_SD0_GRP_CD_IO {MIO 47} \
   CONFIG.PCW_SD0_PERIPHERAL_ENABLE {1} \
   CONFIG.PCW_SD0_SD0_IO {MIO 40 .. 45} \
   CONFIG.PCW_SPI0_PERIPHERAL_ENABLE {1} \
   CONFIG.PCW_SPI0_SPI0_IO {MIO 16 .. 21} \
   CONFIG.PCW_SPI1_PERIPHERAL_ENABLE {1} \
   CONFIG.PCW_SPI1_SPI1_IO {MIO 22 .. 27} \
   CONFIG.PCW_UART0_BAUD_RATE {115200} \
   CONFIG.PCW_UART0_PERIPHERAL_ENABLE {1} \
   CONFIG.PCW_UART0_UART0_IO {MIO 14 .. 15} \
   CONFIG.PCW_UIPARAM_DDR_ADV_ENABLE {0} \
   CONFIG.PCW_UIPARAM_DDR_AL {0} \
   CONFIG.PCW_UIPARAM_DDR_BANK_ADDR_COUNT {3} \
   CONFIG.PCW_UIPARAM_DDR_BL {8} \
   CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY0 {0.25} \
   CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY1 {0.25} \
   CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY2 {0.25} \
   CONFIG.PCW_UIPARAM_DDR_BOARD_DELAY3 {0.25} \
   CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH {16 Bit} \
   CONFIG.PCW_UIPARAM_DDR_CL {7} \
   CONFIG.PCW_UIPARAM_DDR_CLOCK_STOP_EN {0} \
   CONFIG.PCW_UIPARAM_DDR_COL_ADDR_COUNT {10} \
   CONFIG.PCW_UIPARAM_DDR_CWL {6} \
   CONFIG.PCW_UIPARAM_DDR_DEVICE_CAPACITY {4096 MBits} \
   CONFIG.PCW_UIPARAM_DDR_DRAM_WIDTH {16 Bits} \
   CONFIG.PCW_UIPARAM_DDR_ECC {Disabled} \
   CONFIG.PCW_UIPARAM_DDR_ENABLE {1} \
   CONFIG.PCW_UIPARAM_DDR_FREQ_MHZ {533.33333} \
   CONFIG.PCW_UIPARAM_DDR_HIGH_TEMP {Normal (0-85)} \
   CONFIG.PCW_UIPARAM_DDR_MEMORY_TYPE {DDR 3} \
   CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41K256M16 RE-125} \
   CONFIG.PCW_UIPARAM_DDR_ROW_ADDR_COUNT {15} \
   CONFIG.PCW_UIPARAM_DDR_SPEED_BIN {DDR3_1066F} \
   CONFIG.PCW_UIPARAM_DDR_TRAIN_DATA_EYE {0} \
   CONFIG.PCW_UIPARAM_DDR_TRAIN_READ_GATE {0} \
   CONFIG.PCW_UIPARAM_DDR_TRAIN_WRITE_LEVEL {0} \
   CONFIG.PCW_UIPARAM_DDR_T_FAW {40.0} \
   CONFIG.PCW_UIPARAM_DDR_T_RAS_MIN {35.0} \
   CONFIG.PCW_UIPARAM_DDR_T_RC {48.75} \
   CONFIG.PCW_UIPARAM_DDR_T_RCD {7} \
   CONFIG.PCW_UIPARAM_DDR_T_RP {7} \
   CONFIG.PCW_UIPARAM_DDR_USE_INTERNAL_VREF {0} \
   CONFIG.PCW_USB0_PERIPHERAL_ENABLE {1} \
   CONFIG.PCW_USB0_PERIPHERAL_FREQMHZ {60} \
   CONFIG.PCW_USB0_RESET_ENABLE {1} \
   CONFIG.PCW_USB0_RESET_IO {MIO 46} \
   CONFIG.PCW_USB0_USB0_IO {MIO 28 .. 39} \
   CONFIG.PCW_USB_RESET_ENABLE {1} \
   CONFIG.PCW_USB_RESET_POLARITY {Active Low} \
   CONFIG.PCW_USB_RESET_SELECT {Share reset pin} \
   CONFIG.PCW_USE_M_AXI_GP0 {1} \
] $ps7

# ── MII Ethernet external ports ─────────────────────────────
create_bd_port -dir I -type clk ENET0_GMII_RX_CLK
create_bd_port -dir I -type clk ENET0_GMII_TX_CLK
create_bd_port -dir I ENET0_GMII_RX_DV
create_bd_port -dir O -from 0 -to 0 ENET0_GMII_TX_EN
create_bd_port -dir I -from 3 -to 0 ENET0_RXD
create_bd_port -dir O -from 3 -to 0 ENET0_TXD
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:mdio_rtl:1.0 MDIO_ETHERNET_0

# ── xlconcat for MII 4-bit ↔ 8-bit GMII adaptation ─────────
# TX: PS GMII TXD[7:0] → extract lower 4 bits → MII TXD[3:0]
set txd_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 txd_concat]
set_property -dict [list CONFIG.IN0_WIDTH {4} CONFIG.NUM_PORTS {1}] $txd_concat

# RX: MII RXD[3:0] + const 0 → pad to 8 bits → PS GMII RXD[7:0]
set rxd_concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 rxd_concat]
set_property -dict [list CONFIG.IN0_WIDTH {4} CONFIG.IN1_WIDTH {4} CONFIG.NUM_PORTS {2}] $rxd_concat

set const_zero_4 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_zero_4]
set_property -dict [list CONFIG.CONST_WIDTH {4} CONFIG.CONST_VAL {0}] $const_zero_4

# ── Connections ─────────────────────────────────────────────
create_bd_intf_port -mode Master -vlnv xilinx.com:display_processing_system7:fixedio_rtl:1.0 FIXED_IO
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 DDR
connect_bd_intf_net [get_bd_intf_ports DDR] [get_bd_intf_pins ps7/DDR]
connect_bd_intf_net [get_bd_intf_ports FIXED_IO] [get_bd_intf_pins ps7/FIXED_IO]
connect_bd_intf_net [get_bd_intf_ports MDIO_ETHERNET_0] [get_bd_intf_pins ps7/MDIO_ETHERNET_0]

# Ethernet clocks
connect_bd_net [get_bd_ports ENET0_GMII_RX_CLK] [get_bd_pins ps7/ENET0_GMII_RX_CLK]
connect_bd_net [get_bd_ports ENET0_GMII_TX_CLK] [get_bd_pins ps7/ENET0_GMII_TX_CLK]

# TX path
connect_bd_net [get_bd_pins ps7/ENET0_GMII_TXD] [get_bd_pins txd_concat/In0]
connect_bd_net [get_bd_pins txd_concat/dout] [get_bd_ports ENET0_TXD]
connect_bd_net [get_bd_pins ps7/ENET0_GMII_TX_EN] [get_bd_ports ENET0_GMII_TX_EN]

# RX path
connect_bd_net [get_bd_ports ENET0_RXD] [get_bd_pins rxd_concat/In0]
connect_bd_net [get_bd_pins const_zero_4/dout] [get_bd_pins rxd_concat/In1]
connect_bd_net [get_bd_pins rxd_concat/dout] [get_bd_pins ps7/ENET0_GMII_RXD]
connect_bd_net [get_bd_ports ENET0_GMII_RX_DV] [get_bd_pins ps7/ENET0_GMII_RX_DV]

# FCLK0 → AXI GP0 clock
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/M_AXI_GP0_ACLK]

# GPIO
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:gpio_rtl:1.0 GPIO_0
connect_bd_intf_net [get_bd_intf_ports GPIO_0] [get_bd_intf_pins ps7/GPIO_0]

# ── Add EDM RTL sources ─────────────────────────────────────
set rtl_dir /home/sonnensn/edm-fpga/rtl
add_files -norecurse [list \
    $rtl_dir/edm_top_qmtech.v \
    $rtl_dir/ad9226_capture.v \
    $rtl_dir/axi_edm_regs.v \
    $rtl_dir/edm_pulse_ctrl.v \
    $rtl_dir/waveform_capture.v \
]

# ── Add EDM IP to block design ──────────────────────────────
create_bd_cell -type module -reference edm_top_qmtech edm_0

# AXI interconnect
set axi_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic]
set_property -dict [list CONFIG.NUM_MI {1}] $axi_ic

# Connect AXI interconnect
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_pins axi_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic/M00_AXI] [get_bd_intf_pins edm_0/S_AXI]

# Clock and reset for AXI interconnect and EDM
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi_ic/ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi_ic/S00_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins axi_ic/M00_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins edm_0/S_AXI_ACLK]

connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins axi_ic/ARESETN]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins axi_ic/S00_ARESETN]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins axi_ic/M00_ARESETN]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_pins edm_0/S_AXI_ARESETN]

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

# Tie off AXI-Stream (not used)
create_bd_port -dir I m_axis_tready_port
connect_bd_net [get_bd_ports m_axis_tready_port] [get_bd_pins edm_0/m_axis_tready]

# ── Address map ─────────────────────────────────────────────
assign_bd_address -target_address_space /ps7/Data [get_bd_addr_segs edm_0/S_AXI/reg0]
set_property offset 0x43C00000 [get_bd_addr_segs ps7/Data/SEG_edm_0_reg0]
set_property range 4K [get_bd_addr_segs ps7/Data/SEG_edm_0_reg0]

# ── Validate and save ───────────────────────────────────────
validate_bd_design
save_bd_design

# ── Generate wrapper ────────────────────────────────────────
make_wrapper -files [get_files $proj_dir/$proj_name/$proj_name.srcs/sources_1/bd/edm_system/edm_system.bd] -top
add_files -norecurse $proj_dir/$proj_name/$proj_name.gen/sources_1/bd/edm_system/hdl/edm_system_wrapper.v

# ── Constraints ─────────────────────────────────────────────
set xdc_file $proj_dir/$proj_name/$proj_name.srcs/constrs_1/new/qmtech.xdc
file mkdir [file dirname $xdc_file]
set fp [open $xdc_file w]
puts $fp "# QMTech ZYJZGW Zynq-7010 — Pin Constraints"
puts $fp "# Ethernet EMIO pins are internal to block design (no XDC needed)"
puts $fp ""
puts $fp "# ── MII Ethernet (IP101GA, BANK35) ────────────────────────"
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
puts $fp "# ── AD9226 ADC on JP2 (BANK34) ────────────────────────────"
puts $fp "# ADC board 2x14 connector plugged into JP2 pins 1-28"
puts $fp "# Row 1 (odd/left): A1 A3 A5 A7 A9 A11 ORA B1 B3 B5 B7 B9 B11 ORB"
puts $fp "# Row 2 (even/right): ACK A2 A4 A6 A8 A10 A12 BCK B2 B4 B6 B8 B10 B12"
puts $fp "#"
puts $fp "# Channel A data: A1=data\[0\] .. A12=data\[11\]"
puts $fp "# ACK/BCK = clock outputs from FPGA to ADC"
puts $fp ""
puts $fp "# Ch A data (A1-A12) — interleaved across JP2 odd/even"
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
puts $fp "# Ch B data (B1-B12)"
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
puts $fp "set_property -dict {PACKAGE_PIN Y14 IOSTANDARD LVCMOS33} \[get_ports adc_b_otr\]          ;# JP2-29 ORB (first free pin after B12)"
puts $fp ""
puts $fp "# ADC clock outputs (FPGA → ADC)"
puts $fp "set_property -dict {PACKAGE_PIN N20 IOSTANDARD LVCMOS33} \[get_ports adc_clk\]            ;# JP2-4  ACK"
puts $fp "# BCK gets same clock — connect ACK and BCK pins together externally"
puts $fp "# Or route a second clock output to JP2-18 (R18) for BCK"
puts $fp ""
puts $fp "# ── EDM I/O on JP5 (BANK35) ──────────────────────────────"
puts $fp "set_property -dict {PACKAGE_PIN L17 IOSTANDARD LVCMOS33} \[get_ports pulse_out\]          ;# JP5-3"
puts $fp "set_property -dict {PACKAGE_PIN L16 IOSTANDARD LVCMOS33 PULLUP true} \[get_ports hv_enable\] ;# JP5-4"
puts $fp "set_property -dict {PACKAGE_PIN L15 IOSTANDARD LVCMOS33} \[get_ports lamp_green\]         ;# JP5-5 (was R18)"
puts $fp "set_property -dict {PACKAGE_PIN L14 IOSTANDARD LVCMOS33} \[get_ports lamp_orange\]        ;# JP5-6"
puts $fp "set_property -dict {PACKAGE_PIN K18 IOSTANDARD LVCMOS33} \[get_ports lamp_red\]           ;# JP5-7"
puts $fp ""
puts $fp "# AXI-Stream tready tie-off (active low — pull down)"
puts $fp "set_property -dict {PACKAGE_PIN D19 IOSTANDARD LVCMOS33 PULLDOWN true} \[get_ports m_axis_tready_port\]"
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
