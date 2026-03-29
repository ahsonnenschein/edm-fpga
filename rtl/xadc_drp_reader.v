`timescale 1ns/1ps
// xadc_drp_reader.v  (rev 6 — correct simultaneous-mode channel filtering)
//
// XADC Wizard: simultaneous sampling mode, sequencer has two steps:
//   Step 1: ADC-A=VP/VN  + ADC-B=VAUX8  → EOC, channel_out=0x03
//   Step 2: ADC-A=VAUX1  + ADC-B=VAUX9  → EOC, channel_out=0x11
//
// We trigger DRP reads ONLY on the VAUX1 EOC (channel_out==0x11).
// At that point:
//   • DRP addr 0x03 holds VP/VN result from Step 1 (~1 µs stale, acceptable)
//   • DRP addr 0x11 holds VAUX1 result, freshly written by Step 2
// This yields truly matched (VP/VN, VAUX1) pairs at 500 kHz.
//
// Filtering on channel_out avoids:
//   - Reading stale VAUX9 (0x19) which is unconnected → ch2=0 bug
//   - Double pair_ready rate (2× EOCs per XADC cycle) → wrong timescale bug
//
// Each DRP read takes ~2 DCLK cycles for DRDY (100 MHz = 20 ns each),
// so both reads complete in ~80 ns — well within the 2 µs EOC interval.
//
// temp_data is not updated (temperature channel is disabled in this mode).

module xadc_drp_reader (
    input  wire        clk,
    input  wire        rst_n,

    // DRP outputs from XADC Wizard (ENABLE_DRP mode)
    input  wire [4:0]  channel_out,   // XADC channel indicator at EOC
    input  wire        eoc_out,       // end-of-conversion pulse (1 cycle)
    input  wire [15:0] do_out,        // DRP data output (valid when drdy_out=1)
    input  wire        drdy_out,      // DRP data ready pulse

    // DRP inputs to XADC Wizard
    output reg  [6:0]  daddr_in,      // DRP read address
    output reg         den_in,        // DRP enable (1 cycle read strobe)
    output wire        dwe_in,        // tie 0 — read only
    output wire [15:0] di_in,         // tie 0 — read only

    // Decoded outputs
    output reg  [11:0] ch1_data,      // VP/VN  (DRP addr 0x03)
    output reg  [11:0] ch2_data,      // VAUX1  (DRP addr 0x11)
    output reg  [11:0] temp_data,     // not updated (temp channel disabled)

    // Pulses when a fresh (ch1, ch2) pair is ready — 500 kHz
    output reg         pair_ready
);

assign dwe_in = 1'b0;
assign di_in  = 16'h0;

localparam ADDR_CH1  = 7'h03;   // VP/VN result register (ADC-A)
localparam ADDR_CH2  = 7'h11;   // VAUX1 result register (ADC-A, Step 2)
localparam CH2_EOC   = 5'h11;   // channel_out value when Step-2 EOC fires (VAUX1=0x11)

localparam S_IDLE  = 3'd0;
localparam S_READ1 = 3'd1;   // DEN asserted for ch1
localparam S_WAIT1 = 3'd2;   // waiting for DRDY ch1
localparam S_READ2 = 3'd3;   // DEN asserted for ch2
localparam S_WAIT2 = 3'd4;   // waiting for DRDY ch2 → fire pair_ready

reg [2:0] state;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state      <= S_IDLE;
        daddr_in   <= 7'd0;
        den_in     <= 1'b0;
        ch1_data   <= 12'd0;
        ch2_data   <= 12'd0;
        temp_data  <= 12'd0;
        pair_ready <= 1'b0;
    end else begin
        den_in     <= 1'b0;   // deasserted by default every cycle
        pair_ready <= 1'b0;

        case (state)
            S_IDLE: begin
                // Only trigger on VAUX1 EOC (Step 2); skip VP/VN EOC (Step 1).
                if (eoc_out && channel_out == CH2_EOC) begin
                    daddr_in <= ADDR_CH1;
                    den_in   <= 1'b1;
                    state    <= S_READ1;
                end
            end

            S_READ1: begin
                // DEN was high last cycle; deasserted by default above.
                state <= S_WAIT1;
            end

            S_WAIT1: begin
                if (drdy_out) begin
                    ch1_data <= do_out[15:4];
                    daddr_in <= ADDR_CH2;
                    den_in   <= 1'b1;
                    state    <= S_READ2;
                end
            end

            S_READ2: begin
                state <= S_WAIT2;
            end

            S_WAIT2: begin
                if (drdy_out) begin
                    ch2_data   <= do_out[15:4];
                    pair_ready <= 1'b1;
                    state      <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
