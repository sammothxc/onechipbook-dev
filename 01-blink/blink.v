module blink (
    input  wire clk,  // 21 mhz
    input  wire sw1,  // toggles led2
    output reg  led1, // blink at 1 hz
    output wire led2
);
    localparam HALF_SECOND = 24'd10_499_999; // 21,000,000 / 2 = 10,500,000
    
    reg [23:0] counter;
    
    always @(posedge clk) begin
        if (counter == HALF_SECOND) begin
            counter <= 24'd0;
            led1    <= ~led1;
        end else begin
            counter <= counter + 1'b1;
        end
    end
    
    assign led2 = sw1;

endmodule