`timescale 1ns/1ps
// edm_top.v
// Top-level EDM FPGA controller for PYNQ-Z2 (Zynq-7020)
//
// AXI4-Lite slave: control registers (ton, toff, enable, capture_len)
//                  status registers (pulse_count, hv_enable, waveform_count)
// XADC DRP inputs: eoc/channel/do from XADC Wizard fabric outputs
// AXI4-Stream master: per-pulse waveform stream to AXI DMA → PS HP0

module edm_top #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 5
)(
    // AXI4-Lite slave (from Zynq PS GP0 via AXI interconnect)
    input  wire                             S_AXI_ACLK,
    input  wire                             S_AXI_ARESETN,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]   S_AXI_AWADDR,
    input  wire [2:0]                       S_AXI_AWPROT,
    input  wire                             S_AXI_AWVALID,
    output wire                             S_AXI_AWREADY,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]   S_AXI_WDATA,
    input  wire [3:0]                       S_AXI_WSTRB,
    input  wire                             S_AXI_WVALID,
    output wire                             S_AXI_WREADY,
    output wire [1:0]                       S_AXI_BRESP,
    output wire                             S_AXI_BVALID,
    input  wire                             S_AXI_BREADY,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]   S_AXI_ARADDR,
    input  wire [2:0]                       S_AXI_ARPROT,
    input  wire                             S_AXI_ARVALID,
    output wire                             S_AXI_ARREADY,
    output wire [C_S_AXI_DATA_WIDTH-1:0]   S_AXI_RDATA,
    output wire [1:0]                       S_AXI_RRESP,
    output wire                             S_AXI_RVALID,
    input  wire                             S_AXI_RREADY,

    // Operator HV enable switch (Arduino D3, active high)
    input  wire        hv_enable,

    // EDM pulse output → GEDM pulseboard (Arduino D2)
    output wire        pulse_out,

    // Warning lamp outputs → HFET module (Arduino D4/D5/D6)
    output wire        lamp_green,
    output wire        lamp_orange,
    output wire        lamp_red,

    // Status LEDs (LD0-LD3)
    output wire [3:0]  led,

    // XADC Wizard DRP fabric outputs (connected in block design)
    input  wire [15:0] xadc_do,       // conversion result (left-justified 12-bit)
    input  wire [4:0]  xadc_channel,  // channel address
    input  wire        xadc_eoc,      // end-of-conversion pulse (1 cycle)

    // AXI4-Stream master → AXI DMA S_AXIS_S2MM
    output wire [31:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    output wire        m_axis_tlast,
    input  wire        m_axis_tready
);

// -------------------------------------------------------
// Internal wires
// -------------------------------------------------------
wire [31:0] ton_cycles;
wire [31:0] toff_cycles;
wire        enable;
wire [15:0] capture_len;
wire [31:0] pulse_count;
wire [31:0] waveform_count;

wire        pulse_internal;

// -------------------------------------------------------
// 2-FF synchroniser for HV enable switch
// -------------------------------------------------------
reg hv_enable_r1, hv_enable_sync;
always @(posedge S_AXI_ACLK) begin
    hv_enable_r1   <= hv_enable;
    hv_enable_sync <= hv_enable_r1;
end

assign pulse_out = pulse_internal & hv_enable_sync;

// -------------------------------------------------------
// AXI4-Lite register file
// -------------------------------------------------------
axi_edm_regs #(
    .C_S_AXI_DATA_WIDTH(C_S_AXI_DATA_WIDTH),
    .C_S_AXI_ADDR_WIDTH(C_S_AXI_ADDR_WIDTH)
) u_regs (
    .S_AXI_ACLK      (S_AXI_ACLK),
    .S_AXI_ARESETN   (S_AXI_ARESETN),
    .S_AXI_AWADDR    (S_AXI_AWADDR),
    .S_AXI_AWPROT    (S_AXI_AWPROT),
    .S_AXI_AWVALID   (S_AXI_AWVALID),
    .S_AXI_AWREADY   (S_AXI_AWREADY),
    .S_AXI_WDATA     (S_AXI_WDATA),
    .S_AXI_WSTRB     (S_AXI_WSTRB),
    .S_AXI_WVALID    (S_AXI_WVALID),
    .S_AXI_WREADY    (S_AXI_WREADY),
    .S_AXI_BRESP     (S_AXI_BRESP),
    .S_AXI_BVALID    (S_AXI_BVALID),
    .S_AXI_BREADY    (S_AXI_BREADY),
    .S_AXI_ARADDR    (S_AXI_ARADDR),
    .S_AXI_ARPROT    (S_AXI_ARPROT),
    .S_AXI_ARVALID   (S_AXI_ARVALID),
    .S_AXI_ARREADY   (S_AXI_ARREADY),
    .S_AXI_RDATA     (S_AXI_RDATA),
    .S_AXI_RRESP     (S_AXI_RRESP),
    .S_AXI_RVALID    (S_AXI_RVALID),
    .S_AXI_RREADY    (S_AXI_RREADY),
    .ton_cycles      (ton_cycles),
    .toff_cycles     (toff_cycles),
    .enable          (enable),
    .capture_len     (capture_len),
    .pulse_count     (pulse_count),
    .hv_enable_in    (hv_enable_sync),
    .waveform_count  (waveform_count)
);

// -------------------------------------------------------
// EDM pulse state machine
// -------------------------------------------------------
wire trigger_internal;

edm_pulse_ctrl u_pulse (
    .clk         (S_AXI_ACLK),
    .rst_n       (S_AXI_ARESETN),
    .enable      (enable & hv_enable_sync),
    .ton_cycles  (ton_cycles),
    .toff_cycles (toff_cycles),
    .pulse_out   (pulse_internal),
    .trigger     (trigger_internal),
    .pulse_count (pulse_count)
);

// -------------------------------------------------------
// Per-pulse waveform capture
// -------------------------------------------------------
waveform_capture u_cap (
    .clk            (S_AXI_ACLK),
    .rst_n          (S_AXI_ARESETN),
    .trigger        (pulse_out),       // gated: only fires when HV on
    .xadc_do        (xadc_do),
    .xadc_channel   (xadc_channel),
    .xadc_eoc       (xadc_eoc),
    .capture_len    (capture_len),
    .m_axis_tdata   (m_axis_tdata),
    .m_axis_tvalid  (m_axis_tvalid),
    .m_axis_tlast   (m_axis_tlast),
    .m_axis_tready  (m_axis_tready),
    .capturing      (),               // unused top-level
    .waveform_count (waveform_count)
);

// -------------------------------------------------------
// Warning lamp logic
// -------------------------------------------------------
assign lamp_green  = ~hv_enable_sync;
assign lamp_orange =  hv_enable_sync & ~enable;
assign lamp_red    =  hv_enable_sync &  enable;

// -------------------------------------------------------
// Status LEDs
// -------------------------------------------------------
assign led[0] = enable;
assign led[1] = pulse_out;
assign led[2] = hv_enable_sync;
assign led[3] = lamp_red;

endmodule
