// DDS tone generator. 32-bit phase accumulator clocked at the system clock;
// frequency = clk_freq * FTW / 2^32. Stage A: square wave from phase MSB only.
module tone_gen (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [31:0] ftw,
    output wire [5:0] sample
);
    // Centered around mid-rail (6'h1F/6'h20). Swing of 5 LSBs ≈ 8% amplitude.
    // Square waves are brutal at full swing — start quiet, raise if needed.
    localparam [5:0] HI = 6'h22;
    localparam [5:0] LO = 6'h1D;

    reg [31:0] phase;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) phase <= 32'd0;
        else        phase <= phase + ftw;
    end

    assign sample = phase[31] ? HI : LO;

endmodule
