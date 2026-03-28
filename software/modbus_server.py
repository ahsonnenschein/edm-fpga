#!/usr/bin/env python3
"""
modbus_server.py
Modbus TCP server for EDM FPGA controller (PYNQ-Z2 PS side).

Intended for LinuxCNC HAL integration via the Classic Ladder / pymodbus driver.

Modbus holding registers (16-bit, read/write):
  0: Ton_us        Ton duration in microseconds       (default 10)
  1: Toff_us       Toff duration in microseconds      (default 90)
  2: Enable        0=stop, 1=run                      (default 0)

Modbus input registers (16-bit, read-only):
  0: Pulse_count_lo   Lower 16 bits of running pulse count
  1: Pulse_count_hi   Upper 16 bits of running pulse count
  2: HV_enable        Operator HV enable switch state (0 or 1)

Run as root on the board:
    sudo XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 modbus_server.py
"""

import mmap, struct, logging
from pymodbus.server import StartTcpServer
from pymodbus.datastore import (
    ModbusSlaveContext, ModbusServerContext, ModbusSequentialDataBlock
)

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

EDM_BASE  = 0x43C00000
EDM_SIZE  = 0x1000
CLK_MHZ   = 100

REG_TON_CYCLES  = 0x00
REG_TOFF_CYCLES = 0x04
REG_ENABLE      = 0x08
REG_PULSE_COUNT = 0x0C   # read-only
REG_HV_ENABLE   = 0x10   # read-only


class EdmAxiRegs:
    """Read/write EDM AXI-Lite registers via /dev/mem."""

    def __init__(self):
        self._fd  = open("/dev/mem", "r+b")
        self._mem = mmap.mmap(self._fd.fileno(), EDM_SIZE,
                              offset=EDM_BASE, access=mmap.ACCESS_WRITE)

    def write(self, offset, value):
        self._mem.seek(offset)
        self._mem.write(struct.pack("<I", value & 0xFFFFFFFF))

    def read(self, offset):
        self._mem.seek(offset)
        return struct.unpack("<I", self._mem.read(4))[0]


class EdmHoldingBlock(ModbusSequentialDataBlock):
    """Holding registers — writes go straight to FPGA."""

    def __init__(self, regs: EdmAxiRegs):
        defaults = [10, 90, 0]   # Ton_us, Toff_us, Enable
        super().__init__(0, defaults)
        self._regs = regs
        for i, v in enumerate(defaults):
            self._write_hw(i, v)

    def setValues(self, address, values):
        super().setValues(address, values)
        for i, val in enumerate(values):
            self._write_hw(address - 1 + i, val)

    def _write_hw(self, reg, val):
        try:
            if reg == 0:
                self._regs.write(REG_TON_CYCLES,  max(1, int(val)) * CLK_MHZ)
            elif reg == 1:
                self._regs.write(REG_TOFF_CYCLES, max(1, int(val)) * CLK_MHZ)
            elif reg == 2:
                self._regs.write(REG_ENABLE, 1 if val else 0)
        except Exception as e:
            log.error(f"AXI write error reg {reg}: {e}")


class EdmInputBlock(ModbusSequentialDataBlock):
    """Input registers — read from FPGA on each Modbus read."""

    def __init__(self, regs: EdmAxiRegs):
        super().__init__(0, [0, 0, 0])
        self._regs = regs

    def getValues(self, address, count=1):
        try:
            pc  = self._regs.read(REG_PULSE_COUNT)
            hv  = self._regs.read(REG_HV_ENABLE) & 1
            self.values = [pc & 0xFFFF, (pc >> 16) & 0xFFFF, hv]
        except Exception as e:
            log.error(f"AXI read error: {e}")
        return super().getValues(address, count)


def main():
    log.info(f"Connecting to EDM AXI registers at 0x{EDM_BASE:08X}")
    regs = EdmAxiRegs()

    store   = ModbusSlaveContext(
        hr=EdmHoldingBlock(regs),
        ir=EdmInputBlock(regs),
    )
    context = ModbusServerContext(slaves=store, single=True)

    log.info("Starting Modbus TCP server on port 502")
    log.info("Holding: 0=Ton_us  1=Toff_us  2=Enable")
    log.info("Input:   0=pulse_count_lo  1=pulse_count_hi  2=hv_enable")
    StartTcpServer(context, address=("0.0.0.0", 502))


if __name__ == "__main__":
    main()
