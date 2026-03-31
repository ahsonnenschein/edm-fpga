# rebuild.tcl — Re-run synthesis/implementation/bitstream on existing project.
# Use after modifying RTL source files.
# Usage: vivado -mode batch -source scripts/rebuild.tcl

set project_dir "/home/sonnensn/edm_vivado"
set project_name "edm_pynq"
set root_dir [file normalize [file dirname [info script]]/..]

open_project $project_dir/$project_name.xpr

# Reset ALL synthesis runs including OOC IP/module runs
puts "\n--- Resetting all synthesis runs ---"
foreach run [get_runs -filter {IS_SYNTHESIS}] {
    puts "  Resetting $run"
    reset_run $run
}

puts "Running synthesis..."
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    error "Synthesis failed"
}
puts "Synthesis complete."

# Reset and re-run implementation
puts "Resetting implementation..."
reset_run impl_1
puts "Running implementation..."
launch_runs impl_1 -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    error "Implementation failed"
}
puts "Implementation complete."

# Generate bitstream
puts "Generating bitstream..."
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

# Copy outputs to repo root
set bit_src [glob $project_dir/$project_name.runs/impl_1/*.bit]
set bit_dst [file normalize "$root_dir/edm_pynq.bit"]
file copy -force $bit_src $bit_dst

set hwh_src "$project_dir/$project_name.gen/sources_1/bd/edm_system/hw_handoff/edm_system.hwh"
set hwh_dst [file normalize "$root_dir/edm_pynq.hwh"]
file copy -force $hwh_src $hwh_dst

puts "\n=============================="
puts " Bitstream: $bit_dst"
puts " HWH:       $hwh_dst"
puts "=============================="
close_project
