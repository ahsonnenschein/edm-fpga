# EDM FPGA Controller

FPGA-based EDM (Electrical Discharge Machining) pulse controller for the **PYNQ-Z2** (Zynq-7020). Generates precise Ton/Toff pulse sequences, reads gap voltage and arc current via the on-board XADC, and exposes all parameters via PYNQ Python overlay API.

---

## Hardware

| Item | Detail |
|------|--------|
| Board | PYNQ-Z2 |
| SoC | Xilinx Zynq-7020 (XC7Z020-1CLG400C) |
| PL clock | 100 MHz (FCLK0 from PS) |
| ADC | XADC, 1 MSPS, 12-bit, two channels |
| CH1 | Gap voltage — Hantek HV probe → VP/VN header (÷3 divider to 0–1V) |
| CH2 | Arc current — GEDM optoisolated output (0–3.3V) → Arduino A0 (VAUX1, onboard divider) |
| Pulse output | Arduino D2 → GEDM pulseboard |
| HV enable | Arduino D3 ← operator toggle switch |
| Warning lamps | Arduino D4/D5/D6 → HFET module (green/orange/red) |

---

## Repository Layout

```
edm_fpga/
├── rtl/
│   ├── edm_top.v          # Top-level module
│   ├── edm_pulse_ctrl.v   # Ton/Toff state machine
│   ├── waveform_capture.v # Triggered ADC capture → AXI-Stream
│   └── axi_edm_regs.v     # AXI4-Lite register file
├── constraints/
│   └── redpitaya_v1.xdc   # Pin assignments for RP v1 board
├── scripts/
│   ├── create_project.tcl # Full Vivado build (block design → bitstream)
│   └── synth_check.tcl    # Out-of-context synthesis check
├── sim/
│   └── tb_edm_top.v       # xsim testbench (all tests passing)
└── software/
    ├── modbus_server.py    # Modbus TCP server (runs on RP Linux PS)
    ├── waveform_manager.py # DMA readout, HDF5 save, live display
    └── operator_console.py # PySide6 operator GUI with simulation mode
```

---

## Register Map

### EDM Control Registers — AXI4-Lite base address `0x43C00000`

| Offset | Name | R/W | Default | Description |
|--------|------|-----|---------|-------------|
| 0x00 | `ton_cycles` | RW | 1000 | Ton duration in clock cycles (µs × 100) |
| 0x04 | `toff_cycles` | RW | 9000 | Toff duration in clock cycles |
| 0x08 | `enable` | RW | 0 | bit[0]: 1 = run, 0 = stop |
| 0x0C | `pulse_count` | RO | — | Running count of pulses fired |
| 0x10 | `hv_enable` | RO | — | bit[0]: operator HV enable switch state |

### XADC Wizard Registers — AXI4-Lite base address `0x43C20000`

Standard Xilinx XADC Wizard register map. Key offsets:

| Offset | Description |
|--------|-------------|
| 0x200 | Temperature |
| 0x204 | VCCINT |
| 0x240 | VP/VN (CH1, gap voltage) |
| 0x250 | VAUX1 (CH2, arc current, Arduino A0) |

---

---

## Building the Bitstream

Requires Vivado 2023.2.

```bash
cd /home/sonnensn/edm-fpga
/tools/Xilinx/Vivado/2023.2/bin/vivado -mode batch -source scripts/create_project.tcl
```

Output: `edm_pynq.bit`

### Out-of-Context Synthesis Check

```bash
vivado -mode batch -source scripts/synth_check.tcl
# Resource usage: ~1.7% LUTs, ~1.0% FFs on xc7z010clg400-1
```

---

## Simulation

Requires Vivado xsim (included with Vivado).

```bash
cd sim
xvlog ../rtl/edm_pulse_ctrl.v ../rtl/waveform_capture.v \
      ../rtl/axi_edm_regs.v ../rtl/edm_top.v tb_edm_top.v
xelab -debug typical tb_edm_top -s tb_edm_top_sim
xsim tb_edm_top_sim --runall
```

Tests:
1. AXI-Lite register write and readback
2. Ton/Toff timing (exact cycle count)
3. Waveform capture — sample count and TLAST position
4. Disable stops pulse output

All tests pass.

---

## Software (PS-side, runs on Red Pitaya Linux)

Install dependencies:

```bash
pip3 install pymodbus h5py matplotlib PySide6
```

**Start Modbus server** (run as root for `/dev/mem` access):

```bash
sudo python3 software/modbus_server.py
```

**Start waveform manager** (DMA readout + HDF5 save + live plot):

```bash
python3 software/waveform_manager.py
```

**Operator console** (runs on any PC on the same network):

```bash
python3 software/operator_console.py
# Enter the Red Pitaya IP, uncheck Simulation mode, click Connect
```

The operator console also has a **Simulation mode** (default on) for use before the board arrives — it generates synthetic EDM waveforms with realistic voltage and current transients.

---

## Deployment to Red Pitaya

```bash
# Copy bitstream
scp edm_rp.bit root@<rp-ip>:/root/

# Load on the board
ssh root@<rp-ip>
cat /root/edm_rp.bit > /dev/xdevcfg
```

---

## Status

- [x] RTL design ported to PYNQ-Z2 (Zynq-7020, 100 MHz)
- [x] Vivado block design and bitstream generation script
- [x] XADC Wizard integration (VP/VN + VAUX1)
- [x] HV enable switch input with 2-FF synchroniser
- [x] Warning lamp logic (green/orange/red)
- [ ] Build and verify bitstream
- [ ] Verify XDC pin assignments against PYNQ-Z2 schematic
- [ ] PYNQ Python overlay driver
- [ ] Hardware bring-up and ADC calibration
- [ ] High-speed waveform capture (deferred — requires parallel ADC on RPi header)
