// 04-audio Stage C: PS/2 piano + on-screen frequency display.
// Audio path runs at the raw 21.47727 MHz crystal; video path runs at
// 64.43 MHz from a PLL. Display state is latched on key-press in the
// audio domain and read asynchronously by the pixel domain (see SDC for
// false-path constraints).
module audio (
    input  wire       clk_21m,
    input  wire       rst_n_in,
    input  wire       dip0,        // master enable — high to enable
    input  wire       ps2_clk,
    input  wire       ps2_data,
    // Audio out
    output wire [5:0] sl,
    output wire [5:0] sr,
    // Video out
    output wire       hsync,
    output wire       vsync,
    output wire [5:0] r,
    output wire [5:0] g,
    output wire [5:0] b,
    // Debug
    output reg        led          // heartbeat
);
    localparam [5:0] MID = 6'h20;

    // ====================================================================
    //  Clocks
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
    //  Audio domain (clk_21m)
    // ====================================================================

    // ---- Synchronize DIP0 ----
    reg dip0_s1, dip0_en;
    always @(posedge clk_21m or negedge rst_n_in) begin
        if (!rst_n_in) {dip0_en, dip0_s1} <= 2'b00;
        else           {dip0_en, dip0_s1} <= {dip0_s1, dip0};
    end

    // ---- PS/2 byte receiver ----
    wire [7:0] rx_data;
    wire       rx_valid;
    ps2_rx rx_inst (
        .clk          (clk_21m),
        .rst_n        (rst_n_in),
        .ps2_clk_raw  (ps2_clk),
        .ps2_data_raw (ps2_data),
        .data         (rx_data),
        .data_valid   (rx_valid)
    );

    // ---- Key decoder: emits {scan_code, is_release, valid} ----
    wire [7:0] kd_scan_code;
    wire       kd_is_release;
    wire       kd_valid;
    key_decoder kd_inst (
        .clk        (clk_21m),
        .rst_n      (rst_n_in),
        .rx_data    (rx_data),
        .rx_valid   (rx_valid),
        .scan_code  (kd_scan_code),
        .is_release (kd_is_release),
        .valid      (kd_valid)
    );

    // ---- Lookup: scan_code -> tone + display fields ----
    wire  [1:0] kn_wave_sel;
    wire [31:0] kn_ftw;
    wire  [7:0] kn_note_letter;
    wire  [7:0] kn_note_octave;
    wire  [3:0] kn_freq_h, kn_freq_t, kn_freq_u;
    wire        kn_recognized;
    key_to_note kn_inst (
        .scan_code   (kd_scan_code),
        .wave_sel    (kn_wave_sel),
        .ftw         (kn_ftw),
        .note_letter (kn_note_letter),
        .note_octave (kn_note_octave),
        .freq_h      (kn_freq_h),
        .freq_t      (kn_freq_t),
        .freq_u      (kn_freq_u),
        .recognized  (kn_recognized)
    );

    // ---- Display state — latched on every recognized key-down. Held until
    // next key-down; release does NOT clear (last-frequency-stays semantic).
    // Independent of voice allocation — display reflects most-recent press.
    reg  [7:0] disp_note_letter;
    reg  [7:0] disp_note_octave;
    reg  [3:0] disp_freq_h, disp_freq_t, disp_freq_u;
    reg  [1:0] disp_wave_sel;

    always @(posedge clk_21m or negedge rst_n_in) begin
        if (!rst_n_in) begin
            disp_note_letter <= " ";
            disp_note_octave <= " ";
            disp_freq_h      <= 4'd0;
            disp_freq_t      <= 4'd0;
            disp_freq_u      <= 4'd0;
            disp_wave_sel    <= 2'b11;   // unmapped -> wave_char defaults to spaces
        end else if (kd_valid && kn_recognized && !kd_is_release) begin
            disp_note_letter <= kn_note_letter;
            disp_note_octave <= kn_note_octave;
            disp_freq_h      <= kn_freq_h;
            disp_freq_t      <= kn_freq_t;
            disp_freq_u      <= kn_freq_u;
            disp_wave_sel    <= kn_wave_sel;
        end
    end

    // ---- 4-voice polyphonic bank ----
    wire signed [9:0] sum_sample;

    voicebank vb_inst (
        .clk          (clk_21m),
        .rst_n        (rst_n_in),
        .ev_valid     (kd_valid && kn_recognized),
        .ev_release   (kd_is_release),
        .ev_scan_code (kd_scan_code),
        .ev_wave_sel  (kn_wave_sel),
        .ev_ftw       (kn_ftw),
        .sum_sample   (sum_sample)
    );

    // ---- Re-bias to mid-rail and saturate to 6-bit DAC range ----
    // sum_sample is signed [9:0]; +MID then clamp to [0, 63].
    wire signed [10:0] biased = {sum_sample[9], sum_sample} + 11'sd32;
    wire [5:0] sample_out = (biased < 11'sd0)  ? 6'd0  :
                            (biased > 11'sd63) ? 6'd63 :
                            biased[5:0];

    // ---- DIP0 master mute ----
    wire [5:0] out_sample = dip0_en ? sample_out : MID;
    assign sl = out_sample;
    assign sr = out_sample;

    // ---- Heartbeat LED ----
    reg [23:0] hb_cnt;
    always @(posedge clk_21m or negedge rst_n_in) begin
        if (!rst_n_in) begin
            hb_cnt <= 24'd0;
            led    <= 1'b0;
        end else begin
            hb_cnt <= hb_cnt + 1'b1;
            led    <= hb_cnt[23];
        end
    end

    // ====================================================================
    //  Video domain (pixel_clk @ 64.43 MHz)
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

    freq_display fd_inst (
        .pixel_clk   (pixel_clk),
        .pixel_x     (pixel_x),
        .pixel_y     (pixel_y),
        .visible     (visible),
        .note_letter (disp_note_letter),
        .note_octave (disp_note_octave),
        .freq_h      (disp_freq_h),
        .freq_t      (disp_freq_t),
        .freq_u      (disp_freq_u),
        .wave_sel    (disp_wave_sel),
        .r           (r),
        .g           (g),
        .b           (b)
    );

endmodule
