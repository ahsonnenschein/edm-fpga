# EDM FPGA Controller — PYNQ-Z2

FPGA-based EDM (Electrical Discharge Machining) pulse controller running on the **PYNQ-Z2** (Zynq-7020).

- Generates precise Ton/Toff pulse sequences from the FPGA fabric (PL side)
- Reads gap voltage and arc current via the on-chip XADC
- Safety interlock: pulse output is gated by an operator HV enable switch
- Warning lamp outputs (green / orange / red) reflect system state
- Board-side TCP data server streams live measurements to the PC operator console
- Modbus TCP server for LinuxCNC HAL integration and adaptive feed control

---

## Hardware

| Item | Detail |
|------|--------|
| Board | PYNQ-Z2 |
| SoC | Xilinx Zynq-7020 (XC7Z020-1CLG400C) |
| PL clock | 100 MHz (FCLK0 from PS) |
| ADC | On-chip XADC, 1 MSPS, 12-bit |
| CH1 | Gap voltage — Hantek HV probe → VP/VN header (÷3 resistor divider, 0–1 V ADC input) |
| CH2 | Arc current — GEDM optoisolated output (0–3.3 V) → Arduino A0 / VAUX1 |
| Pulse output | Arduino D2 (T14) → GEDM pulseboard |
| HV enable input | Arduino D3 (U12) ← operator toggle switch |
| Green lamp | Arduino D4 (U13) → HFET module — HV off |
| Orange lamp | Arduino D5 (V13) → HFET module — HV on, sparks off |
| Red lamp | Arduino D6 (V15) → HFET module — sparks running |
| Status LEDs | LD0–LD3 (R14, P14, N16, M14) |

---

## Repository Layout

```
edm-fpga/
├── rtl/
│   ├── edm_top.v            Top-level module — HV interlock, lamp logic, AXI wiring
│   ├── edm_pulse_ctrl.v     Ton/Toff state machine
│   ├── axi_edm_regs.v       AXI4-Lite register file
│   └── waveform_capture.v   Triggered XADC sample capture (deferred)
├── constraints/
│   └── pynq_z2.xdc          Pin assignments for PYNQ-Z2 Arduino header + LEDs
├── scripts/
│   └── create_project.tcl   Full Vivado build: block design → bitstream
├── software/
│   ├── xadc_server.py       Board-side TCP data server (port 5006)
│   ├── modbus_server.py     Modbus TCP server for LinuxCNC (port 502)
│   └── operator_console.py  PC-side PySide6 operator GUI with simulation mode
├── edm_pynq.bit             Generated bitstream (deploy to board)
└── edm_pynq.hwh             Hardware handoff file (required by PYNQ overlay)
```

---

## FPGA Design

The block design (`scripts/create_project.tcl`) connects:

```
Zynq PS (ARM)
    └── AXI GP0 Master
            └── AXI Interconnect
                    ├── M00 → edm_ctrl (RTL module) @ 0x43C00000  4 KB
                    └── M01 → XADC Wizard IP         @ 0x43C20000  64 KB
```

**`edm_top.v`** wraps the pulse controller and register file.  A 2-FF synchroniser cleanly moves the `hv_enable` input from the asynchronous operator switch into the 100 MHz clock domain.  The pulse output is AND-gated with `hv_enable_sync` so sparks are physically impossible while HV is off.

Lamp logic:

| Condition | Green | Orange | Red |
|-----------|-------|--------|-----|
| HV off | ON | off | off |
| HV on, sparks off | off | ON | off |
| HV on, sparks running | off | off | ON |

---

## Register Map

### EDM Control Registers — base `0x43C00000`

| Offset | Name | R/W | Default | Description |
|--------|------|-----|---------|-------------|
| 0x00 | `ton_cycles` | RW | 1000 | Ton in clock cycles (µs × 100 for 100 MHz clock) |
| 0x04 | `toff_cycles` | RW | 9000 | Toff in clock cycles |
| 0x08 | `enable` | RW | 0 | bit[0]: 1 = run, 0 = stop |
| 0x0C | `pulse_count` | RO | — | Running count of completed pulses |
| 0x10 | `hv_enable` | RO | — | bit[0]: operator HV switch state (synchronised) |

### XADC Wizard Registers — base `0x43C20000`

| Offset | Description |
|--------|-------------|
| 0x200 | Temperature (raw 16-bit, left-justified 12-bit) |
| 0x240 | VP/VN — CH1 gap voltage |
| 0x250 | VAUX1 — CH2 arc current (Arduino A0) |

XADC raw value → voltage: `V = (raw >> 4) / 4096 * 1.0`  (full-scale = 1.0 V on VP/VN)

---

## Building the Bitstream

Requires Vivado 2023.2.

```bash
cd /home/sonnensn/edm-fpga
/tools/Xilinx/Vivado/2023.2/bin/vivado -mode batch -source scripts/create_project.tcl
```

Output: `edm_pynq.bit` (copied to repo root automatically by the script)

The `.hwh` (hardware handoff) file is also needed for the PYNQ overlay.  After synthesis:

```bash
cp ../edm_vivado/edm_pynq.gen/sources_1/bd/edm_system/hw_handoff/edm_system.hwh \
   edm_pynq.hwh
```

---

## Deployment to PYNQ-Z2

```bash
# From your PC (board IP 192.168.2.99, password: xilinx)
scp edm_pynq.bit edm_pynq.hwh xilinx@192.168.2.99:/home/xilinx/
scp software/xadc_server.py software/modbus_server.py xilinx@192.168.2.99:/home/xilinx/
```

---

## Loading the Overlay (Jupyter)

Open `http://192.168.2.99:8888/` in a browser (Jupyter must be started with `XILINX_XRT=/usr`).

```python
from pynq import Overlay
ol = Overlay('/home/xilinx/edm_pynq.bit')
print(list(ol.ip_dict.keys()))
# ['edm_ctrl', 'xadc_wiz_0', 'ps7']
```

The overlay programs the FPGA and maps AXI peripherals.  Leave this kernel running — other processes (xadc_server, modbus_server) access the registers directly via MMIO without reloading the bitstream.

---

## XADC Server (`xadc_server.py`)

Runs on the board's ARM CPU.  Reads XADC and EDM registers via MMIO at **200 Hz** and streams JSON frames over TCP (port 5006) to connected clients.

**Start on board:**

```bash
sudo XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 /home/xilinx/xadc_server.py
```

**JSON frame (one per sample, newline-delimited):**

```json
{"ts": 1234.5678, "ch1": 23.4, "ch2": 0.81, "temp": 43.6,
 "pulse_count": 1042, "hv_enable": 1, "enable": 1}
```

| Field | Description |
|-------|-------------|
| `ts` | Unix timestamp |
| `ch1` | Gap voltage (V) — scaled through ÷3 probe divider |
| `ch2` | Arc current proxy (V) — GEDM 0–3.3 V output |
| `temp` | Zynq die temperature (°C) |
| `pulse_count` | Cumulative pulse count from FPGA register |
| `hv_enable` | Operator HV switch state |
| `enable` | Software enable state |

**Commands (send as JSON + newline):**

```json
{"cmd": "set_ton",    "value": 20}
{"cmd": "set_toff",   "value": 80}
{"cmd": "set_enable", "value": 1}
{"cmd": "get_params"}
```

`set_ton` / `set_toff` values are in **microseconds** — the server multiplies by 100 to convert to clock cycles before writing to the FPGA register.

---

## Operator Console (`operator_console.py`)

PySide6 GUI that runs on any PC on the same network.

```bash
pip install PySide6 matplotlib numpy
python3 software/operator_console.py
```

- Enter board IP (`192.168.2.99`), uncheck Simulation mode, click **Connect**
- **Simulation mode** (default on) generates synthetic EDM waveforms — useful without hardware
- Set Ton/Toff and click **Apply** to update FPGA registers in real time
- **Enable Pulses** button sends `set_enable` command to the board

**Waveform display** shows the most recent continuous block of samples received while `enable=1` (sparks active).  The **Prescale 1/N** spinbox subsamples long bursts — set to 10 to display every 10th sample.  The plot title reports total sample count, burst duration, and prescale ratio.

---

## Modbus TCP Server (`modbus_server.py`)

Provides a Modbus TCP interface (port 502) for LinuxCNC HAL integration via `mb2hal`.

**Start on board (requires root for `/dev/mem`):**

```bash
sudo XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 /home/xilinx/modbus_server.py
```

### Holding Registers (read/write, FC3/FC16)

| Register | Name | Default | Description |
|----------|------|---------|-------------|
| 0 | `Ton_us` | 10 | Ton duration in microseconds |
| 1 | `Toff_us` | 90 | Toff duration in microseconds |
| 2 | `Enable` | 0 | 0 = stop, 1 = run |
| 3 | `Gap_setpoint` | 2048 | Target gap voltage (0–4095 raw ADC counts) |
| 4 | `Short_threshold` | 200 | Gap voltage below this = short circuit |
| 5 | `Open_threshold` | 3500 | Gap voltage above this = open gap |

### Input Registers (read-only, FC4)

| Register | Name | Description |
|----------|------|-------------|
| 0 | `Pulse_count_lo` | Lower 16 bits of cumulative pulse count |
| 1 | `Pulse_count_hi` | Upper 16 bits of cumulative pulse count |
| 2 | `HV_enable` | Operator HV switch state (0 or 1) |
| 3 | `Gap_voltage_avg` | IIR-smoothed gap voltage (0–4095 raw ADC counts, α=0.05 at 500 Hz) |
| 4 | `Arc_ok` | 1 = gap voltage in normal arc range, 0 = short or open gap |

`Arc_ok` and `Gap_voltage_avg` are intended as feedback signals for LinuxCNC adaptive feed control — reduce feed rate when `Arc_ok=0` or `Gap_voltage_avg` deviates from `Gap_setpoint`.

---

## Software Dependencies

On PC (operator console):
```bash
pip install PySide6 matplotlib numpy
```

On board (already available in PYNQ venv):
```
pynq  pymodbus  numpy
```

---

## Status

- [x] RTL design complete and ported to PYNQ-Z2 (Zynq-7020, 100 MHz)
- [x] Vivado block design and TCL build script
- [x] XADC Wizard integration (VP/VN gap voltage + VAUX1 arc current)
- [x] HV enable switch with 2-FF clock domain synchroniser
- [x] Warning lamp logic (green / orange / red)
- [x] AXI register map (ton, toff, enable, pulse_count, hv_enable)
- [x] Bitstream built and deployed to board
- [x] PYNQ overlay loads successfully (edm_ctrl, xadc_wiz_0 visible)
- [x] XADC Server — streams live data at 200 Hz, accepts parameter commands
- [x] Operator console — per-burst waveform display with prescale, simulation mode
- [x] Modbus TCP server — LinuxCNC HAL integration with arc_ok feedback
- [ ] Hardware bring-up and ADC calibration (resistor divider, probe factor)
- [ ] Verify VAUX1 (CH2) sampling in current bitstream
- [ ] High-speed per-pulse waveform capture (requires DMA + waveform_capture.v integration)
