create_clock -name clk_21m -period 46.561 [get_ports {clk_21m}]
derive_pll_clocks
derive_clock_uncertainty

set_false_path -from [get_ports {rst_n_in}] -to *
set_false_path -from * -to [get_ports {hsync vsync}]
set_false_path -from * -to [get_ports {r[*] g[*] b[*]}]