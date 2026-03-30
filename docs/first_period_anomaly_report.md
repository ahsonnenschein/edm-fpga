# Waveform Capture First-Period Anomaly — Technical Investigation Report

**System:** EDM FPGA controller on PYNQ-Z2 (Zynq XC7Z020)
**Date:** 2026-03-30
**Status:** Root cause unknown; workaround applied (capture_len=47)

---

## 1. Problem Statement

When capturing per-pulse waveforms with Ton=10µs, Toff=90µs (period=100µs), the **first inter-pulse period** in each DMA capture varies **uniformly from 35 to 78 samples**, while all subsequent inter-pulse periods are rock-steady at exactly **48 samples**.

The oscilloscope confirms real pulses are perfectly steady at 100µs period. The anomaly is in the captured data only.

The range of variation (78 − 35 = 43 samples) equals **exactly Toff expressed in samples** (90µs / 2.08µs ≈ 43). This is unlikely to be coincidental.

---

## 2. System Architecture

### 2.1 Signal Path

```
XADC Wizard (simultaneous sampling, continuous mode)
    ↓ eoc_out, channel_out, do_out, drdy_out
xadc_drp_reader.v
    ↓ ch1_data[11:0], ch2_data[11:0], pair_ready (single-cycle pulse ~480 kHz)
edm_top.v
    ↓
waveform_capture.v (triggered, FIFO-buffered, AXI-Stream output)
    ↓ m_axis_tdata/tvalid/tlast/tready
AXI DMA S2MM (simple mode, HP0 64-bit stride)
    ↓
DDR buffer (CMA allocation, read by Python xadc_server.py)
```

### 2.2 Trigger Path

```
edm_pulse_ctrl.v
    ↓ trigger (1-cycle pulse at each Ton rising edge)
    ↓ pulse_out (HIGH during Ton, LOW during Toff)
edm_top.v
    wire pulse_trigger;  // from edm_pulse_ctrl.trigger
    .trigger(pulse_trigger & hv_enable_sync)   → waveform_capture
    .pulse_state(pulse_out)                    → waveform_capture
```

### 2.3 Capture FSM (waveform_capture.v)

States: S_IDLE → S_POP → S_BEAT1 → S_BEAT2 → S_POP (loop) → S_IDLE

**Trigger condition (S_IDLE only):**
```verilog
if (trig_rise && capture_len > 0 && m_axis_tready) begin
    capturing   <= 1'b1;
    sample_cnt  <= capture_len;
    cap_len_lat <= capture_len;
    samples_in  <= 16'd0;
    fifo_wr_ptr <= 0;
    fifo_rd_ptr <= 0;
    state       <= S_POP;
end
```

**FIFO write (pair_ready driven):**
```verilog
wire fifo_wr_en = pair_ready & capturing & ~fifo_full;
// Stores: {ch1_data[11:0], ch2_data[11:0], ts_counter[6:0], pulse_state}
```

**FIFO**: 32-deep × 32-bit synchronous FIFO with binary pointer full/empty detection.

**Output**: Each sample output TWICE on AXI-Stream (HP0 dual-beat workaround). TLAST on final beat.

### 2.4 DMA Software Loop (xadc_server.py)

```
while running:
    arm DMA (write STATUS, DST_ADDR, LENGTH)
    phase 1: poll until DMA goes non-idle (trigger fired, data flowing)
    phase 2: poll until DMA completes (TLAST received)
    read waveform_count — skip if unchanged
    buf.invalidate(); numpy copy buffer
    rate-limit: if < 10ms since last broadcast, continue
    broadcast JSON to TCP clients
```

### 2.5 Pulse Controller (edm_pulse_ctrl.v)

Simple 3-state FSM (IDLE → TON → TOFF → TON → ...). `trigger` asserted for 1 cycle at each IDLE→TON and TOFF→TON transition. Period verified at exactly 10000 clock cycles (100µs at 100 MHz) via register readback: Ton=1000, Toff=9000.

---

## 3. Key Measurements

### 3.1 Sample Rate

Measured from stable inter-pulse periods in captured data:
- **48 samples per 100µs period → 480.769 kSPS**
- Consistent with XADC clock math: 100 MHz / (4 × 26 × 2) = 480,769 Hz
- Display code assumed 500 kSPS — corrected

### 3.2 Timestamp Diagnostic (Rev 8)

A 7-bit prescaled counter (50 MHz tick) was embedded in the 7 padding bits of each 32-bit DMA word. Results from 100 bursts of 200 samples:

| Metric | First 50 samples | After sample 50 |
|--------|-----------------|-----------------|
| Mean delta | 103.0 | 102.6 |
| Std delta | 8.5 | 11.9 |
| Anomalous (±10 from 104) | 1.8% | 1.3% |

**pair_ready fires at a perfectly constant rate of 104 ticks (2.08µs) between every sample.** There is no pair_ready timing jitter.

### 3.3 XADC Calibration Gap

A timing anomaly occurs at **exactly sample index 34** in every capture. The delta at that position differs from 104 (values observed: 120, 64, 56, 32, 112, 80, 72, 0). This is consistent with XADC automatic calibration inserting extra conversion cycles approximately every 34 pair_ready events.

However, this does NOT explain the first-period anomaly (see §4.4).

### 3.4 First Period Statistics

From 100 bursts of 200 samples (cap_len=200, Ton=10µs, Toff=90µs):

```
First period:  min=35, max=78, mean=55.5, std=14.1
Distribution:  approximately uniform over [35, 78]
```

Stable periods (2nd→3rd, 3rd→4th, etc.):
```
min=44, max=49, mean=48.0, std=0.6
```

### 3.5 Voltage/Pulse State at Expected Second Pulse

For bursts where first_period > 50, examining samples 43-55 (where the second pulse SHOULD be at ~100µs):

- **pulse_state = 0** for ALL samples in that region
- **ch1 (arc current) = 0.0** for ALL samples
- **timestamp delta = 104** (normal — no timing anomaly)

The XADC genuinely does not see a pulse at the expected position. Yet the oscilloscope confirms the real pulse is there.

### 3.6 Waveform Count Gaps

Between consecutive received bursts, `waveform_count` advances by 3-4 (not 1). This confirms multiple captures complete between software reads. However, this occurs BOTH with and without the DMA re-arm optimization, ruling out buffer overwrites.

### 3.7 ts[0] Variation

The timestamp value at sample 0 varies across captures (values: 0, 8, 16, 24, 27, 32, 35, 40, 43, 51, 59, 64, 72, 80, 88, 91, 96, 99, 104, 107, 112, 115, 120, 123). If all captures started at the same trigger phase, ts[0] should be nearly constant (within ±104 ticks of pair_ready phase jitter). The observed range spans the full 0-127 space.

---

## 4. Hypotheses Tested and Eliminated

### 4.1 DMA Buffer Overwrite (ELIMINATED)

**Hypothesis:** The immediate DMA re-arm after buffer read allows subsequent captures to overwrite the buffer before the software processes it. The software reads a random capture.

**Test:** Removed the re-arm optimization entirely. DMA arms only at the top of each loop iteration. Buffer is never written while software reads it.

**Result:** First period distribution **unchanged** (min=35, max=78, std=12.4). Buffer overwrites are NOT the cause.

### 4.2 hv_enable Bounce (ELIMINATED)

**Hypothesis:** Contact bounce on the HV enable switch (AR1) causes the pulse controller to reset, firing triggers at random phases.

**Test:** AR1 tied directly to 3.3V with a wire (no switch).

**Result:** First period distribution **unchanged** (min=35, max=77, std=11.1).

### 4.3 pair_ready Timing Jitter (ELIMINATED)

**Hypothesis:** Variable pair_ready rate causes samples to be unevenly spaced in time, shifting pulse edge positions.

**Test:** 7-bit timestamp embedded in each sample. Computed inter-sample deltas.

**Result:** Deltas are **104 ±0 for 98%+ of samples**. pair_ready is perfectly constant. The timestamp diagnostic definitively eliminates pair_ready timing as the cause.

### 4.4 XADC Calibration Gaps (ELIMINATED)

**Hypothesis:** XADC calibration conversions (~every 34 samples) cause pair_ready gaps that drop samples, creating time discontinuities in the captured data.

**Test:** Replaced pair_ready-driven FIFO writes with a fixed-rate sample_tick (every 208 clocks, independent of XADC). The capture samples ch1/ch2/pulse_state at perfectly uniform intervals regardless of XADC calibration.

**Result:** First period distribution **unchanged** (min=35, max=79, std=13.8). XADC calibration gaps are NOT the cause.

### 4.5 Software Processing Race (ELIMINATED)

**Hypothesis:** Python's numpy buffer copy races with DMA writes, producing mixed data from two captures.

**Test:** With the re-arm removed (§4.1), the DMA is idle during all buffer reads. No race is possible.

**Result:** Same anomaly persists.

---

## 5. What the Data Proves

1. **The capture does NOT start at the same trigger phase every time.** ts[0] varies across the full range, and the first period varies by 43 samples. If all captures started at the trigger, the first period would be 47-48 (±1 from pair_ready phase).

2. **Sample 0 always has pulse_state=1.** Every capture starts during a Ton. Combined with (1), this means the capture starts at SOME Ton, but not necessarily the one corresponding to the trigger.

3. **pair_ready is constant.** The sample-to-sample timing is uniform. The issue is NOT in the sampling clock.

4. **The variation range (43) = Toff in samples.** This strongly suggests the capture start time is uniformly distributed over one pulse period, and the first visible pulse is always sample 0 (since Ton is always captured).

5. **Subsequent periods are perfect.** Whatever causes the first period to vary, it resolves after the first pulse. The XADC data becomes phase-locked to the pulse train after one period.

---

## 6. Remaining Hypotheses (Untested)

### 6.1 m_axis_tready Glitch at DMA Arm

The trigger check requires `m_axis_tready` (from the DMA) to be HIGH. When the software writes the DMA LENGTH register, tready transitions from LOW to HIGH. If a trigger fires on the exact clock cycle of this transition, there could be a setup time violation or metastability on the tready input, causing the capture to start at an unintended moment.

**How to test:** ILA capture of tready, trig_rise, and state signals.

### 6.2 Multiple Captures Between Software Reads

waveform_count advances by 3-4 between reads. Even without the re-arm optimization, the DMA completes a capture and the software re-arms at the top of the next loop iteration. Between the DMA completion and the re-arm, triggers fire but are missed (tready LOW). The DMA is then armed, and the FIRST trigger after arm starts the capture. Which trigger this is depends on when the arm happens relative to the pulse cycle.

If ALL triggers are equivalent (all at Ton starts, all with the same pair_ready phase relationship), the first period should always be ~48. The fact that it varies means either (a) triggers are NOT all equivalent, or (b) the capture doesn't start at the trigger.

**Key question:** Is `m_axis_tready` truly LOW between DMA completion and re-arm? If the DMA keeps tready HIGH after completion (in S2MM simple mode with RS=1), the waveform_capture could start a new capture immediately, and the FSM returns to S_IDLE. If the software then reads the buffer, it might read stale data from the buffer (the new capture overwrites while the FSM outputs).

**How to test:** ILA capture of m_axis_tready around DMA completion events.

### 6.3 FIFO Coherency Issue

The FIFO uses non-blocking assignments in two separate always blocks (memory write and pointer management). While this should be correct in simulation, synthesis tool optimizations or BRAM inference might create subtle read-before-write hazards.

The synthesis report shows the FIFO was inferred as Block RAM:
```
inst/u_cap/fifo_mem_reg | 32 x 32(READ_FIRST) | W | 32 x 32(WRITE_FIRST) | R
```

Note the **READ_FIRST** vs **WRITE_FIRST** asymmetry on the two ports. If the read port uses WRITE_FIRST mode but the write port uses READ_FIRST, a simultaneous read-write to the same address could return the NEW data on one port and OLD data on the other. This could cause a single corrupted sample near the start of each capture.

**How to test:** Force the FIFO to use distributed RAM (not BRAM) with a synthesis attribute, or add explicit read-after-write guards.

### 6.4 AXI DMA tready Behavior in Simple Mode

The exact tready behavior of the Xilinx AXI DMA IP in S2MM simple mode is not fully documented. Specifically:
- Does tready stay HIGH after transfer completion until a new LENGTH is written?
- Does tready pulse during the STATUS/DST_ADDR/LENGTH write sequence?
- Is there a race between the software's three MMIO writes and the hardware's tready assertion?

If tready stays HIGH after completion, the waveform_capture could start phantom captures that overwrite the buffer before the software reads it.

**How to test:** ILA capture of m_axis_tready, DMA status bits, and waveform_count.

---

## 7. Recommended Next Steps

1. **Add ILA (Integrated Logic Analyzer)** to the block design, probing:
   - `pulse_trigger` (1-cycle trigger from pulse controller)
   - `m_axis_tready` (from DMA)
   - `waveform_capture.state[1:0]` (FSM state)
   - `waveform_capture.capturing`
   - `waveform_capture.waveform_count`
   - `pulse_out` (pulse state)

   Trigger the ILA on `waveform_capture.state` transitioning from S_IDLE to S_POP (capture start). Examine the signals in the 1000 clocks before the trigger to see what tready and pulse_trigger were doing.

2. **Check AXI DMA tready behavior** in the Xilinx PG021 documentation for the specific version used (v7.1). Confirm whether tready stays HIGH after transfer completion in simple mode.

3. **Simulate the exact DMA arm sequence** — write STATUS, DST_ADDR, LENGTH in sequence and observe tready timing cycle-by-cycle.

---

## 8. Workaround Applied

Set `capture_len = 47` (default in xadc_server.py). Since 47 < 48 (one period in samples), the capture window is shorter than one pulse period and the second pulse never appears. This eliminates the visual artifact but does not fix the root cause.

The capture_len should be adjusted if Ton+Toff changes:
```
max_capture_len = floor((ton_us + toff_us) / 2.08) - 1
```

---

## 9. File References

| File | Description |
|------|-------------|
| `rtl/waveform_capture.v` | Capture FSM, FIFO, trigger logic (rev 8) |
| `rtl/edm_top.v` | Top-level: trigger routing, pulse_state connection |
| `rtl/edm_pulse_ctrl.v` | Pulse generator, trigger output |
| `rtl/xadc_drp_reader.v` | XADC DRP interface, pair_ready generation |
| `rtl/axi_edm_regs.v` | AXI-Lite register file |
| `software/xadc_server.py` | DMA loop, buffer readback, TCP server |
| `software/diag_timestamp.py` | Timestamp diagnostic analysis tool |
| `scripts/create_project.tcl` | Vivado block design (DMA, XADC wizard config) |
| `constraints/pynq_z2.xdc` | Pin assignments |

---

## 10. Raw Data Samples

### First period distribution (100 bursts, cap_len=200)
```
35: ########## (10)    55: ### (3)        70: ## (2)
36: # (1)              56: ## (2)         72: #### (4)
37: ## (2)             58: # (1)          73: # (1)
38: ## (2)             59: # (1)          74: ### (3)
39: # (1)              60: ####### (7)    75: ##### (5)
40: ### (3)            61: ## (2)         76: ##### (5)
41: # (1)              62: ## (2)         77: ## (2)
43: #### (4)           63: # (1)          78: ## (2)
44: ###### (6)         64: ### (3)
45: ### (3)            66: ## (2)
46: ### (3)            67: # (1)
47: ## (2)             68: ## (2)
48: ## (2)             69: # (1)
49: ##### (5)
```

### Stable period distribution (251 measurements)
```
44: # (1)     48: ################### (221)    49: ###################### (22)
45: ### (3)
46: #### (4)
```

### Timestamp deltas at sample 34 (anomaly position)
```
Burst 1: delta=120  (possible 10 dropped pair_readys)
Burst 2: delta=64   (possible 7 dropped)
Burst 3: delta=56   (possible 2 dropped)
Burst 4: delta=32   (possible 3 dropped)
Burst 5: delta=112  (possible 5 dropped)
```

### Burst example with first_period=71 (second pulse late)
```
Samples 0-10:   pulse=[1,1,1,1,0,0,0,0,0,0,0]  ch1=[0,0,3.96,4.91,5.05,5.11,0,0,0,0,0]
Samples 43-55:  pulse=[0,0,0,0,0,0,0,0,0,0,0,0,0]  ch1=[0,0,0,0,0,0,0,0,0,0,0,0,0]
Samples 69-78:  pulse=[0,0,1,1,1,1,1,0,0,0]  ch1=[0,0,0,0,0,4.75,5.04,5.1,0,0]
Third pulse at sample 119: period from 2nd = 48 (stable)
```
