# run_sim.tcl
# Runs xsim simulation of EDM controller testbench
# Usage: vivado -mode batch -source scripts/run_sim.tcl

set script_dir [file normalize [file dirname [info script]]]
set root_dir   [file normalize "$script_dir/.."]
set rtl_dir    "$root_dir/rtl"
set sim_dir    "$root_dir/sim"
set work_dir   "$root_dir/sim_work"

file mkdir $work_dir

# Compile RTL and testbench
set sources [concat [glob $rtl_dir/*.v] [glob $sim_dir/*.v]]
foreach f $sources {
    puts "Compiling: $f"
}

exec xvlog --work work=$work_dir/work {*}$sources >@ stdout

# Elaborate
exec xelab -L work=$work_dir/work \
    -debug typical \
    -s tb_edm_top_sim \
    work.tb_edm_top >@ stdout

# Simulate (run to $finish)
exec xsim tb_edm_top_sim \
    -R \
    -log $root_dir/sim_results.log >@ stdout

puts "\nSimulation log: $root_dir/sim_results.log"
puts "Waveform:       $root_dir/sim/tb_edm_top.vcd"
puts "\nTo view waveform: gtkwave sim/tb_edm_top.vcd"
