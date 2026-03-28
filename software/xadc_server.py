#!/usr/bin/env python3
"""
xadc_server.py  —  Board-side data server for EDM PYNQ-Z2 controller

Two independent data streams over TCP (port 5006):

  Status frames  (200 Hz, JSON):
    {"type":"status", "ts":…, "ch1":…, "ch2":…, "temp":…,
     "pulse_count":…, "hv_enable":…, "enable":…}

  Burst frames  (one per pulse, JSON):
    {"type":"burst", "waveform_count":…,
     "ch1":[…], "ch2":[…]}
    ch1/ch2 are lists of voltages at ~500 kSPS per channel.
    Length = capture_len (register 0x14, default 10 samples).

Run as root on the board (overlay must already be loaded via Jupyter):
    sudo XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 xadc_server.py
"""

import time, json, socket, threading, struct, sys
import numpy as np

EDM_BASE   = 0x43C00000
XADC_BASE  = 0x43C20000
DMA_BASE   = 0x40400000
SAMPLE_HZ  = 200
TCP_PORT   = 5006

# XADC Wizard AXI register offsets
XADC_TEMP  = 0x200
XADC_VP_VN = 0x240
XADC_VAUX1 = 0x250

# EDM register offsets
REG_TON           = 0x00
REG_TOFF          = 0x04
REG_ENABLE        = 0x08
REG_PULSE_COUNT   = 0x0C
REG_HV_ENABLE     = 0x10
REG_CAPTURE_LEN   = 0x14
REG_WAVEFORM_CNT  = 0x18

# AXI DMA S2MM register offsets (simple mode)
DMA_S2MM_CONTROL  = 0x30
DMA_S2MM_STATUS   = 0x34
DMA_S2MM_DST_ADDR = 0x48
DMA_S2MM_LENGTH   = 0x58

# ADC scaling
CH1_DIVIDER = 3.0    # ÷3 resistor divider on VP/VN probe input
CH1_PROBE   = 1.0    # probe attenuation ratio — calibrate once wired
CH2_RANGE   = 3.3    # GEDM output 0–3.3 V

# Maximum samples per burst buffer (4 KB = 1024 × 32-bit words)
MAX_CAPTURE = 1024


class EdmServer:
    def __init__(self):
        from pynq import MMIO, allocate
        self._lock    = threading.Lock()
        self._clients = []
        self._running = True

        print("Connecting to FPGA registers via MMIO...")
        self._edm  = MMIO(EDM_BASE,  0x20)
        self._xadc = MMIO(XADC_BASE, 0x400)
        self._dma  = MMIO(DMA_BASE,  0x100)
        print("Connected.")

        # Allocate physically contiguous DMA buffer (PYNQ xlnk / CMA)
        self._buf = allocate(shape=(MAX_CAPTURE,), dtype=np.uint32)
        self._buf_phys = self._buf.physical_address
        print(f"DMA buffer: phys=0x{self._buf_phys:08X}, {MAX_CAPTURE} words")

        # Halt DMA in case it was running
        self._dma.write(DMA_S2MM_CONTROL, 0x0000)
        time.sleep(0.01)

    # ── XADC register access ──────────────────────────────────────────────────

    def _read_xadc(self):
        raw1  = self._xadc.read(XADC_VP_VN) >> 4
        raw2  = self._xadc.read(XADC_VAUX1) >> 4
        t_raw = self._xadc.read(XADC_TEMP)
        ch1   = (raw1 / 4096) * CH1_DIVIDER * CH1_PROBE
        ch2   = (raw2 / 4096) * CH2_RANGE
        temp  = (t_raw >> 4) * 503.975 / 4096 - 273.15
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

                frame = json.dumps({
                    'type':        'status',
                    'ts':          round(t0, 4),
                    'ch1':         round(ch1, 4),
                    'ch2':         round(ch2, 4),
                    'temp':        round(temp, 1),
                    'pulse_count': pulse_count,
                    'hv_enable':   hv_enable,
                    'enable':      enable,
                }).encode() + b'\n'

                self._broadcast(frame)

            except Exception as e:
                print(f"Status error: {e}")

            elapsed = time.time() - t0
            time.sleep(max(0, interval - elapsed))

    # ── Per-pulse DMA waveform capture ────────────────────────────────────────

    def _dma_loop(self):
        """
        Waits for each pulse (detected via waveform_count incrementing),
        reads the DMA buffer, and broadcasts a burst frame to all clients.
        """
        last_wf_count = self._edm.read(REG_WAVEFORM_CNT)
        DMA_RUN   = 0x0001
        DMA_RESET = 0x0004
        DMA_IDLE  = 0x0002

        while self._running:
            try:
                capture_len = max(1, min(
                    self._edm.read(REG_CAPTURE_LEN) & 0xFFFF, MAX_CAPTURE
                ))
                nbytes = capture_len * 4

                # Arm the DMA: write destination address and byte count
                self._dma.write(DMA_S2MM_CONTROL, DMA_RUN)
                self._dma.write(DMA_S2MM_DST_ADDR, self._buf_phys & 0xFFFFFFFF)
                self._dma.write(DMA_S2MM_LENGTH, nbytes)

                # Poll for completion (TLAST from waveform_capture ends transfer)
                deadline = time.time() + 5.0   # 5 s timeout
                while time.time() < deadline:
                    status = self._dma.read(DMA_S2MM_STATUS)
                    if status & DMA_IDLE:
                        break
                    time.sleep(0.0001)
                else:
                    # Timeout — reset DMA and try again
                    self._dma.write(DMA_S2MM_CONTROL, DMA_RESET)
                    time.sleep(0.01)
                    continue

                wf_count = self._edm.read(REG_WAVEFORM_CNT)
                if wf_count == last_wf_count:
                    continue   # spurious wakeup

                last_wf_count = wf_count

                # Parse buffer: {ch1[11:0], 4'b0, ch2[11:0], 4'b0}
                words = np.array(self._buf[:capture_len], dtype=np.uint32)
                ch1_raw = ((words >> 20) & 0xFFF).astype(np.float32)
                ch2_raw = ((words >> 4)  & 0xFFF).astype(np.float32)
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
