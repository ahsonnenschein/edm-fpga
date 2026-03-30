#!/usr/bin/env python3
"""
diag_timestamp.py — Analyze per-sample timestamps from waveform_capture rev 8.

Connects to xadc_server, collects bursts, and computes the inter-sample
delta of the 7-bit timestamp (50 MHz tick, mod 128).  Expected delta ≈ 104
if pair_ready fires at a uniform 480 kSPS.

Run:  python3 diag_timestamp.py [host] [num_bursts] [capture_len]
"""

import sys, socket, json, time
import numpy as np

HOST        = sys.argv[1] if len(sys.argv) > 1 else "192.168.2.99"
NUM_BURSTS  = int(sys.argv[2]) if len(sys.argv) > 2 else 50
CAPTURE_LEN = int(sys.argv[3]) if len(sys.argv) > 3 else 200
PORT        = 5006

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(10)
sock.connect((HOST, PORT))

# Set capture length
sock.sendall(json.dumps({'cmd': 'set_capture_len', 'value': CAPTURE_LEN}).encode() + b'\n')
time.sleep(0.5)

buf = b''
bursts = []
t0 = time.time()
while time.time() - t0 < 60 and len(bursts) < NUM_BURSTS:
    try:
        data = sock.recv(16384)
        if not data:
            break
        buf += data
        while b'\n' in buf:
            line, buf = buf.split(b'\n', 1)
            try:
                d = json.loads(line)
                if d.get('type') == 'burst' and 'ts' in d and len(d['ts']) == CAPTURE_LEN:
                    bursts.append(d)
                    if len(bursts) % 10 == 0:
                        print(f"  collected {len(bursts)}/{NUM_BURSTS}...")
            except Exception:
                pass
    except socket.timeout:
        continue

# Restore capture_len
sock.sendall(json.dumps({'cmd': 'set_capture_len', 'value': 50}).encode() + b'\n')
sock.close()

if not bursts:
    print("ERROR: No bursts with timestamp data received.")
    print("Is the rev 8 bitstream loaded?  (ts field missing → old bitstream)")
    sys.exit(1)

print(f"\nCollected {len(bursts)} bursts, {CAPTURE_LEN} samples each.\n")

# ── Per-burst analysis ──────────────────────────────────
all_deltas_first50 = []   # deltas within first 50 samples (first period)
all_deltas_rest    = []   # deltas after sample 50

for i, b in enumerate(bursts):
    ts = np.array(b['ts'], dtype=np.int32)
    pulse = np.array(b['pulse'], dtype=np.int32)

    # Compute inter-sample delta (mod 128)
    delta = np.diff(ts)
    delta = delta % 128   # unwrap mod-128

    all_deltas_first50.extend(delta[:49].tolist())
    all_deltas_rest.extend(delta[49:].tolist())

    if i < 5:
        # Find pulse rising edges
        edges = [0] if pulse[0] else []
        for j in range(1, len(pulse)):
            if pulse[j] == 1 and pulse[j-1] == 0:
                edges.append(j)
        first_p = edges[1] - edges[0] if len(edges) >= 2 else -1

        print(f"--- Burst {i+1} (first period = {first_p} samples) ---")
        print(f"  ts[0:10]    = {ts[:10].tolist()}")
        print(f"  delta[0:10] = {delta[:10].tolist()}")
        print(f"  pulse[0:10] = {pulse[:10].tolist()}")
        print(f"  delta mean(first 50)  = {delta[:49].mean():.1f}")
        print(f"  delta mean(after 50)  = {delta[49:].mean():.1f}")
        print(f"  delta std(first 50)   = {delta[:49].std():.1f}")
        print(f"  delta std(after 50)   = {delta[49:].std():.1f}")
        print()

# ── Aggregate statistics ────────────────────────────────
d1 = np.array(all_deltas_first50)
d2 = np.array(all_deltas_rest)

print("=" * 60)
print("AGGREGATE DELTA STATISTICS (mod 128, expected ≈ 104)")
print("=" * 60)
print(f"\nFirst 50 samples per burst (N={len(d1)}):")
print(f"  mean={d1.mean():.1f}  std={d1.std():.1f}  min={d1.min()}  max={d1.max()}")
print(f"\nAfter sample 50 (N={len(d2)}):")
print(f"  mean={d2.mean():.1f}  std={d2.std():.1f}  min={d2.min()}  max={d2.max()}")

print(f"\n--- Delta histogram (first 50) ---")
vals, counts = np.unique(d1, return_counts=True)
for v, c in sorted(zip(vals, counts), key=lambda x: -x[1])[:20]:
    bar = '#' * min(c, 60)
    print(f"  {v:4d}: {bar} ({c})")

print(f"\n--- Delta histogram (after 50) ---")
vals, counts = np.unique(d2, return_counts=True)
for v, c in sorted(zip(vals, counts), key=lambda x: -x[1])[:20]:
    bar = '#' * min(c, 60)
    print(f"  {v:4d}: {bar} ({c})")

# ── Check for anomalies ─────────────────────────────────
modal_delta = int(np.median(d2))  # stable region's typical delta
print(f"\nModal delta (stable region): {modal_delta}")
print(f"At 50 MHz tick and 100 us period: pair_ready rate = "
      f"{100e-6 / (modal_delta * 20e-9) / 1e3:.1f} kSPS")

anomalous = ((d1 < modal_delta - 10) | (d1 > modal_delta + 10)).sum()
print(f"\nAnomalous deltas in first 50 (±10 from modal): {anomalous}/{len(d1)} "
      f"({100*anomalous/len(d1):.1f}%)")

anomalous2 = ((d2 < modal_delta - 10) | (d2 > modal_delta + 10)).sum()
print(f"Anomalous deltas after 50 (±10 from modal): {anomalous2}/{len(d2)} "
      f"({100*anomalous2/len(d2):.1f}%)")
