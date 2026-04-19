# create_qmtech_project_v3.tcl
# Two-phase approach:
# Phase 1: Create a block design with ONLY PS7 (no PL ports) → generates correct DDR/FIXED_IO
# Phase 2: Add EDM logic as RTL top-level that wraps the PS7 BD + our modules
#
# Usage: vivado -mode batch -source scripts/create_qmtech_project_v3.tcl

set proj_dir /home/sonnensn/qmtech_vivado
set proj_name edm_qmtech
set rtl_dir /home/sonnensn/edm-fpga/rtl

file delete -force $proj_dir/$proj_name
create_project $proj_name $proj_dir/$proj_name -part xc7z010clg400-1

# ── Phase 1: PS7-only block design ─────────────────────────
create_bd_design "ps7_bd"

set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7]

# Set DDR config BEFORE automation
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
    CONFIG.PCW_EN_RST0_PORT {1} \
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

apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" Master "Disable" Slave "Disable"} $ps7

# Make ALL PS7 ports external so our Verilog top can connect to them
# FCLK and reset
create_bd_port -dir O FCLK_CLK0
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_ports FCLK_CLK0]
create_bd_port -dir O FCLK_RESET0_N
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N] [get_bd_ports FCLK_RESET0_N]

# GP0 AXI clock
connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins ps7/M_AXI_GP0_ACLK]

# Ethernet EMIO — make external
create_bd_port -dir I -type clk ENET0_GMII_RX_CLK
create_bd_port -dir I -type clk ENET0_GMII_TX_CLK
create_bd_port -dir I ENET0_GMII_RX_DV
create_bd_port -dir O ENET0_GMII_TX_EN
create_bd_port -dir I -from 7 -to 0 ENET0_GMII_RXD
create_bd_port -dir O -from 7 -to 0 ENET0_GMII_TXD
connect_bd_net [get_bd_ports ENET0_GMII_RX_CLK] [get_bd_pins ps7/ENET0_GMII_RX_CLK]
connect_bd_net [get_bd_ports ENET0_GMII_TX_CLK] [get_bd_pins ps7/ENET0_GMII_TX_CLK]
connect_bd_net [get_bd_ports ENET0_GMII_RX_DV] [get_bd_pins ps7/ENET0_GMII_RX_DV]
connect_bd_net [get_bd_pins ps7/ENET0_GMII_TX_EN] [get_bd_ports ENET0_GMII_TX_EN]
connect_bd_net [get_bd_ports ENET0_GMII_RXD] [get_bd_pins ps7/ENET0_GMII_RXD]
connect_bd_net [get_bd_pins ps7/ENET0_GMII_TXD] [get_bd_ports ENET0_GMII_TXD]

# MDIO
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:mdio_rtl:1.0 MDIO_ETHERNET_0
connect_bd_intf_net [get_bd_intf_ports MDIO_ETHERNET_0] [get_bd_intf_pins ps7/MDIO_ETHERNET_0]

# AXI GP0 — make external as interface
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_GP0
set_property CONFIG.PROTOCOL AXI3 [get_bd_intf_ports M_AXI_GP0]
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] [get_bd_intf_ports M_AXI_GP0]

validate_bd_design
save_bd_design

# Generate output products and wrapper
generate_target all [get_files ps7_bd.bd]
make_wrapper -files [get_files ps7_bd.bd] -top
add_files -norecurse $proj_dir/$proj_name/$proj_name.gen/sources_1/bd/ps7_bd/hdl/ps7_bd_wrapper.v

# ── Phase 2: Create Verilog top level ──────────────────────
# The PS7 BD wrapper handles DDR/FIXED_IO internally.
# Our top level instantiates it + EDM + Ethernet glue.

# Add RTL sources
add_files -norecurse [list \
    $rtl_dir/edm_top_qmtech.v \
    $rtl_dir/ad9226_capture.v \
    $rtl_dir/axi_edm_regs.v \
    $rtl_dir/edm_pulse_ctrl.v \
    $rtl_dir/waveform_capture.v \
]

# Create the top-level wrapper in TCL (writes Verilog file)
set top_file $proj_dir/$proj_name/top.v
set fp [open $top_file w]
puts $fp {`timescale 1ns/1ps
module top (
    inout  wire [14:0] DDR_addr,
    inout  wire [2:0]  DDR_ba,
    inout  wire        DDR_cas_n,
    inout  wire        DDR_ck_n,
    inout  wire        DDR_ck_p,
    inout  wire        DDR_cke,
    inout  wire        DDR_cs_n,
    inout  wire [1:0]  DDR_dm,
    inout  wire [15:0] DDR_dq,
    inout  wire [1:0]  DDR_dqs_n,
    inout  wire [1:0]  DDR_dqs_p,
    inout  wire        DDR_odt,
    inout  wire        DDR_ras_n,
    inout  wire        DDR_reset_n,
    inout  wire        DDR_we_n,
    inout  wire        FIXED_IO_ddr_vrn,
    inout  wire        FIXED_IO_ddr_vrp,
    inout  wire [53:0] FIXED_IO_mio,
    inout  wire        FIXED_IO_ps_clk,
    inout  wire        FIXED_IO_ps_porb,
    inout  wire        FIXED_IO_ps_srstb,
    // MII Ethernet
    input  wire        eth_rx_clk,
    input  wire        eth_tx_clk,
    input  wire        eth_rx_dv,
    input  wire [3:0]  eth_rxd,
    output wire        eth_tx_en,
    output wire [3:0]  eth_txd,
    inout  wire        eth_mdio,
    output wire        eth_mdc,
    // AD9226 ADC
    input  wire [11:0] adc_a_data,
    input  wire        adc_a_otr,
    input  wire [11:0] adc_b_data,
    input  wire        adc_b_otr,
    output wire        adc_clk,
    // EDM I/O
    input  wire        hv_enable,
    output wire        pulse_out,
    output wire        lamp_green,
    output wire        lamp_orange,
    output wire        lamp_red
);

wire        fclk_clk0;
wire        fclk_reset0_n;
wire [7:0]  gmii_txd;
wire [7:0]  gmii_rxd;

// MII 4↔8 adaptation
assign eth_txd = gmii_txd[3:0];
assign eth_tx_en = gmii_tx_en_int;
assign gmii_rxd = {4'b0000, eth_rxd};
wire gmii_tx_en_int;

// AXI GP0 wires
wire [31:0] gp0_araddr, gp0_awaddr, gp0_rdata, gp0_wdata;
wire [2:0]  gp0_arprot, gp0_awprot;
wire        gp0_arvalid, gp0_arready, gp0_rvalid, gp0_rready;
wire [1:0]  gp0_rresp, gp0_bresp;
wire        gp0_awvalid, gp0_awready;
wire        gp0_wvalid, gp0_wready;
wire [3:0]  gp0_wstrb;
wire        gp0_bvalid, gp0_bready;
// Full AXI4 signals (unused by our AXI-Lite slave)
wire [11:0] gp0_arid, gp0_awid, gp0_bid, gp0_rid;
wire [3:0]  gp0_arlen, gp0_awlen;
wire [2:0]  gp0_arsize, gp0_awsize;
wire [1:0]  gp0_arburst, gp0_awburst, gp0_arlock, gp0_awlock;
wire [3:0]  gp0_arcache, gp0_awcache, gp0_arqos, gp0_awqos;
wire        gp0_rlast, gp0_wlast;
wire [11:0] gp0_wid;

// PS7 block design instance
ps7_bd_wrapper u_ps7 (
    .DDR_addr          (DDR_addr),
    .DDR_ba            (DDR_ba),
    .DDR_cas_n         (DDR_cas_n),
    .DDR_ck_n          (DDR_ck_n),
    .DDR_ck_p          (DDR_ck_p),
    .DDR_cke           (DDR_cke),
    .DDR_cs_n          (DDR_cs_n),
    .DDR_dm            (DDR_dm),
    .DDR_dq            (DDR_dq),
    .DDR_dqs_n         (DDR_dqs_n),
    .DDR_dqs_p         (DDR_dqs_p),
    .DDR_odt           (DDR_odt),
    .DDR_ras_n         (DDR_ras_n),
    .DDR_reset_n       (DDR_reset_n),
    .DDR_we_n          (DDR_we_n),
    .FIXED_IO_ddr_vrn  (FIXED_IO_ddr_vrn),
    .FIXED_IO_ddr_vrp  (FIXED_IO_ddr_vrp),
    .FIXED_IO_mio      (FIXED_IO_mio),
    .FIXED_IO_ps_clk   (FIXED_IO_ps_clk),
    .FIXED_IO_ps_porb  (FIXED_IO_ps_porb),
    .FIXED_IO_ps_srstb (FIXED_IO_ps_srstb),
    .FCLK_CLK0         (fclk_clk0),
    .FCLK_RESET0_N     (fclk_reset0_n),
    // Ethernet EMIO
    .ENET0_GMII_RX_CLK (eth_rx_clk),
    .ENET0_GMII_TX_CLK (eth_tx_clk),
    .ENET0_GMII_RX_DV  (eth_rx_dv),
    .ENET0_GMII_TX_EN  (gmii_tx_en_int),
    .ENET0_GMII_RXD    (gmii_rxd),
    .ENET0_GMII_TXD    (gmii_txd),
    .MDIO_ETHERNET_0_mdc    (eth_mdc),
    .MDIO_ETHERNET_0_mdio_io(eth_mdio),
    // AXI GP0
    .M_AXI_GP0_araddr  (gp0_araddr),
    .M_AXI_GP0_arburst (gp0_arburst),
    .M_AXI_GP0_arcache (gp0_arcache),
    .M_AXI_GP0_arid    (gp0_arid),
    .M_AXI_GP0_arlen   (gp0_arlen),
    .M_AXI_GP0_arlock  (gp0_arlock),
    .M_AXI_GP0_arprot  (gp0_arprot),
    .M_AXI_GP0_arqos   (gp0_arqos),
    .M_AXI_GP0_arready (gp0_arready),
    .M_AXI_GP0_arsize  (gp0_arsize),
    .M_AXI_GP0_arvalid (gp0_arvalid),
    .M_AXI_GP0_awaddr  (gp0_awaddr),
    .M_AXI_GP0_awburst (gp0_awburst),
    .M_AXI_GP0_awcache (gp0_awcache),
    .M_AXI_GP0_awid    (gp0_awid),
    .M_AXI_GP0_awlen   (gp0_awlen),
    .M_AXI_GP0_awlock  (gp0_awlock),
    .M_AXI_GP0_awprot  (gp0_awprot),
    .M_AXI_GP0_awqos   (gp0_awqos),
    .M_AXI_GP0_awready (gp0_awready),
    .M_AXI_GP0_awsize  (gp0_awsize),
    .M_AXI_GP0_awvalid (gp0_awvalid),
    .M_AXI_GP0_bid     (gp0_bid),
    .M_AXI_GP0_bready  (gp0_bready),
    .M_AXI_GP0_bresp   (gp0_bresp),
    .M_AXI_GP0_bvalid  (gp0_bvalid),
    .M_AXI_GP0_rdata   (gp0_rdata),
    .M_AXI_GP0_rid     (gp0_rid),
    .M_AXI_GP0_rlast   (gp0_rlast),
    .M_AXI_GP0_rready  (gp0_rready),
    .M_AXI_GP0_rresp   (gp0_rresp),
    .M_AXI_GP0_rvalid  (gp0_rvalid),
    .M_AXI_GP0_wdata   (gp0_wdata),
    .M_AXI_GP0_wid     (gp0_wid),
    .M_AXI_GP0_wlast   (gp0_wlast),
    .M_AXI_GP0_wready  (gp0_wready),
    .M_AXI_GP0_wstrb   (gp0_wstrb),
    .M_AXI_GP0_wvalid  (gp0_wvalid)
);

// EDM controller (AXI4-Lite slave)
edm_top_qmtech #(
    .C_S_AXI_DATA_WIDTH(32),
    .C_S_AXI_ADDR_WIDTH(12)
) u_edm (
    .S_AXI_ACLK    (fclk_clk0),
    .S_AXI_ARESETN (fclk_reset0_n),
    .S_AXI_AWADDR  (gp0_awaddr[11:0]),
    .S_AXI_AWPROT  (gp0_awprot),
    .S_AXI_AWVALID (gp0_awvalid),
    .S_AXI_AWREADY (gp0_awready),
    .S_AXI_WDATA   (gp0_wdata),
    .S_AXI_WSTRB   (gp0_wstrb),
    .S_AXI_WVALID  (gp0_wvalid),
    .S_AXI_WREADY  (gp0_wready),
    .S_AXI_BRESP   (gp0_bresp),
    .S_AXI_BVALID  (gp0_bvalid),
    .S_AXI_BREADY  (gp0_bready),
    .S_AXI_ARADDR  (gp0_araddr[11:0]),
    .S_AXI_ARPROT  (gp0_arprot),
    .S_AXI_ARVALID (gp0_arvalid),
    .S_AXI_ARREADY (gp0_arready),
    .S_AXI_RDATA   (gp0_rdata),
    .S_AXI_RRESP   (gp0_rresp),
    .S_AXI_RVALID  (gp0_rvalid),
    .S_AXI_RREADY  (gp0_rready),
    .hv_enable     (hv_enable),
    .pulse_out     (pulse_out),
    .lamp_green    (lamp_green),
    .lamp_orange   (lamp_orange),
    .lamp_red      (lamp_red),
    .adc_a_data    (adc_a_data),
    .adc_a_otr     (adc_a_otr),
    .adc_b_data    (adc_b_data),
    .adc_b_otr     (adc_b_otr),
    .adc_clk       (adc_clk),
    .m_axis_tdata  (),
    .m_axis_tvalid (),
    .m_axis_tlast  (),
    .m_axis_tready (1'b0)
);

// AXI4 response signals for unused burst features
assign gp0_rlast = 1'b1;
assign gp0_bid   = gp0_awid;
assign gp0_rid   = gp0_arid;

endmodule}
close $fp

add_files -norecurse $top_file
set_property top top [current_fileset]
update_compile_order -fileset sources_1

# ── Constraints ─────────────────────────────────────────────
set xdc_file $proj_dir/$proj_name/$proj_name.srcs/constrs_1/new/qmtech.xdc
file mkdir [file dirname $xdc_file]
set fp [open $xdc_file w]
puts $fp "# QMTech ZYJZGW Zynq-7010 — Pin Constraints"
puts $fp ""
puts $fp "# MII Ethernet (IP101GA, BANK35)"
puts $fp "set_property -dict {PACKAGE_PIN D20 IOSTANDARD LVCMOS33} \[get_ports eth_tx_en\]"
puts $fp "set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVCMOS33} \[get_ports {eth_txd\[0\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN G19 IOSTANDARD LVCMOS33} \[get_ports {eth_txd\[1\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN F20 IOSTANDARD LVCMOS33} \[get_ports {eth_txd\[2\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN F19 IOSTANDARD LVCMOS33} \[get_ports {eth_txd\[3\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN M18 IOSTANDARD LVCMOS33} \[get_ports eth_rx_dv\]"
puts $fp "set_property -dict {PACKAGE_PIN L20 IOSTANDARD LVCMOS33} \[get_ports {eth_rxd\[0\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN L19 IOSTANDARD LVCMOS33} \[get_ports {eth_rxd\[1\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN H20 IOSTANDARD LVCMOS33} \[get_ports {eth_rxd\[2\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN J20 IOSTANDARD LVCMOS33} \[get_ports {eth_rxd\[3\]}\]"
puts $fp "set_property -dict {PACKAGE_PIN J18 IOSTANDARD LVCMOS33} \[get_ports eth_rx_clk\]"
puts $fp "set_property -dict {PACKAGE_PIN H18 IOSTANDARD LVCMOS33} \[get_ports eth_tx_clk\]"
puts $fp "set_property -dict {PACKAGE_PIN M19 IOSTANDARD LVCMOS33} \[get_ports eth_mdio\]"
puts $fp "set_property -dict {PACKAGE_PIN M20 IOSTANDARD LVCMOS33} \[get_ports eth_mdc\]"
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
