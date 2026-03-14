# create_project.tcl
# Creates the Vivado project for the EDM FPGA controller
# Target: Red Pitaya STEMlab 125-14 v1 (Zynq XC7Z010-1CLG400C)
#
# Usage (from Vivado Tcl console or batch mode):
#   source create_project.tcl

set project_name "edm_rp"
set project_dir  "[file normalize "../../vivado_project"]"
set rtl_dir      "[file normalize "../rtl"]"
set part         "xc7z010clg400-1"

# Create project
create_project $project_name $project_dir -part $part -force
set_property board_part [get_board_parts *redpitaya* -quiet] [current_project]

# Add RTL sources
add_files -fileset sources_1 [glob $rtl_dir/*.v]
set_property top edm_top [current_fileset]

# Add constraints
add_files -fileset constrs_1 [file normalize "../constraints/redpitaya_v1.xdc"]

# -------------------------------------------------------
# Block design
# -------------------------------------------------------
create_bd_design "edm_system"

# Zynq PS
create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR" apply_board_preset "1"} [get_bd_cells ps7]

# Configure PS clocks and interfaces
set_property -dict [list \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {125} \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_USE_S_AXI_HP0 {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH {64} \
] [get_bd_cells ps7]

# AXI DMA (waveform data: FPGA → DDR via HP0)
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma dma0
set_property -dict [list \
    CONFIG.c_include_sg          {0} \
    CONFIG.c_sg_include_stscntrl_strm {0} \
    CONFIG.c_m_axi_mm2s_data_width {64} \
    CONFIG.c_m_axis_mm2s_tdata_width {32} \
    CONFIG.c_s2mm_burst_size     {16} \
    CONFIG.c_include_mm2s        {0} \
    CONFIG.c_include_s2mm        {1} \
] [get_bd_cells dma0]

# AXI Interconnect for GP0 (register access)
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect axi_gp0
set_property CONFIG.NUM_MI {2} [get_bd_cells axi_gp0]

# EDM top as AXI-Lite peripheral
create_bd_cell -type module -reference edm_top edm_ctrl
set_property -dict [list \
    CONFIG.C_S_AXI_DATA_WIDTH {32} \
    CONFIG.C_S_AXI_ADDR_WIDTH {5} \
] [get_bd_cells edm_ctrl]

# -------------------------------------------------------
# Connections
# -------------------------------------------------------

# Clocks and resets
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]      [get_bd_pins ps7/M_AXI_GP0_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]      [get_bd_pins ps7/S_AXI_HP0_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]      [get_bd_pins axi_gp0/ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]      [get_bd_pins axi_gp0/S00_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]      [get_bd_pins axi_gp0/M00_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]      [get_bd_pins axi_gp0/M01_ACLK]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]      [get_bd_pins dma0/s_axi_lite_aclk]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]      [get_bd_pins dma0/m_axi_s2mm_aclk]
connect_bd_net [get_bd_pins ps7/FCLK_CLK0]      [get_bd_pins edm_ctrl/S_AXI_ACLK]

connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N]  [get_bd_pins axi_gp0/ARESETN]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N]  [get_bd_pins axi_gp0/S00_ARESETN]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N]  [get_bd_pins axi_gp0/M00_ARESETN]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N]  [get_bd_pins axi_gp0/M01_ARESETN]
connect_bd_net [get_bd_pins ps7/FCLK_RESET0_N]  [get_bd_pins edm_ctrl/S_AXI_ARESETN]

# PS GP0 → AXI interconnect
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] \
                    [get_bd_intf_pins axi_gp0/S00_AXI]

# AXI interconnect M00 → DMA control
connect_bd_intf_net [get_bd_intf_pins axi_gp0/M00_AXI] \
                    [get_bd_intf_pins dma0/S_AXI_LITE]

# AXI interconnect M01 → EDM registers
connect_bd_intf_net [get_bd_intf_pins axi_gp0/M01_AXI] \
                    [get_bd_intf_pins edm_ctrl/S_AXI]

# DMA S2MM → PS HP0 (waveform data to DDR)
connect_bd_intf_net [get_bd_intf_pins dma0/M_AXI_S2MM] \
                    [get_bd_intf_pins ps7/S_AXI_HP0]

# EDM AXI-Stream → DMA S2MM stream
connect_bd_net [get_bd_pins edm_ctrl/m_axis_tdata]  [get_bd_pins dma0/s_axis_s2mm_tdata]
connect_bd_net [get_bd_pins edm_ctrl/m_axis_tvalid] [get_bd_pins dma0/s_axis_s2mm_tvalid]
connect_bd_net [get_bd_pins edm_ctrl/m_axis_tlast]  [get_bd_pins dma0/s_axis_s2mm_tlast]
connect_bd_net [get_bd_pins dma0/s_axis_s2mm_tready] [get_bd_pins edm_ctrl/m_axis_tready]

# DMA interrupt to PS (optional, can poll instead)
connect_bd_net [get_bd_pins dma0/s2mm_introut] [get_bd_pins ps7/IRQ_F2P]

# -------------------------------------------------------
# Address map
# -------------------------------------------------------
# DMA control registers: 0x40400000
assign_bd_address [get_bd_addr_segs dma0/S_AXI_LITE/Reg]
set_property offset 0x40400000 [get_bd_addr_segs ps7/Data/SEG_dma0_Reg]
set_property range  64K        [get_bd_addr_segs ps7/Data/SEG_dma0_Reg]

# EDM registers: 0x43C00000
assign_bd_address [get_bd_addr_segs edm_ctrl/S_AXI/Reg]
set_property offset 0x43C00000 [get_bd_addr_segs ps7/Data/SEG_edm_ctrl_Reg]
set_property range  4K         [get_bd_addr_segs ps7/Data/SEG_edm_ctrl_Reg]

# Validate and save
validate_bd_design
save_bd_design

# Generate wrapper
make_wrapper -files [get_files edm_system.bd] -top
add_files -norecurse $project_dir/$project_name.srcs/sources_1/bd/edm_system/hdl/edm_system_wrapper.v
set_property top edm_system_wrapper [current_fileset]

puts "Project created. Open $project_dir/$project_name.xpr in Vivado."
puts "Run synthesis, implementation, and generate bitstream."
puts "Then: write_bitstream -file edm_rp.bit"
