// DDS tone generator with selectable wave shape.
// Phase accumulator (32-bit) clocked at the system clock.
// Three wave shapes generated at full 6-bit swing (0..63) internally, then
// centered around mid-rail and attenuated by an arithmetic right shift.
// Output is a SIGNED deviation from mid-rail — caller sums voices and
// re-biases. When `active` is low, output is 0 (no contribution to a sum).
// Smaller AMP_SHIFT = louder. Square is intrinsically harshest.
module tone_gen #(
    parameter [2:0] AMP_SHIFT = 3'd3
) (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               active,
    input  wire        [31:0] ftw,
    input  wire         [1:0] wave_sel,    // 00=sine, 01=saw, 10=square
    output wire signed  [6:0] sample
);
    localparam [5:0] MID = 6'h20;

    // ---- Phase accumulator (free-runs even when inactive) ----
    reg [31:0] phase;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) phase <= 32'd0;
        else        phase <= phase + ftw;
    end

    // ---- Sine LUT: 256 x 8-bit storage; only low 6 bits used ----
    reg [7:0] sine_lut [0:255];
    initial $readmemh("sine_lut.hex", sine_lut);

    reg [5:0] sine_val;
    always @(posedge clk) sine_val <= sine_lut[phase[31:24]][5:0];

    // ---- Saw and square (combinational) ----
    wire [5:0] saw_val = phase[31:26];
    wire [5:0] sq_val  = phase[31] ? 6'h3F : 6'h00;

    // ---- Wave mux ----
    reg [5:0] wave_full;
    always @(*) case (wave_sel)
        2'b00:   wave_full = sine_val;
        2'b01:   wave_full = saw_val;
        default: wave_full = sq_val;
    endcase

    // ---- Center around mid-rail, arithmetic shift right ----
    wire signed [6:0] centered   = $signed({1'b0, wave_full}) - $signed({1'b0, MID});
    wire signed [6:0] attenuated = centered >>> AMP_SHIFT;

    assign sample = active ? attenuated : 7'sd0;

endmodule
