// 06-uart Stage C: UART terminal.
//
// PS/2 keyboard keystrokes are sent over UART to the ESP01S echo device
// on pins 237 (TX) and 236 (RX).  Received bytes are displayed on screen.
// Since the ESP01S echoes every byte, typed characters appear on screen
// via the round-trip echo rather than via local echo.
//
// Clock domains:
//   pixel_clk  (~64.43 MHz) — PS/2 keyboard, text buffer, video rendering
//   clk_21m    (21.47727 MHz) — UART TX and RX
//
// CDC: UART RX valid pulses are stretched in the 21m domain to be safely
// captured in the pixel_clk domain via a toggle-based handshake.
module uart (
    input  wire       clk_21m,
    input  wire       rst_n_in,
    // UART to/from ESP01S echoer
    output wire       uart_txd,
    input  wire       uart_rxd,
    // PS/2 keyboard
    input  wire       ps2_clk,
    input  wire       ps2_data,
    // VGA display (1024x768 XGA)
    output wire       hsync,
    output wire       vsync,
    output wire [5:0] r,
    output wire [5:0] g,
    output wire [5:0] b,
    // Debug LEDs: last received byte
    output reg  [7:0] led
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

    wire rst_n = rst_n_in & pll_locked;

    // ----------------------------------------------------------------
    //  UART TX (clk_21m domain)
    // ----------------------------------------------------------------
    reg        tx_start_21m;
    reg  [7:0] tx_data_21m;
    wire       tx_busy;

    uart_tx #(.CLK_HZ(21_477_270), .BAUD(115_200)) tx_inst (
        .clk      (clk_21m),
        .rst_n    (rst_n_in),
        .tx_data  (tx_data_21m),
        .tx_start (tx_start_21m),
        .tx       (uart_txd),
        .tx_busy  (tx_busy)
    );

    // ----------------------------------------------------------------
    //  UART RX (clk_21m domain)
    // ----------------------------------------------------------------
    wire [7:0] rx_byte_21m;
    wire       rx_valid_21m;

    uart_rx #(.CLK_HZ(21_477_270), .BAUD(115_200)) rx_inst (
        .clk        (clk_21m),
        .rst_n      (rst_n_in),
        .rx         (uart_rxd),
        .data       (rx_byte_21m),
        .data_valid (rx_valid_21m)
    );

    // Update debug LEDs in 21m domain on every received byte.
    always @(posedge clk_21m or negedge rst_n_in) begin
        if (!rst_n_in) led <= 8'd0;
        else if (rx_valid_21m) led <= rx_byte_21m;
    end

    // ----------------------------------------------------------------
    //  CDC: UART RX -> pixel_clk domain (toggle handshake)
    //
    //  rx_toggle_21m flips once per received byte in the 21m domain.
    //  Three-flop synchronizer on pixel_clk side detects the edge.
    // ----------------------------------------------------------------
    reg       rx_toggle_21m;
    reg [7:0] rx_latch_21m;   // stable for one full toggle cycle

    always @(posedge clk_21m or negedge rst_n_in) begin
        if (!rst_n_in) begin
            rx_toggle_21m <= 1'b0;
            rx_latch_21m  <= 8'd0;
        end else if (rx_valid_21m) begin
            rx_latch_21m  <= rx_byte_21m;
            rx_toggle_21m <= ~rx_toggle_21m;
        end
    end

    // Three-flop sync + edge detect in pixel_clk domain
    reg [2:0] rx_tog_sync;   // [2]=oldest, [0]=newest

    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) rx_tog_sync <= 3'b000;
        else        rx_tog_sync <= {rx_tog_sync[1:0], rx_toggle_21m};
    end

    wire rx_valid_pclk = rx_tog_sync[2] ^ rx_tog_sync[1];  // edge detect

    // Capture the data latch (multi-cycle path; false-path in SDC).
    // rx_latch_21m is stable well before rx_valid_pclk fires.
    reg [7:0] rx_byte_pclk;
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n)             rx_byte_pclk <= 8'd0;
        else if (rx_valid_pclk) rx_byte_pclk <= rx_latch_21m;
    end

    // ----------------------------------------------------------------
    //  CDC: pixel_clk ASCII -> 21m domain TX
    //
    //  Same toggle scheme in reverse: pixel_clk toggles tx_tog_pclk
    //  when a key is pressed; 21m domain detects the edge and fires TX.
    // ----------------------------------------------------------------
    reg       tx_tog_pclk;
    reg [7:0] tx_latch_pclk;

    // (driven below, after sc_parser)

    reg [2:0] tx_tog_sync;   // synced into clk_21m

    always @(posedge clk_21m or negedge rst_n_in) begin
        if (!rst_n_in) tx_tog_sync <= 3'b000;
        else           tx_tog_sync <= {tx_tog_sync[1:0], tx_tog_pclk};
    end

    wire tx_fire_21m = tx_tog_sync[2] ^ tx_tog_sync[1];

    // tx_latch_pclk was written in pixel_clk at least 3 pixel_clk cycles
    // before tx_fire_21m fires (synchronizer delay), so it is stable here.
    // The false-path SDC entry tells STA not to time this crossing.
    always @(posedge clk_21m or negedge rst_n_in) begin
        if (!rst_n_in) begin
            tx_start_21m <= 1'b0;
            tx_data_21m  <= 8'd0;
        end else begin
            tx_start_21m <= 1'b0;
            if (tx_fire_21m && !tx_busy) begin
                tx_data_21m  <= tx_latch_pclk;   // stable; false-path in SDC
                tx_start_21m <= 1'b1;
            end
        end
    end

    // ----------------------------------------------------------------
    //  PS/2 keyboard (pixel_clk domain)
    // ----------------------------------------------------------------
    wire [7:0] ps2_raw;
    wire       ps2_raw_valid;

    ps2_rx ps2_inst (
        .clk          (pixel_clk),
        .rst_n        (rst_n),
        .ps2_clk_raw  (ps2_clk),
        .ps2_data_raw (ps2_data),
        .data         (ps2_raw),
        .data_valid   (ps2_raw_valid)
    );

    wire [7:0] ascii;
    wire       ascii_valid;

    sc_parser parser_inst (
        .clk         (pixel_clk),
        .rst_n       (rst_n),
        .rx_data     (ps2_raw),
        .rx_valid    (ps2_raw_valid),
        .ascii       (ascii),
        .ascii_valid (ascii_valid)
    );

    // On keystroke: toggle TX handshake so the 21m domain fires the UART.
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_tog_pclk   <= 1'b0;
            tx_latch_pclk <= 8'd0;
        end else if (ascii_valid) begin
            tx_latch_pclk <= ascii;
            tx_tog_pclk   <= ~tx_tog_pclk;
        end
    end

    // ----------------------------------------------------------------
    //  Text buffer write port (pixel_clk domain)
    //
    //  Both received bytes (from ESP01S echo) and control keys (Enter,
    //  Backspace) write into the buffer.  Typed characters appear on
    //  screen only after the echo returns, which is the correct full-
    //  duplex terminal behavior.
    //
    //  Priority: rx_valid_pclk > ascii (Enter/Backspace).
    //  Both arriving in the same cycle is essentially impossible at
    //  human typing speed + 115200 baud round-trip latency.
    // ----------------------------------------------------------------
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

            if (rx_valid_pclk) begin
                // Received byte from ESP01S: display it and advance cursor.
                if (rx_byte_pclk == 8'h0D) begin
                    // CR: move to start of next line
                    cursor_col <= 7'd0;
                    if (cursor_row < 6'd47)
                        cursor_row <= cursor_row + 1'b1;
                end else if (rx_byte_pclk == 8'h0A) begin
                    // LF: treated as newline (advance row, keep col)
                    if (cursor_row < 6'd47)
                        cursor_row <= cursor_row + 1'b1;
                end else if (rx_byte_pclk == 8'h08) begin
                    // BS: erase previous character
                    if (cursor_col > 7'd0) begin
                        cursor_col <= cursor_col - 1'b1;
                        wr_addr    <= {cursor_row, cursor_col - 1'b1};
                        wr_data    <= 8'h20;
                        wr_en      <= 1'b1;
                    end
                end else if (rx_byte_pclk >= 8'h20 && rx_byte_pclk <= 8'h7E) begin
                    // Printable ASCII
                    wr_addr <= {cursor_row, cursor_col};
                    wr_data <= rx_byte_pclk;
                    wr_en   <= 1'b1;
                    if (cursor_col == 7'd127) begin
                        cursor_col <= 7'd0;
                        if (cursor_row < 6'd47)
                            cursor_row <= cursor_row + 1'b1;
                    end else begin
                        cursor_col <= cursor_col + 1'b1;
                    end
                end
            end else if (ascii_valid) begin
                // Local control-only keys (Enter, Backspace) affect the
                // cursor immediately so the user has instant visual response
                // even before the echo returns.  Printable keys do NOT
                // locally echo — they appear when the echo comes back.
                if (ascii == 8'h0D) begin
                    cursor_col <= 7'd0;
                    if (cursor_row < 6'd47)
                        cursor_row <= cursor_row + 1'b1;
                end else if (ascii == 8'h08) begin
                    if (cursor_col > 7'd0) begin
                        cursor_col <= cursor_col - 1'b1;
                        wr_addr    <= {cursor_row, cursor_col - 1'b1};
                        wr_data    <= 8'h20;
                        wr_en      <= 1'b1;
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
    //  VGA timing (1024x768 XGA, pixel_clk)
    // ----------------------------------------------------------------
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

    // ----------------------------------------------------------------
    //  Terminal renderer
    // ----------------------------------------------------------------
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
