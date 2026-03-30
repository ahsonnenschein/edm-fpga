#!/usr/bin/env python3
"""
test_modbus.py — Test client for the EDM Modbus TCP server.

Exercises all holding and input registers, verifying read/write
functionality and correct scaling.

Usage:
    python3 test_modbus.py [host]        # default: 192.168.2.99
"""

import sys, time

try:
    from pymodbus.client import ModbusTcpClient
except ImportError:
    print("Install pymodbus:  pip install pymodbus")
    sys.exit(1)

HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.2.99"
PORT = 502
UNIT = 1

# Register names for display
HR_NAMES = {0: "Ton_us", 1: "Toff_us", 2: "Enable",
            3: "Gap_setpoint", 4: "Short_threshold", 5: "Open_threshold"}
IR_NAMES = {0: "Pulse_count_lo", 1: "Pulse_count_hi", 2: "HV_enable",
            3: "Gap_voltage_avg", 4: "Arc_ok"}


def read_all(client):
    """Read and display all registers."""
    print("\n── Holding Registers (FC3) ──")
    rr = client.read_holding_registers(0, count=6, device_id=UNIT)
    if rr.isError():
        print(f"  ERROR: {rr}")
        return None
    for i, v in enumerate(rr.registers):
        print(f"  HR[{i}] {HR_NAMES[i]:20s} = {v}")

    print("\n── Input Registers (FC4) ──")
    rr = client.read_input_registers(0, count=5, device_id=UNIT)
    if rr.isError():
        print(f"  ERROR: {rr}")
        return None
    for i, v in enumerate(rr.registers):
        print(f"  IR[{i}] {IR_NAMES[i]:20s} = {v}")

    pulse_count = rr.registers[0] | (rr.registers[1] << 16)
    gap_v = rr.registers[3]
    arc_ok = rr.registers[4]
    print(f"\n  Pulse count: {pulse_count}")
    print(f"  Gap voltage (raw ADC): {gap_v}  ({gap_v / 4096 * 50:.2f} V approx)")
    print(f"  Arc OK: {'YES' if arc_ok else 'NO'}")
    return rr.registers


def test_write_read(client, reg, name, value):
    """Write a holding register and read it back."""
    print(f"\n  Writing HR[{reg}] {name} = {value} ... ", end="")
    wr = client.write_register(reg, value, device_id=UNIT)
    if wr.isError():
        print(f"WRITE ERROR: {wr}")
        return False
    time.sleep(0.05)
    rr = client.read_holding_registers(reg, count=1, device_id=UNIT)
    if rr.isError():
        print(f"READ ERROR: {rr}")
        return False
    readback = rr.registers[0]
    ok = readback == value
    print(f"readback={readback}  {'OK' if ok else 'MISMATCH!'}")
    return ok


def main():
    print(f"Connecting to Modbus TCP server at {HOST}:{PORT}")
    client = ModbusTcpClient(HOST, port=PORT, timeout=5)
    if not client.connect():
        print("ERROR: Cannot connect")
        sys.exit(1)
    print("Connected.\n")

    # ── Read initial state ──
    print("=" * 50)
    print("1. INITIAL STATE")
    print("=" * 50)
    read_all(client)

    # ── Test holding register writes ──
    print("\n" + "=" * 50)
    print("2. WRITE TESTS")
    print("=" * 50)

    passed = 0
    total = 0

    # Save originals
    rr = client.read_holding_registers(0, count=6, device_id=UNIT)
    originals = list(rr.registers)

    # Test each writable register
    tests = [
        (0, "Ton_us",          20),
        (1, "Toff_us",         80),
        (2, "Enable",           0),
        (3, "Gap_setpoint",  1500),
        (4, "Short_threshold", 100),
        (5, "Open_threshold", 3800),
    ]

    for reg, name, val in tests:
        total += 1
        if test_write_read(client, reg, name, val):
            passed += 1

    # ── Test input register reads ──
    print("\n\n" + "=" * 50)
    print("3. INPUT REGISTER READS")
    print("=" * 50)
    print("\n  Reading input registers 3 times (0.5s apart):")
    for i in range(3):
        rr = client.read_input_registers(0, count=5, device_id=UNIT)
        if not rr.isError():
            pc = rr.registers[0] | (rr.registers[1] << 16)
            print(f"  [{i+1}] pc={pc:8d}  hv={rr.registers[2]}  "
                  f"gap={rr.registers[3]:4d}  arc_ok={rr.registers[4]}")
        time.sleep(0.5)

    # ── Test pulse count advancing ──
    print("\n" + "=" * 50)
    print("4. PULSE COUNT ADVANCEMENT")
    print("=" * 50)

    # Enable pulses, wait, check count advances
    client.write_register(0, 10, device_id=UNIT)   # Ton=10us
    client.write_register(1, 90, device_id=UNIT)   # Toff=90us
    client.write_register(2, 1, device_id=UNIT)    # Enable=1
    time.sleep(0.1)

    rr1 = client.read_input_registers(0, count=2, device_id=UNIT)
    pc1 = rr1.registers[0] | (rr1.registers[1] << 16)
    time.sleep(1.0)
    rr2 = client.read_input_registers(0, count=2, device_id=UNIT)
    pc2 = rr2.registers[0] | (rr2.registers[1] << 16)

    delta = pc2 - pc1
    expected = 10000  # 100us period = 10000 pulses/sec
    print(f"\n  Pulse count: {pc1} → {pc2}  (delta={delta} in 1s)")
    print(f"  Expected ~{expected} pulses/s at Ton=10+Toff=90")
    total += 1
    if 8000 < delta < 12000:
        print(f"  PASS (within ±20%)")
        passed += 1
    else:
        print(f"  FAIL (outside expected range)")

    client.write_register(2, 0, device_id=UNIT)    # Disable

    # ── Restore originals ──
    print("\n" + "=" * 50)
    print("5. RESTORING ORIGINAL VALUES")
    print("=" * 50)
    for i, v in enumerate(originals):
        client.write_register(i, v, device_id=UNIT)
        print(f"  HR[{i}] {HR_NAMES[i]} = {v}")

    # ── Summary ──
    print("\n" + "=" * 50)
    print(f"RESULT: {passed}/{total} tests passed")
    print("=" * 50)

    client.close()


if __name__ == "__main__":
    main()
