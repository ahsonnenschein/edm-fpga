# create_project.tcl
# Creates the Vivado project for the EDM FPGA controller with 1 MSPS waveform capture.
# Target: PYNQ-Z2 (Zynq XC7Z020-1CLG400C)
#
# Data path:
#   XADC Wizard DRP outputs (eoc/channel/do) → edm_ctrl waveform_capture
#   edm_ctrl M_AXIS → AXI DMA S_AXIS_S2MM → PS HP0 → DDR
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

# Add RTL sources
add_files -fileset sources_1 [list \
    $rtl_dir/edm_top.v \
    $rtl_dir/edm_pulse_ctrl.v \
    $rtl_dir/axi_edm_regs.v \
    $rtl_dir/waveform_capture.v \
]

add_files -fileset constrs_1 "$xdc_dir/pynq_z2.xdc"

# -------------------------------------------------------
# Block design
# -------------------------------------------------------
create_bd_design "edm_system"
update_compile_order -fileset sources_1

# ── Zynq PS ────────────────────────────────────────────
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7
set_property -dict [list \
    CONFIG.PCW_PRESET_BANK0_VOLTAGE      {LVCMOS 3.3V} \
    CONFIG.PCW_PRESET_BANK1_VOLTAGE      {LVCMOS 1.8V} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ  {100.000000} \
    CONFIG.PCW_USE_M_AXI_GP0             {1} \
    CONFIG.PCW_EN_CLK0_PORT              {1} \
    CONFIG.PCW_EN_RST0_PORT              {1} \
    CONFIG.PCW_USE_S_AXI_HP0             {1} \
] [get_bd_cells ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR"} [get_bd_cells ps7]

# ── XADC Wizard ────────────────────────────────────────
# AXI4-Lite for register access; DRP outputs (eoc/channel/do) go to fabric
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

# Expose VP/VN analog input
make_bd_intf_pins_external [get_bd_intf_pins xadc_wiz_0/Vp_Vn]

# ── AXI Interconnect: GP0 → EDM regs + XADC + DMA ─────
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_gp0
set_property CONFIG.NUM_MI {3} [get_bd_cells axi_gp0]

# ── EDM top (RTL module reference) ─────────────────────
create_bd_cell -type module -reference edm_top edm_ctrl

# ── AXI DMA (S2MM only: stream → memory via HP0) ───────
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0
set_property -dict [list \
    CONFIG.c_include_mm2s             {0} \
    CONFIG.c_include_s2mm             {1} \
    CONFIG.c_s2mm_burst_size          {16} \
    CONFIG.c_s2mm_data_width          {32} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_sg_length_width          {16} \
] [get_bd_cells axi_dma_0]

# -------------------------------------------------------
# Clock and reset
# -------------------------------------------------------
set clk  [get_bd_pins ps7/FCLK_CLK0]
set rstn [get_bd_pins ps7/FCLK_RESET0_N]

foreach pin [list \
    ps7/M_AXI_GP0_ACLK \
    ps7/S_AXI_HP0_ACLK \
    axi_gp0/ACLK \
    axi_gp0/S00_ACLK \
    axi_gp0/M00_ACLK \
    axi_gp0/M01_ACLK \
    axi_gp0/M02_ACLK \
    edm_ctrl/S_AXI_ACLK \
    xadc_wiz_0/s_axi_aclk \
    axi_dma_0/s_axi_lite_aclk \
    axi_dma_0/m_axi_s2mm_aclk \
] { connect_bd_net $clk [get_bd_pins $pin] }

foreach pin [list \
    axi_gp0/ARESETN \
    axi_gp0/S00_ARESETN \
    axi_gp0/M00_ARESETN \
    axi_gp0/M01_ARESETN \
    axi_gp0/M02_ARESETN \
    edm_ctrl/S_AXI_ARESETN \
    xadc_wiz_0/s_axi_aresetn \
    axi_dma_0/axi_resetn \
] { connect_bd_net $rstn [get_bd_pins $pin] }

# -------------------------------------------------------
# AXI control bus connections (GP0)
# -------------------------------------------------------
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] \
                    [get_bd_intf_pins axi_gp0/S00_AXI]

# M00 → EDM control registers
connect_bd_intf_net [get_bd_intf_pins axi_gp0/M00_AXI] \
                    [get_bd_intf_pins edm_ctrl/S_AXI]

# M01 → XADC Wizard AXI
connect_bd_intf_net [get_bd_intf_pins axi_gp0/M01_AXI] \
                    [get_bd_intf_pins xadc_wiz_0/s_axi_lite]

# M02 → AXI DMA control
connect_bd_intf_net [get_bd_intf_pins axi_gp0/M02_AXI] \
                    [get_bd_intf_pins axi_dma_0/S_AXI_LITE]

# -------------------------------------------------------
# DMA data path: edm_ctrl stream → DMA → PS HP0 → DDR
# -------------------------------------------------------
connect_bd_intf_net [get_bd_intf_pins edm_ctrl/M_AXIS] \
                    [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] \
                    [get_bd_intf_pins ps7/S_AXI_HP0]

# -------------------------------------------------------
# XADC DRP fabric outputs → edm_ctrl waveform_capture
# -------------------------------------------------------
connect_bd_net [get_bd_pins xadc_wiz_0/eoc_out]     [get_bd_pins edm_ctrl/xadc_eoc]
connect_bd_net [get_bd_pins xadc_wiz_0/channel_out]  [get_bd_pins edm_ctrl/xadc_channel]
connect_bd_net [get_bd_pins xadc_wiz_0/do_out]       [get_bd_pins edm_ctrl/xadc_do]

# -------------------------------------------------------
# GPIO: expose EDM I/O to top level for XDC constraints
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

# Move XADC to 0x43C20000 first (frees default 0x43C00000 range)
foreach seg $all_segs {
    set name [get_property NAME $seg]
    if {[string match "*xadc*" $name]} {
        set_property offset 0x43C20000 $seg
        set_property range  64K        $seg
        puts "XADC segment: $seg -> 0x43C20000"
    }
}
# EDM registers at 0x43C00000
foreach seg $all_segs {
    set name [get_property NAME $seg]
    if {[string match "*edm_ctrl*" $name]} {
        set_property offset 0x43C00000 $seg
        set_property range  4K         $seg
        puts "EDM  segment: $seg -> 0x43C00000"
    }
}
# AXI DMA control at 0x40400000
foreach seg $all_segs {
    set name [get_property NAME $seg]
    if {[string match "*axi_dma*" $name]} {
        set_property offset 0x40400000 $seg
        set_property range  64K        $seg
        puts "DMA  segment: $seg -> 0x40400000"
    }
}

# -------------------------------------------------------
# Validate, save, wrap, and build
# -------------------------------------------------------
validate_bd_design
save_bd_design

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
