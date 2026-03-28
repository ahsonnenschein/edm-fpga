#!/usr/bin/env python3
"""
xadc_server.py  —  Board-side data server for EDM PYNQ-Z2 controller

Reads XADC (gap voltage CH1, arc current CH2) and EDM registers via MMIO,
streams JSON samples over TCP and accepts control commands.

Run as root on the board:
    sudo XILINX_XRT=/usr /usr/local/share/pynq-venv/bin/python3 xadc_server.py
"""

import time, json, socket, threading

EDM_BASE   = 0x43C00000
XADC_BASE  = 0x43C20000
SAMPLE_HZ  = 200
TCP_PORT   = 5006

# XADC Wizard AXI register offsets
XADC_TEMP  = 0x200
XADC_VP_VN = 0x240   # CH1: gap voltage (VP/VN dedicated input)
XADC_VAUX1 = 0x250   # CH2: arc current (Arduino A0, VAUX1) — enabled in future build

# CH1: XADC raw (12-bit) → ADC input voltage → probe output voltage
# Resistor divider ÷3 on VP/VN input (0-3V probe output → 0-1V ADC)
# Probe scale placeholder — calibrate once wired up
CH1_DIVIDER = 3.0
CH1_PROBE   = 1.0    # set to probe attenuation ratio after calibration

# CH2: XADC raw → GEDM output voltage (0-3.3V, onboard divider on Arduino A0)
CH2_RANGE   = 3.3


class EdmServer:
    def __init__(self):
        from pynq import Overlay, MMIO
        self._lock    = threading.Lock()
        self._clients = []
        self._running = True

        print("Loading overlay...")
        self._ol   = Overlay('/home/xilinx/edm_pynq.bit')
        self._edm  = MMIO(EDM_BASE,  0x20)
        self._xadc = MMIO(XADC_BASE, 0x400)
        print("Overlay loaded.")

    # ── register access ───────────────────────────────────────────────────────

    def _read_xadc(self):
        raw1  = self._xadc.read(XADC_VP_VN) >> 4   # 12-bit left-justified
        raw2  = self._xadc.read(XADC_VAUX1) >> 4
        t_raw = self._xadc.read(XADC_TEMP)
        ch1   = (raw1 / 4096) * CH1_DIVIDER * CH1_PROBE
        ch2   = (raw2 / 4096) * CH2_RANGE
        temp  = (t_raw >> 4) * 503.975 / 4096 - 273.15
        return ch1, ch2, temp

    def _write_edm(self, offset, value):
        with self._lock:
            self._edm.write(offset, value)

    # ── sample loop ───────────────────────────────────────────────────────────

    def _sample_loop(self):
        interval = 1.0 / SAMPLE_HZ
        while self._running:
            t0 = time.time()
            try:
                ch1, ch2, temp = self._read_xadc()
                with self._lock:
                    pulse_count = self._edm.read(0x0C)
                    hv_enable   = self._edm.read(0x10) & 1
                    enable      = self._edm.read(0x08) & 1

                frame = json.dumps({
                    'ts':          round(t0, 4),
                    'ch1':         round(ch1, 4),
                    'ch2':         round(ch2, 4),
                    'temp':        round(temp, 1),
                    'pulse_count': pulse_count,
                    'hv_enable':   hv_enable,
                    'enable':      enable,
                }).encode() + b'\n'

                dead = []
                with self._lock:
                    for c in self._clients:
                        try:
                            c.sendall(frame)
                        except Exception:
                            dead.append(c)
                    for c in dead:
                        self._clients.remove(c)

            except Exception as e:
                print(f"Sample error: {e}")

            elapsed = time.time() - t0
            time.sleep(max(0, interval - elapsed))

    # ── command handler ───────────────────────────────────────────────────────

    def _handle_cmd(self, cmd):
        c = cmd.get('cmd', '')
        v = cmd.get('value', 0)
        if c == 'set_ton':
            self._write_edm(0x00, max(1, int(v)) * 100)
        elif c == 'set_toff':
            self._write_edm(0x04, max(1, int(v)) * 100)
        elif c == 'set_enable':
            self._write_edm(0x08, 1 if v else 0)
        elif c == 'get_params':
            with self._lock:
                return {
                    'ton_us':  self._edm.read(0x00) // 100,
                    'toff_us': self._edm.read(0x04) // 100,
                    'enable':  self._edm.read(0x08) & 1,
                }
        return None

    # ── client handler ────────────────────────────────────────────────────────

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

    # ── main ──────────────────────────────────────────────────────────────────

    def run(self):
        threading.Thread(target=self._sample_loop, daemon=True).start()

        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(('0.0.0.0', TCP_PORT))
        srv.listen(4)
        print(f"EDM server listening on port {TCP_PORT} at {SAMPLE_HZ} Hz")
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
