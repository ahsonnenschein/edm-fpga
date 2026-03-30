# pynq_z2.xdc
# Pin constraints for EDM controller on PYNQ-Z2 (Zynq XC7Z020-1CLG400C)
#
# Note: VP/VN (Vp_Vn_0_v_p / Vp_Vn_0_v_n) are dedicated analog pins on the Zynq
# silicon (M9/M10). They do not require XDC LOC/IOSTANDARD constraints.
#
# Note: VAUX6 (J1 A0, AR_AN0_P/N) analog pins are in bank 35 (VCCO=3.3V).
# The XADC Wizard diff_analog_io interface defaults to LVCMOS18 which conflicts
# with the 3.3V bank.  Override to LVCMOS33 to match bank voltage.
# The XADC hardware bypasses the IO buffer for the actual analog sampling.

# -------------------------------------------------------
# J1 A0 analog input — XADC VAUX6 (Zynq CLG400 K14/J14, bank 35)
# Port names come from block design Vaux6_0 diff_analog_io interface.
# -------------------------------------------------------
set_property -dict {PACKAGE_PIN K14 IOSTANDARD LVCMOS33} [get_ports Vaux6_0_v_p]
set_property -dict {PACKAGE_PIN J14 IOSTANDARD LVCMOS33} [get_ports Vaux6_0_v_n]

# -------------------------------------------------------
# Arduino digital I/O
# Port names use the _0 suffix from block design make_bd_pins_external
# -------------------------------------------------------

# AR0: Pulse output → GEDM pulseboard
set_property -dict {PACKAGE_PIN T14 IOSTANDARD LVCMOS33} [get_ports pulse_out_0]

# AR1: Operator HV enable switch input (active high)
set_property -dict {PACKAGE_PIN U12 IOSTANDARD LVCMOS33} [get_ports hv_enable_0]

# AR2: Green lamp (HV off) → HFET module
set_property -dict {PACKAGE_PIN U13 IOSTANDARD LVCMOS33} [get_ports lamp_green_0]

# AR3: Orange lamp (switch on, sparks off) → HFET module
set_property -dict {PACKAGE_PIN V13 IOSTANDARD LVCMOS33} [get_ports lamp_orange_0]

# AR4: Red lamp (sparks on) → HFET module
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports lamp_red_0]

# -------------------------------------------------------
# UART1 EMIO — DPH8909 PSU serial (Pmod B, pins 1–2)
# JB1_P (pin 1, W14): TX out from PS  →  DPH8909 RX
# JB1_N (pin 2, Y14): RX into PS      ←  DPH8909 TX
# GND: Pmod B pin 5 or 11
# -------------------------------------------------------
set_property -dict {PACKAGE_PIN W14 IOSTANDARD LVCMOS33} [get_ports uart1_txd]
set_property -dict {PACKAGE_PIN Y14 IOSTANDARD LVCMOS33} [get_ports uart1_rxd]

# -------------------------------------------------------
# Status LEDs (LD0-LD3)
# -------------------------------------------------------
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports {led_0[0]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports {led_0[1]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {led_0[2]}]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {led_0[3]}]
