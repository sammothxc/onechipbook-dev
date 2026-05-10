// 05-sdcard Stage D: SD-card SPI init + multi-sector boot load.
//
// On reset: walks SD SPI init (CMD0→CMD8→CMD55+ACMD41→CMD58), then issues
// CMD17 × BOOT_SECTORS (32) to fill a 16 KB dual-port BRAM. Once done,
// hex_dump renders the BRAM as a 512-byte hex grid; DIP3–DIP7 (page_sel)
// choose which of the 32 sectors to view on screen.
//
// LED behaviour:
//   loading        → top nibble = current FSM state, bottom = sector_idx[3:0]
//   ready          → 0xAA / 0x55 alternating at ~2.5 Hz
//   error          → err_dbg byte (state nibble | reason nibble)
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

    // DIP3–DIP7 → page_sel[4:0]: which sector (0–31) to display
    input  wire [4:0] page_sel_in,

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
    wire [13:0] sd_buf_addr;
    wire  [7:0] sd_buf_data;
    wire        sd_buf_we;
    wire  [3:0] sd_state;
    wire  [7:0] sd_err;
    wire        sd_ready;

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
    //  16 KB dual-port dual-clock BRAM  (32 sectors × 512 B × 8 bit)
    //  Write port: clk_21m (sd_ctrl fills during boot).
    //  Read port:  pixel_clk (hex_dump reads continuously).
    //  Quartus infers M4K blocks from this two-always-block pattern.
    // ====================================================================
    reg  [7:0] block_mem [0:16383];
    reg  [7:0] block_rd_data;
    wire [13:0] block_rd_addr;

    always @(posedge clk_21m) begin
        if (sd_buf_we) block_mem[sd_buf_addr] <= sd_buf_data;
    end

    always @(posedge pixel_clk) begin
        block_rd_data <= block_mem[block_rd_addr];
    end

    // ====================================================================
    //  page_sel synchronizer (pixel_clk domain)
    //  DIP switches are async; 2-flop sync prevents metastability.
    // ====================================================================
    reg [4:0] page_s1, page_sel;
    always @(posedge pixel_clk) begin
        page_s1  <= page_sel_in;
        page_sel <= page_s1;
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
        .page_sel  (page_sel),
        .rd_addr   (block_rd_addr),
        .rd_data   (block_rd_data),
        .r         (r),
        .g         (g),
        .b         (b)
    );

    // ====================================================================
    //  Debug LEDs
    // ====================================================================
    reg [23:0] hb_cnt;
    always @(posedge clk_21m or negedge rst_n_in) begin
        if (!rst_n_in) hb_cnt <= 24'd0;
        else           hb_cnt <= hb_cnt + 24'd1;
    end

    // During load, top nibble = FSM state, bottom = sector index so you can
    // watch it count from 0x00 to 0x1F as sectors are loaded.
    // On error: raw err_dbg byte.  On done: alternating walking pattern.
    wire [4:0] sector_idx_dbg;
    assign sector_idx_dbg = sd_buf_addr[13:9];  // top 5 bits of buf_addr = sector

    always @* begin
        if (sd_state == 4'hF) begin
            led = sd_err;
        end else if (sd_ready) begin
            led = hb_cnt[23] ? 8'b10101010 : 8'b01010101;
        end else begin
            // Top nibble = FSM state, bottom nibble = sector being loaded.
            // sector_idx_dbg[4] lights LED3 once past sector 15.
            led = {sd_state[3:0], sector_idx_dbg[3:0]};
        end
    end

endmodule
