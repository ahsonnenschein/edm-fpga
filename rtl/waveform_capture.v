`timescale 1ns/1ps
// waveform_capture.v
// Triggered ADC waveform capture.
// On each trigger: captures capture_len samples from CH1 and CH2.
// Packs two 12-bit XADC samples into one 32-bit AXI-Stream word:
//   bits [31:20] = CH1 (12-bit, gap voltage)
//   bits [15:4]  = CH2 (12-bit, arc current)
//   bits [19:16] and [3:0] = 00 (unused)
// TLAST asserts on the final sample of each waveform.
// If a new trigger arrives while capturing, it is ignored.

module waveform_capture (
    input  wire        clk,
    input  wire        rst_n,

    // Trigger from pulse controller
    input  wire        trigger,

    // ADC inputs (12-bit unsigned, from XADC Wizard)
    input  wire [11:0] adc_ch1,
    input  wire [11:0] adc_ch2,

    // Capture length in samples (set to 2 * ton_cycles by software)
    input  wire [31:0] capture_len,

    // AXI4-Stream master to DMA
    output reg  [31:0] m_axis_tdata,
    output reg         m_axis_tvalid,
    output reg         m_axis_tlast,
    input  wire        m_axis_tready,

    // Status
    output reg         capturing,
    output reg  [31:0] waveform_count
);

localparam IDLE    = 2'd0;
localparam CAPTURE = 2'd1;

reg [1:0]  state;
reg [31:0] sample_cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state          <= IDLE;
        sample_cnt     <= 32'd0;
        m_axis_tdata   <= 32'd0;
        m_axis_tvalid  <= 1'b0;
        m_axis_tlast   <= 1'b0;
        capturing      <= 1'b0;
        waveform_count <= 32'd0;
    end else begin
        case (state)
            IDLE: begin
                m_axis_tvalid <= 1'b0;
                m_axis_tlast  <= 1'b0;
                capturing     <= 1'b0;
                if (trigger && capture_len > 0) begin
                    state      <= CAPTURE;
                    sample_cnt <= capture_len - 1;
                    capturing  <= 1'b1;
                    // Latch first sample immediately on trigger
                    m_axis_tdata  <= {adc_ch1, 4'b0000, adc_ch2, 4'b0000};
                    m_axis_tvalid <= 1'b1;
                    m_axis_tlast  <= (capture_len == 1);
                end
            end

            CAPTURE: begin
                if (m_axis_tready && m_axis_tvalid) begin
                    if (m_axis_tlast) begin
                        // Waveform complete
                        state          <= IDLE;
                        m_axis_tvalid  <= 1'b0;
                        m_axis_tlast   <= 1'b0;
                        capturing      <= 1'b0;
                        waveform_count <= waveform_count + 1;
                    end else begin
                        sample_cnt    <= sample_cnt - 1;
                        m_axis_tdata  <= {adc_ch1, 4'b0000, adc_ch2, 4'b0000};
                        m_axis_tlast  <= (sample_cnt == 32'd1);
                    end
                end
            end

            default: state <= IDLE;
        endcase
    end
end

endmodule
