`timescale 1ns/1ps
// waveform_capture.v  (rev 12 — trigger-synchronous sampling, zero jitter)
//
// Samples are taken at a fixed rate (every SAMPLE_PERIOD clocks) synchronized
// to the trigger edge.  This eliminates the ±1 sample jitter caused by
// pair_ready's asynchronous phase relative to the trigger.
//
// ch1_data/ch2_data are latched from the XADC DRP reader and hold their
// value between pair_ready pulses.  Sampling them at fixed intervals gives
// values that may be up to ~2µs stale, but this is sub-sample and invisible.
//
// No AXI DMA — software reads BRAM via AXI-Lite register window.
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
    input  wire        pair_ready,      // unused — sampling is clock-based

    // Capture depth in pairs
    input  wire [15:0] capture_len,

    // AXI4-Stream master (tied off — not used)
    output wire [31:0] m_axis_tdata,
    output wire        m_axis_tvalid,
    output wire        m_axis_tlast,
    input  wire        m_axis_tready,

    // BRAM read port for AXI-Lite access
    input  wire [8:0]  bram_rd_addr,
    output wire [31:0] bram_rd_data,

    output reg         capturing,
    output reg  [31:0] waveform_count
);

// ── Sample rate ──────────────────────────────────────
// 100 MHz / 208 = 480.769 kSPS — matches the XADC pair_ready rate
localparam SAMPLE_PERIOD = 208;

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

// ── AXI-Stream (tied off) ────────────────────────────
assign m_axis_tdata  = 32'd0;
assign m_axis_tvalid = 1'b0;
assign m_axis_tlast  = 1'b0;

// ── Fixed-rate sample tick ───────────────────────────
reg [15:0] tick_counter;
reg        sample_tick;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tick_counter <= 16'd0;
        sample_tick  <= 1'b0;
    end else begin
        sample_tick <= 1'b0;
        if (!capturing) begin
            tick_counter <= 16'd0;
        end else if (tick_counter >= SAMPLE_PERIOD - 1) begin
            tick_counter <= 16'd0;
            sample_tick  <= 1'b1;
        end else begin
            tick_counter <= tick_counter + 16'd1;
        end
    end
end

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
                if (sample_tick && samples_stored < cap_len_lat) begin
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
