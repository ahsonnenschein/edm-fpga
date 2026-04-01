`timescale 1ns/1ps
// xadc_drp_reader.v  (rev 15 — channel_out-gated reads, no register-clear hazard)
//
// CONFIRMED XADC behaviour on this board (from temp_data diagnostic):
//   channel_out alternates: 5'h03 (VP/VN) → 5'h16 (VAUX6) → 5'h03 → ...
//   Two EOC pulses per XADC cycle, ~500 kHz each.
//
// ROOT CAUSE of "every other sample zero" in revs 12-14:
//   The XADC clears result register 0x03 at the START of each VP/VN conversion,
//   not at the end.  The VAUX6 EOC fires while VP/VN is converting, so reading
//   0x03 at VAUX6-EOC time returns 0.  Phase-alternating and read-both approaches
//   all hit this window on every other EOC.
//
// FIX: Only read each register when channel_out confirms that channel just
//      finished converting (register is guaranteed valid):
//
//   channel_out==5'h03  →  read 0x03 → store ch1_data
//   channel_out==5'h16  →  read 0x16 → store ch2_data, fire pair_ready
//   all other channel_out values → ignored
//
// pair_ready fires at the VAUX6-EOC rate (~500 kHz).
// ch1_data is one XADC cycle stale relative to ch2_data — acceptable (~2 µs).

module xadc_drp_reader (
    input  wire        clk,
    input  wire        rst_n,

    // DRP outputs from XADC Wizard
    input  wire [4:0]  channel_out,
    input  wire        eoc_out,
    input  wire [15:0] do_out,
    input  wire        drdy_out,

    // DRP inputs to XADC Wizard
    output reg  [6:0]  daddr_in,
    output reg         den_in,
    output wire        dwe_in,
    output wire [15:0] di_in,

    // Decoded outputs
    output reg  [11:0] ch1_data,    // VP/VN result (DRP 0x03), updated at VP/VN EOC
    output reg  [11:0] ch2_data,    // VAUX6 result (DRP 0x16), updated at VAUX6 EOC
    output reg  [11:0] temp_data,   // channel_out at last EOC (diagnostic)

    output reg         pair_ready   // fires at VAUX6-EOC rate (~500 kHz)
);

assign dwe_in = 1'b0;
assign di_in  = 16'h0;

localparam ADDR_CH1  = 7'h03;   // VP/VN result register
localparam ADDR_CH2  = 7'h16;   // VAUX6 result register (J1 A2)
localparam CH_VP_VN  = 5'h03;   // channel_out code for VP/VN conversion done
localparam CH_VAUX6  = 5'h16;   // channel_out code for VAUX6 conversion done

localparam S_IDLE  = 3'd0;
localparam S_READ  = 3'd1;   // DEN asserted for one cycle
localparam S_WAIT  = 3'd2;   // waiting for DRDY

// which result to store after DRDY
localparam DEST_CH1 = 1'b0;
localparam DEST_CH2 = 1'b1;

reg [2:0] state;
reg       dest;   // 0 = store into ch1_data, 1 = store into ch2_data + fire pair_ready

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state      <= S_IDLE;
        dest       <= DEST_CH1;
        daddr_in   <= 7'd0;
        den_in     <= 1'b0;
        ch1_data   <= 12'd0;
        ch2_data   <= 12'd0;
        temp_data  <= 12'd0;
        pair_ready <= 1'b0;
    end else begin
        den_in     <= 1'b0;
        pair_ready <= 1'b0;

        case (state)
            S_IDLE: begin
                if (eoc_out) begin
                    temp_data <= {7'd0, channel_out};
                    if (channel_out == CH_VP_VN) begin
                        // VP/VN conversion just finished — register 0x03 is valid now
                        daddr_in <= ADDR_CH1;
                        den_in   <= 1'b1;
                        dest     <= DEST_CH1;
                        state    <= S_READ;
                    end else if (channel_out == CH_VAUX6) begin
                        // VAUX6 conversion just finished — register 0x16 is valid now
                        daddr_in <= ADDR_CH2;
                        den_in   <= 1'b1;
                        dest     <= DEST_CH2;
                        state    <= S_READ;
                    end
                    // all other channel_out codes (calibration etc.) — ignore
                end
            end

            S_READ: begin
                // DEN was high last cycle; deasserted by default above.
                state <= S_WAIT;
            end

            S_WAIT: begin
                if (drdy_out) begin
                    if (dest == DEST_CH1) begin
                        ch1_data <= do_out[15:4];
                    end else begin
                        ch2_data   <= do_out[15:4];
                        pair_ready <= 1'b1;
                    end
                    state <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule
