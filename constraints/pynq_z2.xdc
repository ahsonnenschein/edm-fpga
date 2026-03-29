# pynq_z2.xdc
# Pin constraints for EDM controller on PYNQ-Z2 (Zynq XC7Z020-1CLG400C)
#
# Note: VP/VN (Vp_Vn_0_v_p / Vp_Vn_0_v_n) are dedicated analog pins on the Zynq
# silicon (M9/M10). They do not require XDC LOC/IOSTANDARD constraints.
#
# Note: VAUX1 (Arduino A0, AR_AN0_P/N) analog pins are handled by the XADC Wizard
# IP internally and do not require XDC constraints.

# -------------------------------------------------------
# Arduino digital I/O
# Port names use the _0 suffix from block design make_bd_pins_external
# -------------------------------------------------------

# D2: Pulse output → GEDM pulseboard
set_property -dict {PACKAGE_PIN T14 IOSTANDARD LVCMOS33} [get_ports pulse_out_0]

# D3: Operator HV enable switch input (active high)
set_property -dict {PACKAGE_PIN U12 IOSTANDARD LVCMOS33} [get_ports hv_enable_0]

# D4: Green lamp (HV off) → HFET module
set_property -dict {PACKAGE_PIN U13 IOSTANDARD LVCMOS33} [get_ports lamp_green_0]

# D5: Orange lamp (switch on, sparks off) → HFET module
set_property -dict {PACKAGE_PIN V13 IOSTANDARD LVCMOS33} [get_ports lamp_orange_0]

# D6: Red lamp (sparks on) → HFET module
set_property -dict {PACKAGE_PIN V15 IOSTANDARD LVCMOS33} [get_ports lamp_red_0]

# -------------------------------------------------------
# UART1 EMIO — DPH8909 PSU serial (Raspberry Pi header)
# Pin 8  (GPIO14): TX out from PS  →  DPH8909 RX
# Pin 10 (GPIO15): RX into PS      ←  DPH8909 TX
# -------------------------------------------------------
set_property -dict {PACKAGE_PIN V6 IOSTANDARD LVCMOS33} [get_ports uart1_txd]
set_property -dict {PACKAGE_PIN Y6 IOSTANDARD LVCMOS33} [get_ports uart1_rxd]

# -------------------------------------------------------
# Status LEDs (LD0-LD3)
# -------------------------------------------------------
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33} [get_ports {led_0[0]}]
set_property -dict {PACKAGE_PIN P14 IOSTANDARD LVCMOS33} [get_ports {led_0[1]}]
set_property -dict {PACKAGE_PIN N16 IOSTANDARD LVCMOS33} [get_ports {led_0[2]}]
set_property -dict {PACKAGE_PIN M14 IOSTANDARD LVCMOS33} [get_ports {led_0[3]}]
