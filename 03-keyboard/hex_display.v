// Renders the last received PS/2 byte as two hex characters ("XX") at
// the center of the 640x480 display (pixel origin x=312, y=232).
//
// 3-cycle pipeline matching text_renderer.v:
//   Cycle 0: ROM address and metadata computed combinationally from pixel_x
//   Cycle 1: ROM address register captures; col_d1/in_area_d1 capture
//   Cycle 2: ROM output register captures; col_d2/in_area_d2 capture;
//            pixel_on computed combinationally
//   Cycle 3: r/g/b output register captures
module hex_display (
    input  wire        pixel_clk,
    input  wire [10:0] pixel_x,
    input  wire  [9:0] pixel_y,
    input  wire        visible,
    input  wire  [7:0] byte_in,
    output reg   [5:0] r,
    output reg   [5:0] g,
    output reg   [5:0] b
);

    // Two 8x16 characters centered at (512, 384) on 1024x768:
    //   x in [504, 520), y in [376, 392)
    localparam [10:0] HEX_X = 11'd504;
    localparam  [9:0] HEX_Y = 10'd376;

    // ---- Stage 1: address computation ----

    wire in_area = visible
                && (pixel_x >= HEX_X) && (pixel_x < HEX_X + 11'd16)
                && (pixel_y >= HEX_Y) && (pixel_y < HEX_Y + 10'd16);

    // Offset within the 16x16 bounding box.
    // HEX_X[3:0] == HEX_Y[3:0] == 4'h8, so 4-bit subtraction wraps
    // correctly for both character columns (x in [504,512) and [512,520)).
    // in_area guards the output so values outside the box don't matter.
    wire [3:0] rel_x = pixel_x[3:0] - HEX_X[3:0];
    wire [3:0] rel_y = pixel_y[3:0] - HEX_Y[3:0];

    wire        which  = rel_x[3];      // 0 = left char (high nibble), 1 = right (low nibble)
    wire [2:0]  col    = rel_x[2:0];   // column within character (0 = leftmost)
    wire [3:0]  row    = rel_y;        // row within character (0..15)

    wire [3:0] nibble = which ? byte_in[3:0] : byte_in[7:4];

    // '0'-'9' = 0x30-0x39;  'A'-'F' = nibble + 0x37 (since 10+0x37 = 0x41 = 'A')
    wire [7:0] ascii = (nibble < 4'd10) ? (8'h30 + {4'h0, nibble})
                                        : (8'h37 + {4'h0, nibble});

    wire [10:0] rom_addr = {ascii[6:0], row};

    // 2 delay stages for metadata — ROM registers both address and output
    // (outdata_reg_a = CLOCK0), so it has 2 cycles of latency total.
    reg        in_area_d1, in_area_d2;
    reg [2:0]  col_d1,     col_d2;

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

    // rom_data and _d2 metadata are now aligned — same pattern as text_renderer.v
    wire pixel_on = in_area_d2 && rom_data[3'd7 - col_d2];

    always @(posedge pixel_clk) begin
        r <= pixel_on ? 6'h3F : 6'h00;
        g <= pixel_on ? 6'h3F : 6'h00;
        b <= pixel_on ? 6'h3F : 6'h00;
    end

endmodule
