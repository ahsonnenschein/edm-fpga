`timescale 1ns/1ps
// edm_pulse_ctrl.v
// EDM Pulse State Machine
// Generates precise Ton/Toff pulse sequence.
// ton_cycles and toff_cycles are pre-scaled by software (us * 125).
// pulse_out goes HIGH during Ton, LOW during Toff.
// trigger is a single-cycle pulse at the rising edge of each Ton period.

module edm_pulse_ctrl (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        enable,
    input  wire [31:0] ton_cycles,     // Ton duration in clock cycles
    input  wire [31:0] toff_cycles,    // Toff duration in clock cycles
    output reg         pulse_out,
    output reg         trigger,        // 1-cycle pulse at TON start
    output reg  [31:0] pulse_count     // running count of pulses fired
);

localparam IDLE = 2'd0;
localparam TON  = 2'd1;
localparam TOFF = 2'd2;

reg [1:0]  state;
reg [31:0] counter;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state       <= IDLE;
        counter     <= 32'd0;
        pulse_out   <= 1'b0;
        trigger     <= 1'b0;
        pulse_count <= 32'd0;
    end else begin
        trigger <= 1'b0; // default: deasserted

        case (state)
            IDLE: begin
                pulse_out <= 1'b0;
                if (enable && ton_cycles > 0 && toff_cycles > 0) begin
                    state       <= TON;
                    counter     <= ton_cycles - 1;
                    pulse_out   <= 1'b1;
                    trigger     <= 1'b1;
                    pulse_count <= pulse_count + 1;
                end
            end

            TON: begin
                if (!enable) begin
                    state     <= IDLE;
                    pulse_out <= 1'b0;
                end else if (counter == 32'd0) begin
                    state     <= TOFF;
                    counter   <= toff_cycles - 1;
                    pulse_out <= 1'b0;
                end else begin
                    counter <= counter - 1;
                end
            end

            TOFF: begin
                if (!enable) begin
                    state <= IDLE;
                end else if (counter == 32'd0) begin
                    // Latch updated ton/toff at start of each new period
                    state       <= TON;
                    counter     <= ton_cycles - 1;
                    pulse_out   <= 1'b1;
                    trigger     <= 1'b1;
                    pulse_count <= pulse_count + 1;
                end else begin
                    counter <= counter - 1;
                end
            end

            default: state <= IDLE;
        endcase
    end
end

endmodule
