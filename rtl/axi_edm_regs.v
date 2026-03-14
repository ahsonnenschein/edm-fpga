`timescale 1ns/1ps
// axi_edm_regs.v
// AXI4-Lite slave register file for EDM controller.
//
// Register map (byte addresses, 32-bit words):
//   0x00  ton_cycles      RW  Ton duration in clock cycles (ton_us * 125)
//   0x04  toff_cycles     RW  Toff duration in clock cycles
//   0x08  enable          RW  bit[0]: 1=run, 0=stop
//   0x0C  capture_len     RW  Waveform capture length in samples
//   0x10  f_save          RW  bits[15:0]: fraction to save    (0-10000 = 0.00-100.00%)
//   0x14  f_display       RW  bits[15:0]: fraction to display (0-10000)
//   0x18  pulse_count     RO  Running count of pulses fired
//   0x1C  waveform_count  RO  Running count of waveforms captured

module axi_edm_regs #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 5   // covers 8 x 4-byte registers = 32 bytes
)(
    // AXI4-Lite slave
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

    // Control outputs to FPGA logic
    output reg  [31:0] ton_cycles,
    output reg  [31:0] toff_cycles,
    output reg         enable,
    output reg  [31:0] capture_len,
    output reg  [15:0] f_save,
    output reg  [15:0] f_display,

    // Status inputs (read-only registers)
    input  wire [31:0] pulse_count,
    input  wire [31:0] waveform_count
);

reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr;
reg [C_S_AXI_ADDR_WIDTH-1:0] axi_araddr;

// -------------------------------------------------------
// Write channel
// -------------------------------------------------------
always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN) begin
        S_AXI_AWREADY <= 1'b0;
        S_AXI_WREADY  <= 1'b0;
        S_AXI_BVALID  <= 1'b0;
        S_AXI_BRESP   <= 2'b00;
        axi_awaddr    <= 0;
        // Default register values
        ton_cycles    <= 32'd1250;   // 10 us * 125
        toff_cycles   <= 32'd11250;  // 90 us * 125
        enable        <= 1'b0;
        capture_len   <= 32'd2500;   // 2 * 10 us * 125
        f_save        <= 16'd100;    // 1.00%
        f_display     <= 16'd1000;   // 10.00%
    end else begin

        // AW handshake
        if (!S_AXI_AWREADY && S_AXI_AWVALID && S_AXI_WVALID) begin
            S_AXI_AWREADY <= 1'b1;
            axi_awaddr    <= S_AXI_AWADDR;
        end else begin
            S_AXI_AWREADY <= 1'b0;
        end

        // W handshake
        if (!S_AXI_WREADY && S_AXI_AWVALID && S_AXI_WVALID) begin
            S_AXI_WREADY <= 1'b1;
        end else begin
            S_AXI_WREADY <= 1'b0;
        end

        // Register write (word address = byte_addr[4:2])
        if (S_AXI_AWREADY && S_AXI_AWVALID && S_AXI_WREADY && S_AXI_WVALID) begin
            case (axi_awaddr[4:2])
                3'd0: ton_cycles  <= S_AXI_WDATA;
                3'd1: toff_cycles <= S_AXI_WDATA;
                3'd2: enable      <= S_AXI_WDATA[0];
                3'd3: capture_len <= S_AXI_WDATA;
                3'd4: f_save      <= S_AXI_WDATA[15:0];
                3'd5: f_display   <= S_AXI_WDATA[15:0];
                // 6, 7: read-only
                default: ;
            endcase
        end

        // B channel
        if (S_AXI_AWREADY && S_AXI_AWVALID && S_AXI_WREADY && S_AXI_WVALID && !S_AXI_BVALID) begin
            S_AXI_BVALID <= 1'b1;
            S_AXI_BRESP  <= 2'b00;
        end else if (S_AXI_BVALID && S_AXI_BREADY) begin
            S_AXI_BVALID <= 1'b0;
        end
    end
end

// -------------------------------------------------------
// Read channel
// -------------------------------------------------------
always @(posedge S_AXI_ACLK) begin
    if (!S_AXI_ARESETN) begin
        S_AXI_ARREADY <= 1'b0;
        S_AXI_RVALID  <= 1'b0;
        S_AXI_RRESP   <= 2'b00;
        S_AXI_RDATA   <= 32'd0;
        axi_araddr    <= 0;
    end else begin

        // AR handshake
        if (!S_AXI_ARREADY && S_AXI_ARVALID) begin
            S_AXI_ARREADY <= 1'b1;
            axi_araddr    <= S_AXI_ARADDR;
        end else begin
            S_AXI_ARREADY <= 1'b0;
        end

        // R channel
        if (S_AXI_ARREADY && S_AXI_ARVALID && !S_AXI_RVALID) begin
            S_AXI_RVALID <= 1'b1;
            S_AXI_RRESP  <= 2'b00;
            case (axi_araddr[4:2])
                3'd0: S_AXI_RDATA <= ton_cycles;
                3'd1: S_AXI_RDATA <= toff_cycles;
                3'd2: S_AXI_RDATA <= {31'd0, enable};
                3'd3: S_AXI_RDATA <= capture_len;
                3'd4: S_AXI_RDATA <= {16'd0, f_save};
                3'd5: S_AXI_RDATA <= {16'd0, f_display};
                3'd6: S_AXI_RDATA <= pulse_count;
                3'd7: S_AXI_RDATA <= waveform_count;
                default: S_AXI_RDATA <= 32'd0;
            endcase
        end else if (S_AXI_RVALID && S_AXI_RREADY) begin
            S_AXI_RVALID <= 1'b0;
        end
    end
end

endmodule
