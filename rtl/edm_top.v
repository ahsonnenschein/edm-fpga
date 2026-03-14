// edm_top.v
// Top-level EDM FPGA controller for Red Pitaya STEMlab 125-14 (Zynq-7010)
//
// Connections:
//   axi_*        : AXI4-Lite from Zynq PS GP0 (control registers)
//   m_axis_*     : AXI4-Stream to AXI DMA (waveform data to DDR)
//   adc_ch1/ch2  : 14-bit ADC data from Red Pitaya ADC (registered in IOB)
//   pulse_out    : 3.3V GPIO to GEDM pulseboard logic input
//   led          : status LEDs

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

    // AXI4-Stream master (to AXI DMA, waveform samples → DDR)
    output wire [31:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    output wire        m_axis_tlast,
    input  wire        m_axis_tready,

    // Red Pitaya ADC interface (125 MSPS, 14-bit)
    input  wire [13:0] adc_ch1_i,   // CH1: voltage (Hentek probe)
    input  wire [13:0] adc_ch2_i,   // CH2: current feedback

    // EDM pulse output → GEDM pulseboard (3.3V GPIO)
    output wire        pulse_out,

    // Status LEDs
    output wire [7:0]  led
);

// -------------------------------------------------------
// Internal signals
// -------------------------------------------------------
wire [31:0] ton_cycles;
wire [31:0] toff_cycles;
wire        enable;
wire [31:0] capture_len;
wire [15:0] f_save;
wire [15:0] f_display;
wire [31:0] pulse_count;
wire [31:0] waveform_count;

wire        trigger;
wire        capturing;

// Register ADC inputs in IOB (minimise input delay)
reg [13:0] adc_ch1_reg;
reg [13:0] adc_ch2_reg;
always @(posedge S_AXI_ACLK) begin
    adc_ch1_reg <= adc_ch1_i;
    adc_ch2_reg <= adc_ch2_i;
end

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
    .capture_len     (capture_len),
    .f_save          (f_save),
    .f_display       (f_display),
    .pulse_count     (pulse_count),
    .waveform_count  (waveform_count)
);

// -------------------------------------------------------
// EDM pulse state machine
// -------------------------------------------------------
edm_pulse_ctrl u_pulse (
    .clk         (S_AXI_ACLK),
    .rst_n       (S_AXI_ARESETN),
    .enable      (enable),
    .ton_cycles  (ton_cycles),
    .toff_cycles (toff_cycles),
    .pulse_out   (pulse_out),
    .trigger     (trigger),
    .pulse_count (pulse_count)
);

// -------------------------------------------------------
// Waveform capture
// -------------------------------------------------------
waveform_capture u_capture (
    .clk            (S_AXI_ACLK),
    .rst_n          (S_AXI_ARESETN),
    .trigger        (trigger),
    .adc_ch1        (adc_ch1_reg),
    .adc_ch2        (adc_ch2_reg),
    .capture_len    (capture_len),
    .m_axis_tdata   (m_axis_tdata),
    .m_axis_tvalid  (m_axis_tvalid),
    .m_axis_tlast   (m_axis_tlast),
    .m_axis_tready  (m_axis_tready),
    .capturing      (capturing),
    .waveform_count (waveform_count)
);

// -------------------------------------------------------
// Status LEDs
// -------------------------------------------------------
assign led[0] = enable;
assign led[1] = pulse_out;
assign led[2] = capturing;
assign led[7:3] = 5'b0;

endmodule
