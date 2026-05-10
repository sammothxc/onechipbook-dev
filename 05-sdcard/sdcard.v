// 05-sdcard Stage B: SD-card SPI init + CMD17 read of sector 0, displayed
// as a 512-byte hex dump on the 1024×768 LCD.
//
// On reset the FSM walks the standard SD SPI init handshake (CMD0 → CMD8 →
// CMD55+ACMD41 → optional CMD58), switches the SPI clock from ~336 kHz to
// ~5.4 MHz, then issues CMD17 for sector 0. The 512 bytes land in a dual-
// port BRAM whose read port is on the pixel clock; hex_dump renders it.
//
// LED behaviour:
//   ready (after successful read) → 0b10101010 walking pattern
//   error                          → err_dbg latched (state nibble + reason)
//   otherwise                      → top nibble = current FSM state, bottom = 0
module sdcard (
    input  wire       clk_21m,
    input  wire       rst_n_in,

    // Video out — VGA-style sync + 6-bit RGB to LCD scaler
    output wire       hsync,
    output wire       vsync,
    output wire [5:0] r,
    output wire [5:0] g,
    output wire [5:0] b,

    // SD card SPI
    output wire       sd_clk,
    output wire       sd_cs_n,
    output wire       sd_mosi,
    input  wire       sd_miso,

    // Debug LEDs
    output reg  [7:0] led
);

    // ====================================================================
    //  Clocks / reset
    // ====================================================================
    wire pixel_clk;
    wire pll_locked;

    vga65mhz_pll pll_inst (
        .inclk0 (clk_21m),
        .c0     (pixel_clk),
        .locked (pll_locked)
    );

    wire video_rst_n = rst_n_in & pll_locked;

    // ====================================================================
    //  SD controller (clk_21m domain)
    // ====================================================================
    wire [8:0] sd_buf_addr;
    wire [7:0] sd_buf_data;
    wire       sd_buf_we;
    wire [3:0] sd_state;
    wire [7:0] sd_err;
    wire       sd_ready;

    sd_ctrl sd_inst (
        .clk       (clk_21m),
        .rst_n     (rst_n_in),
        .sd_cs_n   (sd_cs_n),
        .sd_clk    (sd_clk),
        .sd_mosi   (sd_mosi),
        .sd_miso   (sd_miso),
        .buf_addr  (sd_buf_addr),
        .buf_data  (sd_buf_data),
        .buf_we    (sd_buf_we),
        .state_dbg (sd_state),
        .err_dbg   (sd_err),
        .ready     (sd_ready)
    );

    // ====================================================================
    //  512×8 dual-port dual-clock BRAM
    //  Write port: clk_21m (sd_ctrl). Read port: pixel_clk (hex_dump).
    //  Quartus infers a single M4K from this pattern.
    // ====================================================================
    reg [7:0] block_mem [0:511];
    reg [7:0] block_rd_data;
    wire [8:0] block_rd_addr;

    always @(posedge clk_21m) begin
        if (sd_buf_we) block_mem[sd_buf_addr] <= sd_buf_data;
    end

    always @(posedge pixel_clk) begin
        block_rd_data <= block_mem[block_rd_addr];
    end

    // ====================================================================
    //  Video timing + hex-dump renderer (pixel_clk domain)
    // ====================================================================
    wire        visible;
    wire [10:0] pixel_x;
    wire  [9:0] pixel_y;

    timing timing_inst (
        .pixel_clk (pixel_clk),
        .rst_n     (video_rst_n),
        .hsync     (hsync),
        .vsync     (vsync),
        .visible   (visible),
        .pixel_x   (pixel_x),
        .pixel_y   (pixel_y)
    );

    hex_dump dump_inst (
        .pixel_clk (pixel_clk),
        .pixel_x   (pixel_x),
        .pixel_y   (pixel_y),
        .visible   (visible),
        .rd_addr   (block_rd_addr),
        .rd_data   (block_rd_data),
        .r         (r),
        .g         (g),
        .b         (b)
    );

    // ====================================================================
    //  Debug LEDs
    // ====================================================================
    // Slow walking-bit when ready, raw err_dbg on error, state in top nibble
    // otherwise. The walking bit lets us tell "ready" apart from a frozen FSM.
    reg [23:0] hb_cnt;
    always @(posedge clk_21m or negedge rst_n_in) begin
        if (!rst_n_in) hb_cnt <= 24'd0;
        else           hb_cnt <= hb_cnt + 24'd1;
    end

    always @* begin
        if (sd_state == 4'hF) begin
            led = sd_err;
        end else if (sd_ready) begin
            led = hb_cnt[23] ? 8'b10101010 : 8'b01010101;
        end else begin
            led = {sd_state, 4'h0};
        end
    end

endmodule
