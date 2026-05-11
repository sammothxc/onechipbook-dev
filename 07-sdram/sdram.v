// 07-sdram Stage B: interactive SDRAM command interpreter.
//
// Type commands on the PS/2 keyboard, see results on the LCD:
//   w XXXXXXX DDDD<Enter>  — write 16-bit DDDD to byte-address XXXXXXX
//   r XXXXXXX<Enter>       — read from byte-address XXXXXXX, see RD=XXXX
//
// Address is 7 hex digits (28 bits; low 25 used as the byte address into
// the 32 MB chip).  Data is exactly 4 hex digits.  Any other input
// produces "ERR" after Enter.
//
// Clock domains:
//   pixel_clk (~64.43 MHz) — PS/2, parser, text buffer, video
//   clk_21m   (21.47727 MHz) — SDRAM controller and pins
// CDC is handled inside sdram_if.v via toggle handshakes.
module sdram (
    input  wire        clk_21m,
    input  wire        rst_n_in,

    // PS/2 keyboard
    input  wire        ps2_clk,
    input  wire        ps2_dat,

    // VGA display
    output wire        vga_hsync,
    output wire        vga_vsync,
    output wire  [5:0] vga_r,
    output wire  [5:0] vga_g,
    output wire  [5:0] vga_b,

    // SDRAM
    output wire        sdram_clk,
    output wire        sdram_cke,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire  [1:0] sdram_ba,
    output wire [12:0] sdram_a,
    output wire  [1:0] sdram_dqm,
    inout  wire [15:0] sdram_dq,

    output reg   [8:1] led
);

    // ----------------------------------------------------------------
    //  PLL: 21.47727 MHz -> ~64.43 MHz pixel clock
    // ----------------------------------------------------------------
    wire pixel_clk;
    wire pll_locked;

    vga65mhz_pll pll_inst (
        .inclk0 (clk_21m),
        .c0     (pixel_clk),
        .locked (pll_locked)
    );

    wire prst_n = rst_n_in & pll_locked;

    // SDRAM clock is the 21 MHz system clock, forwarded straight to the chip.
    assign sdram_clk = clk_21m;

    // ----------------------------------------------------------------
    //  PS/2 keyboard
    // ----------------------------------------------------------------
    wire [7:0] ps2_raw;
    wire       ps2_raw_valid;

    ps2_rx ps2_inst (
        .clk          (pixel_clk),
        .rst_n        (prst_n),
        .ps2_clk_raw  (ps2_clk),
        .ps2_data_raw (ps2_dat),
        .data         (ps2_raw),
        .data_valid   (ps2_raw_valid)
    );

    wire [7:0] ascii;
    wire       ascii_valid;

    sc_parser parser_inst (
        .clk         (pixel_clk),
        .rst_n       (prst_n),
        .rx_data     (ps2_raw),
        .rx_valid    (ps2_raw_valid),
        .ascii       (ascii),
        .ascii_valid (ascii_valid)
    );

    // ----------------------------------------------------------------
    //  Command interpreter
    // ----------------------------------------------------------------
    wire [7:0] term_ascii;
    wire       term_ascii_valid;

    wire        sdram_req;
    wire        sdram_we_w;
    wire [24:0] sdram_addr;
    wire [15:0] sdram_wr_data;
    wire  [1:0] sdram_wr_mask;
    wire [15:0] sdram_rd_data;
    wire        sdram_done;

    cmd_interp interp_inst (
        .clk            (pixel_clk),
        .rst_n          (prst_n),
        .ascii_in       (ascii),
        .ascii_in_valid (ascii_valid),
        .ascii_out      (term_ascii),
        .ascii_out_valid(term_ascii_valid),
        .sdram_req      (sdram_req),
        .sdram_we       (sdram_we_w),
        .sdram_addr     (sdram_addr),
        .sdram_wr_data  (sdram_wr_data),
        .sdram_wr_mask  (sdram_wr_mask),
        .sdram_rd_data  (sdram_rd_data),
        .sdram_done     (sdram_done)
    );

    // ----------------------------------------------------------------
    //  SDRAM bridge (pixel_clk <-> clk_21m, includes sdram_ctrl)
    // ----------------------------------------------------------------
    sdram_if bridge_inst (
        .pclk        (pixel_clk),
        .prst_n      (prst_n),
        .req         (sdram_req),
        .we          (sdram_we_w),
        .addr        (sdram_addr),
        .wr_data     (sdram_wr_data),
        .wr_mask     (sdram_wr_mask),
        .rd_data     (sdram_rd_data),
        .done        (sdram_done),
        .sclk        (clk_21m),
        .srst_n      (rst_n_in),
        .sdram_cke   (sdram_cke),
        .sdram_cs_n  (sdram_cs_n),
        .sdram_ras_n (sdram_ras_n),
        .sdram_cas_n (sdram_cas_n),
        .sdram_we_n  (sdram_we_n),
        .sdram_ba    (sdram_ba),
        .sdram_a     (sdram_a),
        .sdram_dqm   (sdram_dqm),
        .sdram_dq    (sdram_dq)
    );

    // ----------------------------------------------------------------
    //  Text buffer cursor controller — copied from 03-keyboard/06-uart
    //  The interpreter's ascii_out stream contains both echoed keystrokes
    //  and the auto-typed replies; both go through the same cursor logic.
    // ----------------------------------------------------------------
    reg  [6:0] cursor_col;
    reg  [5:0] cursor_row;
    reg [12:0] wr_addr;
    reg  [7:0] wr_data;
    reg        wr_en;

    always @(posedge pixel_clk or negedge prst_n) begin
        if (!prst_n) begin
            cursor_col <= 7'd0;
            cursor_row <= 6'd0;
            wr_addr    <= 13'd0;
            wr_data    <= 8'h20;
            wr_en      <= 1'b0;
        end else begin
            wr_en <= 1'b0;

            if (term_ascii_valid) begin
                if (term_ascii == 8'h0D) begin
                    cursor_col <= 7'd0;
                    if (cursor_row < 6'd47)
                        cursor_row <= cursor_row + 1'b1;
                end else if (term_ascii == 8'h08) begin
                    if (cursor_col > 7'd0) begin
                        cursor_col <= cursor_col - 1'b1;
                        wr_addr    <= {cursor_row, cursor_col - 1'b1};
                        wr_data    <= 8'h20;
                        wr_en      <= 1'b1;
                    end
                end else begin
                    wr_addr <= {cursor_row, cursor_col};
                    wr_data <= term_ascii;
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

    // ----------------------------------------------------------------
    //  Text buffer
    // ----------------------------------------------------------------
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

    // ----------------------------------------------------------------
    //  VGA timing + terminal renderer
    // ----------------------------------------------------------------
    wire        visible;
    wire [10:0] pixel_x;
    wire  [9:0] pixel_y;

    timing timing_inst (
        .pixel_clk (pixel_clk),
        .rst_n     (prst_n),
        .hsync     (vga_hsync),
        .vsync     (vga_vsync),
        .visible   (visible),
        .pixel_x   (pixel_x),
        .pixel_y   (pixel_y)
    );

    terminal term_inst (
        .pixel_clk  (pixel_clk),
        .pixel_x    (pixel_x),
        .pixel_y    (pixel_y),
        .visible    (visible),
        .rd_addr    (rd_addr),
        .rd_data    (rd_data),
        .cursor_col (cursor_col),
        .cursor_row (cursor_row),
        .r          (vga_r),
        .g          (vga_g),
        .b          (vga_b)
    );

    // ----------------------------------------------------------------
    //  Heartbeat LED so you can tell the FPGA is alive even before any
    //  display sync.  LED1 toggles ~once per 0.5s.
    // ----------------------------------------------------------------
    reg [23:0] hb_cnt;

    always @(posedge clk_21m or negedge rst_n_in) begin
        if (!rst_n_in) begin
            hb_cnt <= 24'd0;
            led    <= 8'd0;
        end else begin
            hb_cnt <= hb_cnt + 1'b1;
            led[1] <= hb_cnt[23];
            // led[8:2] reserved for future debug
            led[8:2] <= 7'd0;
        end
    end

endmodule
