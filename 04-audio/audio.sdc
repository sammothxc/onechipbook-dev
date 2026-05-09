create_clock -name clk_21m -period 46.561 [get_ports {clk_21m}]
derive_pll_clocks
derive_clock_uncertainty

set_false_path -from [get_ports {rst_n_in dip0 ps2_clk ps2_data}] -to *
set_false_path -from * -to [get_ports {sl[*] sr[*]}]
set_false_path -from * -to [get_ports {hsync vsync}]
set_false_path -from * -to [get_ports {r[*] g[*] b[*]}]
set_false_path -from * -to [get_ports {led}]

# Display state crosses from audio domain (clk_21m) to pixel domain
# (vga65mhz_pll c0). It only changes on key-press; brief inconsistency
# during transition would be invisible at 60 Hz refresh.
set_false_path -from [get_clocks clk_21m] -to [get_clocks {pll_inst|altpll_component|*|c0}]
