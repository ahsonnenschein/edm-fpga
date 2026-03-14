# EDM FPGA Controller

FPGA-based EDM (Electrical Discharge Machining) pulse controller for the **Red Pitaya STEMlab 125-14** (Zynq-7010). Generates precise Ton/Toff pulse sequences, captures voltage and current waveforms via the on-board ADCs, streams them to DDR via AXI DMA, and exposes all parameters over Modbus TCP from the Zynq Linux PS.

---

## Hardware

| Item | Detail |
|------|--------|
| Board | Red Pitaya STEMlab 125-14 v1 |
| SoC | Xilinx Zynq-7010 (XC7Z010-1CLG400C) |
| PL clock | 125 MHz (FCLK0 from PS) |
| ADC | 125 MSPS, 14-bit, two channels |
| CH1 | Gap voltage (Hentek high-voltage probe) |
| CH2 | Arc current (shunt resistor feedback) |
| Pulse output | 3.3 V GPIO → GEDM pulseboard |

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

All registers are 32-bit, accessible via AXI4-Lite at base address `0x43C00000`.

| Offset | Name | R/W | Default | Description |
|--------|------|-----|---------|-------------|
| 0x00 | `ton_cycles` | RW | 1250 | Ton duration in clock cycles (µs × 125) |
| 0x04 | `toff_cycles` | RW | 11250 | Toff duration in clock cycles |
| 0x08 | `enable` | RW | 0 | bit[0]: 1 = run, 0 = stop |
| 0x0C | `capture_len` | RW | 2500 | Waveform capture length in samples |
| 0x10 | `f_save` | RW | 100 | Fraction to save to HDF5 (0–10000 = 0–100.00%) |
| 0x14 | `f_display` | RW | 1000 | Fraction to display live (0–10000) |
| 0x18 | `pulse_count` | RO | — | Running count of pulses fired |
| 0x1C | `waveform_count` | RO | — | Running count of waveforms captured |

---

## Waveform Data Format

Each AXI-Stream word (32 bits) contains one sample pair:

```
[31:18]  CH1 (14-bit, gap voltage, 2's complement)
[17:16]  00 (unused)
[15:2]   CH2 (14-bit, arc current, 2's complement)
[ 1:0]   00 (unused)
```

TLAST asserts on the final sample of each waveform. Waveforms are transferred to DDR via AXI DMA (S2MM, simple mode).

---

## Modbus TCP Interface

The PS-side `modbus_server.py` translates Modbus holding registers to AXI register writes via `/dev/mem`.

| Modbus Register | Parameter | Units |
|-----------------|-----------|-------|
| 0 | Ton | µs |
| 1 | Toff | µs |
| 2 | Enable | 0/1 |
| 3 | Capture window | µs |
| 4 | f_save | 0–10000 |
| 5 | f_display | 0–10000 |
| 6 (read) | pulse_count | — |
| 7 (read) | waveform_count | — |

Default port: **502**.

---

## Building the Bitstream

Requires Vivado 2023.2.

```bash
vivado -mode batch -source scripts/create_project.tcl
```

Output: `~/edm_fpga/edm_rp.bit`

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

- [x] RTL design complete
- [x] xsim simulation — all tests passing
- [x] Vivado block design and bitstream generation script
- [x] Modbus TCP server
- [x] HDF5 waveform storage
- [x] Operator console with simulation mode
- [ ] Hardware bring-up (board on order)
- [ ] Verify XDC pin assignments against RP v1 schematic
- [ ] Calibrate CH1 probe attenuation and CH2 shunt resistor scaling
- [ ] CH2 input voltage divider (3.3 V → 0.9 V for RP ADC)
