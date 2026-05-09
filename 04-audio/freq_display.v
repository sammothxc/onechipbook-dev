// Renders an 18-character status string centered on the 1024x768 display:
//   "An  HHH Hz  WWWWWW"
// where An is note name (letter+octave), HHH is integer Hz, WWWWWW is the
// padded wave name ("sine  ", "saw   ", "square").
//
// Display window: 18 chars * 8 px = 144 px wide, 16 px tall, starting at
// (440, 376) so the centre lands on (512, 384) — same vertical line as
// hex_display from 03-keyboard.
//
// Pipeline mirrors hex_display / terminal:
//   Cycle 0: combinational ascii lookup + char_rom address
//   Cycle 1: ROM address register captures internally; col_d1 captures
//   Cycle 2: ROM data register captures; col_d2 captures; pixel_on combinational
//   Cycle 3: r/g/b output register captures
module freq_display (
    input  wire        pixel_clk,
    input  wire [10:0] pixel_x,
    input  wire  [9:0] pixel_y,
    input  wire        visible,
    // Latched display state from audio domain (treat as static for the frame)
    input  wire  [7:0] note_letter,
    input  wire  [7:0] note_octave,
    input  wire  [3:0] freq_h,
    input  wire  [3:0] freq_t,
    input  wire  [3:0] freq_u,
    input  wire  [1:0] wave_sel,
    output reg   [5:0] r,
    output reg   [5:0] g,
    output reg   [5:0] b
);

    localparam [10:0] DISP_X = 11'd440;
    localparam  [9:0] DISP_Y = 10'd376;
    localparam [10:0] DISP_W = 11'd144;  // 18 chars * 8 px

    // ---- Stage 0: position decode ----

    wire in_area = visible
                && (pixel_x >= DISP_X) && (pixel_x < DISP_X + DISP_W)
                && (pixel_y >= DISP_Y) && (pixel_y < DISP_Y + 10'd16);

    // DISP_X[2:0] == 0 so col is just pixel_x[2:0].
    // DISP_Y[3:0] == 4'h8 so row needs the wrap subtraction.
    wire [10:0] rel_x    = pixel_x - DISP_X;
    wire  [4:0] char_idx = rel_x[7:3];   // 0..17 inside area
    wire  [2:0] col      = rel_x[2:0];
    wire  [3:0] row      = pixel_y[3:0] - DISP_Y[3:0];

    // ---- Wave-name character lookup (combinational) ----
    // Each wave name is 6 chars, padded to fixed width.
    wire [2:0] wave_pos = char_idx[2:0] - 3'd4;  // char_idx 12..17 -> 0..5

    reg [7:0] wave_char;
    always @(*) begin
        case ({wave_sel, wave_pos})
            // sine
            {2'b00, 3'd0}: wave_char = "s";
            {2'b00, 3'd1}: wave_char = "i";
            {2'b00, 3'd2}: wave_char = "n";
            {2'b00, 3'd3}: wave_char = "e";
            {2'b00, 3'd4}: wave_char = " ";
            {2'b00, 3'd5}: wave_char = " ";
            // saw
            {2'b01, 3'd0}: wave_char = "s";
            {2'b01, 3'd1}: wave_char = "a";
            {2'b01, 3'd2}: wave_char = "w";
            {2'b01, 3'd3}: wave_char = " ";
            {2'b01, 3'd4}: wave_char = " ";
            {2'b01, 3'd5}: wave_char = " ";
            // square
            {2'b10, 3'd0}: wave_char = "s";
            {2'b10, 3'd1}: wave_char = "q";
            {2'b10, 3'd2}: wave_char = "u";
            {2'b10, 3'd3}: wave_char = "a";
            {2'b10, 3'd4}: wave_char = "r";
            {2'b10, 3'd5}: wave_char = "e";
            default:       wave_char = " ";
        endcase
    end

    // ---- Per-position ASCII lookup (combinational) ----
    reg [7:0] ascii;
    always @(*) begin
        case (char_idx)
            5'd0:  ascii = note_letter;
            5'd1:  ascii = note_octave;
            5'd4:  ascii = 8'h30 + {4'b0, freq_h};
            5'd5:  ascii = 8'h30 + {4'b0, freq_t};
            5'd6:  ascii = 8'h30 + {4'b0, freq_u};
            5'd8:  ascii = "H";
            5'd9:  ascii = "z";
            5'd12, 5'd13, 5'd14, 5'd15, 5'd16, 5'd17:
                   ascii = wave_char;
            default: ascii = " ";    // 2, 3, 7, 10, 11
        endcase
    end

    wire [10:0] rom_addr = {ascii[6:0], row};

    // ---- _d1 / _d2 metadata pipeline (mirrors hex_display) ----
    reg        in_area_d1, in_area_d2;
    reg  [2:0] col_d1,     col_d2;

    always @(posedge pixel_clk) begin
        in_area_d1 <= in_area;  in_area_d2 <= in_area_d1;
        col_d1     <= col;      col_d2     <= col_d1;
    end

    wire [7:0] rom_data;
    char_rom rom_inst (
        .address (rom_addr),
        .clock   (pixel_clk),
        .q       (rom_data)
    );

    wire pixel_on = in_area_d2 && rom_data[3'd7 - col_d2];

    always @(posedge pixel_clk) begin
        r <= pixel_on ? 6'h3F : 6'h00;
        g <= pixel_on ? 6'h3F : 6'h00;
        b <= pixel_on ? 6'h3F : 6'h00;
    end

endmodule
