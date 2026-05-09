// 04-audio Stage A: fixed 440 Hz square wave on both DAC channels.
// FTW for 440 Hz at 21.47727 MHz: round(440 * 2^32 / 21477270) = 87990.
module audio (
    input  wire       clk_21m,
    input  wire       rst_n_in,
    input  wire       dip0,        // audio enable — high to enable
    output wire [5:0] sl,
    output wire [5:0] sr,
    output reg        led
);
    localparam [31:0] FTW_440 = 32'd87990;
    localparam [5:0]  MID     = 6'h20;  // mid-rail = silent DC

    // Synchronize DIP0 (async, slow) into the audio clock domain.
    reg dip0_s1, dip0_en;
    always @(posedge clk_21m or negedge rst_n_in) begin
        if (!rst_n_in) {dip0_en, dip0_s1} <= 2'b00;
        else           {dip0_en, dip0_s1} <= {dip0_s1, dip0};
    end

    wire [5:0] sample;

    tone_gen tone_inst (
        .clk    (clk_21m),
        .rst_n  (rst_n_in),
        .ftw    (FTW_440),
        .sample (sample)
    );

    wire [5:0] out_sample = dip0_en ? sample : MID;

    assign sl = out_sample;
    assign sr = out_sample;

    // Heartbeat LED: toggles at ~1 Hz so we know the FPGA is alive.
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

endmodule
