// CDC wrapper around sdram_ctrl.
//
// Presents a simple synchronous request/done interface on the pixel_clk
// domain.  Internally crosses into clk_21m, drives sdram_ctrl, captures
// the result, and crosses back.
//
// Usage (pixel_clk side):
//   1. Wait for done==0 or initial state.
//   2. Set we / addr / wr_data / wr_mask and pulse req for one cycle.
//   3. Wait for done to pulse (one cycle).  rd_data is valid that cycle
//      (for reads) or undefined (for writes).
//   4. Repeat.
//
// Strictly one transaction at a time — there is no busy signal, the user
// must hold off on a new req until the previous done has fired.
module sdram_if (
    // pixel_clk side (user)
    input  wire        pclk,
    input  wire        prst_n,
    input  wire        req,
    input  wire        we,
    input  wire [24:0] addr,
    input  wire [15:0] wr_data,
    input  wire  [1:0] wr_mask,
    output reg  [15:0] rd_data,
    output reg         done,

    // clk_21m side (controller)
    input  wire        sclk,
    input  wire        srst_n,

    // SDRAM pins (passed through to sdram_ctrl)
    output wire        sdram_cke,
    output wire        sdram_cs_n,
    output wire        sdram_ras_n,
    output wire        sdram_cas_n,
    output wire        sdram_we_n,
    output wire  [1:0] sdram_ba,
    output wire [12:0] sdram_a,
    output wire  [1:0] sdram_dqm,
    inout  wire [15:0] sdram_dq
);

    // ----------------------------------------------------------------
    //  Pixel-side: latch request data, flip toggle
    // ----------------------------------------------------------------
    reg        req_toggle_p;
    reg        we_lat_p;
    reg [24:0] addr_lat_p;
    reg [15:0] wr_data_lat_p;
    reg  [1:0] wr_mask_lat_p;

    always @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            req_toggle_p  <= 1'b0;
            we_lat_p      <= 1'b0;
            addr_lat_p    <= 25'd0;
            wr_data_lat_p <= 16'd0;
            wr_mask_lat_p <= 2'b11;
        end else if (req) begin
            req_toggle_p  <= ~req_toggle_p;
            we_lat_p      <= we;
            addr_lat_p    <= addr;
            wr_data_lat_p <= wr_data;
            wr_mask_lat_p <= wr_mask;
        end
    end

    // ----------------------------------------------------------------
    //  Sync request toggle into clk_21m, edge-detect
    // ----------------------------------------------------------------
    reg [2:0] req_tog_s;   // [2]=oldest, [0]=newest sample of req_toggle_p

    always @(posedge sclk or negedge srst_n) begin
        if (!srst_n) req_tog_s <= 3'b000;
        else         req_tog_s <= {req_tog_s[1:0], req_toggle_p};
    end

    wire req_edge_s = req_tog_s[2] ^ req_tog_s[1];

    // ----------------------------------------------------------------
    //  clk_21m side: drive sdram_ctrl, capture result
    // ----------------------------------------------------------------
    reg        req_s;
    reg [15:0] rd_data_lat_s;
    reg        rsp_toggle_s;
    wire[15:0] rd_data_ctrl;
    wire       rd_valid_ctrl;
    wire       busy_ctrl;

    sdram_ctrl ctrl (
        .clk        (sclk),
        .rst_n      (srst_n),
        .req        (req_s),
        .we         (we_lat_p),       // CDC data path; false-pathed in SDC
        .addr       (addr_lat_p),     // stable when req_s fires
        .wr_data    (wr_data_lat_p),
        .wr_mask    (wr_mask_lat_p),
        .rd_data    (rd_data_ctrl),
        .rd_valid   (rd_valid_ctrl),
        .busy       (busy_ctrl),
        .sdram_cke  (sdram_cke),
        .sdram_cs_n (sdram_cs_n),
        .sdram_ras_n(sdram_ras_n),
        .sdram_cas_n(sdram_cas_n),
        .sdram_we_n (sdram_we_n),
        .sdram_ba   (sdram_ba),
        .sdram_a    (sdram_a),
        .sdram_dqm  (sdram_dqm),
        .sdram_dq   (sdram_dq)
    );

    // Fire req_s when we see a request edge AND the controller is idle.
    // The user guarantees one transaction at a time, but the controller
    // may also be doing a refresh — wait for it to finish first.
    reg req_pending_s;

    always @(posedge sclk or negedge srst_n) begin
        if (!srst_n) begin
            req_s         <= 1'b0;
            req_pending_s <= 1'b0;
        end else begin
            req_s <= 1'b0;
            if (req_edge_s) begin
                req_pending_s <= 1'b1;
            end
            if (req_pending_s && !busy_ctrl) begin
                req_s         <= 1'b1;
                req_pending_s <= 1'b0;
            end
        end
    end

    // Capture read data and flip response toggle on completion.
    // For writes there is no rd_valid pulse from sdram_ctrl, so we generate
    // our own "done" pulse one cycle after req_s fires for writes.
    reg write_in_flight_s;
    reg write_done_s;

    always @(posedge sclk or negedge srst_n) begin
        if (!srst_n) begin
            rd_data_lat_s     <= 16'd0;
            rsp_toggle_s      <= 1'b0;
            write_in_flight_s <= 1'b0;
            write_done_s      <= 1'b0;
        end else begin
            write_done_s <= 1'b0;

            // Track when a write has been issued and the controller has
            // returned to idle (write completion has no dedicated valid).
            if (req_s && we_lat_p) write_in_flight_s <= 1'b1;
            if (write_in_flight_s && !busy_ctrl) begin
                write_in_flight_s <= 1'b0;
                write_done_s      <= 1'b1;
            end

            if (rd_valid_ctrl) begin
                rd_data_lat_s <= rd_data_ctrl;
                rsp_toggle_s  <= ~rsp_toggle_s;
            end else if (write_done_s) begin
                rsp_toggle_s  <= ~rsp_toggle_s;
            end
        end
    end

    // ----------------------------------------------------------------
    //  Sync response toggle into pixel_clk, edge-detect, produce done
    // ----------------------------------------------------------------
    reg [2:0] rsp_tog_s_in_p;

    always @(posedge pclk or negedge prst_n) begin
        if (!prst_n) rsp_tog_s_in_p <= 3'b000;
        else         rsp_tog_s_in_p <= {rsp_tog_s_in_p[1:0], rsp_toggle_s};
    end

    wire rsp_edge_p = rsp_tog_s_in_p[2] ^ rsp_tog_s_in_p[1];

    always @(posedge pclk or negedge prst_n) begin
        if (!prst_n) begin
            rd_data <= 16'd0;
            done    <= 1'b0;
        end else begin
            done <= rsp_edge_p;
            if (rsp_edge_p) rd_data <= rd_data_lat_s;
        end
    end

endmodule
