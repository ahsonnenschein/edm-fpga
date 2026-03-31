`timescale 1ns/1ps
// edm_top.v
// Top-level EDM FPGA controller for PYNQ-Z2 (Zynq-7020)
//
// XADC Wizard in ENABLE_DRP mode.
// xadc_drp_reader issues one DRP read per EOC (~1 MSPS total, 500 kSPS per channel).
// waveform_capture uses the decoded pair_ready pulses for triggered capture.
// Latest CH1/CH2/temp values are latched into AXI registers for the 200 Hz server.

module edm_top #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 6
)(
    // AXI4-Lite slave
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI:M_AXIS, ASSOCIATED_RESET S_AXI_ARESETN" *)
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

    // Operator HV enable switch (Arduino D3)
    input  wire        hv_enable,

    // EDM pulse output (Arduino D2)
    output wire        pulse_out,

    // Warning lamps (Arduino D4/D5/D6)
    output wire        lamp_green,
    output wire        lamp_orange,
    output wire        lamp_red,

    // Status LEDs
    output wire [3:0]  led,

    // XADC Wizard DRP interface (ENABLE_DRP mode)
    input  wire [4:0]  xadc_channel,  // channel_out: channel just converted
    input  wire        xadc_eoc,      // eoc_out: end-of-conversion pulse
    input  wire [15:0] xadc_do,       // do_out: DRP read data
    input  wire        xadc_drdy,     // drdy_out: DRP data ready
    output wire [6:0]  xadc_daddr,    // daddr_in: DRP read address
    output wire        xadc_den,      // den_in: DRP read enable

    // AXI4-Stream master to AXI DMA S_AXIS_S2MM
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
    output wire [31:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TVALID" *)
    output wire        m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TLAST" *)
    output wire        m_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TREADY" *)
    input  wire        m_axis_tready
);

// ── Internal wires ─────────────────────────────────────
wire [31:0] ton_cycles, toff_cycles, pulse_count, waveform_count;
wire        enable;
wire [15:0] capture_len;
wire        pulse_internal;

// Decoded XADC outputs
wire [11:0] xadc_ch1_raw, xadc_ch2_raw, xadc_temp_raw;
wire        pair_ready;

// ── 2-FF synchroniser for HV enable ───────────────────
reg hv_enable_r1, hv_enable_sync;
always @(posedge S_AXI_ACLK) begin
    hv_enable_r1   <= hv_enable;
    hv_enable_sync <= hv_enable_r1;
end
assign pulse_out = pulse_internal & hv_enable_sync;

// ── XADC DRP reader ────────────────────────────────────
xadc_drp_reader u_drp (
    .clk         (S_AXI_ACLK),
    .rst_n       (S_AXI_ARESETN),
    .channel_out (xadc_channel),
    .eoc_out     (xadc_eoc),
    .do_out      (xadc_do),
    .drdy_out    (xadc_drdy),
    .daddr_in    (xadc_daddr),
    .den_in      (xadc_den),
    .dwe_in      (),            // tied to 0 inside xadc_drp_reader
    .di_in       (),            // tied to 0 inside xadc_drp_reader
    .ch1_data    (xadc_ch1_raw),
    .ch2_data    (xadc_ch2_raw),
    .temp_data   (xadc_temp_raw),
    .pair_ready  (pair_ready)
);

// ── AXI4-Lite register file ────────────────────────────
axi_edm_regs #(
    .C_S_AXI_DATA_WIDTH(C_S_AXI_DATA_WIDTH),
    .C_S_AXI_ADDR_WIDTH(C_S_AXI_ADDR_WIDTH)
) u_regs (
    .S_AXI_ACLK      (S_AXI_ACLK),    .S_AXI_ARESETN   (S_AXI_ARESETN),
    .S_AXI_AWADDR    (S_AXI_AWADDR),   .S_AXI_AWPROT    (S_AXI_AWPROT),
    .S_AXI_AWVALID   (S_AXI_AWVALID),  .S_AXI_AWREADY   (S_AXI_AWREADY),
    .S_AXI_WDATA     (S_AXI_WDATA),    .S_AXI_WSTRB     (S_AXI_WSTRB),
    .S_AXI_WVALID    (S_AXI_WVALID),   .S_AXI_WREADY    (S_AXI_WREADY),
    .S_AXI_BRESP     (S_AXI_BRESP),    .S_AXI_BVALID    (S_AXI_BVALID),
    .S_AXI_BREADY    (S_AXI_BREADY),
    .S_AXI_ARADDR    (S_AXI_ARADDR),   .S_AXI_ARPROT    (S_AXI_ARPROT),
    .S_AXI_ARVALID   (S_AXI_ARVALID),  .S_AXI_ARREADY   (S_AXI_ARREADY),
    .S_AXI_RDATA     (S_AXI_RDATA),    .S_AXI_RRESP     (S_AXI_RRESP),
    .S_AXI_RVALID    (S_AXI_RVALID),   .S_AXI_RREADY    (S_AXI_RREADY),
    .ton_cycles      (ton_cycles),     .toff_cycles     (toff_cycles),
    .enable          (enable),         .capture_len     (capture_len),
    .pulse_count     (pulse_count),    .hv_enable_in    (hv_enable_sync),
    .waveform_count  (waveform_count),
    .xadc_ch1_raw    (xadc_ch1_raw),
    .xadc_ch2_raw    (xadc_ch2_raw),
    .xadc_temp_raw   (xadc_temp_raw)
);

// ── EDM pulse state machine ────────────────────────────
wire pulse_trigger;   // single-cycle pulse at each Ton rising edge
edm_pulse_ctrl u_pulse (
    .clk         (S_AXI_ACLK),
    .rst_n       (S_AXI_ARESETN),
    .enable      (enable & hv_enable_sync),
    .ton_cycles  (ton_cycles),
    .toff_cycles (toff_cycles),
    .pulse_out   (pulse_internal),
    .trigger     (pulse_trigger),
    .pulse_count (pulse_count)
);

// ── Per-pulse waveform capture ─────────────────────────
waveform_capture u_cap (
    .clk            (S_AXI_ACLK),
    .rst_n          (S_AXI_ARESETN),
    .trigger        (pulse_trigger & hv_enable_sync),
    .pulse_state    (pulse_out),
    .ch1_data       (xadc_ch1_raw),
    .ch2_data       (xadc_ch2_raw),
    .pair_ready     (pair_ready),
    .capture_len    (capture_len),
    .m_axis_tdata   (m_axis_tdata),
    .m_axis_tvalid  (m_axis_tvalid),
    .m_axis_tlast   (m_axis_tlast),
    .m_axis_tready  (m_axis_tready),
    .capturing      (),
    .waveform_count (waveform_count)
);

// ── Warning lamps ──────────────────────────────────────
assign lamp_green  = ~hv_enable_sync;
assign lamp_orange =  hv_enable_sync & ~enable;
assign lamp_red    =  hv_enable_sync &  enable;

// ── Status LEDs ────────────────────────────────────────
assign led[0] = enable;
assign led[1] = pulse_out;
assign led[2] = hv_enable_sync;
assign led[3] = lamp_red;

endmodule
