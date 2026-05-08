# Define the system clock: 21 MHz on the 'clk' input pin
create_clock -name clk_21m -period 47.619 [get_ports {clk}]

# Tell TimeQuest to derive clock uncertainty automatically
derive_clock_uncertainty

# sw1 is asynchronous (DIP switch) - timing analysis is meaningless
set_false_path -from [get_ports {sw1}] -to *

# led1 and led2 drive LEDs - timing doesn't matter for human-visible signals
set_false_path -from * -to [get_ports {led1 led2}]