# redpitaya_v1.xdc
# Pin constraints for Red Pitaya STEMlab 125-14 v1 (Zynq XC7Z010-1CLG400C)
# ADC: LTC2145-14, 125 MSPS, 14-bit
# GPIO: expansion connector E1

# -------------------------------------------------------
# ADC Channel 1 (voltage, Hentek probe on CH1)
# -------------------------------------------------------
set_property PACKAGE_PIN V17 [get_ports {adc_ch1_i[0]}]
set_property PACKAGE_PIN U17 [get_ports {adc_ch1_i[1]}]
set_property PACKAGE_PIN Y17 [get_ports {adc_ch1_i[2]}]
set_property PACKAGE_PIN W16 [get_ports {adc_ch1_i[3]}]
set_property PACKAGE_PIN Y16 [get_ports {adc_ch1_i[4]}]
set_property PACKAGE_PIN W15 [get_ports {adc_ch1_i[5]}]
set_property PACKAGE_PIN W14 [get_ports {adc_ch1_i[6]}]
set_property PACKAGE_PIN Y14 [get_ports {adc_ch1_i[7]}]
set_property PACKAGE_PIN W13 [get_ports {adc_ch1_i[8]}]
set_property PACKAGE_PIN V12 [get_ports {adc_ch1_i[9]}]
set_property PACKAGE_PIN V13 [get_ports {adc_ch1_i[10]}]
set_property PACKAGE_PIN T14 [get_ports {adc_ch1_i[11]}]
set_property PACKAGE_PIN T15 [get_ports {adc_ch1_i[12]}]
set_property PACKAGE_PIN V15 [get_ports {adc_ch1_i[13]}]

# -------------------------------------------------------
# ADC Channel 2 (current feedback from GEDM pulseboard)
# -------------------------------------------------------
set_property PACKAGE_PIN E17 [get_ports {adc_ch2_i[0]}]
set_property PACKAGE_PIN D18 [get_ports {adc_ch2_i[1]}]
set_property PACKAGE_PIN E18 [get_ports {adc_ch2_i[2]}]
set_property PACKAGE_PIN E19 [get_ports {adc_ch2_i[3]}]
set_property PACKAGE_PIN D20 [get_ports {adc_ch2_i[4]}]
set_property PACKAGE_PIN D19 [get_ports {adc_ch2_i[5]}]
set_property PACKAGE_PIN F19 [get_ports {adc_ch2_i[6]}]
set_property PACKAGE_PIN F20 [get_ports {adc_ch2_i[7]}]
set_property PACKAGE_PIN G19 [get_ports {adc_ch2_i[8]}]
set_property PACKAGE_PIN G20 [get_ports {adc_ch2_i[9]}]
set_property PACKAGE_PIN H17 [get_ports {adc_ch2_i[10]}]
set_property PACKAGE_PIN H18 [get_ports {adc_ch2_i[11]}]
set_property PACKAGE_PIN H19 [get_ports {adc_ch2_i[12]}]
set_property PACKAGE_PIN H20 [get_ports {adc_ch2_i[13]}]

# -------------------------------------------------------
# Pulse output → GEDM pulseboard (GPIO E1 pin 3, 3.3V)
# -------------------------------------------------------
set_property PACKAGE_PIN G17 [get_ports pulse_out]

# -------------------------------------------------------
# Status LEDs (active high, LD0–LD7)
# -------------------------------------------------------
set_property PACKAGE_PIN F16 [get_ports {led[0]}]
set_property PACKAGE_PIN F17 [get_ports {led[1]}]
set_property PACKAGE_PIN G15 [get_ports {led[2]}]
set_property PACKAGE_PIN H15 [get_ports {led[3]}]
set_property PACKAGE_PIN K14 [get_ports {led[4]}]
set_property PACKAGE_PIN G14 [get_ports {led[5]}]
set_property PACKAGE_PIN J15 [get_ports {led[6]}]
set_property PACKAGE_PIN J14 [get_ports {led[7]}]

# -------------------------------------------------------
# I/O standards
# -------------------------------------------------------
set_property IOSTANDARD LVCMOS33 [get_ports {adc_ch1_i[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports {adc_ch2_i[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports pulse_out]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]

# -------------------------------------------------------
# Timing
# -------------------------------------------------------
# ADC data is synchronous to 125 MHz ADC clock (same as FCLK0)
set_input_delay -clock [get_clocks clk_fpga_0] -max 3.0 [get_ports {adc_ch1_i[*]}]
set_input_delay -clock [get_clocks clk_fpga_0] -min 1.0 [get_ports {adc_ch1_i[*]}]
set_input_delay -clock [get_clocks clk_fpga_0] -max 3.0 [get_ports {adc_ch2_i[*]}]
set_input_delay -clock [get_clocks clk_fpga_0] -min 1.0 [get_ports {adc_ch2_i[*]}]
set_output_delay -clock [get_clocks clk_fpga_0] -max 1.0 [get_ports pulse_out]
set_output_delay -clock [get_clocks clk_fpga_0] -min 0.0 [get_ports pulse_out]
