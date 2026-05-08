module keyboard (
    input  wire       clk_21m,
    input  wire       rst_n_in,
    input  wire       ps2_clk,
    input  wire       ps2_data,
    output wire       hsync,
    output wire       vsync,
    output wire [5:0] r,
    output wire [5:0] g,
    output wire [5:0] b,
    output reg  [7:0] led
);

    // PLL: 21.47727 MHz -> 64.43 MHz pixel clock for 1024x768 XGA
    wire pixel_clk;
    wire pll_locked;

    vga65mhz_pll pll_inst (
        .inclk0 (clk_21m),
        .c0     (pixel_clk),
        .locked (pll_locked)
    );

    wire rst_n = rst_n_in & pll_locked;

    // PS/2 byte receiver
    wire [7:0] rx_data;
    wire       rx_valid;

    ps2_rx rx_inst (
        .clk          (pixel_clk),
        .rst_n        (rst_n),
        .ps2_clk_raw  (ps2_clk),
        .ps2_data_raw (ps2_data),
        .data         (rx_data),
        .data_valid   (rx_valid)
    );

    // Raw scan code on LEDs for debugging
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) led <= 8'h00;
        else if (rx_valid) led <= rx_data;
    end

    // Scan code parser: strips E0/F0 prefixes, tracks shift, emits ASCII
    wire [7:0] ascii;
    wire       ascii_valid;

    sc_parser parser_inst (
        .clk        (pixel_clk),
        .rst_n      (rst_n),
        .rx_data    (rx_data),
        .rx_valid   (rx_valid),
        .ascii      (ascii),
        .ascii_valid(ascii_valid)
    );

    // ---- Text buffer write port + cursor controller ----

    reg  [6:0] cursor_col;
    reg  [5:0] cursor_row;
    reg [12:0] wr_addr;
    reg  [7:0] wr_data;
    reg        wr_en;

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            cursor_col <= 7'd0;
            cursor_row <= 6'd0;
            wr_addr    <= 13'd0;
            wr_data    <= 8'h20;
            wr_en      <= 1'b0;
        end else begin
            wr_en <= 1'b0;

            if (ascii_valid) begin
                if (ascii == 8'h0D) begin
                    // Enter: go to start of next line
                    cursor_col <= 7'd0;
                    if (cursor_row < 6'd47)
                        cursor_row <= cursor_row + 1'b1;
                end else if (ascii == 8'h08) begin
                    // Backspace: erase previous character
                    if (cursor_col > 7'd0) begin
                        cursor_col <= cursor_col - 1'b1;
                        wr_addr    <= {cursor_row, cursor_col - 1'b1};
                        wr_data    <= 8'h20;
                        wr_en      <= 1'b1;
                    end
                end else begin
                    // Printable: write char and advance cursor
                    wr_addr <= {cursor_row, cursor_col};
                    wr_data <= ascii;
                    wr_en   <= 1'b1;
                    if (cursor_col == 7'd127) begin
                        cursor_col <= 7'd0;
                        if (cursor_row < 6'd47)
                            cursor_row <= cursor_row + 1'b1;
                    end else begin
                        cursor_col <= cursor_col + 1'b1;
                    end
                end
            end
        end
    end

    // ---- Text buffer (dual-port RAM) ----

    wire [12:0] rd_addr;
    wire  [7:0] rd_data;

    text_buf buf_inst (
        .clk     (pixel_clk),
        .rd_addr (rd_addr),
        .rd_data (rd_data),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .wr_en   (wr_en)
    );

    // ---- VGA timing (1024x768 XGA) ----

    wire        visible;
    wire [10:0] pixel_x;
    wire  [9:0] pixel_y;

    timing timing_inst (
        .pixel_clk (pixel_clk),
        .rst_n     (rst_n),
        .hsync     (hsync),
        .vsync     (vsync),
        .visible   (visible),
        .pixel_x   (pixel_x),
        .pixel_y   (pixel_y)
    );

    // ---- Terminal renderer ----

    terminal term_inst (
        .pixel_clk  (pixel_clk),
        .pixel_x    (pixel_x),
        .pixel_y    (pixel_y),
        .visible    (visible),
        .rd_addr    (rd_addr),
        .rd_data    (rd_data),
        .cursor_col (cursor_col),
        .cursor_row (cursor_row),
        .r          (r),
        .g          (g),
        .b          (b)
    );

endmodule
