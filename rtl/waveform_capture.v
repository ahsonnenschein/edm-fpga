`timescale 1ns/1ps
// waveform_capture.v  (rev 6 — dual-beat HP0 workaround + tready gate)
//
// Zynq HP0 port drops every other 32-bit write even in "32-bit mode."
// Workaround: output each sample TWICE on AXI-S.  The DMA receives 2N
// words; HP0 commits only the even-addressed ones.  Software reads the
// buffer at stride 2 and recovers all N original samples.
//
// Trigger gate: capture only starts when m_axis_tready=1 (DMA armed).
// If the DMA isn't ready when a pulse fires, that pulse is skipped.

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
localparam S_DUP     = 2'd2;   // outputting the duplicate beat
localparam S_DRAIN   = 2'd3;

localparam DRAIN_TIMEOUT = 16'd1000;

reg [1:0]  state;
reg [15:0] sample_cnt;
reg [15:0] drain_timer;
reg        last_sample;   // set when sample_cnt was 1 at latch time

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
        last_sample    <= 1'b0;
    end else begin
        trig_r <= trigger;

        case (state)
            // ── IDLE: wait for trigger + DMA ready ──────────
            S_IDLE: begin
                capturing <= 1'b0;
                if (m_axis_tvalid && m_axis_tready)
                    m_axis_tvalid <= 1'b0;
                if (trig_rise && capture_len > 0 && m_axis_tready) begin
                    state      <= S_CAPTURE;
                    sample_cnt <= capture_len;
                    capturing  <= 1'b1;
                end
            end

            // ── CAPTURE: on pair_ready, present first beat ──
            S_CAPTURE: begin
                if (pair_ready) begin
                    if (!m_axis_tvalid || m_axis_tready) begin
                        m_axis_tdata  <= {ch1_data, 4'b0000, ch2_data, 4'b0000};
                        m_axis_tvalid <= 1'b1;
                        m_axis_tlast  <= 1'b0;
                        last_sample   <= (sample_cnt <= 16'd1);
                        state         <= S_DUP;
                        // sample_cnt decremented after duplicate is accepted
                    end
                    // else: DMA backpressure — drop this pair_ready
                end else if (m_axis_tready && m_axis_tvalid) begin
                    m_axis_tvalid <= 1'b0;
                end
            end

            // ── DUP: wait for first beat accepted, then hold
            //    tvalid for the duplicate second beat ─────────
            S_DUP: begin
                if (m_axis_tvalid && m_axis_tready) begin
                    // First beat just accepted by DMA.
                    // Present duplicate with same tdata.
                    // Keep tvalid=1 (data unchanged).
                    if (last_sample)
                        m_axis_tlast <= 1'b1;   // TLAST on duplicate of last sample
                    // Stay in S_DUP; next tready accepts the duplicate.
                    // Use drain_timer as a one-shot to distinguish first vs second accept.
                    if (drain_timer == 16'd0) begin
                        drain_timer <= 16'd1;   // mark: first beat done
                    end else begin
                        // Second beat accepted — sample complete
                        drain_timer   <= 16'd0;
                        m_axis_tvalid <= 1'b0;
                        m_axis_tlast  <= 1'b0;
                        if (last_sample) begin
                            state          <= S_IDLE;
                            capturing      <= 1'b0;
                            waveform_count <= waveform_count + 32'd1;
                        end else begin
                            sample_cnt <= sample_cnt - 16'd1;
                            state      <= S_CAPTURE;
                        end
                    end
                end
            end

            // S_DRAIN kept for default recovery only
            S_DRAIN: begin
                m_axis_tvalid <= 1'b0;
                m_axis_tlast  <= 1'b0;
                state         <= S_IDLE;
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
