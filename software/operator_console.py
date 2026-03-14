#!/usr/bin/env python3
"""
operator_console.py
EDM Controller Operator Console

Left panel:  Connection | Parameters | Status
Right panel: Live waveform plots (CH1 voltage, CH2 current)
             Statistics stub (expandable later)

Simulation mode generates synthetic EDM-like waveforms so the app
can be tested before the Red Pitaya board arrives.
"""

import sys
import time
import math
import random
import socket
import struct
import numpy as np
from threading import Thread, Event

from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QGroupBox, QLabel, QLineEdit, QPushButton, QCheckBox, QSlider,
    QSpinBox, QDoubleSpinBox, QFormLayout, QSizePolicy, QFrame,
    QStatusBar,
)
from PySide6.QtCore import Qt, QTimer, Signal, QObject
from PySide6.QtGui import QFont

import matplotlib
matplotlib.use("QtAgg")
from matplotlib.backends.backend_qtagg import FigureCanvasQTAgg as FigureCanvas
from matplotlib.figure import Figure

# ── Modbus (optional – imported lazily so sim mode works without it) ──────────
try:
    from pymodbus.client import ModbusTcpClient
    MODBUS_AVAILABLE = True
except ImportError:
    MODBUS_AVAILABLE = False

# ── Register indices (holding registers, 0-based) ────────────────────────────
REG_TON_US      = 0
REG_TOFF_US     = 1
REG_ENABLE      = 2
REG_CAPTURE_US  = 3
REG_FSAVE       = 4   # 0-10000 (× 0.01 %)
REG_FDISPLAY    = 5
# Input registers (read-only, mapped to holding regs 6-7 in server)
REG_PULSE_CNT   = 6
REG_WAVE_CNT    = 7

DEFAULT_HOST    = "192.168.1.100"
DEFAULT_PORT    = 502
STREAM_PORT     = 5005   # waveform stream from waveform_manager.py

PLOT_REFRESH_MS = 100   # ms between plot updates when connected / simulating


# ─────────────────────────────────────────────────────────────────────────────
# Simulation waveform generator
# ─────────────────────────────────────────────────────────────────────────────
class SimWaveform:
    """Generates one synthetic EDM waveform (CH1 voltage, CH2 current)."""

    def __init__(self, ton_us: int = 10, capture_us: int = 20):
        self.ton_us     = ton_us
        self.capture_us = capture_us

    def generate(self):
        n   = self.capture_us * 125          # samples at 125 MSPS
        t   = np.linspace(0, self.capture_us, n)  # µs

        # CH1: voltage – high before breakdown, drops to ~20-40 V during arc
        v_gap   = 60 + random.uniform(-5, 5)
        v_arc   = random.uniform(18, 35)
        bd_idx  = int(random.uniform(0.05, 0.30) * n)  # breakdown point

        ch1 = np.full(n, v_gap)
        ch1[bd_idx:] = v_arc + np.random.normal(0, 1.5, n - bd_idx)
        # Smooth transition
        ramp = min(15, bd_idx)
        ch1[bd_idx - ramp:bd_idx] = np.linspace(v_gap, v_arc, ramp)

        # CH2: current – zero before breakdown, arc current during pulse
        i_arc = random.uniform(3.0, 8.0)
        ch2 = np.zeros(n)
        ch2[bd_idx:] = i_arc + np.abs(np.random.normal(0, 0.5, n - bd_idx))
        # Exponential rise
        rise = min(20, n - bd_idx)
        ch2[bd_idx:bd_idx + rise] *= np.linspace(0, 1, rise)

        return t, ch1, ch2


# ─────────────────────────────────────────────────────────────────────────────
# Worker thread signals
# ─────────────────────────────────────────────────────────────────────────────
class WorkerSignals(QObject):
    waveform_ready = Signal(object, object, object)   # t, ch1, ch2
    status_update  = Signal(int, int)                 # pulse_cnt, wave_cnt
    connection_ok  = Signal(bool)
    error          = Signal(str)


# ─────────────────────────────────────────────────────────────────────────────
# Modbus / sim polling worker
# ─────────────────────────────────────────────────────────────────────────────
class PollWorker:
    def __init__(self, signals: WorkerSignals):
        self.signals    = signals
        self.stop_evt   = Event()
        self._thread    = None
        self.sim_mode   = False
        self.client     = None

        # Mirrored params (set by GUI thread)
        self.ton_us     = 10
        self.capture_us = 20

        # Sim counters
        self._pulse_cnt = 0
        self._wave_cnt  = 0

    # ── public API (called from GUI thread) ───────────────────────────────────
    def start(self, host: str, port: int, sim: bool):
        self.stop()
        self.sim_mode   = sim
        self._host      = host
        self._port      = port
        self.stop_evt.clear()
        self._thread    = Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self.stop_evt.set()
        if self._thread:
            self._thread.join(timeout=2)
        if self.client:
            try: self.client.close()
            except: pass
            self.client = None

    def write_param(self, reg: int, value: int):
        """Write a single holding register (no-op in sim mode)."""
        if self.sim_mode:
            self._apply_sim_param(reg, value)
            return
        if self.client and self.client.connected:
            self.client.write_register(reg, value)

    def _apply_sim_param(self, reg, value):
        if reg == REG_TON_US:
            self.ton_us = value
        elif reg == REG_CAPTURE_US:
            self.capture_us = value

    # ── worker loop ───────────────────────────────────────────────────────────
    def _run(self):
        if self.sim_mode:
            self._run_sim()
        else:
            self._run_modbus()

    def _run_sim(self):
        self.signals.connection_ok.emit(True)
        period_us = self.ton_us + max(10, self.ton_us * 9)  # 10 % duty sim
        t_next    = time.time()

        while not self.stop_evt.is_set():
            now = time.time()
            if now >= t_next:
                gen = SimWaveform(self.ton_us, self.capture_us)
                t, ch1, ch2 = gen.generate()
                self._pulse_cnt += 1
                self._wave_cnt  += 1
                self.signals.waveform_ready.emit(t, ch1, ch2)
                self.signals.status_update.emit(self._pulse_cnt, self._wave_cnt)
                t_next = now + (self.ton_us + self.ton_us * 9) / 1e6 * 1000
                # Clamp to at least 100 ms between waveforms for readability
                t_next = max(t_next, now + 0.1)
            time.sleep(0.01)

    def _run_modbus(self):
        if not MODBUS_AVAILABLE:
            self.signals.error.emit("pymodbus not installed")
            return
        try:
            self.client = ModbusTcpClient(self._host, port=self._port, timeout=3)
            if not self.client.connect():
                self.signals.connection_ok.emit(False)
                self.signals.error.emit(f"Cannot connect to {self._host}:{self._port}")
                return
            self.signals.connection_ok.emit(True)
        except Exception as e:
            self.signals.connection_ok.emit(False)
            self.signals.error.emit(str(e))
            return

        # Start waveform stream receiver in a separate thread
        stream_thread = Thread(target=self._run_stream, daemon=True)
        stream_thread.start()

        while not self.stop_evt.is_set():
            try:
                rr = self.client.read_holding_registers(REG_PULSE_CNT, 2)
                if not rr.isError():
                    self.signals.status_update.emit(rr.registers[0], rr.registers[1])
            except Exception:
                pass
            time.sleep(0.5)

        self.client.close()
        stream_thread.join(timeout=2)

    def _run_stream(self):
        """Connect to waveform_manager TCP stream and receive waveform frames."""
        while not self.stop_evt.is_set():
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                sock.settimeout(3)
                sock.connect((self._host, STREAM_PORT))
                sock.settimeout(None)
            except Exception as e:
                self.signals.error.emit(f"Waveform stream: {e}")
                time.sleep(3)
                continue

            try:
                while not self.stop_evt.is_set():
                    # Read 4-byte header: n_samples
                    header = self._recv_exact(sock, 4)
                    if header is None:
                        break
                    n = struct.unpack("<I", header)[0]
                    if n == 0 or n > 1_000_000:
                        break

                    body = self._recv_exact(sock, n * 8)  # ch1 + ch2, float32 each
                    if body is None:
                        break

                    ch1 = np.frombuffer(body[:n * 4], dtype=np.float32).copy()
                    ch2 = np.frombuffer(body[n * 4:], dtype=np.float32).copy()
                    t   = np.arange(n, dtype=np.float32) / 125.0  # µs at 125 MSPS
                    self.signals.waveform_ready.emit(t, ch1, ch2)
            except Exception:
                pass
            finally:
                try: sock.close()
                except: pass

    @staticmethod
    def _recv_exact(sock: socket.socket, n: int):
        """Read exactly n bytes from sock; return None on connection loss."""
        buf = bytearray()
        while len(buf) < n:
            try:
                chunk = sock.recv(n - len(buf))
            except Exception:
                return None
            if not chunk:
                return None
            buf.extend(chunk)
        return bytes(buf)


# ─────────────────────────────────────────────────────────────────────────────
# Waveform plot widget
# ─────────────────────────────────────────────────────────────────────────────
class WaveformWidget(QWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self.fig = Figure(figsize=(6, 4), tight_layout=True)
        self.ax1, self.ax2 = self.fig.subplots(2, 1, sharex=True)

        self.ax1.set_ylabel("Voltage (V)")
        self.ax1.set_ylim(-5, 100)
        self.ax1.grid(True, alpha=0.3)
        self.ax1.set_title("CH1 – Gap Voltage", fontsize=9)

        self.ax2.set_ylabel("Current (A)")
        self.ax2.set_xlabel("Time (µs)")
        self.ax2.set_ylim(-0.5, 12)
        self.ax2.grid(True, alpha=0.3)
        self.ax2.set_title("CH2 – Arc Current", fontsize=9)

        self.line1, = self.ax1.plot([], [], color="#2196F3", lw=0.8)
        self.line2, = self.ax2.plot([], [], color="#F44336", lw=0.8)

        self.canvas = FigureCanvas(self.fig)
        self.canvas.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)

        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(self.canvas)

    def update_waveform(self, t, ch1, ch2):
        self.line1.set_data(t, ch1)
        self.line2.set_data(t, ch2)
        self.ax1.set_xlim(t[0], t[-1])
        self.ax2.set_xlim(t[0], t[-1])
        self.canvas.draw_idle()


# ─────────────────────────────────────────────────────────────────────────────
# Statistics panel (stub — expandable later)
# ─────────────────────────────────────────────────────────────────────────────
class StatsWidget(QGroupBox):
    def __init__(self, parent=None):
        super().__init__("Statistics", parent)
        form = QFormLayout(self)
        self._v_peak  = QLabel("—")
        self._i_peak  = QLabel("—")
        self._energy  = QLabel("—")
        self._rate    = QLabel("—")
        form.addRow("V peak (V):", self._v_peak)
        form.addRow("I peak (A):", self._i_peak)
        form.addRow("Energy (µJ):", self._energy)
        form.addRow("Pulse rate (Hz):", self._rate)

        self._count = 0
        self._t_start = time.time()

    def update(self, t, ch1, ch2):
        self._count += 1
        dt_us   = (t[-1] - t[0]) / (len(t) - 1) if len(t) > 1 else 0.008  # µs
        v_peak  = float(np.max(ch1))
        i_peak  = float(np.max(ch2))
        energy  = float(np.trapz(ch1 * ch2, t))  # V·A·µs = µJ

        elapsed = time.time() - self._t_start
        rate    = self._count / elapsed if elapsed > 0 else 0

        self._v_peak.setText(f"{v_peak:.1f}")
        self._i_peak.setText(f"{i_peak:.2f}")
        self._energy.setText(f"{energy:.1f}")
        self._rate.setText(f"{rate:.1f}")


# ─────────────────────────────────────────────────────────────────────────────
# Main window
# ─────────────────────────────────────────────────────────────────────────────
class OperatorConsole(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("EDM Controller – Operator Console")
        self.resize(1100, 620)

        self._signals = WorkerSignals()
        self._worker  = PollWorker(self._signals)

        self._signals.waveform_ready.connect(self._on_waveform)
        self._signals.status_update.connect(self._on_status)
        self._signals.connection_ok.connect(self._on_connection)
        self._signals.error.connect(self._on_error)

        self._build_ui()

    # ── UI construction ───────────────────────────────────────────────────────
    def _build_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        root = QHBoxLayout(central)
        root.setSpacing(8)

        # ── Left panel ────────────────────────────────────────────────────────
        left = QVBoxLayout()
        left.setSpacing(8)
        root.addLayout(left, stretch=0)

        # Connection
        conn_box = QGroupBox("Connection")
        cf = QFormLayout(conn_box)
        self._host_edit = QLineEdit(DEFAULT_HOST)
        self._port_edit = QLineEdit(str(DEFAULT_PORT))
        self._sim_chk   = QCheckBox("Simulation mode")
        self._sim_chk.setChecked(True)
        self._conn_btn  = QPushButton("Connect")
        self._conn_btn.setCheckable(True)
        self._conn_btn.clicked.connect(self._toggle_connect)
        cf.addRow("Host:", self._host_edit)
        cf.addRow("Port:", self._port_edit)
        cf.addRow("", self._sim_chk)
        cf.addRow("", self._conn_btn)
        left.addWidget(conn_box)

        # Parameters
        param_box = QGroupBox("Parameters")
        pf = QFormLayout(param_box)

        self._ton_spin     = self._make_spin(1, 10000, 10,  "µs")
        self._toff_spin    = self._make_spin(1, 100000, 90, "µs")
        self._capture_spin = self._make_spin(1, 10000, 20,  "µs")
        self._fsave_spin   = self._make_dspin(0, 100, 1.00,  "%")
        self._fdisp_spin   = self._make_dspin(0, 100, 10.00, "%")
        self._enable_btn   = QPushButton("Enable Pulses")
        self._enable_btn.setCheckable(True)
        self._enable_btn.setStyleSheet(
            "QPushButton:checked { background-color: #4CAF50; color: white; font-weight: bold; }"
        )
        self._enable_btn.clicked.connect(self._on_enable)

        pf.addRow("Ton (µs):",       self._ton_spin)
        pf.addRow("Toff (µs):",      self._toff_spin)
        pf.addRow("Capture (µs):",   self._capture_spin)
        pf.addRow("Save fraction:",  self._fsave_spin)
        pf.addRow("Disp fraction:",  self._fdisp_spin)
        pf.addRow("",                self._enable_btn)

        apply_btn = QPushButton("Apply Parameters")
        apply_btn.clicked.connect(self._apply_params)
        pf.addRow("", apply_btn)
        left.addWidget(param_box)

        # Status
        status_box = QGroupBox("Status")
        sf = QFormLayout(status_box)
        self._lbl_pulse = QLabel("—")
        self._lbl_wave  = QLabel("—")
        self._lbl_conn  = QLabel("Disconnected")
        self._lbl_conn.setStyleSheet("color: gray;")
        sf.addRow("Pulse count:", self._lbl_pulse)
        sf.addRow("Wave count:",  self._lbl_wave)
        sf.addRow("Link:",        self._lbl_conn)
        left.addWidget(status_box)

        left.addStretch()

        # ── Right panel ───────────────────────────────────────────────────────
        right = QVBoxLayout()
        root.addLayout(right, stretch=1)

        self._wave_widget = WaveformWidget()
        right.addWidget(self._wave_widget, stretch=3)

        self._stats_widget = StatsWidget()
        right.addWidget(self._stats_widget, stretch=0)

        # Status bar
        self.statusBar().showMessage("Ready — enable Simulation mode and click Connect")

    # ── helpers ───────────────────────────────────────────────────────────────
    @staticmethod
    def _make_spin(lo, hi, val, suffix=""):
        s = QSpinBox()
        s.setRange(lo, hi)
        s.setValue(val)
        s.setSuffix(f" {suffix}" if suffix else "")
        s.setMinimumWidth(90)
        return s

    @staticmethod
    def _make_dspin(lo, hi, val, suffix=""):
        s = QDoubleSpinBox()
        s.setRange(lo, hi)
        s.setValue(val)
        s.setDecimals(2)
        s.setSuffix(f" {suffix}" if suffix else "")
        s.setMinimumWidth(90)
        return s

    # ── slots ─────────────────────────────────────────────────────────────────
    def _toggle_connect(self, checked: bool):
        if checked:
            self._conn_btn.setText("Disconnect")
            host = self._host_edit.text().strip()
            port = int(self._port_edit.text().strip())
            sim  = self._sim_chk.isChecked()
            self._host_edit.setEnabled(False)
            self._port_edit.setEnabled(False)
            self._sim_chk.setEnabled(False)
            self._worker.start(host, port, sim)
        else:
            self._conn_btn.setText("Connect")
            self._worker.stop()
            self._lbl_conn.setText("Disconnected")
            self._lbl_conn.setStyleSheet("color: gray;")
            self._host_edit.setEnabled(True)
            self._port_edit.setEnabled(True)
            self._sim_chk.setEnabled(True)
            self.statusBar().showMessage("Disconnected")

    def _on_enable(self, checked: bool):
        self._enable_btn.setText("Disable Pulses" if checked else "Enable Pulses")
        self._worker.write_param(REG_ENABLE, 1 if checked else 0)

    def _apply_params(self):
        ton      = self._ton_spin.value()
        toff     = self._toff_spin.value()
        cap      = self._capture_spin.value()
        f_save   = int(round(self._fsave_spin.value() * 100))   # → 0-10000
        f_disp   = int(round(self._fdisp_spin.value() * 100))

        self._worker.ton_us     = ton
        self._worker.capture_us = cap

        self._worker.write_param(REG_TON_US,     ton)
        self._worker.write_param(REG_TOFF_US,    toff)
        self._worker.write_param(REG_CAPTURE_US, cap)
        self._worker.write_param(REG_FSAVE,      f_save)
        self._worker.write_param(REG_FDISPLAY,   f_disp)
        self.statusBar().showMessage(
            f"Parameters applied: Ton={ton}µs  Toff={toff}µs  Cap={cap}µs"
        )

    def _on_waveform(self, t, ch1, ch2):
        self._wave_widget.update_waveform(t, ch1, ch2)
        self._stats_widget.update(t, ch1, ch2)

    def _on_status(self, pulse_cnt: int, wave_cnt: int):
        self._lbl_pulse.setText(str(pulse_cnt))
        self._lbl_wave.setText(str(wave_cnt))

    def _on_connection(self, ok: bool):
        if ok:
            mode = "Simulation" if self._sim_chk.isChecked() else "Hardware"
            self._lbl_conn.setText(f"Connected ({mode})")
            self._lbl_conn.setStyleSheet("color: #4CAF50; font-weight: bold;")
            self.statusBar().showMessage(f"{mode} mode active")
        else:
            self._lbl_conn.setText("Failed")
            self._lbl_conn.setStyleSheet("color: #F44336;")

    def _on_error(self, msg: str):
        self.statusBar().showMessage(f"Error: {msg}")

    def closeEvent(self, event):
        self._worker.stop()
        super().closeEvent(event)


# ─────────────────────────────────────────────────────────────────────────────
def main():
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    win = OperatorConsole()
    win.show()
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
