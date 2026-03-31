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
    $rtl_dir/xadc_drp_reader.v \
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
    CONFIG.PCW_USE_M_AXI_GP0             {1} \
    CONFIG.PCW_EN_CLK0_PORT              {1} \
    CONFIG.PCW_EN_RST0_PORT              {1} \
    CONFIG.PCW_USE_S_AXI_HP0             {1} \
    CONFIG.PCW_S_AXI_HP0_DATA_WIDTH      {32} \
    CONFIG.PCW_UART1_PERIPHERAL_ENABLE   {1} \
    CONFIG.PCW_UART1_UART1_IO            {EMIO} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT      {1} \
    CONFIG.PCW_IRQ_F2P_INTR             {1} \
] [get_bd_cells ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config {make_external "FIXED_IO, DDR"} [get_bd_cells ps7]

# Re-apply settings after automation (apply_bd_automation overrides them)
set_property CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {100.000000} [get_bd_cells ps7]

# ── XADC Wizard ────────────────────────────────────────
# Simultaneous sampling mode: ADC-A samples VP/VN, ADC-B samples VAUX6,
# both at 1 MSPS.  One EOC fires per pair; xadc_drp_reader reads each
# channel's result register when channel_out confirms conversion done.
# Temperature channel is disabled (not available in simultaneous mode).
#
# NOTE: if Vivado rejects XADC_STARUP_SELECTION {simultaneous_sampling},
# open the IP customization GUI for xadc_wiz_0 and select
# "Simultaneous Sampling" — then re-export the TCL to get the exact name.
create_bd_cell -type ip -vlnv xilinx.com:ip:xadc_wiz:3.3 xadc_wiz_0
set_property -dict [list \
    CONFIG.INTERFACE_SELECTION       {ENABLE_DRP} \
    CONFIG.XADC_STARUP_SELECTION     {simultaneous_sampling} \
    CONFIG.CHANNEL_ENABLE_VP_VN      {true} \
    CONFIG.CHANNEL_ENABLE_VAUXP6_VAUXN6 {true} \
    CONFIG.TIMING_MODE               {Continuous} \
    CONFIG.DCLK_FREQUENCY            {100} \
    CONFIG.ADC_CONVERSION_RATE       {1000} \
] [get_bd_cells xadc_wiz_0]

# Expose VP/VN and VAUX6 analog inputs
make_bd_intf_pins_external [get_bd_intf_pins xadc_wiz_0/Vp_Vn]
make_bd_intf_pins_external [get_bd_intf_pins xadc_wiz_0/Vaux6]

# Tie DRP write-side inputs to 0 (read-only DRP master in edm_ctrl)
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_0
set_property -dict [list CONFIG.CONST_VAL {0} CONFIG.CONST_WIDTH {1}] \
    [get_bd_cells const_0]
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_16b
set_property -dict [list CONFIG.CONST_VAL {0} CONFIG.CONST_WIDTH {16}] \
    [get_bd_cells const_16b]
connect_bd_net [get_bd_pins const_0/dout]   [get_bd_pins xadc_wiz_0/dwe_in]
connect_bd_net [get_bd_pins const_16b/dout] [get_bd_pins xadc_wiz_0/di_in]

# ── AXI Interconnect: GP0 → EDM regs + DMA ────────────
# XADC no longer needs AXI4-Lite (stream mode); only 2 masters needed
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_gp0
set_property CONFIG.NUM_MI {2} [get_bd_cells axi_gp0]

# ── EDM top (RTL module reference) ─────────────────────
create_bd_cell -type module -reference edm_top edm_ctrl

# Associate M_AXIS with S_AXI_ACLK to suppress BD 41-967 and let IPI
# know which clock domain drives the AXI4-Stream master port.
set_property -dict [list \
    CONFIG.ASSOCIATED_BUSIF  {S_AXI:M_AXIS} \
    CONFIG.ASSOCIATED_RESET  {S_AXI_ARESETN} \
] [get_bd_pins edm_ctrl/S_AXI_ACLK]

# ── AXI DMA (S2MM only: stream → memory via HP0) ───────
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma:7.1 axi_dma_0
set_property -dict [list \
    CONFIG.c_include_mm2s             {0} \
    CONFIG.c_include_s2mm             {1} \
    CONFIG.c_include_sg               {0} \
    CONFIG.c_s2mm_burst_size          {16} \
    CONFIG.c_sg_length_width          {16} \
] [get_bd_cells axi_dma_0]

# ── AXI Protocol Converter: DMA AXI4 → PS HP0 AXI3 ────
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_protocol_converter:2.1 axi_proto_conv_0

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
    edm_ctrl/S_AXI_ACLK \
    xadc_wiz_0/dclk_in \
    axi_dma_0/s_axi_lite_aclk \
    axi_dma_0/m_axi_s2mm_aclk \
    axi_proto_conv_0/aclk \
] { connect_bd_net $clk [get_bd_pins $pin] }

foreach pin [list \
    axi_gp0/ARESETN \
    axi_gp0/S00_ARESETN \
    axi_gp0/M00_ARESETN \
    axi_gp0/M01_ARESETN \
    edm_ctrl/S_AXI_ARESETN \
    axi_dma_0/axi_resetn \
    axi_proto_conv_0/aresetn \
] { connect_bd_net $rstn [get_bd_pins $pin] }

# -------------------------------------------------------
# AXI control bus connections (GP0)
# -------------------------------------------------------
connect_bd_intf_net [get_bd_intf_pins ps7/M_AXI_GP0] \
                    [get_bd_intf_pins axi_gp0/S00_AXI]

# M00 → EDM control registers
connect_bd_intf_net [get_bd_intf_pins axi_gp0/M00_AXI] \
                    [get_bd_intf_pins edm_ctrl/S_AXI]

# M01 → AXI DMA control
connect_bd_intf_net [get_bd_intf_pins axi_gp0/M01_AXI] \
                    [get_bd_intf_pins axi_dma_0/S_AXI_LITE]

# -------------------------------------------------------
# DMA data path: edm_ctrl stream → DMA → PS HP0 → DDR
# -------------------------------------------------------
connect_bd_intf_net [get_bd_intf_pins edm_ctrl/M_AXIS] \
                    [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]

# DMA AXI4 → protocol converter → PS HP0 AXI3
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] \
                    [get_bd_intf_pins axi_proto_conv_0/S_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_proto_conv_0/M_AXI] \
                    [get_bd_intf_pins ps7/S_AXI_HP0]

# DMA S2MM interrupt: deferred until after all connections (see below)

# -------------------------------------------------------
# XADC DRP signals → edm_ctrl (xadc_drp_reader)
# -------------------------------------------------------
connect_bd_net [get_bd_pins xadc_wiz_0/channel_out] [get_bd_pins edm_ctrl/xadc_channel]
connect_bd_net [get_bd_pins xadc_wiz_0/eoc_out]     [get_bd_pins edm_ctrl/xadc_eoc]
connect_bd_net [get_bd_pins xadc_wiz_0/do_out]      [get_bd_pins edm_ctrl/xadc_do]
connect_bd_net [get_bd_pins xadc_wiz_0/drdy_out]    [get_bd_pins edm_ctrl/xadc_drdy]
connect_bd_net [get_bd_pins edm_ctrl/xadc_daddr]    [get_bd_pins xadc_wiz_0/daddr_in]
connect_bd_net [get_bd_pins edm_ctrl/xadc_den]      [get_bd_pins xadc_wiz_0/den_in]

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
# UART1 EMIO — DPH8909 PSU serial via RPi header
#   Pin 8  (GPIO14, V6) = TX  (PS → DPH8909 RX)
#   Pin 10 (GPIO15, Y6) = RX  (DPH8909 TX → PS)
# Creates /dev/ttyPS1 in Linux on the board.
# -------------------------------------------------------
create_bd_port -dir O uart1_txd
create_bd_port -dir I uart1_rxd
connect_bd_net [get_bd_pins ps7/UART1_TX] [get_bd_ports uart1_txd]
connect_bd_net [get_bd_pins ps7/UART1_RX] [get_bd_ports uart1_rxd]

# -------------------------------------------------------
# Address map
# -------------------------------------------------------
assign_bd_address

set all_segs [get_bd_addr_segs ps7/Data/*]
puts "Address segments: $all_segs"

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
# Enable fabric interrupts and connect DMA interrupt.
# Must be done AFTER all other connections are made, because:
# 1. apply_bd_automation resets PCW_USE_FABRIC_INTERRUPT to 0
# 2. The PS7 doesn't regenerate IRQ_F2P pin until validate_bd_design
# 3. validate_bd_design requires all clocks/resets connected first
# -------------------------------------------------------
set_property CONFIG.PCW_USE_FABRIC_INTERRUPT {1} [get_bd_cells ps7]
set_property CONFIG.PCW_IRQ_F2P_INTR {1} [get_bd_cells ps7]
validate_bd_design
puts "IRQ_F2P pin exists: [llength [get_bd_pins -quiet ps7/IRQ_F2P]]"
if {[llength [get_bd_pins -quiet ps7/IRQ_F2P]] > 0} {
    connect_bd_net [get_bd_pins axi_dma_0/s2mm_introut] [get_bd_pins ps7/IRQ_F2P]
    puts "DMA interrupt connected to PS IRQ_F2P"
} else {
    puts "WARNING: IRQ_F2P pin not found — DMA interrupts will not work"
}

# -------------------------------------------------------
# Re-validate, save, wrap, and build
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
