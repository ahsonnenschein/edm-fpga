`timescale 1ns/1ps
// edm_top_qmtech.v
// Top-level EDM FPGA controller for QMTech ZYJZGW Zynq-7010
//
// Uses AD9226 dual-channel 12-bit ADC at 25 MSPS instead of XADC.
// Otherwise functionally identical to edm_top.v (PYNQ-Z2 version).

module edm_top_qmtech #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 12   // 4KB: control regs + waveform BRAM
)(
    // AXI4-Lite slave
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

    // Operator HV enable switch
    input  wire        hv_enable,

    // EDM pulse output
    output wire        pulse_out,

    // Warning lamps
    output wire        lamp_green,
    output wire        lamp_orange,
    output wire        lamp_red,

    // AD9226 Channel A (arc current)
    input  wire [11:0] adc_a_data,
    input  wire        adc_a_otr,

    // AD9226 Channel B (gap voltage)
    input  wire [11:0] adc_b_data,
    input  wire        adc_b_otr,

    // ADC clock output (active drives both AD9226 CLK inputs)
    output wire        adc_clk,

    // AXI4-Stream master (active off — reserved for future DMA)
    output wire [31:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    output wire        m_axis_tlast,
    input  wire        m_axis_tready
);

// ── Internal wires ─────────────────────────────────────
wire [31:0] ton_cycles, toff_cycles, pulse_count, waveform_count;
wire        enable;
wire [15:0] capture_len;
wire        pulse_internal;

// ADC outputs
wire [11:0] ch1_raw, ch2_raw;
wire        pair_ready;

// BRAM read port (register file ↔ waveform capture)
wire [8:0]  bram_rd_addr;
wire [31:0] bram_rd_data;

// Gap voltage accumulator (per-pulse average during Ton)
reg [31:0] gap_sum;
reg [15:0] gap_count;
reg [31:0] gap_sum_lat;
reg [15:0] gap_count_lat;
reg        pulse_out_prev;

// ── 2-FF synchroniser for Operator HV Enable ─────────
// Switch is active-LOW: normally HIGH (enabled), pulled LOW to disable.
reg hv_enable_r1, hv_enable_sync;
always @(posedge S_AXI_ACLK) begin
    hv_enable_r1   <= ~hv_enable;
    hv_enable_sync <= hv_enable_r1;
end
assign pulse_out = pulse_internal & hv_enable_sync;

// ── AD9226 ADC capture ─────────────────────────────────
ad9226_capture u_adc (
    .clk         (S_AXI_ACLK),
    .rst_n       (S_AXI_ARESETN),
    .adc_a_data  (adc_a_data),
    .adc_a_otr   (adc_a_otr),
    .adc_b_data  (adc_b_data),
    .adc_b_otr   (adc_b_otr),
    .adc_clk     (adc_clk),
    .ch1_data    (ch1_raw),
    .ch2_data    (ch2_raw),
    .ch1_otr     (),
    .ch2_otr     (),
    .pair_ready  (pair_ready)
);

// ── AXI4-Lite register file ────────────────────────────
// temp_raw tied to 0 (no on-chip temperature sensor with external ADC)
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
    .xadc_ch1_raw    (ch1_raw),
    .xadc_ch2_raw    (ch2_raw),
    .xadc_temp_raw   (12'd0),
    .gap_sum         (gap_sum_lat),
    .gap_count       (gap_count_lat),
    .bram_rd_addr    (bram_rd_addr),
    .bram_rd_data    (bram_rd_data)
);

// ── EDM pulse state machine ────────────────────────────
wire pulse_trigger;
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

// ── Gap voltage accumulator (per-pulse Ton average) ────
always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN) begin
        gap_sum       <= 32'd0;
        gap_count     <= 16'd0;
        gap_sum_lat   <= 32'd0;
        gap_count_lat <= 16'd0;
        pulse_out_prev <= 1'b0;
    end else begin
        pulse_out_prev <= pulse_out;

        if (pulse_out_prev && !pulse_out) begin
            gap_sum_lat   <= gap_sum;
            gap_count_lat <= gap_count;
            gap_sum       <= 32'd0;
            gap_count     <= 16'd0;
        end
        else if (pulse_out && pair_ready) begin
            gap_sum   <= gap_sum + {20'd0, ch2_raw};
            gap_count <= gap_count + 16'd1;
        end
    end
end

// ── Per-pulse waveform capture ─────────────────────────
waveform_capture u_cap (
    .clk            (S_AXI_ACLK),
    .rst_n          (S_AXI_ARESETN),
    .trigger        (pulse_trigger & hv_enable_sync),
    .pulse_state    (pulse_out),
    .ch1_data       (ch1_raw),
    .ch2_data       (ch2_raw),
    .pair_ready     (pair_ready),
    .capture_len    (capture_len),
    .m_axis_tdata   (m_axis_tdata),
    .m_axis_tvalid  (m_axis_tvalid),
    .m_axis_tlast   (m_axis_tlast),
    .m_axis_tready  (m_axis_tready),
    .bram_rd_addr   (bram_rd_addr),
    .bram_rd_data   (bram_rd_data),
    .capturing      (),
    .waveform_count (waveform_count)
);

// ── Warning lamps ──────────────────────────────────────
assign lamp_green  = ~hv_enable_sync;
assign lamp_orange =  hv_enable_sync & ~enable;
assign lamp_red    =  hv_enable_sync &  enable;

endmodule
