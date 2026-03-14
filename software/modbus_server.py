#!/usr/bin/env python3
"""
modbus_server.py
Modbus TCP server for EDM FPGA controller (Red Pitaya PS side).

Modbus holding registers (16-bit, read/write):
  0: Ton_us        Ton duration in microseconds       (default 10)
  1: Toff_us       Toff duration in microseconds      (default 90)
  2: Enable        0=stop, 1=run                      (default 0)
  3: Capture_us    Waveform capture window in µs       (default 20 = 2*Ton)
  4: F_save        Fraction to save    0-10000=0-100% (default 100 = 1%)
  5: F_display     Fraction to display 0-10000=0-100% (default 1000 = 10%)

Modbus input registers (16-bit, read-only):
  0: Pulse_count_lo   Lower 16 bits of pulse count
  1: Pulse_count_hi   Upper 16 bits of pulse count
  2: Waveform_count_lo
  3: Waveform_count_hi

Install deps: pip3 install pymodbus mmap
"""

import mmap
import struct
import time
import logging
from pymodbus.server import StartTcpServer
from pymodbus.datastore import ModbusSlaveContext, ModbusServerContext
from pymodbus.datastore import ModbusSequentialDataBlock

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

# AXI register base address (from Vivado address map)
EDM_BASE_ADDR  = 0x43C00000
EDM_ADDR_RANGE = 0x1000  # 4KB

CLK_MHZ = 125  # FPGA clock frequency

# AXI register offsets (bytes)
REG_TON_CYCLES     = 0x00
REG_TOFF_CYCLES    = 0x04
REG_ENABLE         = 0x08
REG_CAPTURE_LEN    = 0x0C
REG_F_SAVE         = 0x10
REG_F_DISPLAY      = 0x14
REG_PULSE_COUNT    = 0x18  # read-only
REG_WAVEFORM_COUNT = 0x1C  # read-only


class EdmAxiRegs:
    """Read/write EDM AXI-Lite registers via /dev/mem."""

    def __init__(self, base=EDM_BASE_ADDR, size=EDM_ADDR_RANGE):
        self._fd = open("/dev/mem", "r+b")
        self._mem = mmap.mmap(self._fd.fileno(), size,
                              offset=base, access=mmap.ACCESS_WRITE)

    def write(self, offset, value):
        self._mem.seek(offset)
        self._mem.write(struct.pack("<I", value & 0xFFFFFFFF))

    def read(self, offset):
        self._mem.seek(offset)
        return struct.unpack("<I", self._mem.read(4))[0]

    def close(self):
        self._mem.close()
        self._fd.close()


class EdmDataBlock(ModbusSequentialDataBlock):
    """
    Custom datablock that writes Modbus register changes
    directly to the FPGA AXI registers.
    """

    def __init__(self, regs):
        # Holding registers: 6 writable
        initial = [10, 90, 0, 20, 100, 1000]  # defaults in user units
        super().__init__(0, initial)
        self._regs = regs
        self._apply_all(initial)

    def setValues(self, address, values):
        super().setValues(address, values)
        # address is 1-based in pymodbus
        for i, val in enumerate(values):
            reg = address - 1 + i
            self._apply_one(reg, val)

    def _apply_all(self, values):
        for i, val in enumerate(values):
            self._apply_one(i, val)

    def _apply_one(self, reg, val):
        try:
            if reg == 0:   # Ton_us
                self._regs.write(REG_TON_CYCLES, val * CLK_MHZ)
                # Update capture_len to 2*Ton by default if not overridden
                # (software can set reg 3 explicitly to override)
            elif reg == 1: # Toff_us
                self._regs.write(REG_TOFF_CYCLES, val * CLK_MHZ)
            elif reg == 2: # Enable
                self._regs.write(REG_ENABLE, val & 1)
            elif reg == 3: # Capture_us
                self._regs.write(REG_CAPTURE_LEN, val * CLK_MHZ)
            elif reg == 4: # F_save
                self._regs.write(REG_F_SAVE, val)
            elif reg == 5: # F_display
                self._regs.write(REG_F_DISPLAY, val)
        except Exception as e:
            log.error(f"AXI write error reg {reg}: {e}")


class EdmStatusBlock(ModbusSequentialDataBlock):
    """Input registers that reflect FPGA status (read-only)."""

    def __init__(self, regs):
        super().__init__(0, [0, 0, 0, 0])
        self._regs = regs

    def getValues(self, address, count=1):
        # Refresh from hardware on each read
        try:
            pc = self._regs.read(REG_PULSE_COUNT)
            wc = self._regs.read(REG_WAVEFORM_COUNT)
            self.values = [pc & 0xFFFF, (pc >> 16) & 0xFFFF,
                           wc & 0xFFFF, (wc >> 16) & 0xFFFF]
        except Exception as e:
            log.error(f"AXI read error: {e}")
        return super().getValues(address, count)


def main():
    log.info("Connecting to EDM AXI registers at 0x{:08X}".format(EDM_BASE_ADDR))
    regs = EdmAxiRegs()

    holding = EdmDataBlock(regs)
    inputs  = EdmStatusBlock(regs)

    store   = ModbusSlaveContext(hr=holding, ir=inputs)
    context = ModbusServerContext(slaves=store, single=True)

    log.info("Starting Modbus TCP server on port 502")
    log.info("Registers: Ton_us=0, Toff_us=1, Enable=2, Capture_us=3, F_save=4, F_display=5")
    StartTcpServer(context, address=("0.0.0.0", 502))


if __name__ == "__main__":
    main()
