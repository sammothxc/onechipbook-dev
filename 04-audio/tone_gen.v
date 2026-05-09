// DDS tone generator with selectable wave shape.
// Phase accumulator (32-bit) clocked at the system clock.
// Three wave shapes generated at full 6-bit swing (0..63), then attenuated
// uniformly around mid-rail (6'h20) by a single arithmetic right shift.
// Smaller AMP_SHIFT = louder. Square is intrinsically harshest.
module tone_gen #(
    parameter [2:0] AMP_SHIFT = 3'd3
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] ftw,
    input  wire  [1:0] wave_sel,    // 00=sine, 01=saw, 10=square
    output wire  [5:0] sample
);
    localparam [5:0] MID = 6'h20;

    // ---- Phase accumulator ----
    reg [31:0] phase;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) phase <= 32'd0;
        else        phase <= phase + ftw;
    end

    // ---- Sine LUT: 256 entries x 8 bits storage; only low 6 bits used.
    // Stored as 8-bit so $readmemh's natural 8-bit hex tokens don't trigger
    // truncation warnings on every line. Top 2 bits ignored at read.
    reg [7:0] sine_lut [0:255];
    initial $readmemh("sine_lut.hex", sine_lut);

    reg [5:0] sine_val;
    always @(posedge clk) sine_val <= sine_lut[phase[31:24]][5:0];

    // ---- Saw and square (combinational) ----
    wire [5:0] saw_val = phase[31:26];                  // top 6 bits ramp
    wire [5:0] sq_val  = phase[31] ? 6'h3F : 6'h00;

    // ---- Wave mux ----
    reg [5:0] wave_full;
    always @(*) case (wave_sel)
        2'b00:   wave_full = sine_val;
        2'b01:   wave_full = saw_val;
        default: wave_full = sq_val;
    endcase

    // ---- Attenuation: out = MID + ((wave_full - MID) >>> AMP_SHIFT) ----
    // Sign-extend to 7 bits, center, arithmetic right shift, re-bias.
    // Modular 6-bit arithmetic naturally truncates back into 0..63.
    wire signed [6:0] centered   = $signed({1'b0, wave_full}) - $signed({1'b0, MID});
    wire signed [6:0] attenuated = centered >>> AMP_SHIFT;
    assign sample = attenuated[5:0] + MID;

endmodule
