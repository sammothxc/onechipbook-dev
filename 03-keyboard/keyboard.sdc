create_clock -period 46.561 [get_ports clk_21m]

# PS/2 lines enter through 2-flop synchronizers; no timing path to analyze
set_false_path -from [get_ports ps2_clk]
set_false_path -from [get_ports ps2_data]
