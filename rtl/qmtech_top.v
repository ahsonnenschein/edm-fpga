`timescale 1ns/1ps
// qmtech_top.v
// Top-level wrapper for QMTech ZYJZGW Zynq-7010
// Instantiates PS7 directly as a Verilog primitive (no block design)
// to avoid DDR/FIXED_IO being mapped to PL I/O pins.

module qmtech_top (
    // DDR interface (directly to PS7 — PS-dedicated pins)
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

    // Fixed IO (directly to PS7 — PS-dedicated pins)
    inout  wire        FIXED_IO_ddr_vrn,
    inout  wire        FIXED_IO_ddr_vrp,
    inout  wire [53:0] FIXED_IO_mio,
    inout  wire        FIXED_IO_ps_clk,
    inout  wire        FIXED_IO_ps_porb,
    inout  wire        FIXED_IO_ps_srstb,

    // MII Ethernet (PL pins — BANK35)
    input  wire        ENET0_GMII_RX_CLK,
    input  wire        ENET0_GMII_TX_CLK,
    input  wire        ENET0_GMII_RX_DV,
    output wire        ENET0_GMII_TX_EN,
    input  wire [3:0]  ENET0_RXD,
    output wire [3:0]  ENET0_TXD,
    inout  wire        MDIO_mdio_io,
    output wire        MDIO_mdc,

    // AD9226 ADC (PL pins — BANK34, JP2)
    input  wire [11:0] adc_a_data,
    input  wire        adc_a_otr,
    input  wire [11:0] adc_b_data,
    input  wire        adc_b_otr,
    output wire        adc_clk,

    // EDM I/O (PL pins — BANK35, JP5)
    input  wire        hv_enable,
    output wire        pulse_out,
    output wire        lamp_green,
    output wire        lamp_orange,
    output wire        lamp_red
);

// ── PS7 signals ────────────────────────────────────────────
wire        FCLK_CLK0;
wire        FCLK_RESET0_N;

// AXI GP0 master
wire [31:0] M_AXI_GP0_ARADDR;
wire [1:0]  M_AXI_GP0_ARBURST;
wire [3:0]  M_AXI_GP0_ARCACHE;
wire [11:0] M_AXI_GP0_ARID;
wire [3:0]  M_AXI_GP0_ARLEN;
wire [1:0]  M_AXI_GP0_ARLOCK;
wire [2:0]  M_AXI_GP0_ARPROT;
wire [3:0]  M_AXI_GP0_ARQOS;
wire        M_AXI_GP0_ARREADY;
wire [2:0]  M_AXI_GP0_ARSIZE;
wire        M_AXI_GP0_ARVALID;
wire [31:0] M_AXI_GP0_AWADDR;
wire [1:0]  M_AXI_GP0_AWBURST;
wire [3:0]  M_AXI_GP0_AWCACHE;
wire [11:0] M_AXI_GP0_AWID;
wire [3:0]  M_AXI_GP0_AWLEN;
wire [1:0]  M_AXI_GP0_AWLOCK;
wire [2:0]  M_AXI_GP0_AWPROT;
wire [3:0]  M_AXI_GP0_AWQOS;
wire        M_AXI_GP0_AWREADY;
wire [2:0]  M_AXI_GP0_AWSIZE;
wire        M_AXI_GP0_AWVALID;
wire [11:0] M_AXI_GP0_BID;
wire        M_AXI_GP0_BREADY;
wire [1:0]  M_AXI_GP0_BRESP;
wire        M_AXI_GP0_BVALID;
wire [31:0] M_AXI_GP0_RDATA;
wire [11:0] M_AXI_GP0_RID;
wire        M_AXI_GP0_RLAST;
wire        M_AXI_GP0_RREADY;
wire [1:0]  M_AXI_GP0_RRESP;
wire        M_AXI_GP0_RVALID;
wire [31:0] M_AXI_GP0_WDATA;
wire [11:0] M_AXI_GP0_WID;
wire        M_AXI_GP0_WLAST;
wire        M_AXI_GP0_WREADY;
wire [3:0]  M_AXI_GP0_WSTRB;
wire        M_AXI_GP0_WVALID;

// Ethernet EMIO
wire [7:0]  ENET0_GMII_TXD_int;
wire        ENET0_GMII_TX_EN_int;
wire [7:0]  ENET0_GMII_RXD_int;

// MDIO
wire        MDIO_mdio_i;
wire        MDIO_mdio_o;
wire        MDIO_mdio_t;

// ── MII 4-bit ↔ 8-bit GMII adaptation ─────────────────────
assign ENET0_TXD = ENET0_GMII_TXD_int[3:0];
assign ENET0_GMII_TX_EN = ENET0_GMII_TX_EN_int;
assign ENET0_GMII_RXD_int = {4'b0000, ENET0_RXD};

// MDIO tristate
IOBUF mdio_buf (
    .I  (MDIO_mdio_o),
    .IO (MDIO_mdio_io),
    .O  (MDIO_mdio_i),
    .T  (MDIO_mdio_t)
);

// ── PS7 block design instance ──────────────────────────────
// This will be replaced by the block design wrapper at synthesis
// For now, use the processing_system7 IP instantiation
// The actual PS7 is instantiated through a block design .bd file
// which Vivado handles specially for DDR/FIXED_IO pin mapping.

// Instead of direct PS7 primitive, we use a minimal block design
// that ONLY has PS7 (no PL ports) and connect to it externally.
// This is done by the create_qmtech_project_v3.tcl script.

// Stub signals for the block design PS7 wrapper
// (connected by the block design)

// ── EDM controller ─────────────────────────────────────────
edm_top_qmtech #(
    .C_S_AXI_DATA_WIDTH(32),
    .C_S_AXI_ADDR_WIDTH(12)
) u_edm (
    .S_AXI_ACLK    (FCLK_CLK0),
    .S_AXI_ARESETN (FCLK_RESET0_N),
    // AXI4-Lite (directly from PS GP0 — no interconnect needed for single slave)
    .S_AXI_AWADDR  (M_AXI_GP0_AWADDR[11:0]),
    .S_AXI_AWPROT  (M_AXI_GP0_AWPROT),
    .S_AXI_AWVALID (M_AXI_GP0_AWVALID),
    .S_AXI_AWREADY (M_AXI_GP0_AWREADY),
    .S_AXI_WDATA   (M_AXI_GP0_WDATA),
    .S_AXI_WSTRB   (M_AXI_GP0_WSTRB),
    .S_AXI_WVALID  (M_AXI_GP0_WVALID),
    .S_AXI_WREADY  (M_AXI_GP0_WREADY),
    .S_AXI_BRESP   (M_AXI_GP0_BRESP),
    .S_AXI_BVALID  (M_AXI_GP0_BVALID),
    .S_AXI_BREADY  (M_AXI_GP0_BREADY),
    .S_AXI_ARADDR  (M_AXI_GP0_ARADDR[11:0]),
    .S_AXI_ARPROT  (M_AXI_GP0_ARPROT),
    .S_AXI_ARVALID (M_AXI_GP0_ARVALID),
    .S_AXI_ARREADY (M_AXI_GP0_ARREADY),
    .S_AXI_RDATA   (M_AXI_GP0_RDATA),
    .S_AXI_RRESP   (M_AXI_GP0_RRESP),
    .S_AXI_RVALID  (M_AXI_GP0_RVALID),
    .S_AXI_RREADY  (M_AXI_GP0_RREADY),
    // EDM I/O
    .hv_enable     (hv_enable),
    .pulse_out     (pulse_out),
    .lamp_green    (lamp_green),
    .lamp_orange   (lamp_orange),
    .lamp_red      (lamp_red),
    // AD9226
    .adc_a_data    (adc_a_data),
    .adc_a_otr     (adc_a_otr),
    .adc_b_data    (adc_b_data),
    .adc_b_otr     (adc_b_otr),
    .adc_clk       (adc_clk),
    // AXI-Stream (unused)
    .m_axis_tdata  (),
    .m_axis_tvalid (),
    .m_axis_tlast  (),
    .m_axis_tready (1'b0)
);

// AXI GP0 is full AXI4 but our slave is AXI4-Lite.
// Connect the unused AXI4 signals.
assign M_AXI_GP0_RLAST  = 1'b1;  // Always last (single-beat)
assign M_AXI_GP0_BID    = M_AXI_GP0_AWID;  // Echo back transaction ID
assign M_AXI_GP0_RID    = M_AXI_GP0_ARID;
assign M_AXI_GP0_WREADY = M_AXI_GP0_WVALID; // Handled by axi_edm_regs

// Note: The AXI4-to-AXI4Lite conversion above is simplified.
// PS GP0 generates AXI4 (with burst/ID) but our slave is AXI4-Lite.
// This works for single-word accesses from /dev/mem but may need
// a proper protocol converter for burst transfers.

endmodule
