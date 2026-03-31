`timescale 1ns/1ps
// waveform_capture.v  (rev 11 — decoupled BRAM capture with AXI-Lite readout)
//
// Two-phase capture, NO AXI DMA dependency:
//   Phase 1 (CAPTURE): trigger starts sampling into local BRAM.
//     Independent of m_axis_tready and DMA state.
//   Phase 2: Software reads BRAM via AXI-Lite register interface.
//
// waveform_count increments when BRAM capture completes.
// AXI-Stream output is kept for compatibility but not required.
// Max capture depth: 512 samples.

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

    // AXI4-Stream master (optional — kept for compatibility)
    output wire [31:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    output wire        m_axis_tlast,
    input  wire        m_axis_tready,

    // BRAM read port for AXI-Lite access
    input  wire [8:0]  bram_rd_addr,    // 0-511
    output wire [31:0] bram_rd_data,    // {ch1, 4'b0, ch2, 3'b0, pulse}

    output reg         capturing,
    output reg  [31:0] waveform_count
);

// ── Local BRAM buffer (512 × 25 bits) ────────────────
localparam MAX_DEPTH = 512;
localparam ADDR_W    = 9;
localparam SAMPLE_W  = 25;

reg [SAMPLE_W-1:0] bram [0:MAX_DEPTH-1];
reg [ADDR_W-1:0]   wr_addr;
reg [15:0]          cap_len_lat;
reg [15:0]          samples_stored;

// ── BRAM read port (for AXI-Lite) ────────────────────
wire [SAMPLE_W-1:0] rd_raw = bram[bram_rd_addr];
assign bram_rd_data = {rd_raw[24:13], 4'b0000,
                       rd_raw[12:1],  3'b000,
                       rd_raw[0]};

// ── AXI-Stream (no-op — tied off) ────────────────────
assign m_axis_tdata  = 32'd0;
assign m_axis_tvalid = 1'b0;
assign m_axis_tlast  = 1'b0;

// ── FSM ──────────────────────────────────────────────
localparam S_IDLE    = 1'd0;
localparam S_CAPTURE = 1'd1;

reg state;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state          <= S_IDLE;
        capturing      <= 1'b0;
        waveform_count <= 32'd0;
        wr_addr        <= 0;
        cap_len_lat    <= 16'd0;
        samples_stored <= 16'd0;
    end else begin
        case (state)

            S_IDLE: begin
                if (trigger && capture_len > 0) begin
                    capturing      <= 1'b1;
                    cap_len_lat    <= (capture_len > MAX_DEPTH) ?
                                      MAX_DEPTH[15:0] : capture_len;
                    samples_stored <= 16'd0;
                    wr_addr        <= 0;
                    state          <= S_CAPTURE;
                end
            end

            S_CAPTURE: begin
                if (pair_ready && samples_stored < cap_len_lat) begin
                    bram[wr_addr] <= {ch1_data, ch2_data, pulse_state};
                    wr_addr        <= wr_addr + 1;
                    samples_stored <= samples_stored + 16'd1;
                end

                if (samples_stored >= cap_len_lat) begin
                    capturing      <= 1'b0;
                    waveform_count <= waveform_count + 32'd1;
                    state          <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
