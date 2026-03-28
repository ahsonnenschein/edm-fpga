#!/usr/bin/env python3
"""
operator_console.py  —  EDM Controller Operator Console (PYNQ-Z2)

Left panel:  Connection | Parameters | Status
Right panel: Per-burst waveform (CH1 gap voltage, CH2 arc current) + statistics

Waveform display shows the most recent continuous block of samples where
'enable' was active (sparks running), subsampled by the prescale factor.

Connects to xadc_server.py running on the PYNQ-Z2 board.
Simulation mode works without a board connection.
"""

import sys, time, json, math, random, socket
import numpy as np
from collections import deque
from threading import Thread, Event

from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QGroupBox, QLabel, QLineEdit, QPushButton, QCheckBox,
    QSpinBox, QFormLayout, QSizePolicy, QFrame,
)
from PySide6.QtCore import Qt, QTimer, Signal, QObject
from PySide6.QtGui import QFont

import matplotlib
matplotlib.use("QtAgg")
from matplotlib.backends.backend_qtagg import FigureCanvasQTAgg as FigureCanvas
from matplotlib.figure import Figure

DEFAULT_HOST    = "192.168.2.99"
SERVER_PORT     = 5006
PLOT_REFRESH_MS = 100       # 10 fps
BUF_MAX         = 60_000    # ~5 min at 200 Hz


# ─────────────────────────────────────────────────────────────────────────────
# Simulation waveform generator
# ─────────────────────────────────────────────────────────────────────────────
class SimSource:
    """
    Generates a realistic EDM gap voltage / arc current time-series at ~200 Hz.
    Models the pulse-idle-breakdown-arc cycle visible on a real oscilloscope.
    """
    def __init__(self):
        self.ton_us   = 10
        self.toff_us  = 90
        self.enable   = False
        self._phase   = 0.0
        self._in_arc  = False
        self._bd_frac = 0.2
        self._pulse_count = 0
        self._t_last  = time.time()

    def sample(self):
        """Return (ch1_V, ch2_V) at the current simulated instant."""
        now = time.time()
        dt  = now - self._t_last
        self._t_last = now

        if not self.enable:
            return 0.0, 0.0

        period_us = self.ton_us + self.toff_us
        self._phase = (self._phase + dt * 1e6 / period_us) % 1.0
        ton_frac  = self.ton_us / period_us

        if self._phase < ton_frac:
            pos_in_ton = self._phase / ton_frac
            if pos_in_ton < self._bd_frac:
                ch1 = 55 + random.gauss(0, 1.0)
                ch2 = 0.0
            else:
                if not self._in_arc:
                    self._in_arc = True
                    self._pulse_count += 1
                    self._bd_frac = random.uniform(0.1, 0.5)
                ch1 = random.gauss(22, 2.0)
                ch2 = random.gauss(0.8, 0.05)
        else:
            self._in_arc = False
            ch1 = 0.0
            ch2 = 0.0

        return max(0.0, ch1), max(0.0, ch2)

    @property
    def pulse_count(self):
        return self._pulse_count


# ─────────────────────────────────────────────────────────────────────────────
# Worker signals
# ─────────────────────────────────────────────────────────────────────────────
class WorkerSignals(QObject):
    sample_ready  = Signal(float, float, float)   # ch1, ch2, ts  (status frame)
    burst_ready   = Signal(object, object)         # ch1_list, ch2_list (burst frame)
    status_update = Signal(dict)
    connection_ok = Signal(bool)
    error         = Signal(str)


# ─────────────────────────────────────────────────────────────────────────────
# Poll / sim worker
# ─────────────────────────────────────────────────────────────────────────────
class PollWorker:
    def __init__(self, signals: WorkerSignals):
        self.signals   = signals
        self.stop_evt  = Event()
        self._thread   = None
        self.sim_mode  = True
        self._sim      = SimSource()

    def start(self, host: str, sim: bool):
        self.stop()
        self.sim_mode = sim
        self._host    = host
        self.stop_evt.clear()
        self._thread  = Thread(target=self._run, daemon=True)
        self._thread.start()

    def stop(self):
        self.stop_evt.set()
        if self._thread:
            self._thread.join(timeout=2)

    def send_cmd(self, cmd: dict):
        if self.sim_mode:
            self._apply_sim_cmd(cmd)
            return
        if hasattr(self, '_sock') and self._sock:
            try:
                self._sock.sendall(json.dumps(cmd).encode() + b'\n')
            except Exception:
                pass

    def _apply_sim_cmd(self, cmd):
        c = cmd.get('cmd', '')
        v = cmd.get('value', 0)
        if c == 'set_ton':    self._sim.ton_us   = int(v)
        elif c == 'set_toff': self._sim.toff_us  = int(v)
        elif c == 'set_enable': self._sim.enable = bool(v)

    def _run(self):
        if self.sim_mode: self._run_sim()
        else:             self._run_network()

    def _run_sim(self):
        self.signals.connection_ok.emit(True)
        while not self.stop_evt.is_set():
            ch1, ch2 = self._sim.sample()
            ts = time.time()
            self.signals.sample_ready.emit(ch1, ch2, ts)
            self.signals.status_update.emit({
                'pulse_count': self._sim.pulse_count,
                'hv_enable':   1,
                'enable':      int(self._sim.enable),
                'temp':        45.0,
            })
            time.sleep(0.005)

    def _run_network(self):
        self._sock = None
        try:
            self._sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self._sock.settimeout(5)
            self._sock.connect((self._host, SERVER_PORT))
            self._sock.settimeout(2)
            self.signals.connection_ok.emit(True)
        except Exception as e:
            self.signals.connection_ok.emit(False)
            self.signals.error.emit(f"Cannot connect to {self._host}:{SERVER_PORT}: {e}")
            return

        buf = b''
        try:
            while not self.stop_evt.is_set():
                try:
                    data = self._sock.recv(4096)
                    if not data:
                        break
                    buf += data
                    while b'\n' in buf:
                        line, buf = buf.split(b'\n', 1)
                        try:
                            d = json.loads(line)
                            if d.get('type') == 'burst':
                                self.signals.burst_ready.emit(
                                    d.get('ch1', []),
                                    d.get('ch2', []),
                                )
                            else:
                                self.signals.sample_ready.emit(
                                    d.get('ch1', 0.0),
                                    d.get('ch2', 0.0),
                                    d.get('ts',  time.time()),
                                )
                                self.signals.status_update.emit(d)
                        except Exception:
                            pass
                except socket.timeout:
                    continue
                except Exception:
                    break
        finally:
            try:
                self._sock.close()
            except Exception:
                pass
            self._sock = None
            if not self.stop_evt.is_set():
                self.signals.error.emit("Connection lost")
                self.signals.connection_ok.emit(False)


# ─────────────────────────────────────────────────────────────────────────────
# Per-burst waveform widget
# ─────────────────────────────────────────────────────────────────────────────
class WaveformWidget(QWidget):
    """
    Displays a rolling window of the most recent samples received while
    enable=1 (sparks active), sized to show approximately 10 Ton+Toff cycles.

    Call set_timing(ton_us, toff_us) whenever the pulse parameters change so
    the window width stays calibrated.  A prescale of N shows every Nth sample.

    Each entry in the buffer is (ts, ch1, ch2, enable).
    """

    PULSE_WINDOW = 10   # number of Ton+Toff cycles to display

    def __init__(self, parent=None):
        super().__init__(parent)
        self._buf      = deque(maxlen=BUF_MAX)
        self._prescale = 1
        self._ton_us   = 10
        self._toff_us  = 90
        self._has_burst  = False
        self._burst_ch1  = np.array([])
        self._burst_ch2  = np.array([])
        self._burst_t    = np.array([])

        self.fig = Figure(figsize=(7, 4), tight_layout=True)
        self.fig.patch.set_facecolor('#1e1e1e')
        self.ax1, self.ax2 = self.fig.subplots(2, 1, sharex=True)

        for ax in (self.ax1, self.ax2):
            ax.set_facecolor('#1e1e1e')
            ax.tick_params(colors='#cccccc', labelsize=8)
            ax.grid(True, color='#333333', linewidth=0.5)
            for spine in ax.spines.values():
                spine.set_edgecolor('#444444')

        self.ax1.set_ylabel("Gap Voltage (V)", color='#cccccc', fontsize=8)
        self.ax1.set_ylim(-2, 80)
        self.ax1.yaxis.label.set_color('#cccccc')

        self.ax2.set_ylabel("Arc Current proxy (V)", color='#cccccc', fontsize=8)
        self.ax2.set_xlabel("Time in burst (s)", color='#cccccc', fontsize=8)
        self.ax2.set_ylim(-0.1, 3.5)
        self.ax2.yaxis.label.set_color('#cccccc')

        self.line1, = self.ax1.plot([], [], color='#2196F3', lw=0.8)
        self.line2, = self.ax2.plot([], [], color='#F44336', lw=0.8)

        self._title1 = self.ax1.set_title(
            "CH1 – Gap Voltage", color='#cccccc', fontsize=9)
        self._title2 = self.ax2.set_title(
            "CH2 – Arc Current (GEDM output)", color='#cccccc', fontsize=9)

        self.canvas = FigureCanvas(self.fig)
        self.canvas.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(self.canvas)

    def add_sample(self, ch1: float, ch2: float, ts: float, enable: bool):
        self._buf.append((ts, ch1, ch2, enable))

    def add_burst(self, ch1_list: list, ch2_list: list):
        """Replace display with a hardware DMA burst (already at ~500 kSPS)."""
        if not ch1_list:
            return
        n    = len(ch1_list)
        dt   = 1.0 / 500_000   # ~500 kSPS per channel
        now  = time.time()
        self._burst_ch1 = np.array(ch1_list, dtype=np.float32)
        self._burst_ch2 = np.array(ch2_list, dtype=np.float32)
        self._burst_t   = np.arange(n) * dt
        self._has_burst = True

    def set_prescale(self, n: int):
        self._prescale = max(1, n)

    def set_timing(self, ton_us: int, toff_us: int):
        self._ton_us  = max(1, ton_us)
        self._toff_us = max(1, toff_us)

    def _window_seconds(self):
        # Pulse-period window, but never less than 1 s so there are always
        # visible samples regardless of sample rate vs pulse rate.
        return max(self.PULSE_WINDOW * (self._ton_us + self._toff_us) * 1e-6, 1.0)

    def refresh(self):
        # Hardware DMA bursts take priority over the 200 Hz status samples
        if self._has_burst:
            self._refresh_burst()
            return

        if not self._buf:
            return

        buf = list(self._buf)
        end = len(buf) - 1

        # If currently disabled, find the most recent sample where enable was True
        if not buf[end][3]:
            while end >= 0 and not buf[end][3]:
                end -= 1
            if end < 0:
                self._show_idle()
                return

        # Walk back to find the start of this enable=1 run
        start = end
        while start > 0 and buf[start - 1][3]:
            start -= 1

        burst = buf[start:end + 1]
        if len(burst) < 2:
            return

        # Trim to the most recent ~10 pulse periods
        window_s  = self._window_seconds()
        t_cutoff  = burst[-1][0] - window_s
        trim_start = 0
        for i, s in enumerate(burst):
            if s[0] >= t_cutoff:
                trim_start = i
                break
        burst = burst[trim_start:]

        # Apply prescale
        n   = self._prescale
        sub = burst[::n]

        ts_arr  = np.array([s[0] for s in sub])
        ch1_arr = np.array([s[1] for s in sub])
        ch2_arr = np.array([s[2] for s in sub])
        t_rel   = ts_arr - ts_arr[0]

        self.line1.set_data(t_rel, ch1_arr)
        self.line2.set_data(t_rel, ch2_arr)

        x_max = max(window_s, t_rel[-1], 0.001)
        self.ax1.set_xlim(0, x_max)
        self.ax2.set_xlim(0, x_max)

        live      = buf[-1][3]
        state_tag = "LIVE" if live else "last burst"
        n_total   = len(burst)
        dur_ms    = window_s * 1000

        self._title1.set_text(
            f"CH1 – Gap Voltage  [last {self.PULSE_WINDOW} pulses "
            f"({dur_ms:.3g} ms), {n_total} samples, 1/{n} shown — {state_tag}]"
        )
        self.canvas.draw_idle()

    def _refresh_burst(self):
        n   = self._prescale
        sub_t   = self._burst_t[::n]
        sub_ch1 = self._burst_ch1[::n]
        sub_ch2 = self._burst_ch2[::n]
        self.line1.set_data(sub_t * 1e6, sub_ch1)   # x in µs
        self.line2.set_data(sub_t * 1e6, sub_ch2)
        x_max = max(self._burst_t[-1] * 1e6, 1.0)
        self.ax1.set_xlim(0, x_max)
        self.ax2.set_xlim(0, x_max)
        self.ax2.set_xlabel("Time in pulse (µs)", color='#cccccc', fontsize=8)
        n_total = len(self._burst_ch1)
        self._title1.set_text(
            f"CH1 – Gap Voltage  [{n_total} samples @ ~500 kSPS, 1/{n} shown — HW burst]"
        )
        self.canvas.draw_idle()

    def _show_idle(self):
        self.line1.set_data([], [])
        self.line2.set_data([], [])
        self._title1.set_text("CH1 – Gap Voltage  [waiting for enable…]")
        self.canvas.draw_idle()

    # expose arrays for stats
    def last_burst_arrays(self):
        """Return (ch1_arr, ch2_arr) for the most recent burst, or empty arrays."""
        buf = list(self._buf)
        end = len(buf) - 1
        if not buf:
            return np.array([]), np.array([])
        if not buf[end][3]:
            while end >= 0 and not buf[end][3]:
                end -= 1
            if end < 0:
                return np.array([]), np.array([])
        start = end
        while start > 0 and buf[start - 1][3]:
            start -= 1
        burst = buf[start:end + 1]
        return (np.array([s[1] for s in burst]),
                np.array([s[2] for s in burst]))


# ─────────────────────────────────────────────────────────────────────────────
# Statistics panel
# ─────────────────────────────────────────────────────────────────────────────
class StatsWidget(QGroupBox):
    def __init__(self, parent=None):
        super().__init__("Statistics", parent)
        f = QFormLayout(self)
        self._v_peak   = QLabel("—")
        self._ch2_peak = QLabel("—")
        self._rate     = QLabel("—")
        self._temp     = QLabel("—")
        f.addRow("V peak (V):",      self._v_peak)
        f.addRow("CH2 peak (V):",    self._ch2_peak)
        f.addRow("Pulse rate (Hz):", self._rate)
        f.addRow("Chip temp (°C):",  self._temp)

        self._last_pulse_count  = 0
        self._t_start           = time.time()
        self._pulses_in_window  = 0

    def update(self, ch1_arr, ch2_arr, status: dict):
        if len(ch1_arr):
            self._v_peak.setText(f"{float(np.max(ch1_arr)):.1f}")
            self._ch2_peak.setText(f"{float(np.max(ch2_arr)):.3f}")

        pcnt = status.get('pulse_count', 0)
        dp   = pcnt - self._last_pulse_count
        self._last_pulse_count = pcnt
        if dp > 0:
            self._pulses_in_window += dp
        elapsed = time.time() - self._t_start
        if elapsed > 1.0:
            self._rate.setText(f"{self._pulses_in_window / elapsed:.1f}")
            if elapsed > 10:
                self._pulses_in_window = 0
                self._t_start = time.time()

        temp = status.get('temp')
        if temp is not None:
            self._temp.setText(f"{temp:.1f}")


# ─────────────────────────────────────────────────────────────────────────────
# Main window
# ─────────────────────────────────────────────────────────────────────────────
class OperatorConsole(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("EDM Controller – PYNQ-Z2")
        self.resize(1200, 700)

        self._signals     = WorkerSignals()
        self._worker      = PollWorker(self._signals)
        self._last_status : dict = {}
        self._last_enable : bool = False

        self._signals.sample_ready.connect(self._on_sample)
        self._signals.burst_ready.connect(self._on_burst)
        self._signals.status_update.connect(self._on_status)
        self._signals.connection_ok.connect(self._on_connection)
        self._signals.error.connect(self._on_error)

        self._build_ui()

        self._plot_timer = QTimer(self)
        self._plot_timer.timeout.connect(self._refresh_plot)
        self._plot_timer.start(PLOT_REFRESH_MS)

    # ── UI ────────────────────────────────────────────────────────────────────

    def _build_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        root = QHBoxLayout(central)
        root.setSpacing(8)

        # ── Left panel ────────────────────────────────────────────────────────
        left = QVBoxLayout()
        left.setSpacing(6)
        root.addLayout(left, stretch=0)

        # Connection
        cbox = QGroupBox("Connection")
        cf   = QFormLayout(cbox)
        self._host_edit = QLineEdit(DEFAULT_HOST)
        self._sim_chk   = QCheckBox("Simulation mode")
        self._sim_chk.setChecked(True)
        self._conn_btn  = QPushButton("Connect")
        self._conn_btn.setCheckable(True)
        self._conn_btn.clicked.connect(self._toggle_connect)
        cf.addRow("Board IP:", self._host_edit)
        cf.addRow("",          self._sim_chk)
        cf.addRow("",          self._conn_btn)
        left.addWidget(cbox)

        # Parameters
        pbox = QGroupBox("Parameters")
        pf   = QFormLayout(pbox)
        self._ton_spin  = QSpinBox()
        self._ton_spin.setRange(1, 10000)
        self._ton_spin.setValue(10)
        self._ton_spin.setSuffix(" µs")
        self._toff_spin = QSpinBox()
        self._toff_spin.setRange(1, 100000)
        self._toff_spin.setValue(90)
        self._toff_spin.setSuffix(" µs")
        self._enable_btn = QPushButton("Enable Pulses")
        self._enable_btn.setCheckable(True)
        self._enable_btn.setStyleSheet(
            "QPushButton:checked { background-color: #c62828; color: white; font-weight: bold; }"
        )
        self._enable_btn.clicked.connect(self._on_enable)
        apply_btn = QPushButton("Apply")
        apply_btn.clicked.connect(self._apply_params)
        pf.addRow("Ton:",  self._ton_spin)
        pf.addRow("Toff:", self._toff_spin)
        pf.addRow("",      apply_btn)
        pf.addRow("",      self._enable_btn)
        left.addWidget(pbox)

        # Status
        sbox = QGroupBox("Status")
        sf   = QFormLayout(sbox)
        self._lbl_conn   = QLabel("Disconnected")
        self._lbl_conn.setStyleSheet("color: gray;")
        self._lbl_pulse  = QLabel("—")
        self._lbl_hven   = QLabel("—")
        self._lbl_enable = QLabel("—")
        sf.addRow("Link:",        self._lbl_conn)
        sf.addRow("Pulse count:", self._lbl_pulse)
        sf.addRow("HV switch:",   self._lbl_hven)
        sf.addRow("Sparks:",      self._lbl_enable)
        left.addWidget(sbox)

        left.addStretch()

        # ── Right panel ───────────────────────────────────────────────────────
        right = QVBoxLayout()
        root.addLayout(right, stretch=1)

        # Prescale control bar
        pscale_row = QHBoxLayout()
        pscale_row.addWidget(QLabel("Prescale  1/"))
        self._prescale_spin = QSpinBox()
        self._prescale_spin.setRange(1, 1000)
        self._prescale_spin.setValue(1)
        self._prescale_spin.setToolTip(
            "Show every Nth sample.  1 = show all,  10 = show every 10th sample."
        )
        self._prescale_spin.valueChanged.connect(self._on_prescale_changed)
        pscale_row.addWidget(self._prescale_spin)
        pscale_row.addStretch()
        right.addLayout(pscale_row)

        self._wave_widget = WaveformWidget()
        self._wave_widget.set_timing(
            self._ton_spin.value(), self._toff_spin.value()
        )
        right.addWidget(self._wave_widget, stretch=3)

        self._stats_widget = StatsWidget()
        right.addWidget(self._stats_widget, stretch=0)

        self.statusBar().showMessage(
            "Enable Simulation mode and click Connect, or enter board IP and connect to hardware."
        )

    # ── slots ─────────────────────────────────────────────────────────────────

    def _toggle_connect(self, checked: bool):
        if checked:
            self._conn_btn.setText("Disconnect")
            self._host_edit.setEnabled(False)
            self._sim_chk.setEnabled(False)
            self._worker.start(self._host_edit.text().strip(), self._sim_chk.isChecked())
        else:
            self._conn_btn.setText("Connect")
            self._worker.stop()
            self._lbl_conn.setText("Disconnected")
            self._lbl_conn.setStyleSheet("color: gray;")
            self._host_edit.setEnabled(True)
            self._sim_chk.setEnabled(True)
            self.statusBar().showMessage("Disconnected.")

    def _on_enable(self, checked: bool):
        self._enable_btn.setText("Disable Pulses" if checked else "Enable Pulses")
        self._worker.send_cmd({'cmd': 'set_enable', 'value': 1 if checked else 0})

    def _apply_params(self):
        ton  = self._ton_spin.value()
        toff = self._toff_spin.value()
        self._worker.send_cmd({'cmd': 'set_ton',  'value': ton})
        self._worker.send_cmd({'cmd': 'set_toff', 'value': toff})
        self._wave_widget.set_timing(ton, toff)
        self.statusBar().showMessage(f"Parameters applied: Ton={ton}µs  Toff={toff}µs")

    def _on_prescale_changed(self, value: int):
        self._wave_widget.set_prescale(value)

    def _on_sample(self, ch1: float, ch2: float, ts: float):
        self._wave_widget.add_sample(ch1, ch2, ts, self._last_enable)

    def _on_burst(self, ch1_list, ch2_list):
        self._wave_widget.add_burst(ch1_list, ch2_list)

    def _on_status(self, d: dict):
        self._last_status = d
        self._last_enable = bool(d.get('enable', 0))
        self._lbl_pulse.setText(str(d.get('pulse_count', '—')))

        hven = d.get('hv_enable')
        if hven is not None:
            if hven:
                self._lbl_hven.setText("ON")
                self._lbl_hven.setStyleSheet("color: #F44336; font-weight: bold;")
            else:
                self._lbl_hven.setText("OFF")
                self._lbl_hven.setStyleSheet("color: #4CAF50;")

        en = d.get('enable')
        if en is not None:
            if en:
                self._lbl_enable.setText("RUNNING")
                self._lbl_enable.setStyleSheet("color: #F44336; font-weight: bold;")
            else:
                self._lbl_enable.setText("Stopped")
                self._lbl_enable.setStyleSheet("color: #888888;")

    def _refresh_plot(self):
        self._wave_widget.refresh()
        ch1_arr, ch2_arr = self._wave_widget.last_burst_arrays()
        self._stats_widget.update(ch1_arr, ch2_arr, self._last_status)

    def _on_connection(self, ok: bool):
        if ok:
            mode = "Simulation" if self._sim_chk.isChecked() else "Hardware"
            self._lbl_conn.setText(f"Connected ({mode})")
            self._lbl_conn.setStyleSheet("color: #4CAF50; font-weight: bold;")
            self.statusBar().showMessage(f"{mode} mode active.")
        else:
            self._lbl_conn.setText("Disconnected")
            self._lbl_conn.setStyleSheet("color: gray;")

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
