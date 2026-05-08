module timing (
    input  wire        pixel_clk,
    input  wire        rst_n,           // active-low reset
    output reg         hsync,
    output reg         vsync,
    output reg         visible,
    output reg [10:0]  pixel_x,
    output reg  [9:0]  pixel_y
);

    // 640x480 @ 60Hz timing (VGA)
    localparam H_VISIBLE     = 11'd640;
    localparam H_FRONT_PORCH = 11'd16;
    localparam H_SYNC_PULSE  = 11'd96;
    localparam H_BACK_PORCH  = 11'd48;
    localparam H_TOTAL       = 11'd800;

    localparam V_VISIBLE     = 10'd480;
    localparam V_FRONT_PORCH = 10'd10;
    localparam V_SYNC_PULSE  = 10'd2;
    localparam V_BACK_PORCH  = 10'd33;
    localparam V_TOTAL       = 10'd525;

    // 800x600 @ 60Hz timing (SVGA)
    // localparam H_VISIBLE     = 11'd800;
    // localparam H_FRONT_PORCH = 11'd40;
    // localparam H_SYNC_PULSE  = 11'd128;
    // localparam H_BACK_PORCH  = 11'd88;
    // localparam H_TOTAL       = 11'd1056;

    // localparam V_VISIBLE     = 10'd600;
    // localparam V_FRONT_PORCH = 10'd1;
    // localparam V_SYNC_PULSE  = 10'd4;
    // localparam V_BACK_PORCH  = 10'd23;
    // localparam V_TOTAL       = 10'd628;

    // 1024x768 @ 60Hz timing (XGA)
    // localparam H_VISIBLE     = 11'd1024;
    // localparam H_FRONT_PORCH = 11'd24;
    // localparam H_SYNC_PULSE  = 11'd136;
    // localparam H_BACK_PORCH  = 11'd160;
    // localparam H_TOTAL       = 11'd1344;

    // localparam V_VISIBLE     = 10'd768;
    // localparam V_FRONT_PORCH = 10'd3;
    // localparam V_SYNC_PULSE  = 10'd6;
    // localparam V_BACK_PORCH  = 10'd29;
    // localparam V_TOTAL       = 10'd806;
    
    // Sync pulse boundaries (precomputed for cleaner combinational logic)
    localparam H_SYNC_START = H_VISIBLE + H_FRONT_PORCH;             // 1048
    localparam H_SYNC_END   = H_SYNC_START + H_SYNC_PULSE;           // 1184
    localparam V_SYNC_START = V_VISIBLE + V_FRONT_PORCH;             // 771
    localparam V_SYNC_END   = V_SYNC_START + V_SYNC_PULSE;           // 777
    
    reg [10:0] h_count;
    reg  [9:0] v_count;
    
    // Counter logic
    always @(posedge pixel_clk or negedge rst_n) begin
        if (!rst_n) begin
            h_count <= 0;
            v_count <= 0;
        end else if (h_count == H_TOTAL - 1) begin
            h_count <= 0;
            if (v_count == V_TOTAL - 1)
                v_count <= 0;
            else
                v_count <= v_count + 1'b1;
        end else begin
            h_count <= h_count + 1'b1;
        end
    end
    
    // Registered outputs (one cycle of latency, but cleaner timing)
    always @(posedge pixel_clk) begin

        // Active-low sync pulses (XGA standard)
        hsync   <= ~((h_count >= H_SYNC_START) && (h_count < H_SYNC_END));
        vsync   <= ~((v_count >= V_SYNC_START) && (v_count < V_SYNC_END));

        // SVGA: positive (active-high) sync
        // hsync   <= (h_count >= H_SYNC_START) && (h_count < H_SYNC_END);
        // vsync   <= (v_count >= V_SYNC_START) && (v_count < V_SYNC_END);

        visible <= (h_count < H_VISIBLE) && (v_count < V_VISIBLE);
        pixel_x <= h_count;
        pixel_y <= v_count;
    end

endmodule