module text_renderer (
    input  wire        pixel_clk,
    input  wire [10:0] pixel_x,
    input  wire  [9:0] pixel_y,
    input  wire        visible,
    output reg   [5:0] r,
    output reg   [5:0] g,
    output reg   [5:0] b
);

    // ------------------------------------------------------------------
    // Stage 1: figure out character cell and position within character
    // ------------------------------------------------------------------
    
    wire  [6:0] char_col      = pixel_x[9:3];   // 0..99 (column)
    wire  [2:0] pixel_in_col  = pixel_x[2:0];   // 0..7  (within char)
    wire  [5:0] char_row      = pixel_y[9:4];   // 0..36 (row)
    wire  [3:0] pixel_in_row  = pixel_y[3:0];   // 0..15 (within char)
    
    // ------------------------------------------------------------------
    // Stage 2: figure out the message position and which character
    //          of "Hello, World!" we're looking at (if any)
    // ------------------------------------------------------------------
    
    // VGA
    localparam MSG_ROW = 6'd15;
    localparam MSG_COL = 7'd33;

    // SVGA
    // localparam MSG_ROW = 6'd18;
    // localparam MSG_COL = 7'd41;

    // XGA
    // localparam MSG_ROW = 6'd24;
    // localparam MSG_COL = 7'd57;

    localparam MSG_LEN   = 13;
    
    wire in_message_row = (char_row == MSG_ROW);
    wire in_message_col = (char_col >= MSG_COL) && (char_col < MSG_COL + MSG_LEN);
    wire in_message     = in_message_row && in_message_col;
    
    wire [7:0] msg_index = char_col - MSG_COL;  // 0..12 within message
    
    // The string "Hello, World!" as a lookup
    reg [7:0] current_char;
    always @(*) begin
        case (msg_index)
            7'd0:  current_char = 8'h48;  // 'H'
            7'd1:  current_char = 8'h65;  // 'e'
            7'd2:  current_char = 8'h6C;  // 'l'
            7'd3:  current_char = 8'h6C;  // 'l'
            7'd4:  current_char = 8'h6F;  // 'o'
            7'd5:  current_char = 8'h2C;  // ','
            7'd6:  current_char = 8'h20;  // ' '
            7'd7:  current_char = 8'h57;  // 'W'
            7'd8:  current_char = 8'h6F;  // 'o'
            7'd9:  current_char = 8'h72;  // 'r'
            7'd10: current_char = 8'h6C;  // 'l'
            7'd11: current_char = 8'h64;  // 'd'
            7'd12: current_char = 8'h21;  // '!'
            default: current_char = 8'h20;  // space
        endcase
    end
    
    // ------------------------------------------------------------------
    // Stage 3: read the character ROM
    // ------------------------------------------------------------------
    
    // Address: {ascii[6:0], pixel_in_row[3:0]} = 11 bits, 2048 bytes
    wire [10:0] char_rom_addr = {current_char[6:0], pixel_in_row};
    wire  [7:0] char_rom_data;
    
    char_rom char_rom_inst (
        .address (char_rom_addr),
        .clock   (pixel_clk),
        .q       (char_rom_data)
    );
    
    // ------------------------------------------------------------------
    // Stage 4: pixel selection (with 2-cycle pipeline matching)
    // ------------------------------------------------------------------
    
    // Total pipeline delay from pixel_x to r/g/b is 2 cycles:
    //   1 cycle for char_rom read
    //   1 cycle for the output register
    // So we need to delay pixel_in_col, in_message, and visible by 2 cycles.
    
    reg  [2:0] pixel_in_col_d1, pixel_in_col_d2;
    reg        in_message_d1,   in_message_d2;
    reg        visible_d1,      visible_d2;
    
    always @(posedge pixel_clk) begin
        // Stage 1 delay
        pixel_in_col_d1 <= pixel_in_col;
        in_message_d1   <= in_message;
        visible_d1      <= visible;
        // Stage 2 delay
        pixel_in_col_d2 <= pixel_in_col_d1;
        in_message_d2   <= in_message_d1;
        visible_d2      <= visible_d1;
    end
    
    // Bit 7 of char_rom_data is the leftmost pixel in the character row
    wire pixel_on = char_rom_data[7 - pixel_in_col_d2];

    
    // ------------------------------------------------------------------
    // Stage 5: output
    // ------------------------------------------------------------------
    
    always @(posedge pixel_clk) begin
        if (visible_d2 && in_message_d2 && pixel_on) begin
            r <= 6'b111111;
            g <= 6'b111111;
            b <= 6'b111111;
        end else begin
            r <= 6'b000000;
            g <= 6'b000000;
            b <= 6'b000000;
        end
    end

endmodule