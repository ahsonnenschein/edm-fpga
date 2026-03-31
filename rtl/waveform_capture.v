`timescale 1ns/1ps
// waveform_capture.v  (rev 10 — decoupled BRAM capture, trigger-independent of DMA)
//
// Architecture: two-phase capture
//   Phase 1 (CAPTURE): trigger alone starts sampling into local BRAM.
//     No dependency on m_axis_tready — capture timing is determined
//     solely by the trigger and pair_ready, independent of DMA state.
//   Phase 2 (STREAM):  after all samples are stored, stream the BRAM
//     contents to the AXI DMA via AXI4-Stream.  tready is only checked
//     here, where backpressure cannot affect capture alignment.
//
// This fixes the "first-period anomaly" where qualifying trigger on
// tready caused capture to start on a random trigger relative to the
// DMA arm, producing a uniform first-period distribution.
//
// BRAM is single-port: written during CAPTURE, read during STREAM.
// Max capture depth: 1024 samples (uses ~4 KB of BRAM).
// HP0 dual-beat workaround retained: each sample output TWICE on AXI-S.

module waveform_capture (
    input  wire        clk,
    input  wire        rst_n,

    // Trigger: single-cycle pulse starts capture
    input  wire        trigger,

    // Pulse output state (embedded in capture data)
    input  wire        pulse_state,

    // Decoded XADC pair from xadc_drp_reader
    input  wire [11:0] ch1_data,
    input  wire [11:0] ch2_data,
    input  wire        pair_ready,

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

// ── Local BRAM buffer (1024 × 25 bits) ───────────────
// Stores {ch1[11:0], ch2[11:0], pulse_state} per sample.
// Written during CAPTURE phase, read during STREAM phase.
localparam MAX_DEPTH = 1024;
localparam ADDR_W    = 10;       // log2(1024)
localparam SAMPLE_W  = 25;      // {ch1[11:0], ch2[11:0], pulse_state}

(* ram_style = "block" *)
reg [SAMPLE_W-1:0] bram [0:MAX_DEPTH-1];

reg [ADDR_W-1:0] wr_addr;       // write pointer during CAPTURE
reg [ADDR_W-1:0] rd_addr;       // read pointer during STREAM
reg [15:0]       cap_len_lat;   // capture_len latched at trigger
reg [15:0]       samples_stored;// samples written to BRAM

// ── FSM ──────────────────────────────────────────────
localparam S_IDLE    = 3'd0;    // waiting for trigger
localparam S_CAPTURE = 3'd1;    // filling BRAM from pair_ready
localparam S_STREAM1 = 3'd2;    // AXI beat 1 (first copy)
localparam S_STREAM2 = 3'd3;    // AXI beat 2 (HP0 duplicate)
localparam S_DONE    = 3'd4;    // frame complete, back to IDLE

reg [2:0]  state;
reg [15:0] stream_cnt;          // samples remaining to stream
reg        last_sample;

// Registered BRAM read data (one cycle read latency)
reg [SAMPLE_W-1:0] rd_data;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state          <= S_IDLE;
        capturing      <= 1'b0;
        waveform_count <= 32'd0;
        wr_addr        <= 0;
        rd_addr        <= 0;
        cap_len_lat    <= 16'd0;
        samples_stored <= 16'd0;
        stream_cnt     <= 16'd0;
        last_sample    <= 1'b0;
        m_axis_tdata   <= 32'd0;
        m_axis_tvalid  <= 1'b0;
        m_axis_tlast   <= 1'b0;
        rd_data        <= 0;
    end else begin

        case (state)

            // ── IDLE: wait for trigger (NO tready check) ────
            S_IDLE: begin
                // Clear tvalid from previous frame's last beat
                if (m_axis_tvalid && m_axis_tready)
                    m_axis_tvalid <= 1'b0;

                if (trigger && capture_len > 0) begin
                    capturing      <= 1'b1;
                    cap_len_lat    <= capture_len;
                    samples_stored <= 16'd0;
                    wr_addr        <= 0;
                    state          <= S_CAPTURE;
                end
            end

            // ── CAPTURE: store samples into BRAM ────────────
            S_CAPTURE: begin
                if (pair_ready && samples_stored < cap_len_lat) begin
                    bram[wr_addr] <= {ch1_data, ch2_data, pulse_state};
                    wr_addr        <= wr_addr + 1;
                    samples_stored <= samples_stored + 16'd1;
                end

                // All samples collected → start streaming
                if (samples_stored >= cap_len_lat) begin
                    capturing  <= 1'b0;
                    rd_addr    <= 0;
                    stream_cnt <= cap_len_lat;
                    // Initiate first BRAM read (1-cycle latency)
                    rd_data    <= bram[0];
                    rd_addr    <= 1;
                    state      <= S_STREAM1;
                end
            end

            // ── STREAM1: present beat 1, wait for accept ────
            // Data format: {ch1[11:0], 4'b0, ch2[11:0], 3'b0, pulse_state}
            S_STREAM1: begin
                m_axis_tdata  <= {rd_data[24:13], 4'b0000,
                                  rd_data[12:1],  3'b000,
                                  rd_data[0]};
                m_axis_tvalid <= 1'b1;
                m_axis_tlast  <= 1'b0;
                last_sample   <= (stream_cnt <= 16'd1);

                if (m_axis_tvalid && m_axis_tready) begin
                    // Beat 1 accepted → present duplicate
                    state <= S_STREAM2;
                    if (stream_cnt <= 16'd1)
                        m_axis_tlast <= 1'b1;
                end
            end

            // ── STREAM2: duplicate beat, wait for accept ────
            S_STREAM2: begin
                // tdata unchanged, tvalid stays 1
                if (m_axis_tvalid && m_axis_tready) begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;

                    if (last_sample) begin
                        waveform_count <= waveform_count + 32'd1;
                        state          <= S_IDLE;
                    end else begin
                        stream_cnt <= stream_cnt - 16'd1;
                        // Read next sample from BRAM
                        rd_data    <= bram[rd_addr];
                        rd_addr    <= rd_addr + 1;
                        state      <= S_STREAM1;
                    end
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
