// 4-voice polyphonic bank. Each voice is a free-running tone_gen plus a
// slot register holding {active, key_id, ftw, wave_sel}.
//
// Allocation policy on key-down: assign to the lowest-indexed free voice.
// If all 4 voices are busy, the new key is silently dropped.
// On key-up: deactivate any voice whose key_id matches the released key
// (normally exactly one).
//
// Output is the SIGNED sum of the 4 voices' deviations around mid-rail.
// Caller re-biases (add 0x20) and saturates to the 6-bit DAC range.
module voicebank #(
    parameter [2:0] AMP_SHIFT = 3'd3
) (
    input  wire        clk,
    input  wire        rst_n,
    // Key event input (one-cycle pulse on ev_valid)
    input  wire        ev_valid,
    input  wire        ev_release,
    input  wire  [7:0] ev_scan_code,
    input  wire  [1:0] ev_wave_sel,
    input  wire [31:0] ev_ftw,
    // Sum of 4 signed deviations
    output wire signed [9:0] sum_sample
);
    // ---- Voice slot state ----
    reg  [3:0]  v_active;
    reg  [7:0]  v_key  [0:3];
    reg [31:0]  v_ftw  [0:3];
    reg  [1:0]  v_wave [0:3];

    // ---- Allocation: find lowest-index free voice ----
    integer    i;
    reg [1:0]  alloc_idx;
    reg        alloc_valid;

    always @(*) begin
        alloc_valid = 1'b0;
        alloc_idx   = 2'd0;
        // Iterate high-to-low so the lowest free index wins.
        for (i = 3; i >= 0; i = i - 1) begin
            if (!v_active[i]) begin
                alloc_valid = 1'b1;
                alloc_idx   = i[1:0];
            end
        end
    end

    // ---- Slot update ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v_active <= 4'b0;
            for (i = 0; i < 4; i = i + 1) begin
                v_key[i]  <= 8'h00;
                v_ftw[i]  <= 32'd0;
                v_wave[i] <= 2'b00;
            end
        end else if (ev_valid) begin
            if (ev_release) begin
                // Deactivate any voice playing this key.
                for (i = 0; i < 4; i = i + 1) begin
                    if (v_active[i] && (v_key[i] == ev_scan_code))
                        v_active[i] <= 1'b0;
                end
            end else if (alloc_valid) begin
                v_active[alloc_idx] <= 1'b1;
                v_key[alloc_idx]    <= ev_scan_code;
                v_ftw[alloc_idx]    <= ev_ftw;
                v_wave[alloc_idx]   <= ev_wave_sel;
            end
            // else: key-down with all voices busy — drop silently
        end
    end

    // ---- 4 tone generators ----
    wire signed [6:0] s0, s1, s2, s3;

    tone_gen #(.AMP_SHIFT(AMP_SHIFT)) tg0 (
        .clk(clk), .rst_n(rst_n),
        .active(v_active[0]), .ftw(v_ftw[0]), .wave_sel(v_wave[0]),
        .sample(s0)
    );
    tone_gen #(.AMP_SHIFT(AMP_SHIFT)) tg1 (
        .clk(clk), .rst_n(rst_n),
        .active(v_active[1]), .ftw(v_ftw[1]), .wave_sel(v_wave[1]),
        .sample(s1)
    );
    tone_gen #(.AMP_SHIFT(AMP_SHIFT)) tg2 (
        .clk(clk), .rst_n(rst_n),
        .active(v_active[2]), .ftw(v_ftw[2]), .wave_sel(v_wave[2]),
        .sample(s2)
    );
    tone_gen #(.AMP_SHIFT(AMP_SHIFT)) tg3 (
        .clk(clk), .rst_n(rst_n),
        .active(v_active[3]), .ftw(v_ftw[3]), .wave_sel(v_wave[3]),
        .sample(s3)
    );

    // ---- Signed sum (10-bit headroom) ----
    // Each voice is signed [6:0] with range ~[-32, +31] worst case.
    // 4 voices summed could in theory hit ±128, fits in signed [9:0].
    wire signed [9:0] s0_ext = {{3{s0[6]}}, s0};
    wire signed [9:0] s1_ext = {{3{s1[6]}}, s1};
    wire signed [9:0] s2_ext = {{3{s2[6]}}, s2};
    wire signed [9:0] s3_ext = {{3{s3[6]}}, s3};

    assign sum_sample = s0_ext + s1_ext + s2_ext + s3_ext;

endmodule
