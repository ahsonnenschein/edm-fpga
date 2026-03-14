# synth_check.tcl
# Quick synthesis check of EDM RTL modules against Zynq-7010
# Does NOT require block design or board — just checks RTL for errors.

set part "xc7z010clg400-1"
set rtl_dir [file normalize "[file dirname [info script]]/../rtl"]

create_project -in_memory -part $part

read_verilog [glob $rtl_dir/*.v]
set_property top edm_top [current_fileset]

synth_design -top edm_top -part $part -mode out_of_context

report_utilization
report_timing_summary -no_header

puts "\n--- RTL synthesis complete ---"
