module keyboard (
    input  wire       clk_21m,
    input  wire       rst_n_in,
    input  wire       ps2_clk,
    input  wire       ps2_data,
    output reg  [7:0] led
);

    wire [7:0] rx_data;
    wire       rx_valid;

    ps2_rx rx_inst (
        .clk          (clk_21m),
        .rst_n        (rst_n_in),
        .ps2_clk_raw  (ps2_clk),
        .ps2_data_raw (ps2_data),
        .data         (rx_data),
        .data_valid   (rx_valid)
    );

    // Latch last received scan code onto LEDs
    always @(posedge clk_21m or negedge rst_n_in) begin
        if (!rst_n_in)
            led <= 8'h00;
        else if (rx_valid)
            led <= rx_data;
    end

endmodule
