create_clock -name clk_21m -period 46.561 [get_ports {clk_21m}]
derive_pll_clocks
derive_clock_uncertainty

# Async inputs
set_false_path -from [get_ports {rst_n_in}]   -to *
set_false_path -from [get_ports {uart_rxd}]   -to *
set_false_path -from [get_ports {ps2_clk}]    -to *
set_false_path -from [get_ports {ps2_data}]   -to *

# Async outputs
set_false_path -from * -to [get_ports {uart_txd}]
set_false_path -from * -to [get_ports {hsync vsync}]
set_false_path -from * -to [get_ports {r[*] g[*] b[*]}]
set_false_path -from * -to [get_ports {led[*]}]

# CDC paths: synchronizer inputs and data latches are not timed by STA.
# The synchronizer chains provide metastability protection; hold/setup
# margins on the raw crossing are intentionally not required.

# RX toggle (clk_21m -> pixel_clk synchronizer input)
set_false_path -from [get_keepers {rx_toggle_21m}] -to *
# RX data latch (clk_21m -> pixel_clk, stable before toggle fires)
set_false_path -from [get_keepers {rx_latch_21m[*]}] -to *

# TX toggle (pixel_clk -> clk_21m synchronizer input)
set_false_path -from [get_keepers {tx_tog_pclk}] -to *
# TX data latch (pixel_clk -> clk_21m, stable before toggle fires)
set_false_path -from [get_keepers {tx_latch_pclk[*]}] -to *
