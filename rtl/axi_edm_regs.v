`timescale 1ns/1ps
// axi_edm_regs.v
// AXI4-Lite slave register file for EDM controller.
//
// Register map (byte addresses, 32-bit words):
//   0x000  ton_cycles      RW  Ton in clock cycles
//   0x004  toff_cycles     RW  Toff in clock cycles
//   0x008  enable          RW  bit[0]: 1=run, 0=stop
//   0x00C  pulse_count     RO  Running count of pulses fired
//   0x010  hv_enable       RO  bit[0]: operator HV switch state
//   0x014  capture_len     RW  Waveform pairs to capture per pulse
//   0x018  waveform_count  RO  Number of waveforms captured since reset
//   0x01C  xadc_ch1_raw    RO  Latest CH1 12-bit value
//   0x020  xadc_ch2_raw    RO  Latest CH2 12-bit value
//   0x024  xadc_temp_raw   RO  Latest temperature 12-bit value
//   0x800-0xFFC  waveform BRAM  RO  Captured samples (up to 512 words)

module axi_edm_regs #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 12   // 4KB address space
)(
    input  wire                             S_AXI_ACLK,
    input  wire                             S_AXI_ARESETN,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]   S_AXI_AWADDR,
    input  wire [2:0]                       S_AXI_AWPROT,
    input  wire                             S_AXI_AWVALID,
    output reg                              S_AXI_AWREADY,
    input  wire [C_S_AXI_DATA_WIDTH-1:0]   S_AXI_WDATA,
    input  wire [3:0]                       S_AXI_WSTRB,
    input  wire                             S_AXI_WVALID,
    output reg                              S_AXI_WREADY,
    output reg  [1:0]                       S_AXI_BRESP,
    output reg                              S_AXI_BVALID,
    input  wire                             S_AXI_BREADY,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]   S_AXI_ARADDR,
    input  wire [2:0]                       S_AXI_ARPROT,
    input  wire                             S_AXI_ARVALID,
    output reg                              S_AXI_ARREADY,
    output reg  [C_S_AXI_DATA_WIDTH-1:0]   S_AXI_RDATA,
    output reg  [1:0]                       S_AXI_RRESP,
    output reg                              S_AXI_RVALID,
    input  wire                             S_AXI_RREADY,

    // Control outputs
    output reg  [31:0] ton_cycles,
    output reg  [31:0] toff_cycles,
    output reg         enable,
    output reg  [15:0] capture_len,

    // Status inputs
    input  wire [31:0] pulse_count,
    input  wire        hv_enable_in,
    input  wire [31:0] waveform_count,

    // XADC latched values
    input  wire [11:0] xadc_ch1_raw,
    input  wire [11:0] xadc_ch2_raw,
    input  wire [11:0] xadc_temp_raw,

    // Waveform BRAM read port
    output wire [8:0]  bram_rd_addr,
    input  wire [31:0] bram_rd_data
);

reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr;
reg [C_S_AXI_ADDR_WIDTH-1:0] axi_araddr;

// BRAM address from AXI read address: bits [10:2] when bit 11 is set
assign bram_rd_addr = axi_araddr[10:2];

// ── Write channel ──────────────────────────────────────
always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN) begin
        S_AXI_AWREADY <= 1'b0;
        S_AXI_WREADY  <= 1'b0;
        S_AXI_BVALID  <= 1'b0;
        S_AXI_BRESP   <= 2'b00;
        axi_awaddr    <= 0;
        ton_cycles    <= 32'd1000;
        toff_cycles   <= 32'd9000;
        enable        <= 1'b0;
        capture_len   <= 16'd100;
    end else begin
        if (!S_AXI_AWREADY && S_AXI_AWVALID && S_AXI_WVALID) begin
            S_AXI_AWREADY <= 1'b1;
            axi_awaddr    <= S_AXI_AWADDR;
        end else S_AXI_AWREADY <= 1'b0;

        if (!S_AXI_WREADY && S_AXI_AWVALID && S_AXI_WVALID)
            S_AXI_WREADY <= 1'b1;
        else
            S_AXI_WREADY <= 1'b0;

        if (S_AXI_AWREADY && S_AXI_AWVALID && S_AXI_WREADY && S_AXI_WVALID) begin
            // Only control registers are writable (address < 0x800)
            if (!axi_awaddr[11]) begin
                case (axi_awaddr[5:2])
                    4'd0: ton_cycles  <= S_AXI_WDATA;
                    4'd1: toff_cycles <= S_AXI_WDATA;
                    4'd2: enable      <= S_AXI_WDATA[0];
                    4'd5: capture_len <= S_AXI_WDATA[15:0];
                    default: ;
                endcase
            end
        end

        if (S_AXI_AWREADY && S_AXI_AWVALID && S_AXI_WREADY && S_AXI_WVALID && !S_AXI_BVALID) begin
            S_AXI_BVALID <= 1'b1;
            S_AXI_BRESP  <= 2'b00;
        end else if (S_AXI_BVALID && S_AXI_BREADY)
            S_AXI_BVALID <= 1'b0;
    end
end

// ── Read channel ───────────────────────────────────────
always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN) begin
        S_AXI_ARREADY <= 1'b0;
        S_AXI_RVALID  <= 1'b0;
        S_AXI_RRESP   <= 2'b00;
        S_AXI_RDATA   <= 32'd0;
        axi_araddr    <= 0;
    end else begin
        if (!S_AXI_ARREADY && S_AXI_ARVALID) begin
            S_AXI_ARREADY <= 1'b1;
            axi_araddr    <= S_AXI_ARADDR;
        end else S_AXI_ARREADY <= 1'b0;

        if (S_AXI_ARREADY && S_AXI_ARVALID && !S_AXI_RVALID) begin
            S_AXI_RVALID <= 1'b1;
            S_AXI_RRESP  <= 2'b00;

            if (axi_araddr[11]) begin
                // Address >= 0x800: waveform BRAM data
                S_AXI_RDATA <= bram_rd_data;
            end else begin
                // Address < 0x800: control/status registers
                case (axi_araddr[5:2])
                    4'd0:  S_AXI_RDATA <= ton_cycles;
                    4'd1:  S_AXI_RDATA <= toff_cycles;
                    4'd2:  S_AXI_RDATA <= {31'd0, enable};
                    4'd3:  S_AXI_RDATA <= pulse_count;
                    4'd4:  S_AXI_RDATA <= {31'd0, hv_enable_in};
                    4'd5:  S_AXI_RDATA <= {16'd0, capture_len};
                    4'd6:  S_AXI_RDATA <= waveform_count;
                    4'd7:  S_AXI_RDATA <= {20'd0, xadc_ch1_raw};
                    4'd8:  S_AXI_RDATA <= {20'd0, xadc_ch2_raw};
                    4'd9:  S_AXI_RDATA <= {20'd0, xadc_temp_raw};
                    default: S_AXI_RDATA <= 32'd0;
                endcase
            end
        end else if (S_AXI_RVALID && S_AXI_RREADY)
            S_AXI_RVALID <= 1'b0;
    end
end

endmodule
