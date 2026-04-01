# EDM FPGA Controller — PYNQ-Z2

FPGA-based EDM (Electrical Discharge Machining) pulse controller running on the **PYNQ-Z2** (Zynq-7020).

- Generates precise Ton/Toff pulse sequences from the FPGA fabric (PL side)
- Simultaneous 480 kSPS per channel XADC sampling of gap voltage and arc current
- Per-pulse waveform capture via decoupled BRAM + AXI-Lite readout (no DMA)
- Per-pulse gap voltage averaging in PL for real-time adaptive feed control
- Adaptive feed parameter AF1 = (Vset − Vavg) / Vavg exposed via Modbus TCP for LinuxCNC
- Safety interlock: pulse output is gated by an operator HV enable switch
- Warning lamp outputs (green / orange / red) reflect system state
- Board-side TCP server streams 200 Hz status, per-pulse waveforms, and gap statistics
- PC operator console with 50-trace persistence display, histograms, and DPH8909 PSU control
- Modbus TCP server for LinuxCNC HAL integration (mb2hal)

---

## Hardware

| Item | Detail |
|------|--------|
| Board | PYNQ-Z2 |
| SoC | Xilinx Zynq-7020 (XC7Z020-1CLG400C) |
| PL clock | 100 MHz (FCLK0 from PS) |
| ADC | On-chip XADC, simultaneous sampling, 480 kSPS per channel, 12-bit |
| CH1 | Arc current — VP/VN differential input (opto-isolated shunt sense) |
| CH2 | Gap voltage — VAUXP6/VAUXN6 (A2) via on-board ÷5 divider |
| Pulse output | Arduino AR0 (T14) → GEDM pulse board |
| HV enable input | Arduino AR1 (U12) ← operator toggle switch |
| Green lamp | Arduino AR2 (U13) — HV off |
| Orange lamp | Arduino AR3 (V13) — HV on, sparks off |
| Red lamp | Arduino AR4 (V15) — sparks running |
| Status LEDs | LD0–LD3 (R14, P14, N16, M14) |
| PSU serial | Pmod B pin 1 (TX, W14) / pin 2 (RX, Y14) → DPH8909 TTL UART via MMIO UART1 |

---

## Wiring

### Analog — XADC header (4-pin connector on PYNQ-Z2)

| Pin label | Connect to |
|-----------|------------|
| VP | Probe divider output + |
| VN | Probe divider output − / GND |
| GND | Board GND |
| XVREF | Leave unconnected (internal reference used) |

CH1 scaling: `CH1_DIVIDER = 3.0` in `xadc_server.py` — adjust to match your resistor divider ratio.

### Analog — Arduino analog header J1 (A0–A5)

| Board label | Signal | Connect to |
|-------------|--------|------------|
| A2 | VAUX6+ | Gap voltage probe + (Hantek HT8050 output) |
| A1 | VAUX6− | Gap voltage probe − / GND |

### Digital — Arduino header J4, pins AR0–AR7 (3.3 V LVCMOS)

The PYNQ-Z2 labels Arduino digital pins as `AR0`–`AR13` (not `D0`–`D13`).

| Board label | Direction | Signal | Connect to |
|-------------|-----------|--------|------------|
| AR0 | OUT | `pulse_out` | GEDM pulseboard trigger in |
| AR1 | IN | `hv_enable` | HV enable switch (high = enabled; pull to GND when off) |
| AR2 | OUT | `lamp_green` | HFET module green lamp |
| AR3 | OUT | `lamp_orange` | HFET module orange lamp |
| AR4 | OUT | `lamp_red` | HFET module red lamp |

> All digital I/O is 3.3 V.  Use level shifters if the GEDM pulseboard or HFET module require 5 V logic.  Never drive AR1 above 3.3 V.

### Serial — Pmod B header (3.3 V)

| Pmod B pin | Signal | Connect to |
|------------|--------|------------|
| Pin 1 (JB1_P, W14) | UART1 TX → | DPH8909 RX |
| Pin 2 (JB1_N, Y14) | UART1 RX ← | DPH8909 TX |
| Pin 5 or 11 (GND) | GND | DPH8909 GND |

Use the **TTL version** of the DPH8909 — connects directly with no USB adapter.

### No external wiring needed
- **LD0–LD3** — on-board LEDs driven by firmware status bits

---

## Repository Layout

```
edm-fpga/
├── rtl/
│   ├── edm_top.v            Top-level — HV interlock, lamp logic, AXI + XADC wiring
│   ├── edm_pulse_ctrl.v     Ton/Toff state machine, pulse counter
│   ├── axi_edm_regs.v       AXI4-Lite register file
│   ├── xadc_drp_reader.v    Simultaneous-sampling XADC DRP reader (1 MSPS per channel)
│   └── waveform_capture.v   Per-pulse triggered capture → AXI4-Stream → DMA
├── sim/
│   └── tb_edm_top.v         Top-level testbench
├── constraints/
│   └── pynq_z2.xdc          Pin assignments — Arduino header, LEDs
├── scripts/
│   └── create_project.tcl   Full Vivado build: block design → bitstream
├── software/
│   ├── xadc_server.py       Board-side TCP server (port 5006)
│   ├── operator_console.py  PC-side PySide6 operator GUI
│   ├── modbus_server.py     Modbus TCP server for LinuxCNC HAL (port 502)
│   └── waveform_manager.py  Waveform file utilities
├── edm_pynq.bit             Generated bitstream (deploy to board)
└── edm_pynq.hwh             Hardware handoff file (required by PYNQ overlay)
```

---

## FPGA Design

The block design (`scripts/create_project.tcl`) connects:

```
Zynq PS (ARM)
    ├── AXI GP0 Master
    │       └── AXI Interconnect
    │               ├── M00 → edm_ctrl (RTL) @ 0x43C00000  4 KB
    │               └── M01 → AXI DMA        @ 0x40400000  64 KB
    │                           └── S2MM → AXI Protocol Converter → PS HP0 → DDR
    └── AXI HP0 Slave  ←── AXI DMA burst writes (waveform data)

PL fabric
    XADC Wizard (ENABLE_DRP, simultaneous sampling)
        ├── ADC-A → VP/VN          (CH1 arc current)
        └── ADC-B → VAUXP6/VAUXN6 (CH2 gap voltage)
            │   both at 1 MSPS, one EOC per pair
            ▼
    xadc_drp_reader  (two DRP reads per EOC: addr 0x03 → CH1, addr 0x16 → CH2)
            │   pair_ready pulse at 500 kSPS
            ▼
    waveform_capture (triggered on pulse_out rising edge, captures capture_len samples)
            │   AXI4-Stream with TLAST
            ▼
    AXI DMA S_AXIS_S2MM → DDR
```

**`edm_top.v`** wraps the pulse controller, register file, DRP reader, and waveform capture.  A 2-FF synchroniser moves the `hv_enable` input into the 100 MHz clock domain.  The pulse output is AND-gated with `hv_enable_sync` — sparks are physically impossible while HV is off.

### Lamp logic

| Condition | Green | Orange | Red |
|-----------|-------|--------|-----|
| HV off | ON | off | off |
| HV on, sparks off | off | ON | off |
| HV on, sparks running | off | off | ON |

### XADC simultaneous sampling

`xadc_drp_reader.v` (rev 15) reads each channel's DRP result register only when `channel_out` confirms that channel just finished converting:

- `channel_out == 0x03` (VP/VN EOC) → read DRP address `0x03` → store `ch1_data`
- `channel_out == 0x16` (VAUX6 EOC) → read DRP address `0x16` → store `ch2_data` + fire `pair_ready`

`pair_ready` fires at the VAUX6-EOC rate (~500 kHz).  CH1 is one XADC cycle stale relative to CH2 (~2 µs) — acceptable for EDM monitoring.

---

## Register Map

### EDM Control Registers — base `0x43C00000`

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| 0x00 | `ton_cycles` | RW | Ton in clock cycles (write µs × 100 for 100 MHz clock) |
| 0x04 | `toff_cycles` | RW | Toff in clock cycles |
| 0x08 | `enable` | RW | bit[0]: 1 = run, 0 = stop |
| 0x0C | `pulse_count` | RO | Running count of completed pulses |
| 0x10 | `hv_enable` | RO | bit[0]: operator HV switch state (synchronised) |
| 0x14 | `capture_len` | RW | Samples to capture per pulse (1–512, default 100) |
| 0x18 | `waveform_count` | RO | Count of completed burst captures |
| 0x1C | `xadc_ch1` | RO | Latest CH1 12-bit raw (latched from DRP reader) |
| 0x20 | `xadc_ch2` | RO | Latest CH2 12-bit raw |
| 0x24 | `xadc_temp` | RO | Temperature 12-bit raw (diagnostic) |
| 0x28 | `gap_sum` | RO | Sum of CH2 samples during last Ton (for per-pulse avg) |
| 0x2C | `gap_count` | RO | Number of CH2 samples in gap_sum |
| 0x800–0xFFC | `waveform BRAM` | RO | Captured samples (up to 512 words) |

Software computes per-pulse gap average: `gap_avg = gap_sum / gap_count / 4096 * CH2_RANGE`

### Adaptive Feed Control

The adaptive feed parameter **AF1** enables LinuxCNC to adjust feed rate based on real-time gap voltage:

```
AF1 = (Vset - Vavg) / Vavg
```

- **AF1 ≈ 0**: gap voltage matches setpoint — normal feed
- **AF1 > 0**: gap voltage too low (short circuit risk) — slow down
- **AF1 < 0**: gap voltage too high (open gap) — speed up

AF1 is exposed as Modbus input register IR[5] (×1000, signed 16-bit) for LinuxCNC via mb2hal.

---

## Building the Bitstream

Requires Vivado 2023.2.

```bash
cd /home/sonnensn/edm-fpga
/tools/Xilinx/Vivado/2023.2/bin/vivado -mode batch -source scripts/create_project.tcl
```

Output: `edm_pynq.bit` (copied to repo root automatically).

Copy the hardware handoff file:

```bash
cp ../edm_vivado/edm_pynq.gen/sources_1/bd/edm_system/hw_handoff/edm_system.hwh \
   edm_pynq.hwh
```

---

## Deployment to PYNQ-Z2

```bash
# From the host PC (board default IP 192.168.2.99, password: xilinx)
scp edm_pynq.bit edm_pynq.hwh  xilinx@192.168.2.99:/home/xilinx/jupyter_notebooks/
scp software/xadc_server.py    xilinx@192.168.2.99:/home/xilinx/
```

---

## Data Server (`xadc_server.py`)

Runs on the board's ARM CPU.  Loads the PYNQ overlay, then produces two interleaved JSON streams over TCP port 5006.

**Start on board:**

```bash
sudo XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 /home/xilinx/xadc_server.py
```

### Status frames — 200 Hz

```json
{"type": "status", "ts": 1234.5678, "ch1": 23.4, "ch2": 0.81, "temp": 43.6,
 "pulse_count": 1042, "hv_enable": 1, "enable": 1,
 "psu_ok": true, "psu_vout": 48.0, "psu_iout": 0.012}
```

| Field | Description |
|-------|-------------|
| `ch1` | Arc current (V) — GEDM current sense on VP/VN |
| `ch2` | Gap voltage (V) — Hantek differential probe on VAUX6 |
| `temp` | Zynq die temperature (°C) |
| `pulse_count` | Cumulative pulse count |
| `hv_enable` | Operator HV switch state |
| `psu_ok` | Whether DPH8909 is connected on `/dev/ttyPS1` |
| `psu_vout` / `psu_iout` | Measured PSU output (updated at 1 Hz) |

### Burst frames — one per pulse

```json
{"type": "burst", "waveform_count": 57,
 "ch1": [23.1, 22.8, ...], "ch2": [0.80, 0.81, ...]}
```

`ch1` / `ch2` are lists of `capture_len // 2` voltage samples at **500 kSPS per channel**.  Default `capture_len` = 500 raw DMA words → 250 paired samples.  Set automatically by the console on Apply to cover one Ton + Toff cycle.

### Commands (send as JSON + newline)

```json
{"cmd": "set_ton",          "value": 20}
{"cmd": "set_toff",         "value": 80}
{"cmd": "set_enable",       "value": 1}
{"cmd": "set_capture_len",  "value": 100}
{"cmd": "set_psu_voltage",  "value": 48.0}
{"cmd": "set_psu_current",  "value": 2.0}
{"cmd": "set_psu_output",   "value": 1}
{"cmd": "get_params"}
```

`set_ton` / `set_toff` values are in **microseconds**.

---

## Operator Console (`operator_console.py`)

PySide6 GUI running on the host PC.

```bash
pip install PySide6 matplotlib numpy
python3 software/operator_console.py
```

### Features

- **Connection**: enter board IP, click Connect.
- **Parameters**: set Ton / Toff in µs, click **Apply** — sends values to FPGA and auto-sets `capture_len = Ton + Toff` (one complete pulse cycle per burst, max 1024).
- **Pulse overlay**: shows the last N burst waveforms overlaid (CH1 arc current, CH2 gap voltage).  The **Show 1 in every N pulses** spinbox controls which pulses appear in the overlay (default: 1 in 1000).  Every pulse feeds the histogram regardless.
- **Histogram**: rolling 1-minute distribution of per-pulse mean gap voltage and arc current.
- **Gap Voltage (DPH8909)**: set voltage and current limit, toggle output on/off.  Commands route over TCP to the board; the board drives the PSU directly via `/dev/ttyPS1` (Pmod B UART).  Measured V/I readback updates at 1 Hz.

### DPH8909 PSU wiring

The DPH8909 **TTL version** connects directly to the PYNQ-Z2 Pmod B header — no USB adapter needed.

| DPH8909 pin | PYNQ-Z2 Pmod B |
|-------------|----------------|
| GND | Pin 5 or 11 (GND) |
| RX | Pin 1 (JB1_P / UART TX — `/dev/ttyPS1`) |
| TX | Pin 2 (JB1_N / UART RX — `/dev/ttyPS1`) |

The server uses the Juntek simple ASCII protocol at 9600 baud (device default).  Check menu items **6-bd** (baud) and **7-Ad** (address, must be `01`) on the PSU front panel if it does not respond.

---

## Modbus TCP Server (`modbus_server.py`)

Provides a Modbus TCP interface (port 502) for LinuxCNC HAL integration via `mb2hal`.

```bash
sudo XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 /home/xilinx/modbus_server.py
```

### Holding Registers (FC3/FC16)

| Register | Name | Default | Description |
|----------|------|---------|-------------|
| 0 | `Ton_us` | 10 | Ton in microseconds |
| 1 | `Toff_us` | 90 | Toff in microseconds |
| 2 | `Enable` | 0 | 0 = stop, 1 = run |
| 3 | `Gap_setpoint` | 2048 | Target gap voltage (0–4095 raw ADC counts) |
| 4 | `Short_threshold` | 200 | Gap below this = short circuit |
| 5 | `Open_threshold` | 3500 | Gap above this = open gap |

### Input Registers (FC4)

| Register | Name | Description |
|----------|------|-------------|
| 0 | `Pulse_count_lo` | Lower 16 bits of pulse count |
| 1 | `Pulse_count_hi` | Upper 16 bits of pulse count |
| 2 | `HV_enable` | Operator HV switch state |
| 3 | `Gap_voltage_avg` | Per-pulse gap voltage average (0–4095 raw, from PL accumulator) |
| 4 | `Arc_ok` | 1 = gap in normal arc range, 0 = short or open |
| 5 | `AF1_x1000` | Adaptive feed parameter × 1000 (signed 16-bit): `(Vset−Vavg)/Vavg` |

**AF1** is the primary signal for LinuxCNC adaptive feed control via `mb2hal`.  Map it to a HAL pin and connect to `adaptive-feed` for real-time feed rate adjustment based on gap conditions.

---

## Software Dependencies

On the host PC:
```bash
pip install PySide6 matplotlib numpy
```

On the board (available in PYNQ venv):
```
pynq  numpy  pyserial
```

---

## Status

- [x] RTL design complete — Zynq-7020, 100 MHz
- [x] Vivado block design and TCL build script
- [x] XADC simultaneous sampling — 1 MSPS per channel (VP/VN + VAUXP1/VAUXN1)
- [x] xadc_drp_reader.v — two DRP reads per Step-2 EOC, pair_ready at 500 kSPS
- [x] waveform_capture.v — triggered burst capture to AXI4-Stream
- [x] AXI DMA S2MM — burst waveforms transferred to DDR, polled by server
- [x] HV enable switch with 2-FF synchroniser
- [x] Warning lamp logic (green / orange / red)
- [x] AXI register map — ton, toff, enable, pulse_count, hv_enable, capture_len, waveform_count, XADC CH1/CH2
- [x] Bitstream built and verified (Vivado 2023.2, exit 0, no errors)
- [x] xadc_server.py — 200 Hz status stream + per-pulse burst stream over TCP
- [x] Operator console — burst overlay, pulse decimation, rolling histogram, N-pulse running avg gap voltage
- [x] DPH8909 gap voltage PSU — controlled from board UART via TCP commands
- [x] Modbus TCP server — LinuxCNC HAL integration
- [x] Sample FIFO in waveform_capture.v — eliminates dropped pair_ready events during DMA backpressure
- [ ] Hardware bring-up and calibration (CH1 probe divider ratio, CH2 scaling)
- [ ] Verify /dev/ttyPS1 available on board and DPH8909 communication
- [ ] LinuxCNC HAL configuration and adaptive feed tuning

---

## Lessons Learned

Hard-won debugging notes from bring-up on the PYNQ-Z2.

### 1. Vivado `apply_bd_automation` silently overrides PS7 clock settings

Setting `PCW_FPGA0_PERIPHERAL_FREQMHZ` on the PS7 block **before** calling `apply_bd_automation` is useless — the automation rule reconfigures the PLL and overwrites the frequency.  Our bitstream booted at 62.5 MHz instead of 100 MHz, causing pulse timing to be 1.6× too slow.

**Fix:** Re-apply the FCLK setting **after** `apply_bd_automation`:
```tcl
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 ...
set_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100.000000} [get_bd_cells ps7]
```
Even with this TCL fix, the bitstream still booted at 62.5 MHz in our case.  The reliable workaround is a runtime fix in Python:
```python
from pynq import Clocks
if abs(Clocks.fclk0_mhz - 100.0) > 1.0:
    Clocks.fclk0_mhz = 100.0
```

### 2. XADC channel naming: VAUX1 vs VAUX6

The PYNQ-Z2 Arduino analog header **A2 maps to VAUX6** (pins K14/J14), not VAUX1.  The Vivado XADC Wizard property is `CHANNEL_ENABLE_VAUXP6_VAUXN6`.  Using the wrong channel silently produces zero readings with no synthesis or implementation errors — the XADC simply samples an unconnected channel.

### 3. XADC clears result registers at the START of conversion, not the end

Reading a channel's DRP result register while that channel is being converted returns zero.  In simultaneous sampling mode, VP/VN and VAUX6 conversions overlap in time.  Reading address `0x03` during a VAUX6 EOC (while VP/VN is mid-conversion) returns zero on every other sample.

**Fix:** Only read each register when `channel_out` confirms that specific channel just finished converting.  This guarantees the result register is valid.

### 4. DMA backpressure drops single-cycle pulses — use a FIFO

`pair_ready` from the XADC DRP reader is a single-cycle pulse at ~500 kHz (~200 clock cycles apart).  The AXI DMA deasserts `tready` during DDR burst writes (~16 beats).  If the capture FSM is waiting for `tready` when `pair_ready` fires, the sample is permanently lost.

Symptoms: pulse edges appeared at random positions in the capture buffer; the first few samples captured fine (DMA internal FIFO had room), then samples dropped during the first DDR burst write.

**Fix:** A 32-deep synchronous FIFO between the XADC reader and the AXI-Stream output FSM.  The FIFO absorbs DMA burst pauses completely — at 200 clocks between samples, even short FIFOs work.

### 5. Zynq HP0 port drops every other 32-bit write

Even when `PCW_S_AXI_HP0_DATA_WIDTH` is set to 32, the HP0 port internally operates at 64-bit width and drops (or aliases) odd-addressed 32-bit writes.

**Workaround:** Output each sample **twice** on the AXI4-Stream.  The DMA receives 2N words; HP0 commits only even-addressed ones.  Software reads the buffer at stride 2: `words[::2]`.  DMA transfer length is `capture_len * 8` (×2 for dual-beat, ×4 for 32-bit word size, but HP0 64-bit stride means ×8 total).

### 6. Changing `capture_len` mid-capture causes DMA hang

If the AXI register `capture_len` is changed while a waveform capture is in progress, the FIFO fill count and the output FSM's sample counter disagree on how many samples to expect.  The FSM waits forever for samples that will never arrive, and the DMA never sees TLAST.

**Fix:** Latch `capture_len` into a local register at trigger time.  The latched value is used for both the FIFO fill limit and the output sample count — immune to register changes during capture.

### 7. PYNQ-Z2 VP/VN has a 140 Ohm + 1 nF RC filter; A0–A5 do not

The dedicated VP/VN differential input on the PYNQ-Z2 has a 140 Ohm series resistor and 1 nF differential capacitor on the board (visible in the schematic, confirmed in the user manual).  This creates a low-pass filter with tau ~ 140 ns, which severely attenuates fast edges (10 µs pulse rise/fall becomes a slow exponential ramp taking ~20 samples at 500 kSPS).

The Arduino analog inputs A0–A5 (VAUX channels) do **not** have this RC filter — they have only a series resistor with no capacitor, giving much faster response.

**Implication:** Route the fast-changing signal (gap voltage via differential probe) to A2/VAUX6, and the slower signal (current sense) to VP/VN.

### 8. PYNQ overlay load crashes the SSH session

Loading a PYNQ overlay (`Overlay("edm_pynq.bit")`) on the PYNQ-Z2 reliably kills the SSH session that runs it — the PL reconfiguration disrupts the PS network stack momentarily.

**Workaround:** Use a bash script with `nohup`/`disown`:
```bash
#!/bin/bash
export XILINX_XRT=/usr
nohup python3 -u xadc_server.py > xadc_server.log 2>&1 &
disown
```
Run via SSH (`sudo bash /tmp/restart_edm.sh`).  The SSH session drops, but the Python process survives.  Check the log from a new SSH session after ~5 seconds.

### 9. `XILINX_XRT=/usr` is required for PYNQ overlay loading

Without `export XILINX_XRT=/usr`, the PYNQ overlay loader fails with cryptic errors.  This environment variable is set in the board's default login profile but is lost when running via `sudo` or `nohup` from a script.  Always export it explicitly in wrapper scripts.

### 10. Vivado IP cache must be cleared when modifying block design RTL modules

When RTL source files for a block design module reference (e.g. `edm_top`, `waveform_capture`) are modified, `reset_run synth_1` does NOT re-synthesize the module.  Vivado reuses the OOC synthesis result from its IP cache (`edm_pynq.cache/ip/`).  The only way to force re-synthesis is to **delete the IP cache** before rebuilding.

### 11. Never set XADC calibration parameters in simultaneous sampling mode

Setting `CONFIG.ADC_OFFSET_AND_GAIN_CALIBRATION` or `CONFIG.SENSOR_OFFSET_AND_GAIN_CALIBRATION` on the XADC Wizard in simultaneous sampling mode produces warnings ("disabled parameter … ignored"), but **silently corrupts** the generated IP.  The resulting XADC produces no valid data — temperature reads −270 °C, all channel values are zero, and `pair_ready` never fires.

### 12. XADC actual sample rate is 480 kSPS, not 500 kSPS

With DCLK=100 MHz, divider=4, and 2 channels (VP/VN + VAUX6) sequenced through DRP:
```
pair_rate = 100 MHz / (4 × 26 cycles × 2 channels) = 480.769 kSPS
```
The display time axis must use 480769, not 500000, for accurate pulse timing.  Additionally, XADC automatic calibration inserts extra conversion cycles approximately every 34 samples, creating periodic timing gaps in the `pair_ready` stream.

### 13. Overlay load can crash the board — avoid accessing PL before load

Loading a PYNQ overlay reprograms the PL, destroying all AXI interconnects.  If any PS→PL AXI transaction is in flight (stale DMA, cached MMIO), the bus error crashes the kernel.  Do NOT access any PL-mapped address (0x40000000+) before the overlay is loaded — even a "pre-reset" write to the DMA causes a bus error on fresh boot when the PL is unprogrammed.

On reboot, the overlay load usually succeeds on the first try.  If it fails with EIO, the FPGA manager enters an error state that requires a power cycle.

### 14. PS UART1 via device tree overlay is unreliable — use MMIO instead

The Linux device tree overlay for PS UART1 (`/dev/ttyPS1`) fails with `uart_add_one_port() err=-22` because the PYNQ base device tree has an incomplete UART1 node (missing `reg` property).  Rather than fixing the DT, access the UART1 registers directly via MMIO at `0xE0001000`.  Enable clocks first through the SLCR (unlock `0xDF0D`, set UART1 ref clock bit in `0x154`, AMBA clock bit 21 in `0x12C`, clear reset bits in `0x228`).

### 15. DPH8909 PSU: use `w20` combined command for voltage + current

Sending separate `w10` (voltage) and `w11` (current) commands back-to-back at 9600 baud causes the second command to be dropped — the PSU is still processing the first when the second arrives.  Use the combined `w20` command which sets both in a single frame:
```
:01w20=5000,1500,\r\n    → 50.00 V, 1.500 A
```

### 16. AXI DMA interrupt MUST be connected for PYNQ compatibility

PYNQ's `Overlay` class auto-detects the AXI DMA IP from the HWH file and assigns its `pynq.lib.dma.DMA` driver.  This driver **takes exclusive ownership** of the DMA registers — raw MMIO writes to the DMA control register (0x40400030) are silently ignored.  The driver uses interrupt-based completion detection via `IRQ_F2P`.

If the DMA interrupt (`s2mm_introut`) is NOT connected to `ps7/IRQ_F2P`, the PYNQ DMA driver hangs on `wait()` and the DMA is completely unusable (both through PYNQ API and raw MMIO).

**Fix:** In `create_project.tcl`, enable fabric interrupts and connect the DMA interrupt:
```tcl
set_property CONFIG.PCW_USE_FABRIC_INTERRUPT {1} [get_bd_cells ps7]
set_property CONFIG.PCW_IRQ_F2P_INTR {1} [get_bd_cells ps7]
connect_bd_net [get_bd_pins axi_dma_0/s2mm_introut] [get_bd_pins ps7/IRQ_F2P]
```

Without this, the DMA control register reads back 0x00010006 regardless of what is written, `waveform_count` stays at 0, and no burst data is produced.

### 17. Module reference AXI-Stream needs X_INTERFACE attributes for clock association

When using `create_bd_cell -type module -reference` for RTL modules in Vivado, the block design cannot set `ASSOCIATED_BUSIF` on clock pins (the property is read-only for module references).  Without clock association, IPI warns "AXI interface pin M_AXIS is not associated to any clock pin."

**Fix:** Add Verilog attributes directly in the RTL:
```verilog
(* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI:M_AXIS, ASSOCIATED_RESET S_AXI_ARESETN" *)
input wire S_AXI_ACLK,

(* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
output wire [31:0] m_axis_tdata,
```
This tells Vivado at the HDL level which bus interfaces share which clock, eliminating the warning and ensuring proper timing constraints.

### 18. Never qualify trigger acceptance on `m_axis_tready` — decouple capture from DMA

The original `waveform_capture.v` started capture only when `trig_rise && m_axis_tready`.  This couples the capture start to DMA readiness, meaning the capture begins on "the first trigger where tready happens to be HIGH" — which is a random trigger relative to when software armed the DMA.  This produced a uniform first-period distribution with a range of exactly Toff in samples.

**Fix:** Decouple trigger detection from DMA streaming:
1. `trig_rise` alone starts capture into a local BRAM buffer (no tready check)
2. After `capture_len` samples are stored, assert `frame_ready`
3. Only then begin AXI-Stream output to DMA
4. Add a software-visible `arm_capture` one-shot register so only the intended trigger fires

This also fixes PYNQ DMA compatibility — PYNQ's driver holds the DMA in reset until `transfer()` is called, so `tready` is never HIGH for raw MMIO.  With a decoupled architecture, `tready` timing is irrelevant to capture start.

### 19. `PCW_USE_FABRIC_INTERRUPT` cannot be set via TCL `set_property` — use GUI

Setting `CONFIG.PCW_USE_FABRIC_INTERRUPT {1}` on the PS7 via TCL appears to succeed (the property reads back as 1), but the PS7 IP does not regenerate its `IRQ_F2P` port.  `validate_bd_design` and `save_bd_design` do not help.  The HWH always shows `PCW_USE_FABRIC_INTERRUPT = 0` and the IRQ pin is absent from the synthesized netlist.

**Fix:** Open the block design in the Vivado GUI, double-click the PS7, navigate to Interrupts → Fabric Interrupts → enable `IRQ_F2P[15:0]`, click OK.  This is the only reliable way to enable fabric interrupts on the Zynq PS7 IP.

### 20. PYNQ Overlay auto-detects AXI DMA and blocks raw MMIO

When `Overlay()` parses the HWH and finds an IP with `VLNV=xilinx.com:ip:axi_dma:*`, it installs the `pynq.lib.dma.DMA` driver which takes exclusive ownership of the DMA registers via UIO.  Raw MMIO writes (via PYNQ MMIO or `/dev/mem`) to the DMA control register are silently ignored — DMACR reads back 0x00010006 (Reset stuck, RS=0) regardless of what is written.

Additionally, accessing PYNQ's DMA object (`ol.axi_dma_0`) can **crash the Python process** (segfault/bus error) if the DMA's UIO device isn't properly set up.  Writing to the DMA control register through PYNQ's internal MMIO (`rc._mmio.write(rc._offset, ...)`) can crash the **entire board** (kernel panic from UIO interrupt handler).

**Working approach:** Modify the HWH to rename the DMA's `MODTYPE` and `VLNV` so PYNQ treats it as `DefaultIP` (no DMA driver installed).  Then use raw `/dev/mem` mmap for DMA register access with polling-based completion detection via `waveform_count`.  Combine with the decoupled BRAM capture architecture (lesson #18) so DMA timing doesn't affect capture alignment.

### 21. PYNQ overlay reload crashes the FPGA manager

Loading an overlay a second time on the same boot session often leaves the FPGA manager in a `write init error` state.  Subsequent `Overlay()` calls fail with `OSError: [Errno 16] Device or resource busy`.  The only recovery is a power cycle.

**Workaround:** Design the server to load the overlay once at startup and never reload.  If the server crashes, power-cycle the board before restarting.

### 22. PYNQ DMA requires proper HWH — modified HWH breaks DMA access

Modifying the HWH to hide the DMA (changing MODTYPE/VLNV) does NOT prevent PYNQ from blocking DMA register access.  Even with the modified HWH, DMACR reads 0x00010006 (Reset stuck) and raw MMIO writes are ignored.

The ONLY working approach is to use PYNQ's DMA API (`dma.recvchannel.transfer()`) with the REAL HWH.  Poll `waveform_count` via EDM MMIO for completion detection instead of `dma.recvchannel.wait()` (which requires interrupts).

The first `transfer()` after boot may time out — the DMA channel needs one failed cycle to initialize.  Subsequent transfers work.  Handle the first "DMA channel not idle" errors gracefully.

### 23. DMA arm order: address and length BEFORE RS=1

Writing RS=1 to S2MM_DMACR before setting the destination address and buffer length causes `tready` to drop after 4 beats.  The correct sequence is:
1. Reset (write 0x0004 to DMACR)
2. Write destination address (offset 0x48)
3. Write buffer length (offset 0x58)
4. Set RS=1 (write 0x0001 to DMACR) — LAST

This only matters for raw MMIO access.  PYNQ's DMA API handles the order correctly.

### 24. Eliminate AXI DMA — use AXI-Lite BRAM readout instead

The AXI DMA on PYNQ-Z2 is unreliable due to PYNQ driver conflicts, tready coupling, interrupt requirements, and FPGA manager issues.  After two days of debugging, the solution was to **eliminate the DMA entirely**.

Rev 11 stores waveform samples in local BRAM inside `waveform_capture.v`, then software reads them via the AXI-Lite register file at offsets 0x800–0xFFC (up to 512 samples).  This is slower than DMA (~400µs per 100-sample readout vs ~10µs for DMA) but 100% reliable with no driver conflicts.

This also fixed the first-period anomaly: with the trigger decoupled from `m_axis_tready`, every capture starts at exactly the right pulse edge (std=0.3 vs 14 before).

### 25. XADC VP/VN requires both pins connected — VN must not float


The XADC VP/VN differential input measures (VP − VN).  If VN is left floating, the measurement has a large DC offset (~9V with 50x probe scaling) that makes the signal appear inverted.  Connect VN to the **XADC header GND pin** (pin 3) or to the signal source ground for a proper differential reference.

### 26. Use trigger-synchronous sampling to eliminate jitter

When using `pair_ready` (from the XADC DRP reader) as the sample clock, each capture's first sample lands at a random phase of the XADC conversion cycle relative to the trigger.  This causes ±1 sample (~2µs) of jitter visible as misaligned traces in the persistence display.

**Fix:** Replace `pair_ready`-driven BRAM writes with a fixed-rate `sample_tick` counter that resets on the trigger edge.  Every capture's samples are at identical offsets from the trigger, eliminating inter-trace jitter entirely.  The `ch1_data`/`ch2_data` values may be up to ~2µs stale (from the last `pair_ready`), but this is sub-sample and invisible.

### 27. PYNQ-Z2 Arduino analog pin labels: VAUX6 is A2, not A0

The PYNQ-Z2 XADC VAUX6 channel (Zynq pins K14/J14) physically connects to **Arduino analog header pin A2**, not A0 as some documentation suggests.  The Arduino J1 header pin numbering is A5 (pin 1) through A0 (pin 6), but the VAUX channel-to-pin mapping does not follow sequential order.  Verify analog connections empirically — plug in a known signal and check which pin produces a reading.
