# create_project.tcl
# Creates the Vivado project for the EDM FPGA controller
# Target: PYNQ-Z2 (Zynq XC7Z020-1CLG400C)
#
# Usage from Vivado Tcl console or batch mode:
#   cd /home/sonnensn/edm-fpga
#   source scripts/create_project.tcl

set script_dir  [file normalize [file dirname [info script]]]
set root_dir    [file normalize "$script_dir/.."]
set project_dir [file normalize "$root_dir/../edm_vivado"]
set rtl_dir     [file normalize "$root_dir/rtl"]
set xdc_dir     [file normalize "$root_dir/constraints"]
set part        "xc7z020clg400-1"
set project_name "edm_pynq"

puts "Creating project in $project_dir"
create_project $project_name $project_dir -part $part -force

# Add RTL sources (exclude waveform_capture — not used in this revision)
add_files -fileset sources_1 [list \
    $rtl_dir/edm_top.v \
    $rtl_dir/edm_pulse_ctrl.v \
    $rtl_dir/axi_edm_regs.v \
]

# Add constraints
add_files -fileset constrs_1 "$xdc_dir/pynq_z2.xdc"

# -------------------------------------------------------
# Block design
# -------------------------------------------------------
create_bd_design "edm_system"
update_compile_order -fileset sources_1

# Zynq-7020 PS (PYNQ-Z2, 100 MHz fabric clock)
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7
set_property -dict [list \
    CONFIG.PCW_PRESET_BANK0_VOLTAGE      {LVCMOS 3.3V} \
    CONFIG.PCW_PRESET_BANK1_VOLTAGE      {LVCMOS 1.8V} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ  {100.000000} \
    CONFIG.PCW_USE_M_AXI_GP0             {1} \
    CONFIG.PCW_EN_CLK0_PORT              {1} \
    CONFIG.PCW_EN_RST0_PORT              {1} \
] [get_bd_cells ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR"} [get_bd_cells ps7]

# XADC Wizard — AXI interface, continuous sequencer on VP/VN (CH1) and VAUX1 (CH2, Arduino A0)
create_bd_cell -type ip -vlnv xilinx.com:ip:xadc_wiz:3.3 xadc_wiz_0
set_property -dict [list \
    CONFIG.INTERFACE_SELECTION   {Enable_AXI} \
    CONFIG.XADC_STARUP_SELECTION {channel_sequencer} \
    CONFIG.CHANNEL_ENABLE_VP_VN  {true} \
    CONFIG.CHANNEL_ENABLE_VAUX1  {true} \
    CONFIG.SEQUENCER_MODE        {Continuous} \
    CONFIG.TIMING_MODE           {Event} \
    CONFIG.DCLK_FREQUENCY        {100} \
    CONFIG.ADC_CONVERSION_RATE   {1000} \
] [get_bd_cells xadc_wiz_0]

# Expose VP/VN dedicated analog input to top level
# Vaux1 (Arduino A0) is handled internally by XADC Wizard via PACKAGE_PIN in IP config
make_bd_intf_pins_external [get_bd_intf_pins xadc_wiz_0/Vp_Vn]

# AXI Interconnect: PS GP0 → EDM registers + XADC Wizard
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_gp0
set_property CONFIG.NUM_MI {2} [get_bd_cells axi_gp0]

# EDM top as RTL module reference in block design
create_bd_cell -type module -reference edm_top edm_ctrl

# -------------------------------------------------------
# Clock and reset connections
# -------------------------------------------------------
set clk  [get_bd_pins ps7/FCLK_CLK0]
set rstn [get_bd_pins ps7/FCLK_RESET0_N]

foreach pin [list \
    ps7/M_AXI_GP0_ACLK \
    axi_gp0/ACLK \
    axi_gp0/S00_ACLK \
    axi_gp0/M00_ACLK \
    axi_gp0/M01_ACLK \
    edm_ctrl/S_AXI_ACLK \
    xadc_wiz_0/s_axi_aclk \
] { connect_bd_net $clk [get_bd_pins $pin] }

foreach pin [list \
    axi_gp0/ARESETN \
    axi_gp0/S00_ARESETN \
    axi_gp0/M00_ARESETN \
    axi_gp0/M01_ARESETN \
    edm_ctrl/S_AXI_ARESETN \
    xadc_wiz_0/s_axi_aresetn \
] { connect_bd_net $rstn [get_bd_pins $pin] }

# -------------------------------------------------------
# AXI connections
# -------------------------------------------------------
# PS GP0 → AXI interconnect
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] \
                    [get_bd_intf_pins axi_gp0/S00_AXI]

# Interconnect M00 → EDM control registers
connect_bd_intf_net [get_bd_intf_pins axi_gp0/M00_AXI] \
                    [get_bd_intf_pins edm_ctrl/S_AXI]

# Interconnect M01 → XADC Wizard AXI
connect_bd_intf_net [get_bd_intf_pins axi_gp0/M01_AXI] \
                    [get_bd_intf_pins xadc_wiz_0/s_axi_lite]

# -------------------------------------------------------
# GPIO connections (make external for XDC pin assignment)
# -------------------------------------------------------
make_bd_pins_external [get_bd_pins edm_ctrl/hv_enable]
make_bd_pins_external [get_bd_pins edm_ctrl/pulse_out]
make_bd_pins_external [get_bd_pins edm_ctrl/lamp_green]
make_bd_pins_external [get_bd_pins edm_ctrl/lamp_orange]
make_bd_pins_external [get_bd_pins edm_ctrl/lamp_red]
make_bd_pins_external [get_bd_pins edm_ctrl/led]

# -------------------------------------------------------
# Address map
# -------------------------------------------------------
assign_bd_address

set all_segs [get_bd_addr_segs ps7/Data/*]
puts "Address segments: $all_segs"

# Move XADC first to free up the auto-assigned 0x43C00000 range
foreach seg $all_segs {
    set name [get_property NAME $seg]
    if {[string match "*xadc*" $name]} {
        set_property offset 0x43C20000 $seg
        set_property range  64K        $seg
        puts "XADC segment: $seg -> 0x43C20000"
    }
}
# Now assign EDM registers (0x43C00000 is now free)
foreach seg $all_segs {
    set name [get_property NAME $seg]
    if {[string match "*edm_ctrl*" $name]} {
        set_property offset 0x43C00000 $seg
        set_property range  4K         $seg
        puts "EDM  segment: $seg -> 0x43C00000"
    }
}

# -------------------------------------------------------
# Validate, save, wrap, and build
# -------------------------------------------------------
validate_bd_design
save_bd_design

# Generate HDL wrapper
make_wrapper -files [get_files edm_system.bd] -top
set wrapper [glob $project_dir/$project_name.gen/sources_1/bd/edm_system/hdl/edm_system_wrapper.v]
add_files -norecurse $wrapper
set_property top edm_system_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "\n--- Block design created ---"
puts "Running synthesis..."
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "Synthesis failed"
}

puts "Running implementation..."
launch_runs impl_1 -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "Implementation failed"
}

puts "Generating bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

set bit_src [glob $project_dir/$project_name.runs/impl_1/*.bit]
set bit_dst [file normalize "$root_dir/edm_pynq.bit"]
file copy -force $bit_src $bit_dst

puts "\n=============================="
puts " Bitstream: $bit_dst"
puts "=============================="
