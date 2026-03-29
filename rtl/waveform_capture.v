`timescale 1ns/1ps
// waveform_capture.v  (rev 5 — S_DRAIN timeout to prevent permanent stall)
//
// Triggered waveform capture using decoded XADC outputs from xadc_drp_reader.
// pair_ready pulses at ~500 kHz (once per ch1+ch2 pair from the DRP reader).
//
// On rising edge of trigger (pulse_out):
//   - Captures capture_len (ch1,ch2) pairs
//   - Outputs as AXI4-Stream: {ch1[11:0], 4'b0, ch2[11:0], 4'b0}
//   - TLAST on final word
//   - New trigger while capturing is ignored.

module waveform_capture (
    input  wire        clk,
    input  wire        rst_n,

    // Trigger: rising edge starts capture
    input  wire        trigger,

    // Decoded XADC pair from xadc_drp_reader
    input  wire [11:0] ch1_data,
    input  wire [11:0] ch2_data,
    input  wire        pair_ready,   // pulses when fresh (ch1,ch2) pair available

    // Capture depth in pairs
    input  wire [15:0] capture_len,

    // AXI4-Stream master to AXI DMA
    output reg  [31:0] m_axis_tdata,
    output reg         m_axis_tvalid,
    output reg         m_axis_tlast,
    input  wire        m_axis_tready,

    output reg         capturing,
    output reg  [31:0] waveform_count
);

// Rising-edge on trigger
reg  trig_r;
wire trig_rise = trigger & ~trig_r;

localparam S_IDLE    = 2'd0;
localparam S_CAPTURE = 2'd1;
localparam S_DRAIN   = 2'd2;

// Max cycles to wait for DMA tready in S_DRAIN (1000 × 10 ns = 10 µs).
// If the DMA doesn't accept the final word in time, abandon and return to
// S_IDLE so the next trigger can start a fresh capture.
localparam DRAIN_TIMEOUT = 16'd1000;

reg [1:0]  state;
reg [15:0] sample_cnt;
reg [15:0] drain_timer;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        trig_r         <= 1'b0;
        state          <= S_IDLE;
        sample_cnt     <= 16'd0;
        m_axis_tdata   <= 32'd0;
        m_axis_tvalid  <= 1'b0;
        m_axis_tlast   <= 1'b0;
        capturing      <= 1'b0;
        waveform_count <= 32'd0;
        drain_timer    <= 16'd0;
    end else begin
        trig_r <= trigger;

        case (state)
            S_IDLE: begin
                capturing <= 1'b0;
                if (m_axis_tvalid && m_axis_tready)
                    m_axis_tvalid <= 1'b0;
                if (trig_rise && capture_len > 0) begin
                    state      <= S_CAPTURE;
                    sample_cnt <= capture_len;
                    capturing  <= 1'b1;
                end
            end

            S_CAPTURE: begin
                if (pair_ready) begin
                    if (!m_axis_tvalid || m_axis_tready) begin
                        m_axis_tdata  <= {ch1_data, 4'b0000, ch2_data, 4'b0000};
                        m_axis_tvalid <= 1'b1;

                        if (sample_cnt <= 16'd1) begin
                            m_axis_tlast <= 1'b1;
                            state        <= S_DRAIN;
                            capturing    <= 1'b0;
                            drain_timer  <= 16'd0;
                        end else begin
                            m_axis_tlast <= 1'b0;
                            sample_cnt   <= sample_cnt - 16'd1;
                        end
                    end
                    // else: DMA busy — drop this sample
                end else if (m_axis_tready && m_axis_tvalid) begin
                    m_axis_tvalid <= 1'b0;
                end
            end

            S_DRAIN: begin
                if (m_axis_tvalid && m_axis_tready) begin
                    m_axis_tvalid  <= 1'b0;
                    m_axis_tlast   <= 1'b0;
                    state          <= S_IDLE;
                    waveform_count <= waveform_count + 32'd1;
                    drain_timer    <= 16'd0;
                end else begin
                    // Timeout: abandon if DMA never asserts tready
                    if (drain_timer >= DRAIN_TIMEOUT) begin
                        m_axis_tvalid <= 1'b0;
                        m_axis_tlast  <= 1'b0;
                        state         <= S_IDLE;
                        drain_timer   <= 16'd0;
                    end else begin
                        drain_timer <= drain_timer + 16'd1;
                    end
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
