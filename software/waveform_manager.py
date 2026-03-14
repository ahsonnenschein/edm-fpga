#!/usr/bin/env python3
"""
waveform_manager.py
Reads EDM waveforms from AXI DMA, saves to HDF5, displays via matplotlib,
and streams decoded waveforms to connected operator consoles over TCP port 5005.

Waveform data format (32-bit words from FPGA):
  bits [31:18] = CH1 (voltage, 14-bit 2's complement)
  bits [15:2]  = CH2 (current, 14-bit 2's complement)

Wire protocol (port 5005):
  Each frame: [4 bytes n_samples uint32 LE]
              [n * 4 bytes CH1 float32 LE]
              [n * 4 bytes CH2 float32 LE]

AXI DMA base address: 0x40400000
Waveform buffer: allocated in DDR, address passed to DMA.

Parameters read from AXI EDM registers:
  capture_len  : samples per waveform
  f_save       : fraction to save    (0-10000)
  f_display    : fraction to display (0-10000)

Install deps: pip3 install numpy h5py matplotlib pymodbus
"""

import os
import time
import mmap
import struct
import socket
import threading
import ctypes
import numpy as np
import h5py
import matplotlib.pyplot as plt
import matplotlib.animation as animation
from datetime import datetime
from pymodbus.client import ModbusTcpClient

# -------------------------------------------------------
# Configuration
# -------------------------------------------------------
MODBUS_HOST     = "localhost"
MODBUS_PORT     = 502
STREAM_PORT     = 5005   # waveform streaming to operator consoles

DMA_BASE_ADDR   = 0x40400000
DMA_ADDR_RANGE  = 0x10000
EDM_BASE_ADDR   = 0x43C00000
EDM_ADDR_RANGE  = 0x1000

CLK_MHZ         = 125
ADC_FULL_SCALE  = 2**13          # 14-bit signed: ±8192
VOLTS_PER_ADC   = 1.0 / ADC_FULL_SCALE  # calibrate later
AMPS_PER_ADC    = 1.0 / ADC_FULL_SCALE  # calibrate later

SAVE_DIR        = os.path.expanduser("~/edm_data")
HDF5_FILE       = os.path.join(SAVE_DIR, f"edm_waveforms_{datetime.now().strftime('%Y%m%d_%H%M%S')}.h5")

# AXI register offsets
REG_CAPTURE_LEN    = 0x0C
REG_F_SAVE         = 0x10
REG_F_DISPLAY      = 0x14
REG_WAVEFORM_COUNT = 0x1C

# DMA register offsets (Xilinx AXI DMA simple mode, S2MM)
DMA_S2MM_DMACR  = 0x30   # S2MM control
DMA_S2MM_DMASR  = 0x34   # S2MM status
DMA_S2MM_DA     = 0x48   # destination address (low 32)
DMA_S2MM_DA_MSB = 0x4C   # destination address (high 32, for 64-bit)
DMA_S2MM_LENGTH = 0x58   # transfer length in bytes


class MemMapped:
    def __init__(self, base, size):
        self._fd  = open("/dev/mem", "r+b")
        self._mem = mmap.mmap(self._fd.fileno(), size,
                              offset=base, access=mmap.ACCESS_WRITE)

    def rd(self, offset):
        self._mem.seek(offset)
        return struct.unpack("<I", self._mem.read(4))[0]

    def wr(self, offset, value):
        self._mem.seek(offset)
        self._mem.write(struct.pack("<I", value & 0xFFFFFFFF))

    def close(self):
        self._mem.close()
        self._fd.close()


class WaveformDMA:
    """Simple-mode AXI DMA driver for S2MM (stream → memory)."""

    # Contiguous DMA buffer via /dev/mem CMA region.
    # On Red Pitaya: set mem=490M in uEnv.txt to reserve CMA at 0x1E000000
    DMA_BUF_PHYS = 0x1E000000
    DMA_BUF_SIZE = 4 * 1024 * 1024  # 4 MB buffer

    def __init__(self, dma_regs):
        self._dma = dma_regs
        # Map CMA buffer
        self._buf_fd  = open("/dev/mem", "r+b")
        self._buf_mem = mmap.mmap(self._buf_fd.fileno(), self.DMA_BUF_SIZE,
                                  offset=self.DMA_BUF_PHYS)
        # Reset and start DMA
        self._dma.wr(DMA_S2MM_DMACR, 0x4)   # reset
        time.sleep(0.01)
        self._dma.wr(DMA_S2MM_DMACR, 0x1)   # run
        self._dma.wr(DMA_S2MM_DA,     self.DMA_BUF_PHYS)
        self._dma.wr(DMA_S2MM_DA_MSB, 0)

    def receive(self, n_bytes):
        """Arm DMA for n_bytes, wait for completion, return raw bytes."""
        if n_bytes > self.DMA_BUF_SIZE:
            raise ValueError("Waveform exceeds DMA buffer size")
        # Arm transfer
        self._dma.wr(DMA_S2MM_LENGTH, n_bytes)
        # Wait for IOC (interrupt on complete) bit in status register
        timeout = time.time() + 2.0
        while not (self._dma.rd(DMA_S2MM_DMASR) & 0x1000):
            if time.time() > timeout:
                raise TimeoutError("DMA transfer timed out")
            time.sleep(0.0001)
        # Clear IOC
        self._dma.wr(DMA_S2MM_DMASR, 0x1000)
        # Read from buffer
        self._buf_mem.seek(0)
        return self._buf_mem.read(n_bytes)

    def close(self):
        self._buf_mem.close()
        self._buf_fd.close()


def decode_waveform(raw_bytes):
    """
    Unpack 32-bit words into CH1 and CH2 arrays.
    Returns (ch1_volts, ch2_amps) as float32 numpy arrays.
    """
    n = len(raw_bytes) // 4
    words = np.frombuffer(raw_bytes, dtype=np.uint32)[:n]

    # Extract 14-bit fields and sign-extend
    ch1_raw = ((words >> 18) & 0x3FFF).astype(np.int16)
    ch2_raw = ((words >>  2) & 0x3FFF).astype(np.int16)

    # Sign-extend from 14 to 16 bits
    ch1_raw = np.where(ch1_raw >= 0x2000, ch1_raw - 0x4000, ch1_raw)
    ch2_raw = np.where(ch2_raw >= 0x2000, ch2_raw - 0x4000, ch2_raw)

    return ch1_raw.astype(np.float32) * VOLTS_PER_ADC, \
           ch2_raw.astype(np.float32) * AMPS_PER_ADC


class WaveformStats:
    """Running per-waveform summary statistics."""

    def __init__(self):
        self.count        = 0
        self.v_peak_mean  = 0.0
        self.i_peak_mean  = 0.0
        self.energy_mean  = 0.0  # proportional to sum(V*I*dt)

    def update(self, ch1, ch2, dt_s):
        self.count       += 1
        v_peak = np.max(np.abs(ch1))
        i_peak = np.max(np.abs(ch2))
        energy = np.sum(ch1 * ch2) * dt_s
        alpha  = 1.0 / self.count  # running mean
        self.v_peak_mean  += alpha * (v_peak - self.v_peak_mean)
        self.i_peak_mean  += alpha * (i_peak - self.i_peak_mean)
        self.energy_mean  += alpha * (energy  - self.energy_mean)

    def __str__(self):
        return (f"n={self.count}  "
                f"V_peak={self.v_peak_mean:.3f}  "
                f"I_peak={self.i_peak_mean:.3f}  "
                f"Energy={self.energy_mean:.3e}")


def should_act(counter, fraction_10000):
    """Return True for approximately fraction_10000/10000 of calls."""
    if fraction_10000 <= 0:
        return False
    if fraction_10000 >= 10000:
        return True
    # Simple modulo approach: act every N-th waveform
    n = max(1, round(10000 / fraction_10000))
    return (counter % n) == 0


class WaveformServer:
    """
    TCP server that broadcasts decoded waveforms to connected operator consoles.

    Frame format:
        [4 bytes]     n_samples  (uint32, little-endian)
        [n * 4 bytes] CH1        (float32 array, little-endian)
        [n * 4 bytes] CH2        (float32 array, little-endian)
    """

    def __init__(self, port: int = STREAM_PORT):
        self._port    = port
        self._clients = []          # list of open sockets
        self._lock    = threading.Lock()
        self._server  = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server.bind(("0.0.0.0", port))
        self._server.listen(8)
        self._thread  = threading.Thread(target=self._accept_loop, daemon=True)
        self._thread.start()
        print(f"Waveform server listening on port {port}")

    def _accept_loop(self):
        while True:
            try:
                conn, addr = self._server.accept()
                conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                with self._lock:
                    self._clients.append(conn)
                print(f"Operator console connected from {addr[0]}:{addr[1]}")
            except Exception:
                break

    def broadcast(self, ch1: np.ndarray, ch2: np.ndarray):
        """Send one waveform frame to all connected clients."""
        n      = len(ch1)
        header = struct.pack("<I", n)
        body   = ch1.astype(np.float32).tobytes() + ch2.astype(np.float32).tobytes()
        frame  = header + body

        dead = []
        with self._lock:
            for sock in self._clients:
                try:
                    sock.sendall(frame)
                except Exception:
                    dead.append(sock)
            for sock in dead:
                self._clients.remove(sock)
                try: sock.close()
                except: pass

    def close(self):
        self._server.close()
        with self._lock:
            for sock in self._clients:
                try: sock.close()
                except: pass
            self._clients.clear()


def main():
    os.makedirs(SAVE_DIR, exist_ok=True)

    # Connect to Modbus to read parameters
    mb = ModbusTcpClient(MODBUS_HOST, port=MODBUS_PORT)
    mb.connect()

    dma_regs = MemMapped(DMA_BASE_ADDR, DMA_ADDR_RANGE)
    edm_regs = MemMapped(EDM_BASE_ADDR, EDM_ADDR_RANGE)
    dma      = WaveformDMA(dma_regs)

    stream_server = WaveformServer(STREAM_PORT)

    stats = WaveformStats()
    waveform_counter = 0
    dt_s = 1.0 / (CLK_MHZ * 1e6)  # sample period in seconds

    # Live display setup
    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(10, 6))
    fig.suptitle("EDM Waveform Monitor")
    ax1.set_ylabel("Voltage (V)")
    ax2.set_ylabel("Current (A)")
    ax2.set_xlabel("Time (µs)")
    line1, = ax1.plot([], [], 'b-', linewidth=0.8)
    line2, = ax2.plot([], [], 'r-', linewidth=0.8)
    stats_text = fig.text(0.5, 0.01, "", ha='center', fontsize=9)
    plt.tight_layout()
    plt.ion()
    plt.show()

    print(f"Saving waveforms to {HDF5_FILE}")
    print("Press Ctrl+C to stop.")

    with h5py.File(HDF5_FILE, "w") as hf:
        hf.attrs["created"]  = datetime.now().isoformat()
        hf.attrs["clk_mhz"]  = CLK_MHZ
        wf_grp = hf.create_group("waveforms")

        try:
            while True:
                # Read current parameters from hardware
                capture_len = edm_regs.rd(REG_CAPTURE_LEN)
                f_save      = edm_regs.rd(REG_F_SAVE)
                f_display   = edm_regs.rd(REG_F_DISPLAY)

                if capture_len == 0:
                    time.sleep(0.1)
                    continue

                n_bytes = capture_len * 4  # 4 bytes per sample

                try:
                    raw = dma.receive(n_bytes)
                except TimeoutError:
                    # No pulse running, wait
                    time.sleep(0.1)
                    continue

                ch1, ch2 = decode_waveform(raw)
                stats.update(ch1, ch2, dt_s)
                waveform_counter += 1

                # Stream to connected operator consoles
                stream_server.broadcast(ch1, ch2)

                # Save to HDF5
                if should_act(waveform_counter, f_save):
                    ds_name = f"wf_{waveform_counter:08d}"
                    ds = wf_grp.create_dataset(ds_name, data=np.stack([ch1, ch2]))
                    ds.attrs["timestamp"] = time.time()
                    ds.attrs["v_peak"]    = float(np.max(np.abs(ch1)))
                    ds.attrs["i_peak"]    = float(np.max(np.abs(ch2)))

                # Display
                if should_act(waveform_counter, f_display):
                    t_us = np.arange(len(ch1)) / CLK_MHZ
                    line1.set_data(t_us, ch1)
                    line2.set_data(t_us, ch2)
                    ax1.relim(); ax1.autoscale_view()
                    ax2.relim(); ax2.autoscale_view()
                    stats_text.set_text(str(stats))
                    fig.canvas.draw_idle()
                    fig.canvas.flush_events()

                if waveform_counter % 100 == 0:
                    print(stats)

        except KeyboardInterrupt:
            print("\nStopping.")
        finally:
            stream_server.close()
            mb.close()
            dma.close()
            dma_regs.close()
            edm_regs.close()
            print(f"Saved {waveform_counter} waveforms to {HDF5_FILE}")


if __name__ == "__main__":
    main()
