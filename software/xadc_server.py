#!/usr/local/share/pynq-venv/bin/python3
"""
xadc_server.py  —  Board-side data server for EDM PYNQ-Z2 controller

Rev 11: Reads waveform data via AXI-Lite MMIO (no DMA).
Waveform samples are in BRAM at register offsets 0x800-0xFFC.
No AXI DMA, no PYNQ DMA driver, no tready issues.
"""

import os, time, json, socket, threading, struct, sys

_script_dir = os.path.dirname(os.path.abspath(__file__))
sys.path = [p for p in sys.path if os.path.abspath(p) != _script_dir]

import numpy as np

PSU_BAUD    = 9600
EDM_BASE    = 0x43C00000
EDM_SIZE    = 0x1000        # 4KB — control regs + waveform BRAM
SAMPLE_HZ   = 200
TCP_PORT    = 5006
OVERLAY_BIT = '/home/xilinx/edm_pynq.bit'

# Control register offsets
REG_TON           = 0x00
REG_TOFF          = 0x04
REG_ENABLE        = 0x08
REG_PULSE_COUNT   = 0x0C
REG_HV_ENABLE     = 0x10
REG_CAPTURE_LEN   = 0x14
REG_WAVEFORM_CNT  = 0x18
REG_XADC_CH1      = 0x1C
REG_XADC_CH2      = 0x20
REG_XADC_TEMP     = 0x24
REG_GAP_SUM       = 0x28
REG_GAP_COUNT     = 0x2C

# Waveform BRAM base offset (within the same AXI-Lite slave)
BRAM_BASE         = 0x800   # samples at 0x800, 0x804, ..., 0xFFC (512 max)

CH1_DIVIDER = 1.0
CH1_PROBE   = 3.333    # calibrated: 2A reads as 2.0 (was 50.0 for voltage probe)
CH2_RANGE   = 198.0   # calibrated: 20V gap reads as 20.0 (÷5 on-board + XADC scaling)
MAX_CAPTURE = 512


# ── DPH8909 PSU driver (MMIO UART1) ─────────────────────────────────────────

class DPH8909:
    def __init__(self, baudrate=9600):
        import mmap
        self._addr = 1
        self._lock = threading.Lock()
        fd = open("/dev/mem", "r+b")
        slcr = mmap.mmap(fd.fileno(), 0x1000, offset=0xF8000000)
        def sw(m,o,v): m.seek(o); m.write(struct.pack("<I",v&0xFFFFFFFF))
        def sr(m,o): m.seek(o); return struct.unpack("<I",m.read(4))[0]
        sw(slcr,0x008,0xDF0D)
        sw(slcr,0x154,sr(slcr,0x154)|0x02)
        sw(slcr,0x12C,sr(slcr,0x12C)|(1<<21))
        sw(slcr,0x228,sr(slcr,0x228)&~0x0C)
        sw(slcr,0x004,0x767B)
        slcr.close(); fd.close()
        time.sleep(0.01)
        ufd = open("/dev/mem","r+b")
        self._um = mmap.mmap(ufd.fileno(),0x1000,offset=0xE0001000)
        self._uw(0x00,0x28); time.sleep(0.001)
        self._uw(0x00,0x03); time.sleep(0.001)
        self._uw(0x04,0x20)
        self._uw(0x18,651); self._uw(0x34,15); self._uw(0x1C,10)
        self._uw(0x00,0x14); time.sleep(0.05)

    def _uw(self,o,v): self._um.seek(o); self._um.write(struct.pack("<I",v&0xFFFFFFFF))
    def _ur(self,o): self._um.seek(o); return struct.unpack("<I",self._um.read(4))[0]
    def close(self): pass
    def _flush(self):
        for _ in range(64):
            if self._ur(0x2C)&0x02: break
            self._ur(0x30)
    def _wb(self,data):
        for b in data:
            while self._ur(0x2C)&0x10: pass
            self._uw(0x30,b)
    def _rl(self,timeout=0.5):
        buf=bytearray(); t0=time.time()
        while time.time()-t0<timeout:
            if self._ur(0x2C)&0x02: time.sleep(0.001); continue
            ch=self._ur(0x30)&0xFF; buf.append(ch)
            if ch==0x0A: break
        return buf.decode(errors='replace').strip()
    def _send(self,f,c,v):
        frame=f":{self._addr:02d}{f}{c:02d}={v},\r\n".encode()
        with self._lock: self._flush(); self._wb(frame)
    def _query(self,c):
        frame=f":{self._addr:02d}r{c:02d}=0,\r\n".encode()
        with self._lock: self._flush(); self._wb(frame); resp=self._rl()
        if not resp: raise IOError("No response")
        sep=max(resp.rfind('='),resp.rfind(':')); return int(resp[sep+1:].rstrip(','))
    def set_voltage(self,v): self._send('w',10,round(v*100))
    def set_current(self,a): self._send('w',11,round(a*1000))
    def set_voltage_current(self,v,a):
        frame=f":{self._addr:02d}w20={round(v*100)},{round(a*1000)},\r\n".encode()
        with self._lock: self._flush(); self._wb(frame)
    def set_output(self,on): self._send('w',12,1 if on else 0)
    def read_output(self): return self._query(30)/100.0, self._query(31)/1000.0


# ── EDM Server ──────────────────────────────────────────────────────────────

class EdmServer:
    def __init__(self):
        from pynq import Overlay, MMIO

        self._lock    = threading.Lock()
        self._clients = []
        self._running = True

        print(f"Loading overlay: {OVERLAY_BIT}")
        Overlay(OVERLAY_BIT)
        time.sleep(1)
        print("Overlay loaded.")

        from pynq import Clocks
        actual = Clocks.fclk0_mhz
        if abs(actual - 100.0) > 1.0:
            print(f"FCLK_CLK0 was {actual:.1f} MHz — forcing to 100 MHz")
            Clocks.fclk0_mhz = 100.0
        else:
            print(f"FCLK_CLK0 = {actual:.1f} MHz (OK)")

        # Single MMIO mapping covers control regs AND waveform BRAM
        self._edm = MMIO(EDM_BASE, EDM_SIZE)
        print(f"EDM MMIO: 0x{EDM_BASE:08X}, {EDM_SIZE} bytes")

        self._edm.write(REG_CAPTURE_LEN, 100)
        print("Capture length set to 100 samples")

        # PSU
        self._psu = None; self._psu_vout = None; self._psu_iout = None
        self._psu_status_iter = 0
        try:
            self._psu = DPH8909(baudrate=PSU_BAUD)
            print(f"PSU connected via MMIO UART1 @ {PSU_BAUD} baud")
        except Exception as e:
            print(f"PSU not available: {e}")

    def _read_xadc(self):
        raw1 = self._edm.read(REG_XADC_CH1) & 0xFFF
        raw2 = self._edm.read(REG_XADC_CH2) & 0xFFF
        t_raw = self._edm.read(REG_XADC_TEMP) & 0xFFF
        return (raw1/4096)*CH1_DIVIDER*CH1_PROBE, (raw2/4096)*CH2_RANGE, t_raw*503.975/4096-273.15

    def _write_edm(self, offset, value):
        with self._lock: self._edm.write(offset, value)

    # ── 200 Hz status stream ─────────────────────────────

    def _status_loop(self):
        interval = 1.0 / SAMPLE_HZ
        while self._running:
            t0 = time.time()
            try:
                ch1, ch2, temp = self._read_xadc()
                with self._lock:
                    pc = self._edm.read(REG_PULSE_COUNT)
                    hv = self._edm.read(REG_HV_ENABLE) & 1
                    en = self._edm.read(REG_ENABLE) & 1
                self._psu_status_iter += 1
                if self._psu and self._psu_status_iter >= 200:
                    self._psu_status_iter = 0
                    try: self._psu_vout, self._psu_iout = self._psu.read_output()
                    except: pass
                # Per-pulse gap voltage average (computed in PL)
                gap_sum = self._edm.read(REG_GAP_SUM)
                gap_count = self._edm.read(REG_GAP_COUNT) & 0xFFFF
                gap_avg_v = (gap_sum / gap_count / 4096 * CH2_RANGE) if gap_count > 0 else 0.0

                d = {'type':'status','ts':round(t0,4),'ch1':round(ch1,4),
                     'ch2':round(ch2,4),'temp':round(temp,1),'pulse_count':pc,
                     'hv_enable':hv,'enable':en,'psu_ok':self._psu is not None,
                     'gap_avg':round(gap_avg_v, 2)}
                if self._psu_vout is not None:
                    d['psu_vout']=round(self._psu_vout,2)
                    d['psu_iout']=round(self._psu_iout,3)
                self._broadcast(json.dumps(d).encode()+b'\n')
            except Exception as e:
                print(f"Status error: {e}")
            elapsed = time.time() - t0
            time.sleep(max(0, interval - elapsed))

    # ── High-rate gap voltage polling (per-pulse batch) ───

    def _gap_poll_loop(self):
        """Read PL gap accumulator at 100 Hz, compute running stats.
        Sends gap_batch (individual values for histogram) every second,
        and gap_stats (avg + std) at 10 Hz for real-time display."""
        last_pc = self._edm.read(REG_PULSE_COUNT)
        batch = []
        last_batch_tx = time.time()
        last_stats_tx = time.time()
        interval = 1.0 / 100   # 100 Hz poll

        while self._running:
            t0 = time.time()
            try:
                pc = self._edm.read(REG_PULSE_COUNT)
                if pc != last_pc:
                    last_pc = pc
                    gap_sum = self._edm.read(REG_GAP_SUM)
                    gap_count = self._edm.read(REG_GAP_COUNT) & 0xFFFF
                    if gap_count > 0:
                        avg = round(gap_sum / gap_count / 4096 * CH2_RANGE, 2)
                        batch.append(avg)

                now = time.time()

                # Send stats at 10 Hz
                if now - last_stats_tx >= 0.1 and len(batch) >= 2:
                    arr = np.array(batch[-100:], dtype=np.float32)  # last 100 readings
                    frame = json.dumps({
                        'type': 'gap_stats',
                        'avg': round(float(arr.mean()), 2),
                        'std': round(float(arr.std()), 3),
                        'n': len(arr),
                    }).encode() + b'\n'
                    self._broadcast(frame)
                    last_stats_tx = now

                # Send batch for histogram every second
                if now - last_batch_tx >= 1.0 and batch:
                    frame = json.dumps({
                        'type': 'gap_batch',
                        'values': batch,
                    }).encode() + b'\n'
                    self._broadcast(frame)
                    batch = []
                    last_batch_tx = now

            except Exception as e:
                print(f"Gap poll error: {e}")
            elapsed = time.time() - t0
            time.sleep(max(0, interval - elapsed))

    # ── Waveform capture via AXI-Lite BRAM readout ───────

    def _capture_loop(self):
        """Poll waveform_count, read BRAM via MMIO when new capture ready."""
        last_wf_count = self._edm.read(REG_WAVEFORM_CNT)
        _last_tx = 0.0
        _ok = 0

        while self._running:
            try:
                wfc = self._edm.read(REG_WAVEFORM_CNT)
                if wfc == last_wf_count:
                    time.sleep(0.0005)
                    continue

                _ok += 1
                last_wf_count = wfc

                capture_len = self._edm.read(REG_CAPTURE_LEN) & 0xFFFF
                capture_len = min(capture_len, MAX_CAPTURE)

                if _ok <= 5 or _ok % 500 == 0:
                    print(f"Capture #{_ok}: wfc={wfc} cap={capture_len}")

                # Read waveform samples from BRAM via MMIO
                words = np.zeros(capture_len, dtype=np.uint32)
                for i in range(capture_len):
                    words[i] = self._edm.read(BRAM_BASE + i * 4)

                ch1_raw = ((words >> 20) & 0xFFF).astype(np.float32)
                ch2_raw = ((words >> 4) & 0xFFF).astype(np.float32)
                pulse_bits = (words & 0x1).astype(np.int32)
                ch1_v = (ch1_raw / 4096.0 * CH1_DIVIDER * CH1_PROBE).tolist()
                ch2_v = (ch2_raw / 4096.0 * CH2_RANGE).tolist()

                # Rate-limit broadcasts
                now = time.time()
                if now - _last_tx < 0.01:
                    continue
                _last_tx = now

                self._broadcast(json.dumps({
                    'type':'burst','waveform_count':int(wfc),
                    'ch1':[round(v,4) for v in ch1_v],
                    'ch2':[round(v,4) for v in ch2_v],
                    'pulse':pulse_bits.tolist(),
                }).encode()+b'\n')

            except Exception as e:
                print(f"Capture error: {e}")
                time.sleep(0.1)

    # ── TCP ──────────────────────────────────────────────

    def _broadcast(self, frame):
        dead = []
        with self._lock:
            for c in self._clients:
                try: c.sendall(frame)
                except: dead.append(c)
            for c in dead: self._clients.remove(c)

    def _handle_cmd(self, cmd):
        c = cmd.get('cmd',''); v = cmd.get('value',0)
        if c == 'set_ton': self._write_edm(REG_TON, max(1,int(v))*100)
        elif c == 'set_toff': self._write_edm(REG_TOFF, max(1,int(v))*100)
        elif c == 'set_enable': self._write_edm(REG_ENABLE, 1 if v else 0)
        elif c == 'set_capture_len': self._write_edm(REG_CAPTURE_LEN, max(1,min(int(v),MAX_CAPTURE)))
        elif c == 'get_params':
            with self._lock:
                return {'ton_us':self._edm.read(REG_TON)//100,
                        'toff_us':self._edm.read(REG_TOFF)//100,
                        'enable':self._edm.read(REG_ENABLE)&1,
                        'capture_len':self._edm.read(REG_CAPTURE_LEN)&0xFFFF}
        elif c == 'set_psu_voltage':
            if self._psu: self._psu.set_voltage(float(v))
        elif c == 'set_psu_current':
            if self._psu: self._psu.set_current(float(v))
        elif c == 'set_psu_vi':
            if self._psu: self._psu.set_voltage_current(float(cmd.get('voltage',0)),float(cmd.get('current',0)))
        elif c == 'set_psu_output':
            if self._psu: self._psu.set_output(bool(v))
        return None

    def _handle_client(self, conn, addr):
        print(f"Client connected: {addr}")
        with self._lock: self._clients.append(conn)
        buf = b''
        try:
            while self._running:
                try:
                    data = conn.recv(256)
                    if not data: break
                    buf += data
                    while b'\n' in buf:
                        line, buf = buf.split(b'\n', 1)
                        try:
                            result = self._handle_cmd(json.loads(line))
                            if result: conn.sendall(json.dumps(result).encode()+b'\n')
                        except: pass
                except: break
        finally:
            with self._lock:
                if conn in self._clients: self._clients.remove(conn)
            try: conn.close()
            except: pass
            print(f"Client disconnected: {addr}")

    def run(self):
        threading.Thread(target=self._status_loop, daemon=True).start()
        threading.Thread(target=self._capture_loop, daemon=True).start()
        threading.Thread(target=self._gap_poll_loop, daemon=True).start()
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(('0.0.0.0', TCP_PORT)); srv.listen(4)
        print(f"EDM server listening on port {TCP_PORT}")
        print(f"Ctrl-C to stop.")
        try:
            while self._running:
                try:
                    conn, addr = srv.accept()
                    threading.Thread(target=self._handle_client, args=(conn,addr), daemon=True).start()
                except: break
        except KeyboardInterrupt: pass
        finally: self._running = False; srv.close(); print("Server stopped.")

if __name__ == '__main__':
    EdmServer().run()
