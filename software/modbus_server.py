#!/usr/bin/env python3
"""
modbus_server.py
Modbus TCP server for EDM FPGA controller (PYNQ-Z2 PS side).

Intended for LinuxCNC HAL integration via mb2hal or Classic Ladder.

Modbus holding registers (16-bit, read/write):
  0: Ton_us           Ton duration in microseconds          (default 10)
  1: Toff_us          Toff duration in microseconds         (default 90)
  2: Enable           0=stop, 1=run                         (default 0)
  3: Gap_setpoint     Target gap voltage, 0-4095            (default 2048)
  4: Short_threshold  Gap voltage below this = short        (default 200)
  5: Open_threshold   Gap voltage above this = open gap     (default 3500)

Modbus input registers (16-bit, read-only):
  0: Pulse_count_lo   Lower 16 bits of running pulse count
  1: Pulse_count_hi   Upper 16 bits of running pulse count
  2: HV_enable        Operator HV enable switch state (0 or 1)
  3: Gap_voltage_avg  Smoothed gap voltage, 0-4095 (XADC CH1)
  4: Arc_ok           1 = gap voltage in normal arc range, 0 = short or open

Run as root on the board:
    sudo XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 modbus_server.py
"""

import mmap, struct, logging, threading, time
from pymodbus.server import StartTcpServer
from pymodbus.datastore import (
    ModbusSlaveContext, ModbusServerContext, ModbusSequentialDataBlock
)

logging.basicConfig(level=logging.INFO)
log = logging.getLogger(__name__)

EDM_BASE   = 0x43C00000
EDM_SIZE   = 0x1000
XADC_BASE  = 0x43C20000
XADC_SIZE  = 0x400
CLK_MHZ    = 100

# EDM AXI register offsets
REG_TON_CYCLES  = 0x00
REG_TOFF_CYCLES = 0x04
REG_ENABLE      = 0x08
REG_PULSE_COUNT = 0x0C
REG_HV_ENABLE   = 0x10

# XADC register offsets
XADC_VP_VN = 0x240   # CH1: gap voltage

# Smoothing factor for gap voltage IIR filter (0 < alpha < 1)
# Lower = smoother but slower response
ALPHA = 0.05

# How often to update the gap voltage average (seconds)
XADC_POLL_HZ = 500


class EdmAxiRegs:
    """Read/write EDM AXI-Lite registers via /dev/mem."""

    def __init__(self):
        self._fd   = open("/dev/mem", "r+b")
        self._mem  = mmap.mmap(self._fd.fileno(), EDM_SIZE,
                               offset=EDM_BASE, access=mmap.ACCESS_WRITE)
        self._xfd  = open("/dev/mem", "rb")
        self._xmem = mmap.mmap(self._xfd.fileno(), XADC_SIZE,
                               offset=XADC_BASE, access=mmap.ACCESS_READ)

    def write(self, offset, value):
        self._mem.seek(offset)
        self._mem.write(struct.pack("<I", value & 0xFFFFFFFF))

    def read(self, offset):
        self._mem.seek(offset)
        return struct.unpack("<I", self._mem.read(4))[0]

    def read_xadc(self, offset):
        self._xmem.seek(offset)
        return struct.unpack("<I", self._xmem.read(4))[0]


class GapVoltageFilter:
    """
    Polls XADC CH1 at high rate and maintains an IIR-smoothed gap voltage.
    Runs in a background thread so Modbus reads always get a fresh average.
    """

    def __init__(self, regs: EdmAxiRegs):
        self._regs   = regs
        self._avg    = 0.0
        self._lock   = threading.Lock()
        t = threading.Thread(target=self._loop, daemon=True)
        t.start()

    def _loop(self):
        interval = 1.0 / XADC_POLL_HZ
        while True:
            t0 = time.monotonic()
            try:
                raw = self._regs.read_xadc(XADC_VP_VN) >> 4  # 12-bit
                with self._lock:
                    self._avg += ALPHA * (raw - self._avg)
            except Exception as e:
                log.warning(f"XADC read error: {e}")
            elapsed = time.monotonic() - t0
            time.sleep(max(0, interval - elapsed))

    def get(self) -> int:
        with self._lock:
            return int(round(self._avg))


class EdmHoldingBlock(ModbusSequentialDataBlock):
    """Holding registers — writes go straight to FPGA."""

    def __init__(self, regs: EdmAxiRegs):
        #              Ton  Toff  En  Setpt  Short  Open
        defaults = [   10,   90,  0,  2048,   200,  3500]
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
            # regs 3-5 are thresholds used by EdmInputBlock — no FPGA write needed
        except Exception as e:
            log.error(f"AXI write error reg {reg}: {e}")


class EdmInputBlock(ModbusSequentialDataBlock):
    """Input registers — refreshed from hardware on each Modbus read."""

    def __init__(self, regs: EdmAxiRegs, holding: EdmHoldingBlock,
                 gap_filter: GapVoltageFilter):
        super().__init__(0, [0, 0, 0, 0, 0])
        self._regs       = regs
        self._holding    = holding
        self._gap_filter = gap_filter

    def getValues(self, address, count=1):
        try:
            pc      = self._regs.read(REG_PULSE_COUNT)
            hv      = self._regs.read(REG_HV_ENABLE) & 1
            gap_avg = self._gap_filter.get()

            # Read thresholds from holding registers (1-based in pymodbus)
            short_thresh = self._holding.getValues(5, 1)[0]
            open_thresh  = self._holding.getValues(6, 1)[0]
            arc_ok = 1 if (short_thresh < gap_avg < open_thresh) else 0

            self.values = [
                pc & 0xFFFF,
                (pc >> 16) & 0xFFFF,
                hv,
                gap_avg,
                arc_ok,
            ]
        except Exception as e:
            log.error(f"Status read error: {e}")
        return super().getValues(address, count)


def main():
    log.info(f"Connecting to EDM AXI registers at 0x{EDM_BASE:08X}")
    regs       = EdmAxiRegs()
    gap_filter = GapVoltageFilter(regs)
    holding    = EdmHoldingBlock(regs)
    inputs     = EdmInputBlock(regs, holding, gap_filter)

    store   = ModbusSlaveContext(hr=holding, ir=inputs)
    context = ModbusServerContext(slaves=store, single=True)

    log.info("Starting Modbus TCP server on port 502")
    log.info("Holding: 0=Ton_us  1=Toff_us  2=Enable  3=Gap_setpoint  "
             "4=Short_threshold  5=Open_threshold")
    log.info("Input:   0=pulse_count_lo  1=pulse_count_hi  2=hv_enable  "
             "3=gap_voltage_avg  4=arc_ok")
    StartTcpServer(context, address=("0.0.0.0", 502))


if __name__ == "__main__":
    main()
