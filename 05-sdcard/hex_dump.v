// Hex-dump renderer: shows a 512-byte block as 16 rows × 32 bytes each, with
// a 4-character row-offset prefix on the left ("000:", "020:", … "1E0:").
//
// Layout (8×16 font):
//   per row: 4 prefix chars + 64 hex chars = 68 chars = 544 px wide
//   16 rows × 16 px = 256 px tall
//   Centered on 1024×768 → top-left at (240, 256), occupies x∈[240,784), y∈[256,512).
//
// Pipeline mirrors terminal.v (4-cycle through char_rom + 1-cycle BRAM):
//   Cycle 0: position decode; present rd_addr to block buffer
//   Cycle 1: rd_data (raw byte) valid; pick high/low nibble; emit ASCII;
//            present char_rom address
//   Cycle 2: char_rom internal address register captures
//   Cycle 3: char_rom data register captures; pixel_on combinational
//   Cycle 4: r/g/b output register
//
// col, in_area need 3 pipeline stages (_d1/_d2/_d3) to align with rom_data.
// is_high_nib, in_offset, char_y, offset_ascii only need _d1 (consumed at cycle 1).
module hex_dump (
    input  wire        pixel_clk,
    input  wire [10:0] pixel_x,
    input  wire  [9:0] pixel_y,
    input  wire        visible,

    // Block-buffer read port (1-cycle latency)
    output wire  [8:0] rd_addr,
    input  wire  [7:0] rd_data,

    output reg   [5:0] r,
    output reg   [5:0] g,
    output reg   [5:0] b
);

    localparam [10:0] DISP_X = 11'd240;
    localparam  [9:0] DISP_Y = 10'd256;
    localparam [10:0] DISP_W = 11'd544;   // 68 chars × 8 px
    localparam  [9:0] DISP_H = 10'd256;   // 16 rows × 16 px

    // ---- Stage 0: position decode ----
    wire in_area = visible
                && (pixel_x >= DISP_X) && (pixel_x < DISP_X + DISP_W)
                && (pixel_y >= DISP_Y) && (pixel_y < DISP_Y + DISP_H);

    // DISP_X[2:0]==0 and DISP_Y[3:0]==0 — bottom bits already aligned.
    wire [10:0] rel_x = pixel_x - DISP_X;
    wire  [9:0] rel_y = pixel_y - DISP_Y;

    wire [6:0]  char_idx = rel_x[9:3];   // 0..67 across the row
    wire [2:0]  col      = rel_x[2:0];   // 0..7 within an 8-px char
    wire [3:0]  text_row = rel_y[7:4];   // 0..15 byte row
    wire [3:0]  char_y   = rel_y[3:0];   // 0..15 within an 8×16 glyph

    wire        in_offset   = (char_idx < 7'd4);
    wire [6:0]  hex_idx     = char_idx - 7'd4;   // valid when !in_offset
    wire [4:0]  byte_col    = hex_idx[5:1];      // 0..31 byte index in row
    wire        is_high_nib = ~hex_idx[0];       // even hex slot = high nibble

    assign rd_addr = {text_row, byte_col};       // 9 bits → 0..511

    // Row-offset prefix is 3 hex digits + ':'. Row addresses run 0x000, 0x020,
    // 0x040, … 0x1E0 — so digit0 is always '0', digit2 ∈ {'0','1'}, and digit1
    // is one of the 8 even nibbles {0,2,4,6,8,A,C,E}.
    reg [7:0] offset_ascii;
    always @* begin
        case (char_idx[1:0])
            2'd0: offset_ascii = text_row[3] ? "1" : "0";
            2'd1: begin
                case (text_row[2:0])
                    3'd0:    offset_ascii = "0";
                    3'd1:    offset_ascii = "2";
                    3'd2:    offset_ascii = "4";
                    3'd3:    offset_ascii = "6";
                    3'd4:    offset_ascii = "8";
                    3'd5:    offset_ascii = "A";
                    3'd6:    offset_ascii = "C";
                    default: offset_ascii = "E";
                endcase
            end
            2'd2:    offset_ascii = "0";
            default: offset_ascii = ":";
        endcase
    end

    // ---- _d1 registers ----
    reg       in_area_d1;
    reg       in_offset_d1;
    reg       is_high_nib_d1;
    reg [3:0] char_y_d1;
    reg [2:0] col_d1;
    reg [7:0] offset_ascii_d1;

    always @(posedge pixel_clk) begin
        in_area_d1      <= in_area;
        in_offset_d1    <= in_offset;
        is_high_nib_d1  <= is_high_nib;
        char_y_d1       <= char_y;
        col_d1          <= col;
        offset_ascii_d1 <= offset_ascii;
    end

    // ---- Cycle 1: rd_data is valid; pick nibble and form ASCII ----
    wire [3:0] hex_nib   = is_high_nib_d1 ? rd_data[7:4] : rd_data[3:0];
    wire [7:0] hex_ascii = (hex_nib < 4'd10)
                         ? (8'h30 + {4'b0, hex_nib})       // '0'..'9'
                         : (8'h37 + {4'b0, hex_nib});      // 'A'..'F'  (0x41 - 10 = 0x37)

    wire [7:0]  ascii    = in_offset_d1 ? offset_ascii_d1 : hex_ascii;
    wire [10:0] rom_addr = {ascii[6:0], char_y_d1};

    // ---- _d2 registers ----
    reg       in_area_d2;
    reg [2:0] col_d2;

    always @(posedge pixel_clk) begin
        in_area_d2 <= in_area_d1;
        col_d2     <= col_d1;
    end

    wire [7:0] rom_data;
    char_rom rom_inst (
        .address (rom_addr),
        .clock   (pixel_clk),
        .q       (rom_data)
    );

    // ---- _d3 registers ----
    reg       in_area_d3;
    reg [2:0] col_d3;

    always @(posedge pixel_clk) begin
        in_area_d3 <= in_area_d2;
        col_d3     <= col_d2;
    end

    wire pixel_on = in_area_d3 && rom_data[3'd7 - col_d3];

    always @(posedge pixel_clk) begin
        r <= pixel_on ? 6'h3F : 6'h00;
        g <= pixel_on ? 6'h3F : 6'h00;
        b <= pixel_on ? 6'h3F : 6'h00;
    end

endmodule
