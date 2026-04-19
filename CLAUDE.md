# EDM FPGA Controller — Project Guide

## What This Is

An FPGA-based EDM (Electrical Discharge Machining) pulse controller on a **PYNQ-Z2** (Zynq-7020). It generates precise pulse sequences, samples gap voltage and arc current via XADC, captures per-pulse waveforms, and streams data to a PC operator console. A Modbus TCP server provides adaptive feed control for LinuxCNC integration.

The system is installed on a real EDM machine. This is production hardware, not a simulation.

## Architecture Overview

```
┌─────────────────────────────────────────────────┐
│  Zynq PL (FPGA fabric) @ 100 MHz               │
│                                                 │
│  edm_pulse_ctrl ──► pulse_out (gated by HV sw)  │
│  xadc_drp_reader ──► ch1/ch2/temp + pair_ready  │
│  waveform_capture ──► BRAM (512 samples max)    │
│  gap accumulator ──► gap_sum / gap_count        │
│  axi_edm_regs ──► AXI4-Lite slave (4KB)        │
│  XADC Wizard IP (DRP mode, simultaneous)        │
│  Warning lamps: green/orange/red                │
│                                                 │
│  PS UART1 (EMIO) ──► DPH8909 PSU serial        │
└────────────────┬────────────────────────────────┘
                 │ AXI4-Lite @ 0x43C0_0000
                 ▼
┌─────────────────────────────────────────────────┐
│  Zynq PS (ARM Linux)                            │
│                                                 │
│  xadc_server.py (TCP :5006)                     │
│    - Reads registers + BRAM via /dev/mem        │
│    - Streams 200 Hz status JSON                 │
│    - Streams per-pulse waveform data            │
│    - Controls DPH8909 PSU via MMIO UART1        │
│    - Safety: PSU tracks (hv_enable AND enable)  │
│                                                 │
│  modbus_server.py (TCP :502)                    │
│    - Modbus TCP for LinuxCNC mb2hal             │
│    - AF1 adaptive feed parameter                │
└─────────────────────────────────────────────────┘
         │ TCP
         ▼
┌─────────────────────────────────────────────────┐
│  PC (operator workstation)                      │
│  operator_console.py (PySide6 GUI)              │
│    - 50-trace persistence waveform display      │
│    - Gap voltage histogram                      │
│    - AF1 display with color coding              │
│    - DPH8909 PSU voltage/current control        │
│    - Connect/Disconnect to board                │
└─────────────────────────────────────────────────┘
```

## Critical Design Decisions (Hard-Won Lessons)

### DO NOT use AXI DMA on PYNQ
The PYNQ Python framework auto-claims the DMA controller and blocks raw MMIO access. We tried every workaround (modified HWH, raw /dev/mem, PYNQ API with polling). **None worked reliably.** The solution is the current AXI-Lite BRAM readout — no DMA at all.

### DO NOT use PYNQ Overlay or PYNQ MMIO classes
PYNQ's `Device` discovery is broken on newer kernels ("No Devices Found"). The server uses `DevMemMMIO` — a simple `/dev/mem` mmap wrapper with zero PYNQ dependency. The PYNQ SD image is only used for a convenient Linux with Python.

### DO NOT reload the FPGA overlay at runtime
Calling `Overlay()` from Python sometimes crashes the FPGA manager ("write init error") requiring a power cycle. The bitstream should be loaded once at boot. The server assumes it's already programmed.

### Vivado IP cache MUST be deleted before rebuilds
After changing RTL, delete `edm_pynq.cache/ip/` before running synthesis. Otherwise, OOC (out-of-context) modules reuse stale cached netlists silently. This caused a bug where a 25-bit FIFO was used instead of the updated 32-bit version.

### NEVER set XADC calibration parameters in simultaneous mode
Setting `ADC_OFFSET_AND_GAIN_CALIBRATION=false` or similar params silently corrupts the XADC Wizard IP in simultaneous sampling mode. The XADC produces no data with no error. Leave all calibration settings at defaults.

### PS7 fabric interrupt (IRQ_F2P) can only be enabled via Vivado GUI
`set_property` on `PCW_USE_FABRIC_INTERRUPT` succeeds in TCL but the PS7 doesn't regenerate the IRQ_F2P port. Must be done through the Vivado block design GUI.

### HV enable switch is active-LOW
The operator switch pulls to ground when disabled. The RTL inverts this: `hv_enable_r1 <= ~hv_enable`. Don't "fix" this — it's correct.

### hv_enable pin (AR1) MUST have a pull-up
Without a pull-up, the hv_enable input floats when the switch is in the enabled (open) position. FPGA fabric switching (~3µs after each pulse trigger, from the gap accumulator pair_ready update) couples into the floating pin, glitching `hv_enable_sync` and causing brief dips on `pulse_out` — visible as "digital noise bursts ~4µs after trigger" on the scope. Fix: `PULLUP true` in XDC, or a 10kΩ resistor from AR1 to 3.3V. **Requires bitstream rebuild.**

### PL clock is 62.5 MHz, not 100 MHz
PYNQ's `Overlay()` sets FCLK0 to 62.5 MHz (IO PLL 1000 MHz ÷ 4 ÷ 4) via SLCR, overriding the 100 MHz target. All cycle↔µs conversions in software must use `CYCLES_PER_US = 62.5`. Attempting to fix this by calling `Clocks.fclk0_mhz = 100` after Overlay() locks up the board (system hang, no kernel panic). Do not do this.

### PSU output indicator uses voltage only
The DPH8909 ammeter reads low average current at EDM duty cycles (e.g., 36mA average even at 4A peak with 6% duty). The "Output: ON" indicator must check only `psu_vout > 1.0V` — the current threshold causes false "OFF" readings during pulsed operation.

## AXI Register Map (base: 0x43C0_0000)

| Offset | Name | R/W | Description |
|--------|------|-----|-------------|
| 0x000 | ton_cycles | RW | Ton duration in clock cycles (100 MHz) |
| 0x004 | toff_cycles | RW | Toff duration in clock cycles |
| 0x008 | enable | RW | bit[0]: 1=run pulses, 0=stop |
| 0x00C | pulse_count | RO | Running count of pulses fired |
| 0x010 | hv_enable | RO | bit[0]: operator HV switch state (after inversion) |
| 0x014 | capture_len | RW | Waveform pairs to capture per pulse |
| 0x018 | waveform_count | RO | Waveforms captured since reset |
| 0x01C | xadc_ch1_raw | RO | Latest CH1 (arc current) 12-bit ADC value |
| 0x020 | xadc_ch2_raw | RO | Latest CH2 (gap voltage) 12-bit ADC value |
| 0x024 | xadc_temp_raw | RO | Latest die temperature 12-bit value |
| 0x028 | gap_sum | RO | Sum of CH2 samples during last pulse's Ton |
| 0x02C | gap_count | RO | Number of CH2 samples in gap_sum |
| 0x800–0xFFC | waveform BRAM | RO | Up to 512 captured samples (32-bit packed: [31:20]=ch1, [19:8]=ch2, [7:0]=index) |

## XADC Configuration

- **Mode**: Simultaneous sampling, continuous sequencer
- **Channels**: VP/VN (CH1, arc current) + VAUX6 (CH2, gap voltage, pins K14/J14)
- **Sample rate**: 480.769 kSPS per channel (100 MHz / 208 ADCCLK divider)
- **DRP interface**: `xadc_drp_reader.v` reads data on each EOC pulse
- **pair_ready**: Fires when both CH1 and CH2 have been read for the same conversion
- XADC calibration inserts extra conversions ~every 34 pairs (causes timing gaps in pair_ready — this is normal and expected)

## Pin Assignments (PYNQ-Z2)

| Signal | Arduino Pin | FPGA Pin | Function |
|--------|------------|----------|----------|
| pulse_out | AR0 | T14 | EDM pulse → GEDM pulseboard |
| hv_enable | AR1 | U12 | Operator HV enable switch (active-LOW) |
| lamp_green | AR2 | U13 | Green lamp: HV off |
| lamp_orange | AR3 | V13 | Orange lamp: HV on, sparks off |
| lamp_red | AR4 | V15 | Red lamp: sparks running |
| uart1_txd | Pmod B pin 1 | W14 | PS UART1 TX → DPH8909 RX |
| uart1_rxd | Pmod B pin 2 | Y14 | PS UART1 RX ← DPH8909 TX |
| Vaux6_p | J1 A2 | K14 | Gap voltage analog + |
| Vaux6_n | J1 A2 | J14 | Gap voltage analog − |
| VP/VN | XADC header | M9/M10 | Arc current (dedicated, no XDC needed) |

## DPH8909 PSU Connection (Pmod B)

The DPH8909 bench power supply is controlled via PS UART1 routed through EMIO to Pmod B. Direct 3.3V TTL connection — no level shifter needed.

| Pmod B Pin | Signal | Connect to |
|------------|--------|------------|
| Pin 1 (W14) | UART1 TX (PS→DPH) | DPH8909 RX |
| Pin 2 (Y14) | UART1 RX (DPH→PS) | DPH8909 TX |
| Pin 5 or 11 | GND | DPH8909 GND |

- Baud rate: 9600, 8N1
- Protocol: SCPI-like text commands (e.g., `w20 0800,0100` sets 8.00V, 1.00A)
- The UART is driven via MMIO writes to PS UART1 registers at 0xE000_1000 (not /dev/ttyPS1) because the device tree overlay for ttyPS1 fails when started via SSH
- SLCR clock gate at 0xF800_0154 must be enabled for UART1 to function
- Response parsing: strip trailing `.` and `,` characters (DPH8909 quirk)

## Software Components

### xadc_server.py (runs on the board)
- TCP server on port 5006
- Uses `DevMemMMIO` (direct `/dev/mem` mmap) — **no PYNQ dependency**
- Streams JSON status at 200 Hz: ch1, ch2, temp, pulse_count, hv_enable, enable, gap_avg, psu_vout, psu_iout
- Streams per-pulse waveform arrays when capture_len > 0
- Controls DPH8909 PSU via MMIO to PS UART1 (0xE000_1000), not /dev/ttyPS1
- Safety interlock: PSU output tracks `bool(hv_enable AND enable)` — turns OFF when either drops, turns back ON when both restored
- Forces enable=0 at startup (safe default)
- Requires root (for /dev/mem access)
- Start: `sudo /usr/local/share/pynq-venv/bin/python3 /home/xilinx/xadc_server.py`

### operator_console.py (runs on PC)
- PySide6 GUI connecting to xadc_server on port 5006
- 50-trace persistence waveform display with quadratic alpha fade
- Separate ON/OFF buttons for Sparks and PSU with state indicators
- Gap voltage histogram from PL accumulator batches
- AF1 display with color coding (green=good, yellow=caution, red=bad)
- PSU voltage/current setting via DPH8909 w20 command
- PSU output state derived from actual readings (Vout>1V AND Iout>50mA)
- Disconnect warning: red border, title bar change, PSU safety reminder
- Requires: PySide6, numpy

### modbus_server.py (runs on the board)
- Modbus TCP on port 502 for LinuxCNC HAL via mb2hal
- pymodbus 3.x (ModbusDeviceContext, devices= parameter)
- Holding registers (RW): Ton(0), Toff(1), Enable(2), Gap_setpoint(3), Short_threshold(4), Open_threshold(5)
- Input registers (RO): Pulse_count_lo/hi(0-1), HV_enable(2), Gap_voltage_avg(3), Arc_ok(4), AF1_x1000(5)
- Uses PL gap accumulator (REG_GAP_SUM/REG_GAP_COUNT), not software IIR
- AF1 = (Vset - Vavg) / Vavg — positive means voltage too high (feed closer), negative means too low (retract)

## RTL Modules

| Module | File | Description |
|--------|------|-------------|
| edm_top | `rtl/edm_top.v` | Top-level: instantiates all submodules, HV enable sync, gap accumulator, lamp logic |
| axi_edm_regs | `rtl/axi_edm_regs.v` | AXI4-Lite slave, 4KB address space, control regs + BRAM read window |
| edm_pulse_ctrl | `rtl/edm_pulse_ctrl.v` | Ton/Toff state machine, pulse counter |
| xadc_drp_reader | `rtl/xadc_drp_reader.v` | Reads XADC DRP on EOC, decodes CH1/CH2/temp, generates pair_ready |
| waveform_capture | `rtl/waveform_capture.v` | Triggered BRAM capture, decoupled from DMA/tready, 512 sample depth |

## Build Process

Vivado 2023.2 at `/tools/Xilinx/Vivado/2023.2/bin/vivado`

```bash
# Full project creation (from scratch)
vivado -mode batch -source scripts/create_project.tcl

# Incremental rebuild (after RTL changes)
# IMPORTANT: delete IP cache first!
rm -rf /home/sonnensn/edm_vivado/edm_pynq.cache/ip/
vivado -mode batch -source scripts/rebuild.tcl
```

Vivado project directory: `/home/sonnensn/edm_vivado/edm_pynq.xpr`

## Deploying to the Board

Board IP: 192.168.2.99, user: xilinx, password: xilinx

The board runs from USB 5V power (JP5 set to USB). The 12V external supply was only used during debugging — crashes were software, not power-related.

```bash
# Copy files
sshpass -p 'xilinx' scp edm_pynq.bit edm_pynq.hwh xadc_server.py xilinx@192.168.2.99:/home/xilinx/

# Deploy systemd service (must be done once; persists through clean shutdowns)
sshpass -p 'xilinx' scp deploy/edm.service xilinx@192.168.2.99:/tmp/edm.service
sshpass -p 'xilinx' ssh -o StrictHostKeyChecking=no xilinx@192.168.2.99 'echo xilinx | sudo -S cp /tmp/edm.service /etc/systemd/system/edm.service && sudo systemctl daemon-reload && sudo systemctl enable edm.service && sudo sync'

# Kill and restart server
sshpass -p 'xilinx' ssh -o StrictHostKeyChecking=no xilinx@192.168.2.99 'echo xilinx | sudo -S killall -9 python3 2>/dev/null'
sshpass -p 'xilinx' ssh -o StrictHostKeyChecking=no -f xilinx@192.168.2.99 'echo xilinx | sudo -S /usr/local/share/pynq-venv/bin/python3 /home/xilinx/xadc_server.py > /tmp/xadc_server.log 2>&1'

# Verify
timeout 3 bash -c 'echo "" | nc 192.168.2.99 5006' | head -1
```

## Calibration Constants (xadc_server.py)

| Constant | Value | Meaning |
|----------|-------|---------|
| CH1_PROBE | 3.333 | Current sense scaling (calibrated for opto-isolated shunt) |
| CH2_RANGE | 198.0 | Gap voltage scaling (÷5 on-board divider + XADC 0-1V range) |
| CH1_DIVIDER | 1.0 | Additional CH1 divider (unused currently) |

## Known Issues / Current State

- **PYNQ-Z2 replacement deployed** (2026-04-09) — PYNQ 2.5, auto-starts via systemd service `edm.service`
- **PYNQ boot timing — edm.service must start AFTER base.bin loads** — The Jupyter/pl_server loads the default `base.bin` overlay ~40s into boot, overwriting any bitstream loaded earlier. **Fix: `ExecStartPre=/bin/sleep 45` in edm.service**. See `deploy/edm.service`.
- **Kernel panics leave filesystem dirty** — ext4 is never cleanly unmounted after a crash. Use serial console (/dev/ttyUSB1 at 115200) to apply filesystem changes.
- **Temperature reading is wrong** (-272°C) — XADC calibration artifact, not critical
- **GEDM pulseboard has ~500Ω off-resistance** — PSU voltage can leak through even with pulses off. Hardware interlock (DPDT switch or relay) needed to physically cut PSU power when HV enable is off.
- **Software PSU safety interlock works** but depends on xadc_server running

## QMTech Zynq-7010 Board (AD9226 upgrade platform)

A $45 QMTech ZYJZGW Zynq-7010 Starter Kit is being brought up as the next-gen EDM controller with an AD9226 dual-channel 65 MSPS ADC.

### Board specs
- XC7Z010-1CLG400C, 512MB DDR3, micro SD boot
- MII Ethernet via PS GEM0 EMIO (IP101GA PHY) — native Linux driver, no PL Ethernet MAC needed
- UART0 on MIO 14-15 (CH340 USB serial), USB host on MIO 28-39
- JP2 header: 50-pin BANK34 PL I/O (for AD9226 ADC)
- JP5 header: 50-pin BANK35 PL I/O + PS MIO (for EDM digital I/O)
- PL clock: 50 MHz external crystal
- Vendor reference: `/home/sonnensn/qmtech_ref/` (cloned from GitHub ChinaQMTECH/ZYJZGW_ZYNQ_STARTER_KIT_V2)

### Ethernet PHY pin assignments (MII, BANK35)
| Signal | Pin |  Signal | Pin |
|--------|-----|---------|-----|
| TXEN | D20 | RXDV | M18 |
| TXD0 | G20 | RXD0 | L20 |
| TXD1 | G19 | RXD1 | L19 |
| TXD2 | F20 | RXD2 | H20 |
| TXD3 | F19 | RXD3 | J20 |
| TXCLK | H18 | RXCLK | J18 |
| MDC | M20 | MDIO | M19 |

### AD9226 ADC
- Dual channel, 12-bit, 65 MSPS max, parallel output
- FPGA provides 25 MHz sample clock to ADC
- Connects via JP2 (BANK34, 40-pin)
- 2 × (12 data + OTR + CLK) = 28 signal pins + power/ground

### Vivado project
- Script: `scripts/create_qmtech_project.tcl`
- Project dir: `/home/sonnensn/qmtech_vivado/edm_qmtech/`
- XSA output: `/home/sonnensn/qmtech_vivado/edm_qmtech.xsa`
- PS7 config extracted from vendor's `design_1_bd.tcl` reference design

### PetaLinux build
- PetaLinux 2023.2 installed at `/tools/Xilinx/PetaLinux/2023.2`
- **MUST build inside Docker container** (Ubuntu 22.04), NOT on host filesystem
- Docker container: `petalinux_build` (Ubuntu 22.04 with build-essential, libtinfo5, lsb-release)
- **CRITICAL: pseudo fails on Docker volume mounts** — project must be created inside the container filesystem (`/tmp/plbuild/`), not on a mounted host directory
- Build user: `builder` (UID matches host user) — bitbake refuses to run as root
- Built images at: `/home/sonnensn/qmtech_boot/` (BOOT.BIN, image.ub, rootfs.ext4)
- Vendor factory image at: `/tmp/qmtech_factory/Factory_Binary_Image/`

### Current status (2026-04-19)
- **Vivado build SUCCEEDS** — bitstream generated for XC7Z010 with EDM + AD9226 + Ethernet
- Resource usage: 23% LUTs, 38% registers, 44% I/O — plenty of headroom
- PetaLinux image with Python 3.10 boots (vendor BOOT.BIN + our image.ub)
- Runtime bitstream loading via `/dev/xdevcfg` confirmed working
- Python 3.10 with json/socket/mmap/threading verified on board
- `/dev/mem` mmap at 0x43C00000 works as root
- Our FSBL doesn't boot (Vivado 2023.2 FSBL incompatible with this board) — use vendor's BOOT.BIN
- SSH/sshd setup doesn't persist across reboots (ramdisk image)

### Boot procedure
1. SD card: vendor `BOOT.BIN` + our PetaLinux `image.ub` (with Python)
2. Board boots with vendor FSBL+U-Boot, loads our kernel+rootfs from image.ub
3. At U-Boot prompt, type `boot` if auto-boot doesn't start
4. Login: `petalinux` / `Pastina`, then `sudo su` for root
5. Fix SSH each boot: `sudo ssh-keygen -A && sudo sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && sudo /usr/sbin/sshd`
6. Load EDM bitstream: `cat /path/to/edm_qmtech.bin > /dev/xdevcfg`

## Pending / Future Work

- **Test EDM bitstream on QMTech board** — load via xdevcfg, verify AXI register access
- **Connect AD9226 board** — solder JP2 header, plug in ADC board, test data capture
- **Adapt xadc_server.py** for AD9226 (same register map, different scaling)
- **Persistent boot** — either fix our FSBL or create startup script for SSH + bitstream loading
- **Hardware HV interlock**: DPDT switch or relay to physically disconnect PSU power
- **LinuxCNC integration**: Configure mb2hal to read/write Modbus registers, wire AF1 to adaptive feed HAL pin
- **Software watchdog in RTL**: Auto-disable pulses if PS doesn't heartbeat within 100ms

## Lessons Learned

### PetaLinux pseudo fails on Docker volume mounts
When building PetaLinux inside Docker, the project directory MUST be on the container's own filesystem (e.g., `/tmp/plbuild/`), NOT on a volume-mounted host directory. Pseudo's file ownership tracking breaks across the Docker overlay filesystem boundary, causing random `do_install` task failures with "PermissionError" or "Broken pipe". The failure pattern is deceptive: the task log shows "Succeeded" but the task reports exit code 1.

### Ubuntu 24.04 / kernel 6.17 blocks PetaLinux pseudo
`kernel.apparmor_restrict_unprivileged_userns=1` (default on Ubuntu 24.04) blocks pseudo's user namespace operations. Fix: `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`. Even with this fix, pseudo still fails intermittently on the host — use Docker with Ubuntu 22.04 instead.

### Zynq-7010 DDR/FIXED_IO placement requires PS7-only block design
On the XC7Z010 (100 PL I/O pins), Vivado 2023.2 incorrectly counts PS DDR/FIXED_IO ports as PL I/O when they're in a block design with PL logic. The XC7Z020 (200 PL I/O) masks this by having enough pins. **Fix:** Create a block design containing ONLY the PS7 (with DDR/FIXED_IO via `apply_bd_automation`), then wrap it from a Verilog top-level alongside the PL logic. The PS7 BD wrapper's DDR/FIXED_IO connect internally to PS-dedicated pins, while only the actual PL ports appear as top-level I/O. See `scripts/create_qmtech_project_v3.tcl`.

### QMTech board uses PS GEM via EMIO (not PL Ethernet MAC)
Despite Ethernet being on PL pins, the board uses the PS's built-in GEM controller routed through EMIO — same driver as MIO Ethernet, just different pin routing. No AXI Ethernet MAC IP needed. This is much simpler than a full PL Ethernet stack.

### Docker setup for PetaLinux builds
```bash
# Start container (mount PetaLinux install read-only, XSA read-only)
docker run --rm -d --name petalinux_build \
  -v /tools/Xilinx/PetaLinux/2023.2:/tools/Xilinx/PetaLinux/2023.2:ro \
  -v /home/sonnensn/qmtech_vivado:/home/sonnensn/qmtech_vivado:ro \
  ubuntu:22.04 sleep infinity

# Install deps
docker exec petalinux_build bash -c 'apt-get update && apt-get install -y \
  gawk xterm autoconf libtool texinfo gcc-multilib zlib1g-dev \
  libncurses5-dev libssl-dev libglib2.0-dev net-tools python3 locales \
  iproute2 diffstat xz-utils chrpath socat cpio file lz4 zstd wget \
  git unzip rsync bc debianutils iputils-ping libegl1-mesa libsdl1.2-dev \
  pylint python3-git python3-jinja2 python3-pexpect python3-subunit \
  mesa-common-dev lsb-release build-essential libtinfo5 libncurses5 && \
  locale-gen en_US.UTF-8 && ln -sf /bin/bash /bin/sh'

# Create non-root build user
docker exec petalinux_build useradd -m -s /bin/bash -u $(id -u) builder

# Build (inside container filesystem, NOT a volume mount)
docker exec petalinux_build su - builder -c '
  export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 HOME=/home/builder
  source /tools/Xilinx/PetaLinux/2023.2/settings.sh
  cd /tmp && petalinux-create --type project --template zynq --name myproject
  cd myproject && petalinux-config --get-hw-description /path/to/file.xsa --silentconfig
  petalinux-build'

# Copy images out
docker cp petalinux_build:/tmp/myproject/images/linux/ ./output/
```
