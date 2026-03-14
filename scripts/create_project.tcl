# create_project.tcl
# Creates the Vivado project for the EDM FPGA controller
# Target: Red Pitaya STEMlab 125-14 v1 (Zynq XC7Z010-1CLG400C)
#
# Usage from Vivado Tcl console or batch mode:
#   cd /home/sonnensn/edm_fpga
#   source scripts/create_project.tcl

set script_dir  [file normalize [file dirname [info script]]]
set root_dir    [file normalize "$script_dir/.."]
set project_dir [file normalize "$root_dir/../edm_vivado"]
set rtl_dir     [file normalize "$root_dir/rtl"]
set xdc_dir     [file normalize "$root_dir/constraints"]
set part        "xc7z010clg400-1"
set project_name "edm_rp"

puts "Creating project in $project_dir"
create_project $project_name $project_dir -part $part -force

# Add RTL sources
add_files -fileset sources_1 [glob $rtl_dir/*.v]

# Add constraints
add_files -fileset constrs_1 "$xdc_dir/redpitaya_v1.xdc"

# -------------------------------------------------------
# Block design
# -------------------------------------------------------
create_bd_design "edm_system"
update_compile_order -fileset sources_1

# Zynq-7010 PS (no board preset — configure manually for RP)
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 ps7
set_property -dict [list \
    CONFIG.PCW_PRESET_BANK0_VOLTAGE        {LVCMOS 3.3V} \
    CONFIG.PCW_PRESET_BANK1_VOLTAGE        {LVCMOS 1.8V} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ   {125.000000} \
    CONFIG.PCW_USE_M_AXI_GP0              {1} \
    CONFIG.PCW_USE_S_AXI_HP0              {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH       {64} \
    CONFIG.PCW_IRQ_F2P_INTR               {1} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT       {1} \
    CONFIG.PCW_EN_CLK0_PORT               {1} \
    CONFIG.PCW_EN_RST0_PORT               {1} \
] [get_bd_cells ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR"} [get_bd_cells ps7]

# AXI DMA — S2MM only (stream-to-memory, FPGA → DDR)
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 dma0
set_property -dict [list \
    CONFIG.c_include_mm2s            {0} \
    CONFIG.c_include_s2mm            {1} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_include_sg              {0} \
    CONFIG.c_s2mm_burst_size         {16} \
    CONFIG.c_m_axi_s2mm_data_width   {64} \
    CONFIG.c_s_axis_s2mm_tdata_width {32} \
] [get_bd_cells dma0]

# AXI Interconnect: PS GP0 → DMA control + EDM registers
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_gp0
set_property CONFIG.NUM_MI {2} [get_bd_cells axi_gp0]

# EDM top as RTL module reference in block design
create_bd_cell -type module -reference edm_top edm_ctrl

# Constant for AXI-Stream TKEEP (all bytes valid, 4-bit = 0xF for 32-bit bus)
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 tkeep_const
set_property -dict [list \
    CONFIG.CONST_WIDTH {4} \
    CONFIG.CONST_VAL   {15} \
] [get_bd_cells tkeep_const]

# -------------------------------------------------------
# Clock and reset connections
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
    dma0/s_axi_lite_aclk \
    dma0/m_axi_s2mm_aclk \
    edm_ctrl/S_AXI_ACLK \
] { connect_bd_net $clk [get_bd_pins $pin] }

foreach pin [list \
    axi_gp0/ARESETN \
    axi_gp0/S00_ARESETN \
    axi_gp0/M00_ARESETN \
    axi_gp0/M01_ARESETN \
    edm_ctrl/S_AXI_ARESETN \
] { connect_bd_net $rstn [get_bd_pins $pin] }

# -------------------------------------------------------
# AXI connections
# -------------------------------------------------------
# PS GP0 → AXI interconnect
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] \
                    [get_bd_intf_pins axi_gp0/S00_AXI]

# Interconnect M00 → DMA control registers
connect_bd_intf_net [get_bd_intf_pins axi_gp0/M00_AXI] \
                    [get_bd_intf_pins dma0/S_AXI_LITE]

# Interconnect M01 → EDM registers
connect_bd_intf_net [get_bd_intf_pins axi_gp0/M01_AXI] \
                    [get_bd_intf_pins edm_ctrl/S_AXI]

# AXI Protocol Converter: DMA AXI4 → PS HP0 AXI3
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_protocol_converter:2.1 proto_conv
connect_bd_net $clk  [get_bd_pins proto_conv/aclk]
connect_bd_net $rstn [get_bd_pins proto_conv/aresetn]

connect_bd_intf_net [get_bd_intf_pins dma0/M_AXI_S2MM]  [get_bd_intf_pins proto_conv/S_AXI]
connect_bd_intf_net [get_bd_intf_pins proto_conv/M_AXI]  [get_bd_intf_pins ps7/S_AXI_HP0]

# EDM AXI-Stream → DMA S2MM stream (connect individual nets)
connect_bd_net [get_bd_pins edm_ctrl/m_axis_tdata]   [get_bd_pins dma0/s_axis_s2mm_tdata]
connect_bd_net [get_bd_pins edm_ctrl/m_axis_tvalid]  [get_bd_pins dma0/s_axis_s2mm_tvalid]
connect_bd_net [get_bd_pins edm_ctrl/m_axis_tlast]   [get_bd_pins dma0/s_axis_s2mm_tlast]
connect_bd_net [get_bd_pins dma0/s_axis_s2mm_tready] [get_bd_pins edm_ctrl/m_axis_tready]
connect_bd_net [get_bd_pins tkeep_const/dout]         [get_bd_pins dma0/s_axis_s2mm_tkeep]

# DMA interrupt → PS IRQ_F2P
connect_bd_net [get_bd_pins dma0/s2mm_introut] [get_bd_pins ps7/IRQ_F2P]

# -------------------------------------------------------
# Address map
# -------------------------------------------------------
assign_bd_address

# Address segments are in ps7/Data space — find them by filtering all segs
set all_segs [get_bd_addr_segs ps7/Data/*]
puts "Address segments: $all_segs"

foreach seg $all_segs {
    set name [get_property NAME $seg]
    if {[string match "*dma0*" $name]} {
        set_property offset 0x40400000 $seg
        set_property range  64K        $seg
        puts "DMA  segment: $seg -> 0x40400000"
    } elseif {[string match "*edm_ctrl*" $name]} {
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
set bit_dst [file normalize "$root_dir/edm_rp.bit"]
file copy -force $bit_src $bit_dst

puts "\n=============================="
puts " Bitstream: $bit_dst"
puts "=============================="
