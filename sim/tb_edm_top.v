// tb_edm_top.v
// Testbench for EDM FPGA controller (edm_top)
//
// Uses short pulse counts for simulation speed:
//   ton_cycles  = 10 (= 80ns @ 125MHz, represents 10us in real use)
//   toff_cycles = 20
//   capture_len = 20 (= 2 * ton_cycles)
//
// Tests:
//   1. AXI-Lite register write and readback
//   2. Pulse timing: ton/toff state machine
//   3. Waveform capture: trigger, AXI-Stream output, TLAST

`timescale 1ns/1ps

module tb_edm_top;

// -------------------------------------------------------
// Parameters
// -------------------------------------------------------
localparam CLK_PERIOD  = 8;     // 125 MHz = 8ns
localparam TON_CYCLES  = 10;
localparam TOFF_CYCLES = 20;
localparam CAP_LEN     = 20;    // 2 * TON_CYCLES
localparam F_SAVE      = 10000; // 100% — capture every waveform in sim
localparam F_DISPLAY   = 10000;

// AXI register byte addresses
localparam ADDR_TON     = 5'h00;
localparam ADDR_TOFF    = 5'h04;
localparam ADDR_ENABLE  = 5'h08;
localparam ADDR_CAPLEN  = 5'h0C;
localparam ADDR_FSAVE   = 5'h10;
localparam ADDR_FDISP   = 5'h14;
localparam ADDR_PCNT    = 5'h18;
localparam ADDR_WCNT    = 5'h1C;

// -------------------------------------------------------
// DUT signals
// -------------------------------------------------------
reg         clk;
reg         rst_n;

// AXI-Lite
reg  [4:0]  awaddr;
reg  [2:0]  awprot  = 0;
reg         awvalid = 0;
wire        awready;
reg  [31:0] wdata   = 0;
reg  [3:0]  wstrb   = 4'hF;
reg         wvalid  = 0;
wire        wready;
wire [1:0]  bresp;
wire        bvalid;
reg         bready  = 1;
reg  [4:0]  araddr;
reg  [2:0]  arprot  = 0;
reg         arvalid = 0;
wire        arready;
wire [31:0] rdata;
wire [1:0]  rresp;
wire        rvalid;
reg         rready  = 1;

// AXI-Stream
wire [31:0] axis_tdata;
wire        axis_tvalid;
wire        axis_tlast;
reg         axis_tready = 1;  // always ready (sink accepts all data)

// ADC — ramp pattern for easy verification
reg  [13:0] adc_ch1;
reg  [13:0] adc_ch2;

// Outputs
wire        pulse_out;
wire [7:0]  led;

// -------------------------------------------------------
// DUT instantiation
// -------------------------------------------------------
edm_top #(
    .C_S_AXI_DATA_WIDTH(32),
    .C_S_AXI_ADDR_WIDTH(5)
) dut (
    .S_AXI_ACLK     (clk),
    .S_AXI_ARESETN  (rst_n),
    .S_AXI_AWADDR   (awaddr),
    .S_AXI_AWPROT   (awprot),
    .S_AXI_AWVALID  (awvalid),
    .S_AXI_AWREADY  (awready),
    .S_AXI_WDATA    (wdata),
    .S_AXI_WSTRB    (wstrb),
    .S_AXI_WVALID   (wvalid),
    .S_AXI_WREADY   (wready),
    .S_AXI_BRESP    (bresp),
    .S_AXI_BVALID   (bvalid),
    .S_AXI_BREADY   (bready),
    .S_AXI_ARADDR   (araddr),
    .S_AXI_ARPROT   (arprot),
    .S_AXI_ARVALID  (arvalid),
    .S_AXI_ARREADY  (arready),
    .S_AXI_RDATA    (rdata),
    .S_AXI_RRESP    (rresp),
    .S_AXI_RVALID   (rvalid),
    .S_AXI_RREADY   (rready),
    .m_axis_tdata   (axis_tdata),
    .m_axis_tvalid  (axis_tvalid),
    .m_axis_tlast   (axis_tlast),
    .m_axis_tready  (axis_tready),
    .adc_ch1_i      (adc_ch1),
    .adc_ch2_i      (adc_ch2),
    .pulse_out      (pulse_out),
    .led            (led)
);

// -------------------------------------------------------
// Clock generation: 125 MHz
// -------------------------------------------------------
initial clk = 0;
always #(CLK_PERIOD/2) clk = ~clk;

// -------------------------------------------------------
// ADC stimulus: incrementing ramp on both channels
// -------------------------------------------------------
always @(posedge clk) begin
    adc_ch1 <= adc_ch1 + 1;
    adc_ch2 <= adc_ch2 + 3;
end

// -------------------------------------------------------
// Waveform dump
// -------------------------------------------------------
initial begin
    $dumpfile("tb_edm_top.vcd");
    $dumpvars(0, tb_edm_top);
end

// -------------------------------------------------------
// Test tasks
// -------------------------------------------------------

// AXI-Lite write
task axi_write;
    input [4:0]  addr;
    input [31:0] data;
    begin
        @(posedge clk); #1;
        awaddr  = addr;
        awvalid = 1;
        wdata   = data;
        wvalid  = 1;
        // Wait for both handshakes
        fork
            begin wait(awready); @(posedge clk); #1; awvalid = 0; end
            begin wait(wready);  @(posedge clk); #1; wvalid  = 0; end
        join
        wait(bvalid);
        @(posedge clk); #1;
    end
endtask

// AXI-Lite read
task axi_read;
    input  [4:0]  addr;
    output [31:0] data;
    begin
        @(posedge clk); #1;
        araddr  = addr;
        arvalid = 1;
        wait(arready);
        @(posedge clk); #1;
        arvalid = 0;
        wait(rvalid);
        data = rdata;
        @(posedge clk); #1;
    end
endtask

// -------------------------------------------------------
// Test variables
// -------------------------------------------------------
integer errors = 0;
reg [31:0] rd_val;
integer pulse_rise_time, pulse_fall_time, ton_meas, toff_meas;
integer waveform_samples;
integer i;

// -------------------------------------------------------
// Main test sequence
// -------------------------------------------------------
initial begin
    $display("=== EDM Controller Simulation ===");

    // Reset
    rst_n = 0;
    adc_ch1 = 14'd0;
    adc_ch2 = 14'd100;
    repeat(10) @(posedge clk);
    rst_n = 1;
    repeat(5) @(posedge clk);

    // --------------------------------------------------
    // Test 1: AXI-Lite register write and readback
    // --------------------------------------------------
    $display("\n--- Test 1: AXI-Lite register write/readback ---");

    axi_write(ADDR_TON,    TON_CYCLES);
    axi_write(ADDR_TOFF,   TOFF_CYCLES);
    axi_write(ADDR_CAPLEN, CAP_LEN);
    axi_write(ADDR_FSAVE,  F_SAVE);
    axi_write(ADDR_FDISP,  F_DISPLAY);

    axi_read(ADDR_TON,    rd_val);
    if (rd_val !== TON_CYCLES) begin
        $display("FAIL ton_cycles: expected %0d got %0d", TON_CYCLES, rd_val);
        errors = errors + 1;
    end else $display("PASS ton_cycles = %0d", rd_val);

    axi_read(ADDR_TOFF,   rd_val);
    if (rd_val !== TOFF_CYCLES) begin
        $display("FAIL toff_cycles: expected %0d got %0d", TOFF_CYCLES, rd_val);
        errors = errors + 1;
    end else $display("PASS toff_cycles = %0d", rd_val);

    axi_read(ADDR_CAPLEN, rd_val);
    if (rd_val !== CAP_LEN) begin
        $display("FAIL capture_len: expected %0d got %0d", CAP_LEN, rd_val);
        errors = errors + 1;
    end else $display("PASS capture_len = %0d", rd_val);

    axi_read(ADDR_FSAVE,  rd_val);
    if (rd_val !== F_SAVE) begin
        $display("FAIL f_save: expected %0d got %0d", F_SAVE, rd_val);
        errors = errors + 1;
    end else $display("PASS f_save = %0d", rd_val);

    // --------------------------------------------------
    // Test 2: Pulse timing
    // --------------------------------------------------
    $display("\n--- Test 2: Pulse timing (ton=%0d toff=%0d cycles) ---",
             TON_CYCLES, TOFF_CYCLES);

    // Enable pulses
    axi_write(ADDR_ENABLE, 1);

    // Wait for first rising edge of pulse_out
    @(posedge pulse_out);
    pulse_rise_time = $time;
    $display("Pulse HIGH at %0t", $time);

    // Wait for falling edge
    @(negedge pulse_out);
    pulse_fall_time = $time;
    ton_meas = (pulse_fall_time - pulse_rise_time) / CLK_PERIOD;
    $display("Pulse LOW  at %0t  (Ton = %0d cycles)", $time, ton_meas);

    if (ton_meas !== TON_CYCLES) begin
        $display("FAIL Ton: expected %0d cycles got %0d", TON_CYCLES, ton_meas);
        errors = errors + 1;
    end else $display("PASS Ton = %0d cycles", ton_meas);

    // Wait for second rising edge (end of Toff)
    @(posedge pulse_out);
    toff_meas = ($time - pulse_fall_time) / CLK_PERIOD;
    $display("Pulse HIGH at %0t  (Toff = %0d cycles)", $time, toff_meas);

    if (toff_meas !== TOFF_CYCLES) begin
        $display("FAIL Toff: expected %0d cycles got %0d", TOFF_CYCLES, toff_meas);
        errors = errors + 1;
    end else $display("PASS Toff = %0d cycles", toff_meas);

    // Check pulse_count after 2 pulses
    @(posedge pulse_out);
    @(negedge pulse_out);
    repeat(2) @(posedge clk);
    axi_read(ADDR_PCNT, rd_val);
    $display("pulse_count = %0d (expect 3)", rd_val);
    if (rd_val < 3) begin
        $display("FAIL pulse_count too low");
        errors = errors + 1;
    end else $display("PASS pulse_count >= 3");

    // --------------------------------------------------
    // Test 3: Waveform capture
    // --------------------------------------------------
    $display("\n--- Test 3: Waveform capture ---");

    // Count AXI-Stream samples until TLAST
    waveform_samples = 0;
    // Wait for next trigger (start of pulse)
    @(posedge dut.u_capture.trigger);
    $display("Trigger received at %0t", $time);

    // Count samples until TLAST (bounded loop)
    for (i = 0; i < CAP_LEN * 4; i = i + 1) begin
        @(posedge clk);
        if (axis_tvalid && axis_tready) begin
            waveform_samples = waveform_samples + 1;
            if (axis_tlast) begin
                $display("TLAST at sample %0d, tdata=0x%08X", waveform_samples, axis_tdata);
                i = CAP_LEN * 4; // exit loop
            end
        end
    end

    if (waveform_samples !== CAP_LEN) begin
        $display("FAIL capture_len: expected %0d samples got %0d", CAP_LEN, waveform_samples);
        errors = errors + 1;
    end else $display("PASS capture_len = %0d samples", waveform_samples);

    // Check waveform_count incremented
    repeat(4) @(posedge clk);
    axi_read(ADDR_WCNT, rd_val);
    $display("waveform_count = %0d (expect >= 1)", rd_val);
    if (rd_val < 1) begin
        $display("FAIL waveform_count");
        errors = errors + 1;
    end else $display("PASS waveform_count = %0d", rd_val);

    // --------------------------------------------------
    // Test 4: Disable stops pulses
    // --------------------------------------------------
    $display("\n--- Test 4: Disable ---");
    axi_write(ADDR_ENABLE, 0);
    repeat(TOFF_CYCLES + TON_CYCLES + 10) @(posedge clk);
    if (pulse_out !== 0) begin
        $display("FAIL: pulse_out still HIGH after disable");
        errors = errors + 1;
    end else $display("PASS: pulse_out LOW after disable");

    // --------------------------------------------------
    // Summary
    // --------------------------------------------------
    $display("\n=================================");
    if (errors == 0)
        $display("ALL TESTS PASSED");
    else
        $display("FAILED: %0d error(s)", errors);
    $display("=================================\n");

    $finish;
end

// Timeout watchdog
initial begin
    #5_000_000; // 5ms sim time
    $display("TIMEOUT: simulation exceeded 5ms");
    $finish;
end

endmodule
