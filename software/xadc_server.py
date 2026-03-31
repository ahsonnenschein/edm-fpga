#!/usr/local/share/pynq-venv/bin/python3
"""
xadc_server.py  —  Board-side data server for EDM PYNQ-Z2 controller

Two independent data streams over TCP (port 5006):

  Status frames  (200 Hz, JSON):
    {"type":"status", "ts":…, "ch1":…, "ch2":…, "temp":…,
     "pulse_count":…, "hv_enable":…, "enable":…}

  Burst frames  (one per pulse, JSON):
    {"type":"burst", "waveform_count":…,
     "ch1":[…], "ch2":[…]}
    ch1/ch2 are lists of voltages at 1 MSPS per channel.
    Length = capture_len (one valid pair per DMA word).

Run from the board's LOCAL terminal (NOT via SSH — overlay load crashes SSH sessions):
    sudo env XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 /home/xilinx/xadc_server.py &
"""

import os, time, json, socket, threading, struct, sys

# Remove the script's own directory from sys.path so /home/xilinx/pynq
# doesn't shadow the pynq package installed in the venv.
_script_dir = os.path.dirname(os.path.abspath(__file__))
sys.path = [p for p in sys.path if os.path.abspath(p) != _script_dir]

import numpy as np

# DPH8909 TTL serial port on the PYNQ-Z2 Raspberry Pi header
# Pin 8 (GPIO14) = TX, Pin 10 (GPIO15) = RX  →  /dev/ttyPS1
PSU_PORT = '/dev/ttyPS1'
PSU_BAUD = 9600

EDM_BASE    = 0x43C00000
DMA_BASE    = 0x40400000
SAMPLE_HZ   = 200
TCP_PORT    = 5006
OVERLAY_BIT = '/home/xilinx/edm_pynq.bit'

# AXI DMA S2MM register offsets (direct/simple mode)
DMA_S2MM_CONTROL  = 0x30
DMA_S2MM_STATUS   = 0x34
DMA_S2MM_DST_ADDR = 0x48
DMA_S2MM_LENGTH   = 0x58

# EDM register offsets (all via edm_ctrl AXI4-Lite)
REG_TON           = 0x00
REG_TOFF          = 0x04
REG_ENABLE        = 0x08
REG_PULSE_COUNT   = 0x0C
REG_HV_ENABLE     = 0x10
REG_CAPTURE_LEN   = 0x14
REG_WAVEFORM_CNT  = 0x18
REG_XADC_CH1      = 0x1C   # latest CH1 12-bit raw (latched from XADC stream)
REG_XADC_CH2      = 0x20   # latest CH2 12-bit raw
REG_XADC_TEMP     = 0x24   # latest temperature 12-bit raw

# ADC scaling
CH1_DIVIDER = 1.0    # no resistor divider on VP/VN — probe output feeds directly
CH1_PROBE   = 50.0   # Hantek 50x probe attenuation
CH2_RANGE   = 4.95   # GEDM output via J1 A0 ÷5 on-board divider (calibrated: 3.3V in → 2.2V displayed at 3.3, so ×1.5)

# Maximum samples per burst buffer (4 KB = 1024 × 32-bit words)
MAX_CAPTURE = 1024


# ── DPH8909 power supply driver (Juntek simple ASCII protocol) ────────────────
class DPH8909:
    """
    Juntek/RD-Tech DPH8909 TTL serial protocol via direct MMIO to PS UART1.
    Bypasses /dev/ttyPS1 (which requires a broken DT overlay on PYNQ).
    Uses w20 combined command for voltage + current to avoid dropped commands.
    """
    _CR = 0x00; _MR = 0x04; _SR = 0x2C; _FIFO = 0x30
    _BAUDGEN = 0x18; _BAUDDIV = 0x34; _RXTOUT = 0x1C

    def __init__(self, port: str = None, address: int = 1, baudrate: int = 9600):
        import mmap, struct
        self._addr = address
        self._lock = threading.Lock()
        self._struct = struct

        # Enable UART1 clocks via SLCR
        fd = open("/dev/mem", "r+b")
        slcr = mmap.mmap(fd.fileno(), 0x1000, offset=0xF8000000)
        def _sw(mem, off, val):
            mem.seek(off); mem.write(struct.pack("<I", val & 0xFFFFFFFF))
        _sw(slcr, 0x008, 0xDF0D)
        slcr.seek(0x154); v = struct.unpack("<I", slcr.read(4))[0]
        _sw(slcr, 0x154, v | 0x02)
        slcr.seek(0x12C); v = struct.unpack("<I", slcr.read(4))[0]
        _sw(slcr, 0x12C, v | (1 << 21))
        slcr.seek(0x228); v = struct.unpack("<I", slcr.read(4))[0]
        _sw(slcr, 0x228, v & ~0x0C)
        _sw(slcr, 0x004, 0x767B)
        slcr.close(); fd.close()
        time.sleep(0.01)

        # Configure UART1: 9600 baud 8N1
        fd = open("/dev/mem", "r+b")
        self._umem = mmap.mmap(fd.fileno(), 0x1000, offset=0xE0001000)
        self._ufd = fd
        self._uw(self._CR, 0x28); time.sleep(0.001)
        self._uw(self._CR, 0x03); time.sleep(0.001)
        self._uw(self._MR, 0x20)
        self._uw(self._BAUDGEN, 651)
        self._uw(self._BAUDDIV, 15)
        self._uw(self._RXTOUT, 10)
        self._uw(self._CR, 0x14)
        time.sleep(0.05)

    def _uw(self, off, val):
        self._umem.seek(off)
        self._umem.write(self._struct.pack("<I", val & 0xFFFFFFFF))

    def _ur(self, off):
        self._umem.seek(off)
        return self._struct.unpack("<I", self._umem.read(4))[0]

    def close(self): pass

    def _flush_rx(self):
        for _ in range(64):
            if self._ur(self._SR) & 0x02: break
            self._ur(self._FIFO)

    def _write_bytes(self, data):
        for b in data:
            while self._ur(self._SR) & 0x10: pass
            self._uw(self._FIFO, b)

    def _read_line(self, timeout=0.5):
        buf = bytearray()
        t0 = time.time()
        while time.time() - t0 < timeout:
            if self._ur(self._SR) & 0x02:
                time.sleep(0.001); continue
            ch = self._ur(self._FIFO) & 0xFF
            buf.append(ch)
            if ch == 0x0A: break
        return buf.decode(errors='replace').strip()

    def _send(self, func, cmd, value):
        frame = f":{self._addr:02d}{func}{cmd:02d}={value},\r\n".encode()
        with self._lock:
            self._flush_rx()
            self._write_bytes(frame)

    def _query(self, cmd):
        frame = f":{self._addr:02d}r{cmd:02d}=0,\r\n".encode()
        with self._lock:
            self._flush_rx()
            self._write_bytes(frame)
            resp = self._read_line()
        if not resp: raise IOError("No response")
        sep = max(resp.rfind('='), resp.rfind(':'))
        return int(resp[sep + 1:].rstrip(','))

    def set_voltage(self, volts):
        self._send('w', 10, round(volts * 100))

    def set_current(self, amps):
        self._send('w', 11, round(amps * 1000))

    def set_voltage_current(self, volts, amps):
        v = round(volts * 100); i = round(amps * 1000)
        frame = f":{self._addr:02d}w20={v},{i},\r\n".encode()
        with self._lock:
            self._flush_rx()
            self._write_bytes(frame)

    def set_output(self, on):
        self._send('w', 12, 1 if on else 0)

    def read_output(self):
        v = self._query(30) / 100.0
        i = self._query(31) / 1000.0
        return v, i


class EdmServer:
    def __init__(self):
        from pynq import Overlay, MMIO, allocate
        self._lock    = threading.Lock()
        self._clients = []
        self._running = True

        # Load overlay with PYNQ DMA API.  Rev 10 decoupled architecture
        # captures into BRAM first (trigger-independent), then streams to DMA.
        # PYNQ's DMA driver timing doesn't affect capture alignment.
        # Load overlay with MODIFIED HWH (DMA type renamed so PYNQ doesn't
        # install its DMA driver, which crashes on access and blocks raw MMIO).
        # The DMA is controlled via raw /dev/mem MMIO with polling.
        print(f"Loading overlay: {OVERLAY_BIT}")
        Overlay(OVERLAY_BIT)
        time.sleep(1)
        print("Overlay loaded.")

        # Force FCLK_CLK0 to 100 MHz
        from pynq import Clocks
        actual = Clocks.fclk0_mhz
        if abs(actual - 100.0) > 1.0:
            print(f"FCLK_CLK0 was {actual:.1f} MHz — forcing to 100 MHz")
            Clocks.fclk0_mhz = 100.0
        else:
            print(f"FCLK_CLK0 = {actual:.1f} MHz (OK)")

        self._edm = MMIO(EDM_BASE, 0x28)

        # DMA via raw /dev/mem (PYNQ driver disabled by HWH modification)
        import mmap as _mmap
        import struct as _struct
        self._devmem_fd = open("/dev/mem", "r+b")
        self._dma_mem = _mmap.mmap(self._devmem_fd.fileno(), 0x100,
                                   offset=DMA_BASE, access=_mmap.ACCESS_WRITE)
        self._struct = _struct

        self._buf = allocate(shape=(MAX_CAPTURE * 2,), dtype=np.uint32)
        self._buf_phys = self._buf.physical_address
        print(f"DMA buffer: phys=0x{self._buf_phys:08X}")

        self._edm.write(REG_CAPTURE_LEN, 100)
        print("Capture length set to 100 samples")

        # Reset and start DMA
        self._dma_write(DMA_S2MM_CONTROL, 0x0004)
        time.sleep(0.01)
        self._dma_write(DMA_S2MM_CONTROL, 0x0001)
        st = self._dma_read(DMA_S2MM_STATUS)
        print(f"DMA init: DMACR=0x{self._dma_read(DMA_S2MM_CONTROL):08X} DMASR=0x{st:08X}")

        # PSU on Pmod B UART (MMIO access to PS UART1)
        self._psu      = None
        self._psu_vout = None
        self._psu_iout = None
        self._psu_status_iter = 0
        try:
            self._psu = DPH8909(baudrate=PSU_BAUD)
            print(f"PSU connected via MMIO UART1 @ {PSU_BAUD} baud")
        except Exception as e:
            print(f"PSU not available: {e}")

    # ── XADC register access ──────────────────────────────────────────────────

    def _read_xadc(self):
        # Read latest values latched in FPGA from XADC AXI4-Stream
        raw1  = self._edm.read(REG_XADC_CH1)  & 0xFFF
        raw2  = self._edm.read(REG_XADC_CH2)  & 0xFFF
        t_raw = self._edm.read(REG_XADC_TEMP) & 0xFFF
        ch1   = (raw1 / 4096) * CH1_DIVIDER * CH1_PROBE
        ch2   = (raw2 / 4096) * CH2_RANGE
        temp  = t_raw * 503.975 / 4096 - 273.15
        return ch1, ch2, temp

    def _write_edm(self, offset, value):
        with self._lock:
            self._edm.write(offset, value)

    # ── 200 Hz status stream ──────────────────────────────────────────────────

    def _status_loop(self):
        interval = 1.0 / SAMPLE_HZ
        while self._running:
            t0 = time.time()
            try:
                ch1, ch2, temp = self._read_xadc()
                with self._lock:
                    pulse_count = self._edm.read(REG_PULSE_COUNT)
                    hv_enable   = self._edm.read(REG_HV_ENABLE) & 1
                    enable      = self._edm.read(REG_ENABLE) & 1

                # Read PSU measured output once per second (every 200 status ticks)
                self._psu_status_iter += 1
                if self._psu and self._psu_status_iter >= 200:
                    self._psu_status_iter = 0
                    try:
                        self._psu_vout, self._psu_iout = self._psu.read_output()
                    except Exception:
                        pass

                d = {
                    'type':        'status',
                    'ts':          round(t0, 4),
                    'ch1':         round(ch1, 4),
                    'ch2':         round(ch2, 4),
                    'temp':        round(temp, 1),
                    'pulse_count': pulse_count,
                    'hv_enable':   hv_enable,
                    'enable':      enable,
                    'psu_ok':      self._psu is not None,
                }
                if self._psu_vout is not None:
                    d['psu_vout'] = round(self._psu_vout, 2)
                    d['psu_iout'] = round(self._psu_iout, 3)

                self._broadcast(json.dumps(d).encode() + b'\n')

            except Exception as e:
                print(f"Status error: {e}")

            elapsed = time.time() - t0
            time.sleep(max(0, interval - elapsed))

    def _dma_write(self, offset, value):
        self._dma_mem.seek(offset)
        self._dma_mem.write(self._struct.pack("<I", value & 0xFFFFFFFF))

    def _dma_read(self, offset):
        self._dma_mem.seek(offset)
        return self._struct.unpack("<I", self._dma_mem.read(4))[0]

    # ── Per-pulse DMA waveform capture ────────────────────────────────────────

    _DMA_HALTED  = 0x0001
    _DMA_IDLE    = 0x0002
    _DMA_IOC_IRQ = 0x1000

    def _dma_loop(self):
        """
        Rev 10 decoupled capture: BRAM fills on trigger (no tready needed),
        then streams to DMA.  Uses raw /dev/mem MMIO for DMA control
        (PYNQ DMA driver disabled via HWH modification).
        Polls waveform_count for completion detection.
        """
        last_wf_count = self._edm.read(REG_WAVEFORM_CNT)
        _last_tx   = 0.0
        _dbg_ok    = 0

        while self._running:
            try:
                capture_len = max(1, min(
                    self._edm.read(REG_CAPTURE_LEN) & 0xFFFF, MAX_CAPTURE
                ))

                # Arm DMA via raw MMIO
                st = self._dma_read(DMA_S2MM_STATUS)
                if st & self._DMA_HALTED:
                    self._dma_write(DMA_S2MM_CONTROL, 0x0004)
                    time.sleep(0.002)
                    self._dma_write(DMA_S2MM_CONTROL, 0x0001)
                    time.sleep(0.001)
                self._dma_write(DMA_S2MM_STATUS, 0x7000)
                self._dma_write(DMA_S2MM_DST_ADDR, self._buf_phys & 0xFFFFFFFF)
                self._dma_write(DMA_S2MM_LENGTH, capture_len * 8)

                # Poll waveform_count for completion (not DMA interrupt).
                # waveform_count increments when the stream phase finishes
                # (after TLAST), so when it changes, the buffer is ready.
                deadline = time.time() + 5.0
                done = False
                while time.time() < deadline:
                    wf_count = self._edm.read(REG_WAVEFORM_CNT)
                    if wf_count != last_wf_count:
                        done = True
                        break
                    time.sleep(0.0002)

                if not done:
                    if _dbg_ok == 0:
                        print(f"DMA: waveform_count stuck at {last_wf_count}")
                    # Reset the PYNQ DMA channel for next attempt
                    try:
                        self._pynq_dma.recvchannel._mmio.write(
                            self._pynq_dma.recvchannel._offset, 0x0004)
                        time.sleep(0.01)
                        self._pynq_dma.recvchannel._mmio.write(
                            self._pynq_dma.recvchannel._offset, 0x10001)
                    except Exception:
                        pass
                    continue

                _dbg_ok += 1
                last_wf_count = wf_count

                if _dbg_ok <= 5 or _dbg_ok % 500 == 0:
                    print(f"DMA capture #{_dbg_ok}: wf_count={wf_count} cap={capture_len}")

                # Parse buffer: {ch1[11:0], 4'b0, ch2[11:0], 3'b0, pulse_state}
                # HP0 writes at 64-bit stride — valid data at even uint32 indices.
                self._buf.invalidate()
                words = np.array(self._buf[:capture_len * 2:2], dtype=np.uint32)
                ch1_raw = ((words >> 20) & 0xFFF).astype(np.float32)
                ch2_raw = ((words >> 4) & 0xFFF).astype(np.float32)
                pulse_bits = (words & 0x1).astype(np.int32)
                ch1_v = (ch1_raw / 4096.0 * CH1_DIVIDER * CH1_PROBE).tolist()
                ch2_v = (ch2_raw / 4096.0 * CH2_RANGE).tolist()

                now = time.time()
                if now - _last_tx < 0.01:
                    continue
                _last_tx = now

                frame = json.dumps({
                    'type':           'burst',
                    'waveform_count': int(wf_count),
                    'ch1':            [round(v, 4) for v in ch1_v],
                    'ch2':            [round(v, 4) for v in ch2_v],
                    'pulse':          pulse_bits.tolist(),
                }).encode() + b'\n'

                self._broadcast(frame)

            except Exception as e:
                print(f"DMA error: {e}")
                time.sleep(0.1)

    # ── TCP helpers ───────────────────────────────────────────────────────────

    def _broadcast(self, frame: bytes):
        dead = []
        with self._lock:
            for c in self._clients:
                try:
                    c.sendall(frame)
                except Exception:
                    dead.append(c)
            for c in dead:
                self._clients.remove(c)

    # ── Command handler ───────────────────────────────────────────────────────

    def _handle_cmd(self, cmd):
        c = cmd.get('cmd', '')
        v = cmd.get('value', 0)
        if c == 'set_ton':
            self._write_edm(REG_TON,  max(1, int(v)) * 100)
        elif c == 'set_toff':
            self._write_edm(REG_TOFF, max(1, int(v)) * 100)
        elif c == 'set_enable':
            self._write_edm(REG_ENABLE, 1 if v else 0)
        elif c == 'set_capture_len':
            self._write_edm(REG_CAPTURE_LEN, max(1, min(int(v), MAX_CAPTURE)))
        elif c == 'get_params':
            with self._lock:
                return {
                    'ton_us':      self._edm.read(REG_TON)  // 100,
                    'toff_us':     self._edm.read(REG_TOFF) // 100,
                    'enable':      self._edm.read(REG_ENABLE) & 1,
                    'capture_len': self._edm.read(REG_CAPTURE_LEN) & 0xFFFF,
                }
        elif c == 'set_psu_voltage':
            if self._psu:
                self._psu.set_voltage(float(v))
        elif c == 'set_psu_current':
            if self._psu:
                self._psu.set_current(float(v))
        elif c == 'set_psu_vi':
            if self._psu:
                self._psu.set_voltage_current(
                    float(cmd.get('voltage', 0)),
                    float(cmd.get('current', 0)))
        elif c == 'set_psu_output':
            if self._psu:
                self._psu.set_output(bool(v))
        return None

    # ── Client handler ────────────────────────────────────────────────────────

    def _handle_client(self, conn, addr):
        print(f"Client connected: {addr}")
        with self._lock:
            self._clients.append(conn)
        buf = b''
        try:
            while self._running:
                try:
                    data = conn.recv(256)
                    if not data:
                        break
                    buf += data
                    while b'\n' in buf:
                        line, buf = buf.split(b'\n', 1)
                        try:
                            result = self._handle_cmd(json.loads(line))
                            if result:
                                conn.sendall(json.dumps(result).encode() + b'\n')
                        except Exception:
                            pass
                except Exception:
                    break
        finally:
            with self._lock:
                if conn in self._clients:
                    self._clients.remove(conn)
            try:
                conn.close()
            except Exception:
                pass
            print(f"Client disconnected: {addr}")

    # ── Main ──────────────────────────────────────────────────────────────────

    def run(self):
        threading.Thread(target=self._status_loop, daemon=True).start()
        threading.Thread(target=self._dma_loop,    daemon=True).start()

        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(('0.0.0.0', TCP_PORT))
        srv.listen(4)
        print(f"EDM server listening on port {TCP_PORT}")
        print(f"  Status stream:  200 Hz JSON (type='status')")
        print(f"  Burst stream:   per-pulse JSON (type='burst'), ~500 kSPS per channel")
        print("Ctrl-C to stop.")

        try:
            while self._running:
                try:
                    conn, addr = srv.accept()
                    threading.Thread(
                        target=self._handle_client, args=(conn, addr), daemon=True
                    ).start()
                except Exception:
                    break
        except KeyboardInterrupt:
            pass
        finally:
            self._running = False
            srv.close()
            print("Server stopped.")


if __name__ == '__main__':
    EdmServer().run()
