// Terminal renderer for 1024x768 display with 128x48 character grid (8x16 font).
//
// 4-cycle pipeline from pixel_x/pixel_y to r/g/b:
//   Cycle 0: compute text_buf rd_addr, font_row, pixel_col, at_cursor (combinational)
//   Cycle 1: text_buf rd_data (ASCII) arrives; compute char_rom address; _d1 regs capture
//   Cycle 2: char_rom address register captures internally; _d2 regs capture
//   Cycle 3: char_rom data register captures; _d3 regs capture; pixel_on computed
//   Cycle 4: r/g/b output register captures
//
// pixel_col, visible, and at_cursor each need 3 delay registers (_d1/_d2/_d3)
// to stay aligned with char_rom_data at the pixel_on stage.
module terminal (
    input  wire        pixel_clk,
    input  wire [10:0] pixel_x,
    input  wire  [9:0] pixel_y,
    input  wire        visible,
    // Text buffer read port (1-cycle latency)
    output wire [12:0] rd_addr,
    input  wire  [7:0] rd_data,
    // Cursor position for block-cursor overlay
    input  wire  [6:0] cursor_col,
    input  wire  [5:0] cursor_row,
    output reg   [5:0] r,
    output reg   [5:0] g,
    output reg   [5:0] b
);

    // ---- Cycle 0: combinational from pixel_x / pixel_y ----

    wire  [6:0] char_col  = pixel_x[9:3];   // 0..127 character column
    wire  [5:0] char_y    = pixel_y[9:4];   // 0..47  character row
    wire  [3:0] font_row  = pixel_y[3:0];   // 0..15  row within character
    wire  [2:0] pixel_col = pixel_x[2:0];   // 0..7   column within character

    assign rd_addr = {char_y, char_col};    // 13-bit address into text_buf

    wire at_cursor = (char_col == cursor_col) && (char_y == cursor_row);

    // ---- _d1 registers (capture cycle-0 values) ----

    reg  [3:0] font_row_d1;
    reg  [2:0] pixel_col_d1;
    reg        visible_d1;
    reg        at_cursor_d1;

    always @(posedge pixel_clk) begin
        font_row_d1  <= font_row;
        pixel_col_d1 <= pixel_col;
        visible_d1   <= visible;
        at_cursor_d1 <= at_cursor;
    end

    // ---- Cycle 1: rd_data (ASCII) now valid; present char_rom address ----

    // rd_data and font_row_d1 are both from cycle 0 — aligned.
    wire [10:0] char_rom_addr = {rd_data[6:0], font_row_d1};

    // ---- _d2 registers ----

    reg  [2:0] pixel_col_d2;
    reg        visible_d2;
    reg        at_cursor_d2;

    always @(posedge pixel_clk) begin
        pixel_col_d2 <= pixel_col_d1;
        visible_d2   <= visible_d1;
        at_cursor_d2 <= at_cursor_d1;
    end

    // ---- Cycles 2-3: char_rom reads (2-cycle latency: address reg + data reg) ----

    wire [7:0] char_rom_data;

    char_rom crom_inst (
        .address (char_rom_addr),
        .clock   (pixel_clk),
        .q       (char_rom_data)
    );

    // ---- _d3 registers (align with char_rom_data) ----

    reg  [2:0] pixel_col_d3;
    reg        visible_d3;
    reg        at_cursor_d3;

    always @(posedge pixel_clk) begin
        pixel_col_d3 <= pixel_col_d2;
        visible_d3   <= visible_d2;
        at_cursor_d3 <= at_cursor_d2;
    end

    // ---- Cycle 3: pixel_on (combinational) ----
    // Block cursor: at_cursor overrides and lights the full cell white.
    // Font bit 7 is the leftmost pixel (pixel_col 0).

    wire pixel_on = visible_d3 && (at_cursor_d3 | char_rom_data[3'd7 - pixel_col_d3]);

    // ---- Cycle 4: registered RGB output ----

    always @(posedge pixel_clk) begin
        r <= pixel_on ? 6'h3F : 6'h00;
        g <= pixel_on ? 6'h3F : 6'h00;
        b <= pixel_on ? 6'h3F : 6'h00;
    end

endmodule
