#!/usr/bin/env python3
"""
modbus_server.py
Modbus TCP server for EDM FPGA controller (PYNQ-Z2 PS side).
Compatible with pymodbus 3.x.

Intended for LinuxCNC HAL integration via mb2hal or Classic Ladder.

Modbus holding registers (16-bit, read/write, FC3/FC16):
  0: Ton_us           Ton duration in microseconds          (default 10)
  1: Toff_us          Toff duration in microseconds         (default 90)
  2: Enable           0=stop, 1=run                         (default 0)
  3: Gap_setpoint     Target gap voltage, 0-4095            (default 2048)
  4: Short_threshold  Gap voltage below this = short        (default 200)
  5: Open_threshold   Gap voltage above this = open gap     (default 3500)

Modbus input registers (16-bit, read-only, FC4):
  0: Pulse_count_lo   Lower 16 bits of running pulse count
  1: Pulse_count_hi   Upper 16 bits of running pulse count
  2: HV_enable        Operator HV enable switch state (0 or 1)
  3: Gap_voltage_avg  Smoothed gap voltage, 0-4095 (XADC CH1)
  4: Arc_ok           1 = gap voltage in normal arc range, 0 = short or open

Run as root on the board:
    sudo XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 modbus_server.py
"""

import mmap, struct, logging, threading, time

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

EDM_BASE   = 0x43C00000
EDM_SIZE   = 0x1000
CLK_MHZ    = 100

# EDM AXI register offsets
REG_TON_CYCLES  = 0x00
REG_TOFF_CYCLES = 0x04
REG_ENABLE      = 0x08
REG_PULSE_COUNT = 0x0C
REG_HV_ENABLE   = 0x10
REG_XADC_CH1    = 0x1C

# Smoothing
ALPHA        = 0.05
XADC_POLL_HZ = 500


class EdmHardware:
    """Direct /dev/mem access to EDM AXI registers."""

    def __init__(self):
        self._fd  = open("/dev/mem", "r+b")
        self._mem = mmap.mmap(self._fd.fileno(), EDM_SIZE,
                              offset=EDM_BASE, access=mmap.ACCESS_WRITE)
        self._gap_avg = 0.0
        self._gap_lock = threading.Lock()

        # Start gap voltage polling thread
        t = threading.Thread(target=self._poll_gap, daemon=True)
        t.start()

    def write(self, offset, value):
        self._mem.seek(offset)
        self._mem.write(struct.pack("<I", value & 0xFFFFFFFF))

    def read(self, offset):
        self._mem.seek(offset)
        return struct.unpack("<I", self._mem.read(4))[0]

    def _poll_gap(self):
        interval = 1.0 / XADC_POLL_HZ
        while True:
            t0 = time.monotonic()
            try:
                raw = self.read(REG_XADC_CH1) & 0xFFF
                with self._gap_lock:
                    self._gap_avg += ALPHA * (raw - self._gap_avg)
            except Exception:
                pass
            elapsed = time.monotonic() - t0
            time.sleep(max(0, interval - elapsed))

    @property
    def gap_voltage_avg(self):
        with self._gap_lock:
            return int(round(self._gap_avg))


# Holding register defaults and thresholds (stored in Python, not on FPGA)
hr_values = {
    0: 10,     # Ton_us
    1: 90,     # Toff_us
    2: 0,      # Enable
    3: 2048,   # Gap_setpoint
    4: 200,    # Short_threshold
    5: 3500,   # Open_threshold
}


def write_hr_to_hw(hw, reg, val):
    """Push a holding register value to the FPGA."""
    if reg == 0:
        hw.write(REG_TON_CYCLES, max(1, int(val)) * CLK_MHZ)
    elif reg == 1:
        hw.write(REG_TOFF_CYCLES, max(1, int(val)) * CLK_MHZ)
    elif reg == 2:
        hw.write(REG_ENABLE, 1 if val else 0)
    # regs 3-5 are software-only thresholds


def main():
    from pymodbus.server import StartTcpServer
    from pymodbus.datastore import (
        ModbusServerContext, ModbusSequentialDataBlock,
    )
    from pymodbus.datastore.context import ModbusBaseDeviceContext

    log.info(f"Connecting to EDM AXI registers at 0x{EDM_BASE:08X}")
    hw = EdmHardware()

    # Write defaults to hardware
    for reg, val in hr_values.items():
        write_hr_to_hw(hw, reg, val)

    # Create data blocks with pymodbus 3.x API
    # Address 0 in the block = Modbus address 0
    hr_block = ModbusSequentialDataBlock(0, list(hr_values.values()))
    ir_block = ModbusSequentialDataBlock(0, [0] * 5)

    # Custom slave context that intercepts reads/writes
    class EdmContext(ModbusBaseDeviceContext):
        def __init__(self):
            super().__init__()
            self.store = {'h': hr_block, 'i': ir_block,
                          'd': ModbusSequentialDataBlock(0, [0]),
                          'c': ModbusSequentialDataBlock(0, [0])}

        def validate(self, fc, address, count=1):
            if fc in (3, 6, 16):  # holding registers
                return 0 <= address < 6 and address + count <= 6
            if fc == 4:           # input registers
                return 0 <= address < 5 and address + count <= 5
            return False

        def getValues(self, fc, address, count=1):
            if fc == 4:  # input registers
                pc = hw.read(REG_PULSE_COUNT)
                hv = hw.read(REG_HV_ENABLE) & 1
                gap = hw.gap_voltage_avg
                short_t = hr_values.get(4, 200)
                open_t = hr_values.get(5, 3500)
                arc_ok = 1 if (short_t < gap < open_t) else 0
                ir_data = [pc & 0xFFFF, (pc >> 16) & 0xFFFF, hv, gap, arc_ok]
                return ir_data[address:address + count]
            if fc in (3,):  # holding registers
                vals = list(hr_values.values())
                return vals[address:address + count]
            return [0] * count

        def setValues(self, fc, address, values):
            if fc in (6, 16):  # write holding registers
                for i, val in enumerate(values):
                    reg = address + i
                    if reg in hr_values:
                        hr_values[reg] = val
                        write_hr_to_hw(hw, reg, val)

    store = EdmContext()
    context = ModbusServerContext(devices=store, single=True)

    log.info("Starting Modbus TCP server on port 502")
    log.info("Holding: 0=Ton_us  1=Toff_us  2=Enable  3=Gap_setpoint  "
             "4=Short_threshold  5=Open_threshold")
    log.info("Input:   0=pulse_count_lo  1=pulse_count_hi  2=hv_enable  "
             "3=gap_voltage_avg  4=arc_ok")
    StartTcpServer(context, address=("0.0.0.0", 502))


if __name__ == "__main__":
    main()
