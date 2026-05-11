create_clock -name clk_21m -period 46.561 [get_ports {clk_21m}]
derive_clock_uncertainty

# sdram_clk is clk_21m forwarded directly to the SDRAM clock pin.
# Declare it as a generated clock so STA knows the launch/latch relationship.
create_generated_clock -name sdram_clk -source [get_ports {clk_21m}] \
    -divide_by 1 [get_ports {sdram_clk}]

# The clk_21m -> sdram_clk path is a clock forwarding path, not a data path.
# STA's hold check on it is meaningless — false-path it.
set_false_path -from [get_clocks {clk_21m}] -to [get_ports {sdram_clk}]

set_false_path -from [get_ports {rst_n_in}] -to *
set_false_path -from * -to [get_ports {led[*]}]

# SDRAM I/O constraints (very relaxed at 21 MHz — tighten if clock is sped up).
# Excludes sdram_clk itself (covered by false path above).
set_output_delay -clock sdram_clk -max  3.0 [get_ports {sdram_cke sdram_cs_n sdram_ras_n sdram_cas_n sdram_we_n sdram_ba[*] sdram_a[*] sdram_dqm[*] sdram_dq[*]}]
set_output_delay -clock sdram_clk -min -1.0 [get_ports {sdram_cke sdram_cs_n sdram_ras_n sdram_cas_n sdram_we_n sdram_ba[*] sdram_a[*] sdram_dqm[*] sdram_dq[*]}]
set_input_delay  -clock sdram_clk -max  8.0 [get_ports {sdram_dq[*]}]
set_input_delay  -clock sdram_clk -min  1.0 [get_ports {sdram_dq[*]}]
