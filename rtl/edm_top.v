`timescale 1ns/1ps
// edm_top.v
// Top-level EDM FPGA controller for PYNQ-Z2 (Zynq-7020)
//
// Connections:
//   axi_*      : AXI4-Lite from Zynq PS GP0 (control registers)
//   hv_enable  : Operator HV enable switch input (Arduino D3, active high)
//   pulse_out  : 3.3V GPIO to GEDM pulseboard (Arduino D2)
//   lamp_*     : Warning light outputs via HFET module (Arduino D4/D5/D6)
//   led        : Status LEDs (LD0-LD3)
//
// Note: ADC waveform capture is handled by the PS via XADC Wizard AXI reads.
// High-speed waveform capture will be added when the parallel ADC is connected.

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
    output wire        lamp_green,   // HV enable switch OFF
    output wire        lamp_orange,  // Switch ON, sparks OFF
    output wire        lamp_red,     // Sparks ON

    // Status LEDs (LD0-LD3)
    output wire [3:0]  led
);

// -------------------------------------------------------
// Internal signals
// -------------------------------------------------------
wire [31:0] ton_cycles;
wire [31:0] toff_cycles;
wire        enable;
wire [31:0] pulse_count;

wire        trigger;
wire        pulse_internal;

// Synchronise hv_enable input to AXI clock domain (2-FF synchroniser)
reg hv_enable_r1, hv_enable_sync;
always @(posedge S_AXI_ACLK) begin
    hv_enable_r1   <= hv_enable;
    hv_enable_sync <= hv_enable_r1;
end

// Gate pulse output: only fire when operator has enabled HV
assign pulse_out = pulse_internal & hv_enable_sync;

// -------------------------------------------------------
// AXI-Lite register file
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
    .pulse_count     (pulse_count),
    .hv_enable_in    (hv_enable_sync)
);

// -------------------------------------------------------
// EDM pulse state machine
// -------------------------------------------------------
edm_pulse_ctrl u_pulse (
    .clk         (S_AXI_ACLK),
    .rst_n       (S_AXI_ARESETN),
    .enable      (enable & hv_enable_sync),
    .ton_cycles  (ton_cycles),
    .toff_cycles (toff_cycles),
    .pulse_out   (pulse_internal),
    .trigger     (trigger),
    .pulse_count (pulse_count)
);

// -------------------------------------------------------
// Warning lamp logic (combinational)
//   green  = HV switch off
//   orange = switch on, sparks disabled
//   red    = sparks actively running
// -------------------------------------------------------
assign lamp_green  = ~hv_enable_sync;
assign lamp_orange =  hv_enable_sync & ~enable;
assign lamp_red    =  hv_enable_sync &  enable;

// -------------------------------------------------------
// Status LEDs (PYNQ-Z2 board LEDs LD0-LD3)
// -------------------------------------------------------
assign led[0] = enable;
assign led[1] = pulse_out;
assign led[2] = hv_enable_sync;
assign led[3] = lamp_red;

endmodule
