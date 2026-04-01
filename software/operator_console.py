#!/usr/bin/env python3
"""
operator_console.py  —  EDM Controller Operator Console (PYNQ-Z2)

Left panel:  Connection | Parameters | Status
Right panel: Per-burst waveform (CH1 arc current, CH2 gap voltage) + statistics

Waveform display shows the most recent continuous block of samples where
'enable' was active (sparks running), subsampled by the prescale factor.

Connects to xadc_server.py running on the PYNQ-Z2 board.
"""

import sys, time, json, math, socket
import numpy as np
from collections import deque
from threading import Thread, Event

from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QGroupBox, QLabel, QLineEdit, QPushButton,
    QSpinBox, QDoubleSpinBox, QFormLayout, QSizePolicy, QFrame,
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
HIST_BUF_MAX    = 12_000    # 1 min at 200 Hz



# ─────────────────────────────────────────────────────────────────────────────
# Worker signals
# ─────────────────────────────────────────────────────────────────────────────
class WorkerSignals(QObject):
    sample_ready  = Signal(float, float, float)   # ch1, ch2, ts  (status frame)
    burst_ready   = Signal(object, object, object)  # ch1_list, ch2_list, pulse_list (burst frame)
    gap_batch     = Signal(object)                   # list of per-pulse gap averages
    gap_stats     = Signal(float, float, int)        # avg, std, n
    status_update = Signal(dict)
    connection_ok = Signal(bool)
    error         = Signal(str)


# ─────────────────────────────────────────────────────────────────────────────
# Network worker
# ─────────────────────────────────────────────────────────────────────────────
class PollWorker:
    def __init__(self, signals: WorkerSignals):
        self.signals   = signals
        self.stop_evt  = Event()
        self._thread   = None

    def start(self, host: str):
        self.stop()
        self._host    = host
        self.stop_evt.clear()
        self._thread  = Thread(target=self._run_network, daemon=True)
        self._thread.start()

    def stop(self):
        self.stop_evt.set()
        if self._thread:
            self._thread.join(timeout=2)

    def send_cmd(self, cmd: dict):
        if hasattr(self, '_sock') and self._sock:
            try:
                self._sock.sendall(json.dumps(cmd).encode() + b'\n')
            except Exception:
                pass

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
                                    d.get('pulse', []),
                                )
                            elif d.get('type') == 'gap_batch':
                                self.signals.gap_batch.emit(d.get('values', []))
                            elif d.get('type') == 'gap_stats':
                                self.signals.gap_stats.emit(
                                    d.get('avg', 0), d.get('std', 0), d.get('n', 0))
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
        self._burst_history = deque(maxlen=50)   # last 50 bursts overlaid

        self.fig = Figure(figsize=(7, 4), tight_layout=True)
        self.fig.patch.set_facecolor('#1e1e1e')
        self.ax1, self.ax2 = self.fig.subplots(2, 1, sharex=True)

        for ax in (self.ax1, self.ax2):
            ax.set_facecolor('#1e1e1e')
            ax.tick_params(colors='#cccccc', labelsize=8)
            ax.grid(True, color='#333333', linewidth=0.5)
            for spine in ax.spines.values():
                spine.set_edgecolor('#444444')

        self.ax1.set_ylabel("Arc Current (A)", color='#cccccc', fontsize=8)
        self.ax1.margins(y=0.12)
        self.ax1.yaxis.label.set_color('#cccccc')

        self.ax2.set_ylabel("Gap Voltage (V)", color='#cccccc', fontsize=8)
        self.ax2.set_xlabel("Time (s)  [status stream — enable pulses to see burst waveforms]", color='#cccccc', fontsize=8)
        self.ax2.margins(y=0.12)
        self.ax2.yaxis.label.set_color('#cccccc')

        self.line1, = self.ax1.plot([], [], color='#2196F3', lw=0.8)
        self.line2, = self.ax2.plot([], [], color='#F44336', lw=0.8)

        self._title1 = self.ax1.set_title(
            "CH1 – Arc Current", color='#cccccc', fontsize=9)
        self._title2 = self.ax2.set_title(
            "CH2 – Gap Voltage", color='#cccccc', fontsize=9)

        self.canvas = FigureCanvas(self.fig)
        self.canvas.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(self.canvas)

    def add_sample(self, ch1: float, ch2: float, ts: float, enable: bool):
        self._buf.append((ts, ch1, ch2, enable))

    def add_burst(self, ch1_list: list, ch2_list: list, pulse_list: list = None):
        """Append a DMA burst to the overlay history (up to 10 kept)."""
        if not ch1_list:
            return
        n   = len(ch1_list)
        t   = np.arange(n, dtype=np.float32) / 500_000 * 1e6   # µs at 500 kSPS (one valid pair per 2 µs)
        ch1 = np.array(ch1_list, dtype=np.float32)
        ch2 = np.array(ch2_list, dtype=np.float32)
        pulse = np.array(pulse_list, dtype=np.int32) if pulse_list else np.zeros(n, dtype=np.int32)
        self._burst_history.append((t, ch1, ch2, pulse))

    def set_prescale(self, n: int):
        self._prescale = max(1, n)   # kept for internal use; pulse decimation is in OperatorConsole

    def set_timing(self, ton_us: int, toff_us: int):
        self._ton_us  = max(1, ton_us)
        self._toff_us = max(1, toff_us)

    def _window_seconds(self):
        # Pulse-period window, but never less than 1 s so there are always
        # visible samples regardless of sample rate vs pulse rate.
        return max(self.PULSE_WINDOW * (self._ton_us + self._toff_us) * 1e-6, 1.0)

    def refresh(self):
        # Hardware DMA bursts take priority over the 200 Hz status samples
        if self._burst_history:
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
        self.ax1.relim(); self.ax1.autoscale_view(scalex=False)
        self.ax2.relim(); self.ax2.autoscale_view(scalex=False)

        live      = buf[-1][3]
        state_tag = "LIVE" if live else "last burst"
        n_total   = len(burst)
        dur_ms    = window_s * 1000

        self._title1.set_text(
            f"CH1 – Arc Current  [last {self.PULSE_WINDOW} pulses "
            f"({dur_ms:.3g} ms), {n_total} samples, 1/{n} shown — {state_tag}]"
        )
        self.canvas.draw_idle()

    def _refresh_burst(self):
        history = list(self._burst_history)
        nb = len(history)

        for ax in (self.ax1, self.ax2):
            ax.cla()
            ax.set_facecolor('#1e1e1e')
            ax.tick_params(colors='#cccccc', labelsize=8)
            ax.grid(True, color='#333333', linewidth=0.5)
            for spine in ax.spines.values():
                spine.set_edgecolor('#444444')

        x_max = 1.0
        for i, (t, ch1, ch2, pulse) in enumerate(history):
            frac  = (i + 1) / nb          # 0→1 from oldest to newest
            alpha = 0.05 + 0.95 * frac**2  # quadratic: old traces very dim
            lw    = 0.3  + 0.9  * frac
            # Show dots at each sample so zero-valued samples are visible
            ms = 5.0 if len(t) <= 200 else 0   # skip dots for very long captures
            self.ax1.plot(t, ch1, color='#2196F3', alpha=alpha, lw=lw,
                          marker='.', markersize=ms, markevery=1)
            self.ax2.plot(t, ch2, color='#F44336', alpha=alpha, lw=lw,
                          marker='.', markersize=ms, markevery=1)
            # Shade pulse-on regions (most recent burst only)
            if i == nb - 1 and pulse.any():
                for ax in (self.ax1, self.ax2):
                    ax.fill_between(t, 0, 1, where=pulse.astype(bool),
                                    transform=ax.get_xaxis_transform(),
                                    color='#FFEB3B', alpha=0.12, label='Ton')
            x_max = max(x_max, t[-1])

        self.ax1.set_xlim(0, x_max)
        self.ax2.set_xlim(0, x_max)
        self.ax1.margins(y=0.12); self.ax1.autoscale_view(scalex=False)
        self.ax2.margins(y=0.12); self.ax2.autoscale_view(scalex=False)
        self.ax1.set_ylabel("Arc Current (A)",  color='#cccccc', fontsize=8)
        self.ax2.set_ylabel("Gap Voltage (V)",  color='#cccccc', fontsize=8)
        self.ax2.set_xlabel("Time in pulse (µs)",    color='#cccccc', fontsize=8)
        n_samp = len(history[-1][0])
        self.ax1.set_title(
            f"CH1 – Arc Current  [last {nb} pulses overlaid, {n_samp} samples @ 480 kSPS]",
            color='#cccccc', fontsize=9)
        self.ax2.set_title("CH2 – Gap Voltage", color='#cccccc', fontsize=9)
        self.canvas.draw_idle()

    def _show_idle(self):
        self.line1.set_data([], [])
        self.line2.set_data([], [])
        self._title1.set_text("CH1 – Arc Current  [waiting for enable…]")
        self.canvas.draw_idle()

    # expose arrays for stats
    def last_burst_arrays(self):
        """Return (ch1_arr, ch2_arr) for the most recent burst, or empty arrays."""
        if self._burst_history:
            _, ch1, ch2, _pulse = self._burst_history[-1]
            return ch1, ch2
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
    _N_DEFAULT = 20

    def __init__(self, parent=None):
        super().__init__("Statistics", parent)
        f = QFormLayout(self)
        self._v_peak   = QLabel("—")
        self._ch2_peak = QLabel("—")
        self._rate     = QLabel("—")
        self._temp     = QLabel("—")
        self._v_ravg   = QLabel("—")

        self._n_spin = QSpinBox()
        self._n_spin.setRange(1, 10000)
        self._n_spin.setValue(self._N_DEFAULT)
        self._n_spin.setSuffix(" pulses")
        self._n_spin.valueChanged.connect(self._on_n_changed)

        f.addRow("CH1 current avg Ton (V):",    self._v_peak)
        f.addRow("CH2 gap voltage avg Ton (V):", self._ch2_peak)
        f.addRow("Pulse rate (Hz):",           self._rate)
        f.addRow("Chip temp (°C):",            self._temp)
        f.addRow("N pulse running avg:", self._n_spin)
        f.addRow("",                           self._v_ravg)

        self._ravg_buf = deque(maxlen=self._N_DEFAULT)

        self._last_pulse_count  = 0
        self._t_start           = time.time()
        self._pulses_in_window  = 0

    def _on_n_changed(self, n: int):
        old = list(self._ravg_buf)
        self._ravg_buf = deque(old[-n:], maxlen=n)

    def update(self, ch1_arr, ch2_arr, status: dict):
        if len(ch1_arr):
            # Average over active samples (ch1 > 0) to exclude Toff idle period
            active = ch1_arr[ch1_arr > 0.0]
            if len(active):
                v_ton = float(np.mean(active))
                self._v_peak.setText(f"{v_ton:.1f}")
                self._ravg_buf.append(v_ton)
                self._v_ravg.setText(
                    f"{np.mean(self._ravg_buf):.1f} V  "
                    f"(n={len(self._ravg_buf)}/{self._ravg_buf.maxlen})"
                )
            ch2_active = ch2_arr[ch2_arr > 0.0]
            if len(ch2_active):
                self._ch2_peak.setText(f"{float(np.mean(ch2_active)):.3f}")

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
# 1-minute voltage/current histogram
# ─────────────────────────────────────────────────────────────────────────────
class HistogramWidget(QWidget):
    """Rolling histogram of per-pulse gap voltage average (from PL accumulator)."""

    def __init__(self, parent=None):
        super().__init__(parent)
        self._buf_gap = deque(maxlen=10_000)   # 10K entries = ~1s at 10 kHz pulse rate
        self._buf_ch1 = deque(maxlen=10_000)
        self._last_pc = 0                       # track pulse_count for new entries

        self.fig = Figure(figsize=(7, 2.2), tight_layout=True)
        self.fig.patch.set_facecolor('#1e1e1e')
        self.ax1, self.ax2 = self.fig.subplots(1, 2)
        for ax in (self.ax1, self.ax2):
            ax.set_facecolor('#1e1e1e')
            ax.tick_params(colors='#cccccc', labelsize=8)
            ax.grid(True, color='#333333', linewidth=0.5, axis='y')
            for spine in ax.spines.values():
                spine.set_edgecolor('#444444')

        self.canvas = FigureCanvas(self.fig)
        self.canvas.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(self.canvas)

    def add_status(self, status: dict):
        """Called at 200 Hz from status stream. Adds gap_avg if pulse advanced."""
        gap_avg = status.get('gap_avg')
        pc = status.get('pulse_count', 0)
        if gap_avg is not None and pc != self._last_pc and gap_avg > 0:
            self._buf_gap.append(gap_avg)
            self._last_pc = pc

    def add_gap_batch(self, values):
        """Called ~1/sec with batch of per-pulse gap averages from PL."""
        for v in values:
            if v > 0:
                self._buf_gap.append(v)

    def add_burst(self, ch1_arr: np.ndarray, ch2_arr: np.ndarray):
        """Add per-pulse current from burst waveform."""
        if len(ch1_arr):
            active = ch1_arr[ch1_arr > 0.01]
            if len(active):
                self._buf_ch1.append(float(np.mean(active)))

    def refresh(self):
        for ax, buf, color, label, title in [
            (self.ax1, self._buf_ch1, '#2196F3', 'Arc Current (A)',
             'CH1 – Ton Current'),
            (self.ax2, self._buf_gap, '#F44336', 'Gap Voltage (V)',
             'Gap Avg (PL, per-pulse)'),
        ]:
            ax.cla()
            ax.set_facecolor('#1e1e1e')
            ax.tick_params(colors='#cccccc', labelsize=8)
            ax.grid(True, color='#333333', linewidth=0.5, axis='y')
            for spine in ax.spines.values():
                spine.set_edgecolor('#444444')
            n = len(buf)
            if n >= 2:
                data = np.array(buf, dtype=np.float32)
                ax.hist(data, bins=60, color=color, alpha=0.85, edgecolor='none')
                ax.set_xlabel(label, color='#cccccc', fontsize=8)
                ax.set_title(f"{title}  ({n} pulses)",
                             color='#cccccc', fontsize=9)
            else:
                ax.set_title(f"{title}  (waiting...)",
                             color='#cccccc', fontsize=9)
            ax.yaxis.label.set_color('#cccccc')

        self.canvas.draw_idle()


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
        self._signals.gap_batch.connect(self._on_gap_batch)
        self._signals.gap_stats.connect(self._on_gap_stats)
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
        self._connect_btn    = QPushButton("Connect")
        self._disconnect_btn = QPushButton("Disconnect")
        self._connect_btn.clicked.connect(lambda: self._toggle_connect(True))
        self._disconnect_btn.clicked.connect(lambda: self._toggle_connect(False))
        self._lbl_conn = QLabel("Disconnected")
        self._lbl_conn.setStyleSheet("color: gray; font-weight: bold;")
        conn_btn_row = QHBoxLayout()
        conn_btn_row.addWidget(self._connect_btn)
        conn_btn_row.addWidget(self._disconnect_btn)
        cf.addRow("Board IP:", self._host_edit)
        cf.addRow("Status:",   self._lbl_conn)
        cf.addRow("",          conn_btn_row)
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
        self._spark_on_btn  = QPushButton("Start Sparks")
        self._spark_off_btn = QPushButton("Stop Sparks")
        self._spark_on_btn.clicked.connect(lambda: self._on_enable(True))
        self._spark_off_btn.clicked.connect(lambda: self._on_enable(False))
        self._spark_state_lbl = QLabel("OFF")
        self._spark_state_lbl.setStyleSheet("color: gray; font-weight: bold;")
        spark_btn_row = QHBoxLayout()
        spark_btn_row.addWidget(self._spark_on_btn)
        spark_btn_row.addWidget(self._spark_off_btn)
        apply_btn = QPushButton("Apply")
        apply_btn.clicked.connect(self._apply_params)
        pf.addRow("Ton:",  self._ton_spin)
        pf.addRow("Toff:", self._toff_spin)
        pf.addRow("",      apply_btn)
        pf.addRow("Sparks:",  self._spark_state_lbl)
        pf.addRow("",        spark_btn_row)
        left.addWidget(pbox)

        # Status
        sbox = QGroupBox("Status")
        sf   = QFormLayout(sbox)
        self._lbl_pulse   = QLabel("—")
        self._lbl_hven    = QLabel("—")
        self._lbl_enable  = QLabel("—")
        self._lbl_gap_avg = QLabel("—")
        sf.addRow("Pulse count:", self._lbl_pulse)
        sf.addRow("Operator HV Enable:", self._lbl_hven)
        sf.addRow("Sparks:",      self._lbl_enable)
        sf.addRow("Gap avg:",     self._lbl_gap_avg)

        # Adaptive feed control
        self._vset_spin = QDoubleSpinBox()
        self._vset_spin.setRange(0.0, 100.0)
        self._vset_spin.setDecimals(1)
        self._vset_spin.setSingleStep(1.0)
        self._vset_spin.setValue(20.0)
        self._vset_spin.setSuffix(" V")
        self._lbl_af1 = QLabel("—")
        sf.addRow("Gap setpoint:", self._vset_spin)
        sf.addRow("AF1:",          self._lbl_af1)
        left.addWidget(sbox)

        # Power supply — serial on PYNQ RPi header, commands via TCP
        psbox = QGroupBox("Gap Voltage (DPH8909)")
        psf   = QFormLayout(psbox)
        self._psu_v_spin = QDoubleSpinBox()
        self._psu_v_spin.setRange(0.0, 96.0)
        self._psu_v_spin.setDecimals(1)
        self._psu_v_spin.setSingleStep(1.0)
        self._psu_v_spin.setValue(50.0)
        self._psu_v_spin.setSuffix(" V")
        self._psu_i_spin = QDoubleSpinBox()
        self._psu_i_spin.setRange(0.0, 9.6)
        self._psu_i_spin.setDecimals(2)
        self._psu_i_spin.setSingleStep(0.1)
        self._psu_i_spin.setValue(1.0)
        self._psu_i_spin.setSuffix(" A")
        psu_set_btn = QPushButton("Set V / I")
        psu_set_btn.clicked.connect(self._psu_set)
        self._psu_on_btn  = QPushButton("Turn ON")
        self._psu_off_btn = QPushButton("Turn OFF")
        self._psu_on_btn.clicked.connect(lambda: self._psu_output(True))
        self._psu_off_btn.clicked.connect(lambda: self._psu_output(False))
        self._psu_state_lbl = QLabel("OFF")
        self._psu_state_lbl.setStyleSheet("color: gray; font-weight: bold;")
        psu_btn_row = QHBoxLayout()
        psu_btn_row.addWidget(self._psu_on_btn)
        psu_btn_row.addWidget(self._psu_off_btn)
        self._psu_link_lbl   = QLabel("—")
        self._psu_vout_lbl   = QLabel("—")
        self._psu_iout_lbl   = QLabel("—")
        psf.addRow("Voltage:",    self._psu_v_spin)
        psf.addRow("I limit:",    self._psu_i_spin)
        psf.addRow("",            psu_set_btn)
        psf.addRow("Output:",     self._psu_state_lbl)
        psf.addRow("",            psu_btn_row)
        psf.addRow("PSU link:",   self._psu_link_lbl)
        psf.addRow("V out:",      self._psu_vout_lbl)
        psf.addRow("I out:",      self._psu_iout_lbl)
        left.addWidget(psbox)

        left.addStretch()

        # ── Right panel ───────────────────────────────────────────────────────
        right = QVBoxLayout()
        root.addLayout(right, stretch=1)

        # Pulse decimation + capture-length control bar
        pscale_row = QHBoxLayout()
        pscale_row.addWidget(QLabel("Show 1 in every"))
        self._prescale_spin = QSpinBox()
        self._prescale_spin.setRange(1, 10000)
        self._prescale_spin.setValue(10)
        self._prescale_spin.setToolTip(
            "Pulse decimation: add one pulse to the overlay for every N pulses fired.\n"
            "1 = every pulse,  100 = every 100th pulse.\n"
            "Does not affect what is captured — only which pulses appear in the overlay."
        )
        self._prescale_spin.valueChanged.connect(self._on_prescale_changed)
        pscale_row.addWidget(self._prescale_spin)
        pscale_row.addWidget(QLabel("pulses"))

        pscale_row.addSpacing(20)
        pscale_row.addWidget(QLabel("Capture len:"))
        self._caplen_spin = QSpinBox()
        self._caplen_spin.setRange(10, 1024)
        self._caplen_spin.setValue(100)
        self._caplen_spin.setSingleStep(50)
        self._caplen_spin.setToolTip(
            "Number of ADC sample pairs captured per pulse (max 1024).\n"
            "500 samples ≈ 1.5 ms at 333 kSPS — covers ~15 pulse cycles at 10 kHz."
        )
        self._caplen_spin.editingFinished.connect(self._on_caplen_changed)
        pscale_row.addWidget(self._caplen_spin)

        pscale_row.addStretch()
        right.addLayout(pscale_row)

        self._wave_widget = WaveformWidget()
        self._wave_widget.set_timing(
            self._ton_spin.value(), self._toff_spin.value()
        )
        right.addWidget(self._wave_widget, stretch=2)

        self._stats_widget = StatsWidget()
        right.addWidget(self._stats_widget, stretch=0)

        self._hist_widget = HistogramWidget()
        right.addWidget(self._hist_widget, stretch=1)

        self.statusBar().showMessage(
            "Enter board IP and click Connect."
        )

    # ── slots ─────────────────────────────────────────────────────────────────

    def _toggle_connect(self, connect: bool):
        if connect:
            self._host_edit.setEnabled(False)
            self._worker.start(self._host_edit.text().strip())
        else:
            self._worker.stop()
            self._lbl_conn.setText("Disconnected")
            self._lbl_conn.setStyleSheet("color: gray; font-weight: bold;")
            self._host_edit.setEnabled(True)
            self.statusBar().showMessage("Disconnected.")
            self.setWindowTitle("EDM Controller – PYNQ-Z2")

    def _on_enable(self, on: bool):
        self._worker.send_cmd({'cmd': 'set_enable', 'value': 1 if on else 0})
        if on:
            self._spark_state_lbl.setText("ON")
            self._spark_state_lbl.setStyleSheet("color: #F44336; font-weight: bold; font-size: 13px;")
        else:
            self._spark_state_lbl.setText("OFF")
            self._spark_state_lbl.setStyleSheet("color: gray; font-weight: bold;")

    def _apply_params(self):
        ton  = self._ton_spin.value()
        toff = self._toff_spin.value()
        window_us = ton + toff        # one complete pulse cycle in µs
        caplen = int(window_us * 500_000 / 1_000_000)  # µs → samples at 500 kSPS
        caplen = max(1, min(caplen, 1024))
        self._worker.send_cmd({'cmd': 'set_ton',         'value': ton})
        self._worker.send_cmd({'cmd': 'set_toff',        'value': toff})
        self._worker.send_cmd({'cmd': 'set_capture_len', 'value': caplen})
        self._caplen_spin.setValue(caplen)
        self._wave_widget.set_timing(ton, toff)
        self.statusBar().showMessage(
            f"Parameters applied: Ton={ton}µs  Toff={toff}µs  Capture={caplen} samples"
        )

    def _on_prescale_changed(self, value: int):
        pass   # decimation is read live from _prescale_spin in _on_burst

    def _on_caplen_changed(self):
        v = self._caplen_spin.value()
        self._worker.send_cmd({'cmd': 'set_capture_len', 'value': v})
        self.statusBar().showMessage(f"Capture length set to {v} samples")

    def _on_sample(self, ch1: float, ch2: float, ts: float):
        self._wave_widget.add_sample(ch1, ch2, ts, self._last_enable)

    def _on_burst(self, ch1_list, ch2_list, pulse_list):
        self._burst_rx_count = getattr(self, '_burst_rx_count', 0) + 1
        decimation = self._prescale_spin.value()
        # Every pulse feeds the histogram; only 1-in-N feeds the waveform overlay.
        ch1_arr = np.array(ch1_list, dtype=np.float32)
        ch2_arr = np.array(ch2_list, dtype=np.float32)
        if self._burst_rx_count % decimation == 0:
            self._wave_widget.add_burst(ch1_list, ch2_list, pulse_list)
        self._hist_widget.add_burst(ch1_arr, ch2_arr)

    def _on_gap_batch(self, values):
        self._hist_widget.add_gap_batch(values)

    def _on_gap_stats(self, avg, std, n):
        if self._lbl_gap_avg:
            self._lbl_gap_avg.setText(f"{avg:.1f} V ± {std:.2f}  (n={n})")
        # AF1 = (Vset - Vavg) / Vavg
        vset = self._vset_spin.value()
        if avg > 0.1:
            af1 = (vset - avg) / avg
            self._lbl_af1.setText(f"{af1:+.3f}")
            # Color: green=on target, red=off target
            if abs(af1) < 0.1:
                self._lbl_af1.setStyleSheet("color: #4CAF50; font-weight: bold;")
            elif abs(af1) < 0.3:
                self._lbl_af1.setStyleSheet("color: #FF9800; font-weight: bold;")
            else:
                self._lbl_af1.setStyleSheet("color: #F44336; font-weight: bold;")
        else:
            self._lbl_af1.setText("—")
            self._lbl_af1.setStyleSheet("")

    def _on_status(self, d: dict):
        self._last_status = d
        self._last_enable = bool(d.get('enable', 0))
        self._hist_widget.add_status(d)
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

        psu_ok = d.get('psu_ok')
        if psu_ok is not None:
            if psu_ok:
                self._psu_link_lbl.setText("Connected")
                self._psu_link_lbl.setStyleSheet("color: #4CAF50;")
            else:
                self._psu_link_lbl.setText("Not available")
                self._psu_link_lbl.setStyleSheet("color: gray;")

        if 'psu_vout' in d:
            self._psu_vout_lbl.setText(f"{d['psu_vout']:.2f} V")
            self._psu_iout_lbl.setText(f"{d['psu_iout']:.3f} A")
            # Update output indicator from actual PSU readings
            if d['psu_vout'] > 1.0 and d['psu_iout'] > 0.05:
                self._psu_state_lbl.setText("ON")
                self._psu_state_lbl.setStyleSheet("color: #F44336; font-weight: bold; font-size: 13px;")
            else:
                self._psu_state_lbl.setText("OFF")
                self._psu_state_lbl.setStyleSheet("color: gray; font-weight: bold;")

    def _refresh_plot(self):
        self._wave_widget.refresh()
        ch1_arr, ch2_arr = self._wave_widget.last_burst_arrays()
        self._stats_widget.update(ch1_arr, ch2_arr, self._last_status)
        self._hist_widget.refresh()

    def _on_connection(self, ok: bool):
        if ok:
            self._lbl_conn.setText("Connected")
            self._lbl_conn.setStyleSheet("color: #4CAF50; font-weight: bold;")
            self.statusBar().showMessage("Connected.")
            self.setStyleSheet("")
            self.setWindowTitle("EDM Controller – PYNQ-Z2")
            # Push UI values to server so they're in sync from the start
            self._worker.send_cmd({'cmd': 'set_capture_len',
                                   'value': self._caplen_spin.value()})
        else:
            self._lbl_conn.setText("⚠ BOARD DISCONNECTED")
            self._lbl_conn.setStyleSheet(
                "color: #F44336; font-weight: bold; font-size: 14px;")
            self.statusBar().showMessage(
                "WARNING: Board connection lost — PSU may still be active! "
                "Check DPH8909 front panel.")
            self.setStyleSheet("QMainWindow { border: 3px solid red; }")
            self.setWindowTitle("⚠ EDM Controller — BOARD DISCONNECTED — CHECK PSU ⚠")

    def _on_error(self, msg: str):
        self.statusBar().showMessage(f"⚠ {msg}")

    # ── PSU slots ─────────────────────────────────────────────────────────────

    def _psu_set(self):
        v = self._psu_v_spin.value()
        i = self._psu_i_spin.value()
        self._worker.send_cmd({'cmd': 'set_psu_vi', 'voltage': v, 'current': i})
        self.statusBar().showMessage(f"PSU set: {v:.1f} V  {i:.2f} A")

    def _psu_output(self, on: bool):
        self._worker.send_cmd({'cmd': 'set_psu_output', 'value': 1 if on else 0})
        if on:
            self._psu_state_lbl.setText("ON")
            self._psu_state_lbl.setStyleSheet("color: #F44336; font-weight: bold; font-size: 13px;")
        else:
            self._psu_state_lbl.setText("OFF")
            self._psu_state_lbl.setStyleSheet("color: gray; font-weight: bold;")

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
