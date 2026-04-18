`timescale 1ns/1ps
// ad9226_capture.v
// Dual-channel AD9226 ADC interface with 25 MHz sample clock generation.
//
// Generates a 25 MHz clock output to both ADC chips.
// Captures 12-bit parallel data from each channel on the rising edge
// of the internal sample clock.
// Outputs pair_ready pulse when both channels have valid data.

module ad9226_capture (
    input  wire        clk,          // 100 MHz system clock
    input  wire        rst_n,

    // AD9226 Channel A
    input  wire [11:0] adc_a_data,   // 12-bit parallel data
    input  wire        adc_a_otr,    // over-range indicator

    // AD9226 Channel B
    input  wire [11:0] adc_b_data,   // 12-bit parallel data
    input  wire        adc_b_otr,    // over-range indicator

    // Clock output to both ADCs
    output wire        adc_clk,      // 25 MHz sample clock

    // Captured data outputs
    output reg  [11:0] ch1_data,     // latest channel A sample
    output reg  [11:0] ch2_data,     // latest channel B sample
    output reg         ch1_otr,      // channel A over-range
    output reg         ch2_otr,      // channel B over-range
    output reg         pair_ready    // pulse: both channels captured
);

// ── 25 MHz clock generation (100 MHz / 4) ──────────────────
reg [1:0] clk_div;
reg       adc_clk_reg;

always @(posedge clk) begin
    if (!rst_n) begin
        clk_div    <= 2'd0;
        adc_clk_reg <= 1'b0;
    end else begin
        clk_div <= clk_div + 2'd1;
        if (clk_div == 2'd1)
            adc_clk_reg <= 1'b1;
        else if (clk_div == 2'd3)
            adc_clk_reg <= 1'b0;
    end
end

assign adc_clk = adc_clk_reg;

// ── Data capture ───────────────────────────────────────────
// Sample ADC data on the falling edge of adc_clk (data stable after
// ADC's pipeline delay). In terms of clk, this is when clk_div == 3
// (just after adc_clk falls).

reg capture_tick;

always @(posedge clk) begin
    if (!rst_n) begin
        ch1_data    <= 12'd0;
        ch2_data    <= 12'd0;
        ch1_otr     <= 1'b0;
        ch2_otr     <= 1'b0;
        pair_ready  <= 1'b0;
        capture_tick <= 1'b0;
    end else begin
        capture_tick <= (clk_div == 2'd3);
        pair_ready  <= capture_tick;

        if (clk_div == 2'd3) begin
            ch1_data <= adc_a_data;
            ch2_data <= adc_b_data;
            ch1_otr  <= adc_a_otr;
            ch2_otr  <= adc_b_otr;
        end
    end
end

endmodule
