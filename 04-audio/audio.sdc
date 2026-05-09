create_clock -name clk_21m -period 46.561 [get_ports {clk_21m}]
derive_clock_uncertainty

set_false_path -from [get_ports {rst_n_in dip0}] -to *
set_false_path -from * -to [get_ports {sl[*] sr[*]}]
set_false_path -from * -to [get_ports {led}]
