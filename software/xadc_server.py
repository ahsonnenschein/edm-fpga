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
    ch1/ch2 are lists of voltages at 500 kSPS per channel.
    Length = capture_len // 2 (capture_len raw DMA words, half are valid pairs).

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
CH1_DIVIDER = 3.0    # ÷3 resistor divider on VP/VN probe input
CH1_PROBE   = 1.0    # probe attenuation ratio — calibrate once wired
CH2_RANGE   = 3.3    # GEDM output 0–3.3 V

# Maximum samples per burst buffer (4 KB = 1024 × 32-bit words)
MAX_CAPTURE = 1024


# ── DPH8909 power supply driver (Juntek simple ASCII protocol) ────────────────
class DPH8909:
    """
    Juntek/RD-Tech DPH8909 TTL serial protocol (not Modbus).
    Frame: :AAf NN=VVVVV,\r\n  — no checksum.
      w10  set voltage ×100    (5000 → 50.00 V)
      w11  set current ×1000   (1500 → 1.500 A)
      w12  output on/off       1=on 0=off
      r30  read VOUT ×100
      r31  read IOUT ×1000
    """
    def __init__(self, port: str, address: int = 1, baudrate: int = 9600):
        import serial
        self._ser  = serial.Serial(port, baudrate=baudrate,
                                   bytesize=8, parity='N', stopbits=1, timeout=0.5)
        self._addr = address
        self._lock = threading.Lock()

    def close(self):
        try: self._ser.close()
        except Exception: pass

    def _send(self, func: str, cmd: int, value: int):
        frame = f":{self._addr:02d}{func}{cmd:02d}={value},\r\n".encode()
        with self._lock:
            self._ser.reset_input_buffer()
            self._ser.write(frame)

    def _query(self, cmd: int) -> int:
        frame = f":{self._addr:02d}r{cmd:02d}=0,\r\n".encode()
        with self._lock:
            self._ser.reset_input_buffer()
            self._ser.write(frame)
            resp = self._ser.readline()
        resp = resp.decode(errors='replace').strip()
        if not resp:
            raise IOError("No response")
        sep = max(resp.rfind('='), resp.rfind(':'))
        return int(resp[sep + 1:].rstrip(','))

    def set_voltage(self, volts: float):
        self._send('w', 10, round(volts * 100))

    def set_current(self, amps: float):
        self._send('w', 11, round(amps * 1000))

    def set_output(self, on: bool):
        self._send('w', 12, 1 if on else 0)

    def read_output(self) -> tuple:
        """Return (vout_V, iout_A)."""
        v = self._query(30) / 100.0
        i = self._query(31) / 1000.0
        return v, i


class EdmServer:
    def __init__(self):
        from pynq import Overlay, MMIO, allocate
        self._lock    = threading.Lock()
        self._clients = []
        self._running = True

        print(f"Loading overlay: {OVERLAY_BIT}")
        ol = Overlay(OVERLAY_BIT)
        time.sleep(1)
        print("Overlay loaded.")

        # Enable PS UART1 (/dev/ttyPS1) via DT overlay now that ps7_init has
        # run and UART1 is clocked.  The dtbo is compiled once and stored in
        # /boot/uart1.dtbo; this is a no-op if already applied.
        _uart1_dtbo = '/boot/uart1.dtbo'
        _uart1_dir  = '/sys/kernel/config/device-tree/overlays/uart1'
        if not os.path.exists('/dev/ttyPS1') and os.path.exists(_uart1_dtbo):
            try:
                import shutil
                os.makedirs(_uart1_dir, exist_ok=True)
                shutil.copy(_uart1_dtbo, f'{_uart1_dir}/dtbo')
                time.sleep(0.3)
                if os.path.exists('/dev/ttyPS1'):
                    print("UART1 overlay applied — /dev/ttyPS1 ready")
                else:
                    print("UART1 overlay applied but /dev/ttyPS1 not found")
            except Exception as e:
                print(f"UART1 overlay failed: {e}")
        elif os.path.exists('/dev/ttyPS1'):
            print("/dev/ttyPS1 already active")
        else:
            print(f"UART1 dtbo not found at {_uart1_dtbo} — PSU serial unavailable")

        self._edm = MMIO(EDM_BASE, 0x28)
        self._dma = MMIO(DMA_BASE, 0x100)

        self._buf = allocate(shape=(MAX_CAPTURE,), dtype=np.uint32)
        self._buf_phys = self._buf.physical_address
        print(f"DMA buffer: phys=0x{self._buf_phys:08X}, {MAX_CAPTURE} words")

        self._edm.write(REG_CAPTURE_LEN, 100)
        print("Capture length set to 100 samples (100 µs at 1 MSPS)")

        # Reset DMA engine
        self._dma.write(DMA_S2MM_CONTROL, 0x0004)
        time.sleep(0.01)
        self._dma.write(DMA_S2MM_CONTROL, 0x0001)   # RS=1 (run)

        # PSU on Raspberry Pi header UART (/dev/ttyPS1)
        self._psu      = None
        self._psu_vout = None
        self._psu_iout = None
        self._psu_status_iter = 0
        try:
            self._psu = DPH8909(PSU_PORT, baudrate=PSU_BAUD)
            print(f"PSU connected: {PSU_PORT} @ {PSU_BAUD} baud")
        except Exception as e:
            print(f"PSU not available ({PSU_PORT}): {e}")

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

    # ── Per-pulse DMA waveform capture ────────────────────────────────────────

    # DMA status register bit masks
    _DMA_HALTED  = 0x0001
    _DMA_IDLE    = 0x0002
    _DMA_SGINCLD = 0x0008
    _DMA_DMAERR  = 0x0010   # Internal error (bad TLAST)
    _DMA_SLVERR  = 0x0020   # Slave error
    _DMA_DECERR  = 0x0040   # Decode error
    _DMA_IOC_IRQ = 0x1000   # Transfer complete interrupt

    def _dma_loop(self):
        """
        Arms the AXI DMA S2MM channel via MMIO, waits for each waveform burst
        (TLAST from waveform_capture), then broadcasts the burst frame.

        Completion detection: poll for IOC_Irq (bit 12) or Idle=1 after the
        DMA has had time to start.  The old two-phase approach missed fast
        completions (<100 µs) because the 100 µs sleep skipped over Idle=0.
        """
        last_wf_count = self._edm.read(REG_WAVEFORM_CNT)
        _last_tx   = 0.0
        _dbg_iter  = 0
        _dbg_p1_to = 0   # phase-1 timeouts (DMA never went non-idle)
        _dbg_p2_to = 0   # phase-2 timeouts (TLAST never arrived)
        _dbg_ok    = 0   # successful captures

        while self._running:
            try:
                capture_len = max(1, min(
                    self._edm.read(REG_CAPTURE_LEN) & 0xFFFF, MAX_CAPTURE
                ))
                _dbg_iter += 1

                # If DMA is halted (error or reset needed), recover before arming.
                st_before = self._dma.read(DMA_S2MM_STATUS)
                if st_before & self._DMA_HALTED:
                    self._dma.write(DMA_S2MM_CONTROL, 0x0004)   # reset
                    time.sleep(0.002)
                    self._dma.write(DMA_S2MM_CONTROL, 0x0001)   # RS=1
                    time.sleep(0.001)
                # Clear sticky status bits (IOC_Irq, Err_Irq) by W1C before arming.
                self._dma.write(DMA_S2MM_STATUS, 0x7000)

                # Arm: destination address then length (length write starts transfer)
                self._dma.write(DMA_S2MM_DST_ADDR, self._buf_phys & 0xFFFFFFFF)
                self._dma.write(DMA_S2MM_LENGTH,   capture_len * 4)
                st_after  = self._dma.read(DMA_S2MM_STATUS)

                if _dbg_iter <= 5 or _dbg_iter % 200 == 0:
                    print(f"DMA arm #{_dbg_iter}: status before=0x{st_before:04X} "
                          f"after=0x{st_after:04X} cap={capture_len} "
                          f"p1_to={_dbg_p1_to} p2_to={_dbg_p2_to} ok={_dbg_ok}")

                # Phase 1: wait for DMA to go non-idle (Idle=0), max 200 ms.
                # A very fast capture (<100 µs) may complete before our first
                # poll — if we already see IOC_Irq set, skip straight to phase 2.
                t0 = time.time()
                phase1_ok = False
                while time.time() - t0 < 0.2:
                    st = self._dma.read(DMA_S2MM_STATUS)
                    if st & self._DMA_IOC_IRQ:          # completed already
                        phase1_ok = True
                        break
                    if not (st & self._DMA_IDLE):       # running (not idle)
                        phase1_ok = True
                        break
                    time.sleep(0.0001)

                if not phase1_ok:
                    _dbg_p1_to += 1
                    st = self._dma.read(DMA_S2MM_STATUS)
                    print(f"DMA phase-1 timeout #{_dbg_p1_to}: status=0x{st:04X} "
                          f"wf_count={self._edm.read(REG_WAVEFORM_CNT)}")
                    self._dma.write(DMA_S2MM_CONTROL, 0x0004)
                    time.sleep(0.01)
                    self._dma.write(DMA_S2MM_CONTROL, 0x0001)
                    continue

                # Phase 2: wait for completion (Idle=1 or IOC_Irq), max 5 s
                deadline = time.time() + 5.0
                phase2_ok = False
                while time.time() < deadline:
                    st = self._dma.read(DMA_S2MM_STATUS)
                    if st & (self._DMA_IDLE | self._DMA_IOC_IRQ):
                        phase2_ok = True
                        break
                    # Abort on DMA errors
                    if st & (self._DMA_DMAERR | self._DMA_SLVERR | self._DMA_DECERR):
                        print(f"DMA error flags: status=0x{st:04X}")
                        break
                    time.sleep(0.0001)

                if not phase2_ok:
                    _dbg_p2_to += 1
                    st = self._dma.read(DMA_S2MM_STATUS)
                    wfc = self._edm.read(REG_WAVEFORM_CNT)
                    print(f"DMA phase-2 timeout #{_dbg_p2_to}: status=0x{st:04X} "
                          f"wf_count={wfc} last_wf_count={last_wf_count}")
                    self._dma.write(DMA_S2MM_CONTROL, 0x0004)
                    time.sleep(0.01)
                    self._dma.write(DMA_S2MM_CONTROL, 0x0001)
                    continue

                wf_count = self._edm.read(REG_WAVEFORM_CNT)
                if wf_count == last_wf_count:
                    time.sleep(0.0005)   # brief yield — avoid busy-spin between pulses
                    continue
                _dbg_ok += 1
                last_wf_count = wf_count

                # Rate-limit broadcasts: max 100 bursts/s to the console.
                # The DMA captures every pulse; we just don't flood the TCP link.
                now = time.time()
                if now - _last_tx < 0.01:
                    continue
                _last_tx = now

                # Flush CPU cache so we read DMA-written values, not stale cache
                self._buf.invalidate()
                # Parse buffer: {ch1[11:0], 4'b0, ch2[11:0], 4'b0}
                #
                # The XADC simultaneous-mode sequencer fires two EOCs per cycle.
                # Both EOCs trigger pair_ready; the resulting DMA words alternate:
                #   even words: {ch1_valid, ch2_valid}  — paired sample
                #   odd  words: 0x00000000              — dropped/skipped by DMA back-pressure
                # Extract both channels from even words; discard odd zeros.
                words   = np.array(self._buf[:capture_len], dtype=np.uint32)
                # Interleave reconstruction: both channels from even words
                n_pairs = capture_len // 2
                ch1_raw = ((words[0::2][:n_pairs] >> 20) & 0xFFF).astype(np.float32)
                ch2_raw = ((words[0::2][:n_pairs] >> 4)  & 0xFFF).astype(np.float32)
                ch1_v   = (ch1_raw / 4096.0 * CH1_DIVIDER * CH1_PROBE).tolist()
                ch2_v   = (ch2_raw / 4096.0 * CH2_RANGE).tolist()

                frame = json.dumps({
                    'type':           'burst',
                    'waveform_count': int(wf_count),
                    'ch1':            [round(v, 4) for v in ch1_v],
                    'ch2':            [round(v, 4) for v in ch2_v],
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
        print(f"  Burst stream:   per-pulse JSON (type='burst'), 500 kSPS per channel")
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
