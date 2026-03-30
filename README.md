# EDM FPGA Controller — PYNQ-Z2

FPGA-based EDM (Electrical Discharge Machining) pulse controller running on the **PYNQ-Z2** (Zynq-7020).

- Generates precise Ton/Toff pulse sequences from the FPGA fabric (PL side)
- Simultaneous 500 kSPS per channel XADC sampling of gap voltage and arc current
- Per-pulse waveform burst capture via AXI DMA to DDR
- Safety interlock: pulse output is gated by an operator HV enable switch
- Warning lamp outputs (green / orange / red) reflect system state
- Board-side TCP server streams 200 Hz status frames and per-pulse burst waveforms
- PC operator console with live waveform overlay, histograms, and DPH8909 PSU control

---

## Hardware

| Item | Detail |
|------|--------|
| Board | PYNQ-Z2 |
| SoC | Xilinx Zynq-7020 (XC7Z020-1CLG400C) |
| PL clock | 100 MHz (FCLK0 from PS) |
| ADC | On-chip XADC, simultaneous sampling, 500 kSPS per channel, 12-bit |
| CH1 | Gap voltage — VP/VN dedicated differential input (÷3 resistor divider, 0–1 V range) |
| CH2 | Arc current — GEDM optoisolated output (0–3.3 V) → VAUXP1/VAUXN1 |
| Pulse output | Arduino AR0 (T14) → GEDM pulse board |
| HV enable input | Arduino AR1 (U12) ← operator toggle switch |
| Green lamp | Arduino AR2 (U13) — HV off |
| Orange lamp | Arduino AR3 (V13) — HV on, sparks off |
| Red lamp | Arduino AR4 (V15) — sparks running |
| Status LEDs | LD0–LD3 (R14, P14, N16, M14) |
| PSU serial | PYNQ-Z2 Raspberry Pi header pin 8 (TX) / pin 10 (RX) → DPH8909 TTL UART |

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
| A0 | VAUX1+ | Arc current sense + |
| A1 | VAUX1− | Arc current sense − / GND |

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

### Serial — Raspberry Pi header (3.3 V)

| RPi header pin | Signal | Connect to |
|----------------|--------|------------|
| Pin 8 (GPIO14) | UART1 TX → | DPH8909 RX |
| Pin 10 (GPIO15) | UART1 RX ← | DPH8909 TX |
| Pin 6 (GND) | GND | DPH8909 GND |

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
        ├── ADC-A → VP/VN          (CH1 gap voltage)
        └── ADC-B → VAUXP1/VAUXN1 (CH2 arc current)
            │   both at 1 MSPS, one EOC per pair
            ▼
    xadc_drp_reader  (two DRP reads per EOC: addr 0x03 → CH1, addr 0x11 → CH2)
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

`xadc_drp_reader.v` (rev 6) operates in simultaneous sampling mode with a two-step sequencer:

- **Step 1**: ADC-A = VP/VN, ADC-B = VAUX8 → EOC, `channel_out = 0x03`
- **Step 2**: ADC-A = VAUX1, ADC-B = VAUX9 → EOC, `channel_out = 0x11`

The module triggers only on the Step-2 EOC (`channel_out == 0x11`) and issues two DRP reads:

1. Address `0x03` → CH1 (VP/VN result from Step 1, ~1 µs stale, acceptable)
2. Address `0x11` → CH2 (VAUX1 result from Step 2, freshly written)

Both reads complete in ~80 ns.  The `pair_ready` pulse triggers `waveform_capture` at 500 kSPS.  The XADC simultaneously fires two EOCs per full cycle; `waveform_capture` stores valid `{CH1, CH2}` pairs in every other DMA word — `xadc_server.py` reconstructs by extracting both channels from even-indexed words.

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
| 0x14 | `capture_len` | RW | Samples to capture per pulse (1–1024, default 500) |
| 0x18 | `waveform_count` | RO | Count of completed burst captures |
| 0x1C | `xadc_ch1` | RO | Latest CH1 12-bit raw (latched from DRP reader) |
| 0x20 | `xadc_ch2` | RO | Latest CH2 12-bit raw |
| 0x24 | `xadc_temp` | RO | Temperature 12-bit raw (not updated in simultaneous mode) |

### AXI DMA — base `0x40400000`

S2MM (stream-to-memory) only.  Programmed by `xadc_server.py` via MMIO to capture each waveform burst into a pre-allocated DDR buffer.

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
| `ch1` | Gap voltage (V) — scaled through ÷3 probe divider |
| `ch2` | Arc current proxy (V) — GEDM 0–3.3 V output |
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
- **Pulse overlay**: shows the last N burst waveforms overlaid (CH1 gap voltage, CH2 arc current).  The **Show 1 in every N pulses** spinbox controls which pulses appear in the overlay (default: 1 in 1000).  Every pulse feeds the histogram regardless.
- **Histogram**: rolling 1-minute distribution of per-pulse mean gap voltage and arc current.
- **Gap Voltage (DPH8909)**: set voltage and current limit, toggle output on/off.  Commands route over TCP to the board; the board drives the PSU directly via `/dev/ttyPS1` (Raspberry Pi header UART).  Measured V/I readback updates at 1 Hz.

### DPH8909 PSU wiring

The DPH8909 **TTL version** connects directly to the PYNQ-Z2 Raspberry Pi header — no USB adapter needed.

| DPH8909 pin | PYNQ-Z2 RPi header |
|-------------|-------------------|
| GND | Pin 6 (GND) |
| RX | Pin 8 (GPIO14 / UART TX — `/dev/ttyPS1`) |
| TX | Pin 10 (GPIO15 / UART RX — `/dev/ttyPS1`) |

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
| 3 | `Gap_voltage_avg` | IIR-smoothed gap voltage (α=0.05) |
| 4 | `Arc_ok` | 1 = gap in normal arc range |

`Arc_ok` is intended for LinuxCNC adaptive feed control — reduce feed when `Arc_ok=0`.

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
- [ ] Hardware bring-up and calibration (CH1 probe divider ratio, CH2 scaling)
- [ ] Verify /dev/ttyPS1 available on board and DPH8909 communication
- [ ] LinuxCNC HAL configuration and adaptive feed tuning
