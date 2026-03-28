`timescale 1ns/1ps
// waveform_capture.v  (rev 2 — XADC DRP input)
//
// Triggered waveform capture from XADC DRP outputs.
// Samples at the XADC conversion rate (~500 kSPS per channel at 1 MSPS total).
//
// On rising edge of trigger (pulse_out):
//   - Waits for a fresh CH1 sample, then captures capture_len (ch1,ch2) pairs.
//   - Outputs as AXI4-Stream: {ch1[11:0], 4'b0, ch2[11:0], 4'b0}
//   - TLAST asserts on the final word.
//   - New trigger while capturing is ignored.
//
// If DMA is not ready (tready=0) when a sample arrives the sample is dropped.
// Arm the DMA before enabling sparks to avoid misses on the first pulse.
//
// XADC channel addresses:
//   CH1 VP/VN  = 5'h03
//   CH2 VAUX1  = 5'h11

module waveform_capture (
    input  wire        clk,
    input  wire        rst_n,

    // Trigger from pulse output (rising edge starts capture)
    input  wire        trigger,

    // XADC Wizard DRP outputs (fabric-level, available in AXI4-Lite mode)
    input  wire [15:0] xadc_do,       // conversion result, left-justified 12-bit
    input  wire [4:0]  xadc_channel,  // channel address of completed conversion
    input  wire        xadc_eoc,      // end-of-conversion pulse (1 cycle wide)

    // Number of (ch1,ch2) pairs to capture per trigger
    input  wire [15:0] capture_len,

    // AXI4-Stream master to AXI DMA
    output reg  [31:0] m_axis_tdata,
    output reg         m_axis_tvalid,
    output reg         m_axis_tlast,
    input  wire        m_axis_tready,

    // Status
    output reg         capturing,
    output reg  [31:0] waveform_count
);

localparam CH1_ADDR = 5'h03;   // VP/VN dedicated differential input
localparam CH2_ADDR = 5'h11;   // VAUX1 (Arduino A0)

// Rising-edge detector on trigger
reg  trig_r;
wire trig_rise = trigger & ~trig_r;

// Hold latest value from each channel (updated every EOC regardless of state)
reg [11:0] ch1_hold;
reg [11:0] ch2_hold;
reg        ch1_fresh;   // goes high when CH1 has been updated since last pair output

localparam S_IDLE   = 2'd0;
localparam S_CAPTURE = 2'd1;
localparam S_DRAIN  = 2'd2;   // wait for TLAST handshake

reg [1:0]  state;
reg [15:0] sample_cnt;   // remaining pairs to output

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        trig_r         <= 1'b0;
        ch1_hold       <= 12'd0;
        ch2_hold       <= 12'd0;
        ch1_fresh      <= 1'b0;
        state          <= S_IDLE;
        sample_cnt     <= 16'd0;
        m_axis_tdata   <= 32'd0;
        m_axis_tvalid  <= 1'b0;
        m_axis_tlast   <= 1'b0;
        capturing      <= 1'b0;
        waveform_count <= 32'd0;
    end else begin
        trig_r <= trigger;

        // Always track latest XADC values from DRP output
        if (xadc_eoc) begin
            if (xadc_channel == CH1_ADDR) begin
                ch1_hold  <= xadc_do[15:4];
                ch1_fresh <= 1'b1;
            end else if (xadc_channel == CH2_ADDR) begin
                ch2_hold <= xadc_do[15:4];
            end
        end

        case (state)

            S_IDLE: begin
                capturing <= 1'b0;
                // Clear tvalid once any pending transfer completes
                if (m_axis_tvalid && m_axis_tready)
                    m_axis_tvalid <= 1'b0;
                if (trig_rise && capture_len > 0) begin
                    state      <= S_CAPTURE;
                    sample_cnt <= capture_len;
                    capturing  <= 1'b1;
                    ch1_fresh  <= 1'b0;   // require samples taken after trigger
                end
            end

            S_CAPTURE: begin
                // Emit one word per complete (ch1,ch2) pair.
                // A pair is ready when CH2 arrives and we have a fresh CH1.
                if (xadc_eoc && xadc_channel == CH2_ADDR && ch1_fresh) begin
                    // Only emit if previous word has been consumed (or none pending)
                    if (!m_axis_tvalid || m_axis_tready) begin
                        m_axis_tdata  <= {ch1_hold, 4'b0000, ch2_hold, 4'b0000};
                        m_axis_tvalid <= 1'b1;
                        ch1_fresh     <= 1'b0;

                        if (sample_cnt <= 16'd1) begin
                            m_axis_tlast <= 1'b1;
                            state        <= S_DRAIN;
                            capturing    <= 1'b0;
                        end else begin
                            m_axis_tlast <= 1'b0;
                            sample_cnt   <= sample_cnt - 16'd1;
                        end
                    end
                    // else: DMA back-pressure — drop this sample
                end else if (m_axis_tready && m_axis_tvalid) begin
                    // Word consumed; clear tvalid until next sample ready
                    m_axis_tvalid <= 1'b0;
                end
            end

            S_DRAIN: begin
                // Wait for the TLAST word to be accepted by DMA
                if (m_axis_tvalid && m_axis_tready) begin
                    m_axis_tvalid  <= 1'b0;
                    m_axis_tlast   <= 1'b0;
                    state          <= S_IDLE;
                    waveform_count <= waveform_count + 32'd1;
                end
            end

            default: state <= S_IDLE;

        endcase
    end
end

endmodule
