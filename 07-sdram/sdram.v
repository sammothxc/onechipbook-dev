// 07-sdram Stage A diagnostic mode: write/read a single word at the address
// that was failing (bank 3, row 0x1000) and display the low byte of the
// read result on the LEDs.
//
// Expected result: 8'hBE (low byte of 0xBABE).
// If we see something else, the actual bits returned tell us what's broken:
//   8'h00  -> read returned zero; A12 likely stuck low during ACTIVE
//   8'hFF  -> read returned all-ones; DQ floating or tri-state stuck
//   other  -> partial bit failure; compare to 0xBE to identify failing DQ pins
module sdram (
    input  wire       clk_21m,
    input  wire       rst_n_in,

    // SDRAM
    output wire       sdram_clk,
    output wire       sdram_cke,
    output wire       sdram_cs_n,
    output wire       sdram_ras_n,
    output wire       sdram_cas_n,
    output wire       sdram_we_n,
    output wire [1:0] sdram_ba,
    output wire[12:0] sdram_a,
    output wire [1:0] sdram_dqm,
    inout  wire[15:0] sdram_dq,

    // led[1..8] match physical labels LED1..LED8 on the board.
    // The compiler will warn that led[0] and led[9] are unused — that's
    // expected; led[0] is just a wasted bit so the indices line up.
    output reg  [8:1] led
);

    // Drive SDRAM clock directly from system clock.
    // At 21.47 MHz (46.5 ns cycle), setup/hold margins are enormous —
    // no phase shift needed for Stage A.
    assign sdram_clk = clk_21m;

    // ----------------------------------------------------------------
    //  Controller wires
    // ----------------------------------------------------------------
    reg        req;
    reg        we;
    reg [24:0] addr;
    reg [15:0] wr_data;
    reg  [1:0] wr_mask;
    wire[15:0] rd_data;
    wire       rd_valid;
    wire       busy;

    sdram_ctrl ctrl (
        .clk        (clk_21m),
        .rst_n      (rst_n_in),
        .req        (req),
        .we         (we),
        .addr       (addr),
        .wr_data    (wr_data),
        .wr_mask    (wr_mask),
        .rd_data    (rd_data),
        .rd_valid   (rd_valid),
        .busy       (busy),
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

    // ----------------------------------------------------------------
    //  Diagnostic FSM — single write+read to the failing address.
    //
    //  Write 0xBABE to bank 3, row 0x1000, col 0.
    //  Read it back. Display low byte of result on LEDs.
    //  Expected: 8'hBE.
    // ----------------------------------------------------------------
    localparam DIAG_ADDR = 25'h1C00000;   // bank3, row=0x1000, col=0x000
    localparam DIAG_DATA = 16'hBABE;

    localparam T_WRITE   = 3'd0;
    localparam T_WRITE_W = 3'd1;
    localparam T_READ    = 3'd2;
    localparam T_READ_W  = 3'd3;
    localparam T_DONE    = 3'd4;

    reg [2:0] tstate;

    always @(posedge clk_21m or negedge rst_n_in) begin
        if (!rst_n_in) begin
            tstate   <= T_WRITE;
            req      <= 1'b0;
            we       <= 1'b0;
            addr     <= 25'd0;
            wr_data  <= 16'd0;
            wr_mask  <= 2'b11;
            led      <= 8'hFF;   // "running" sentinel
        end else begin
            req <= 1'b0;

            case (tstate)

                T_WRITE: begin
                    if (!busy) begin
                        req     <= 1'b1;
                        we      <= 1'b1;
                        addr    <= DIAG_ADDR;
                        wr_data <= DIAG_DATA;
                        wr_mask <= 2'b11;
                        tstate  <= T_WRITE_W;
                    end
                end

                T_WRITE_W: begin
                    if (!busy) begin
                        tstate <= T_READ;
                    end
                end

                T_READ: begin
                    if (!busy) begin
                        req    <= 1'b1;
                        we     <= 1'b0;
                        addr   <= DIAG_ADDR;
                        tstate <= T_READ_W;
                    end
                end

                T_READ_W: begin
                    if (rd_valid) begin
                        led    <= rd_data[7:0];   // show low byte
                        tstate <= T_DONE;
                    end
                end

                T_DONE: begin
                    // Hold result forever
                end

            endcase
        end
    end

endmodule
