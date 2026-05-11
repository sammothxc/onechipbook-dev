create_clock -name clk_21m -period 46.561 [get_ports {clk_21m}]
derive_pll_clocks
derive_clock_uncertainty

# sdram_clk is clk_21m forwarded directly to the SDRAM clock pin.
create_generated_clock -name sdram_clk -source [get_ports {clk_21m}] \
    -divide_by 1 [get_ports {sdram_clk}]

# Clock forwarding path — not a data path, false-path it.
set_false_path -from [get_clocks {clk_21m}] -to [get_ports {sdram_clk}]

# Async inputs
set_false_path -from [get_ports {rst_n_in}]   -to *
set_false_path -from [get_ports {ps2_clk}]    -to *
set_false_path -from [get_ports {ps2_dat}]    -to *

# Async outputs
set_false_path -from * -to [get_ports {led[*]}]
set_false_path -from * -to [get_ports {vga_hsync vga_vsync}]
set_false_path -from * -to [get_ports {vga_r[*] vga_g[*] vga_b[*]}]

# SDRAM I/O constraints (very relaxed at 21 MHz)
set_output_delay -clock sdram_clk -max  3.0 [get_ports {sdram_cke sdram_cs_n sdram_ras_n sdram_cas_n sdram_we_n sdram_ba[*] sdram_a[*] sdram_dqm[*] sdram_dq[*]}]
set_output_delay -clock sdram_clk -min -1.0 [get_ports {sdram_cke sdram_cs_n sdram_ras_n sdram_cas_n sdram_we_n sdram_ba[*] sdram_a[*] sdram_dqm[*] sdram_dq[*]}]
set_input_delay  -clock sdram_clk -max  8.0 [get_ports {sdram_dq[*]}]
set_input_delay  -clock sdram_clk -min  1.0 [get_ports {sdram_dq[*]}]

# CDC inside sdram_if: toggle synchronizers and the latched request/response
# data buses are intentionally untimed by STA.  The toggles enforce stability
# of the data well before the destination latches.
set_false_path -from [get_keepers {sdram_if:bridge_inst|req_toggle_p}] -to *
set_false_path -from [get_keepers {sdram_if:bridge_inst|rsp_toggle_s}] -to *
set_false_path -from [get_keepers {sdram_if:bridge_inst|we_lat_p}]     -to *
set_false_path -from [get_keepers {sdram_if:bridge_inst|addr_lat_p[*]}]    -to *
set_false_path -from [get_keepers {sdram_if:bridge_inst|wr_data_lat_p[*]}] -to *
set_false_path -from [get_keepers {sdram_if:bridge_inst|wr_mask_lat_p[*]}] -to *
set_false_path -from [get_keepers {sdram_if:bridge_inst|rd_data_lat_s[*]}] -to *
