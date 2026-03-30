`timescale 1ns/1ps
// waveform_capture.v  (rev 8 — diagnostic timestamp in padding bits)
//
// Root cause of "dropped pair_ready" bug: pair_ready is a single-cycle pulse
// from xadc_drp_reader (~500 kHz, every ~200 clocks).  When the DMA deasserts
// tready during DDR burst writes, the old FSM was stuck waiting and missed
// incoming pair_ready pulses — samples were silently lost.
//
// Fix: a small synchronous FIFO (32 deep) buffers {ch1, ch2, pulse_state}
// on every pair_ready while capturing.  The AXI-Stream output FSM drains
// from the FIFO, decoupled from XADC timing.  DMA burst pauses (~16 beats)
// are fully absorbed.
//
// HP0 dual-beat workaround retained: each sample output TWICE on AXI-S.
//
// Rev 8: embed 7-bit timestamp (clk/2, ~50 MHz tick) in the 7 padding bits
// of each 32-bit DMA word.  Expected inter-sample delta ≈ 104 ticks at
// 480 kSPS.  Allows software to measure per-sample timing to diagnose
// variable pair_ready rate at capture start.

module waveform_capture (
    input  wire        clk,
    input  wire        rst_n,

    // Trigger: single-cycle pulse starts capture
    input  wire        trigger,

    // Pulse output state (embedded in capture data for diagnostics)
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

wire trig_rise = trigger;

// ── Prescaled timestamp counter (clk/2 ≈ 50 MHz) ────
reg [7:0] ts_prescale;
reg [6:0] ts_counter;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ts_prescale <= 8'd0;
        ts_counter  <= 7'd0;
    end else begin
        ts_prescale <= ts_prescale + 8'd1;
        if (ts_prescale[0])
            ts_counter <= ts_counter + 7'd1;
    end
end

// ── Sample FIFO (32 deep × 32 bits) ──────────────────
localparam FIFO_DEPTH = 32;
localparam FIFO_AW    = 5;
localparam FIFO_DW    = 32;  // {ch1[11:0], ch2[11:0], ts[6:0], pulse_state}

reg [FIFO_DW-1:0] fifo_mem [0:FIFO_DEPTH-1];
reg [FIFO_AW:0]   fifo_wr_ptr, fifo_rd_ptr;

wire fifo_empty = (fifo_wr_ptr == fifo_rd_ptr);
wire fifo_full  = (fifo_wr_ptr[FIFO_AW] != fifo_rd_ptr[FIFO_AW]) &&
                  (fifo_wr_ptr[FIFO_AW-1:0] == fifo_rd_ptr[FIFO_AW-1:0]);

wire fifo_wr_en = pair_ready & capturing & ~fifo_full;

always @(posedge clk) begin
    if (fifo_wr_en)
        fifo_mem[fifo_wr_ptr[FIFO_AW-1:0]] <= {ch1_data, ch2_data, ts_counter, pulse_state};
end

wire [FIFO_DW-1:0] fifo_rd_data = fifo_mem[fifo_rd_ptr[FIFO_AW-1:0]];

// ── Output FSM ────────────────────────────────────────
localparam S_IDLE  = 2'd0;
localparam S_POP   = 2'd1;
localparam S_BEAT1 = 2'd2;
localparam S_BEAT2 = 2'd3;

reg [1:0]  state;
reg [15:0] sample_cnt;
reg [15:0] samples_in;
reg [15:0] cap_len_lat;
reg        last_sample;

reg [FIFO_DW-1:0] sample_reg;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state          <= S_IDLE;
        sample_cnt     <= 16'd0;
        samples_in     <= 16'd0;
        m_axis_tdata   <= 32'd0;
        m_axis_tvalid  <= 1'b0;
        m_axis_tlast   <= 1'b0;
        capturing      <= 1'b0;
        waveform_count <= 32'd0;
        last_sample    <= 1'b0;
        sample_reg     <= 0;
        cap_len_lat    <= 16'd0;
        fifo_wr_ptr    <= 0;
        fifo_rd_ptr    <= 0;
    end else begin

        if (fifo_wr_en) begin
            fifo_wr_ptr <= fifo_wr_ptr + 1;
            samples_in  <= samples_in + 16'd1;
        end

        if (capturing && samples_in >= cap_len_lat)
            capturing <= 1'b0;

        case (state)
            S_IDLE: begin
                if (m_axis_tvalid && m_axis_tready)
                    m_axis_tvalid <= 1'b0;

                if (trig_rise && capture_len > 0 && m_axis_tready) begin
                    capturing   <= 1'b1;
                    sample_cnt  <= capture_len;
                    cap_len_lat <= capture_len;
                    samples_in  <= 16'd0;
                    fifo_wr_ptr <= 0;
                    fifo_rd_ptr <= 0;
                    state       <= S_POP;
                end
            end

            S_POP: begin
                if (!fifo_empty) begin
                    sample_reg  <= fifo_rd_data;
                    fifo_rd_ptr <= fifo_rd_ptr + 1;
                    last_sample <= (sample_cnt <= 16'd1);
                    state       <= S_BEAT1;
                end
            end

            // FIFO layout:  {ch1[11:0], ch2[11:0], ts[6:0], pulse_state}
            //                [31:20]    [19:8]     [7:1]    [0]
            // DMA word:     {ch1[11:0], ts[6:3],  ch2[11:0], ts[2:0], pulse_state}
            //                [31:20]    [19:16]   [15:4]     [3:1]    [0]
            S_BEAT1: begin
                m_axis_tdata  <= {sample_reg[31:20], sample_reg[7:4],
                                  sample_reg[19:8],  sample_reg[3:1],
                                  sample_reg[0]};
                m_axis_tvalid <= 1'b1;
                m_axis_tlast  <= 1'b0;
                if (m_axis_tvalid && m_axis_tready) begin
                    state <= S_BEAT2;
                    if (last_sample)
                        m_axis_tlast <= 1'b1;
                end
            end

            S_BEAT2: begin
                if (m_axis_tvalid && m_axis_tready) begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    if (last_sample) begin
                        waveform_count <= waveform_count + 32'd1;
                        capturing      <= 1'b0;
                        state          <= S_IDLE;
                    end else begin
                        sample_cnt <= sample_cnt - 16'd1;
                        state      <= S_POP;
                    end
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
