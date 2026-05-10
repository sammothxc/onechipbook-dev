create_clock -name clk_21m -period 46.561 [get_ports {clk_21m}]
derive_pll_clocks
derive_clock_uncertainty

set_false_path -from [get_ports {rst_n_in}] -to *
set_false_path -from [get_ports {sd_miso}] -to *
set_false_path -from * -to [get_ports {hsync vsync}]
set_false_path -from * -to [get_ports {r[*] g[*] b[*]}]
set_false_path -from * -to [get_ports {led[*]}]
set_false_path -from * -to [get_ports {sd_clk sd_cs_n sd_mosi}]

# Block buffer crosses from SD-controller domain (clk_21m) to pixel domain.
# Writes happen once during init; once sd_ready is high the buffer is stable.
# Clock name confirmed from sdcard.sta.rpt — derive_pll_clocks creates this name
# (no module-type prefixes, clk[0] not c0 or _clk0).
set_false_path -from [get_clocks clk_21m] -to [get_clocks {pll_inst|altpll_component|pll|clk[0]}]
