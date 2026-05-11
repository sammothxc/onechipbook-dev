// 07-sdram Stage A: SDRAM init + 8-vector read/write self-test.
//
// After reset the FSM writes 8 known 16-bit words to addresses spanning
// all 4 banks and all 13 row-address bits, then reads them back and
// compares.  Results shown on LEDs (1-indexed, LED1=LSB ... LED8=MSB):
//   8'hAA — all 8 words matched (pass)
//   8'h5N — mismatch at test index N (bits 2:0 = failing index)
//   8'hFF — still initializing / running test
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
    //  Test vectors: 8 write addresses + expected data
    // ----------------------------------------------------------------
    function [15:0] test_data;
        input [2:0] idx;
        case (idx)
            3'd0: test_data = 16'hDEAD;
            3'd1: test_data = 16'hBEEF;
            3'd2: test_data = 16'hCAFE;
            3'd3: test_data = 16'hBABE;
            3'd4: test_data = 16'h1234;
            3'd5: test_data = 16'h5678;
            3'd6: test_data = 16'h9ABC;
            3'd7: test_data = 16'hDEF0;
        endcase
    endfunction

    function [24:0] test_addr;
        input [2:0] idx;
        // Spread across all 4 banks; row values exercise all 13 row bits.
        // addr[24:23]=bank, addr[22:10]=row, addr[9:1]=col, addr[0]=ignored.
        case (idx)
            3'd0: test_addr = 25'h02AA800;  // bank0, row=0x0AAA, col=0x000
            3'd1: test_addr = 25'h0D55400;  // bank1, row=0x1555, col=0x000
            3'd2: test_addr = 25'h13FFC00;  // bank2, row=0x0FFF, col=0x000
            3'd3: test_addr = 25'h1C00000;  // bank3, row=0x1000, col=0x000
            3'd4: test_addr = 25'h02AABFE;  // bank0, row=0x0AAA, col=0x1FF
            3'd5: test_addr = 25'h0D557FE;  // bank1, row=0x1555, col=0x1FF
            3'd6: test_addr = 25'h1000402;  // bank2, row=0x0001, col=0x001
            3'd7: test_addr = 25'h1FFF800;  // bank3, row=0x1FFE, col=0x000
        endcase
    endfunction

    // ----------------------------------------------------------------
    //  Test FSM: write all 8, then read all 8 and compare.
    // ----------------------------------------------------------------
    localparam T_WRITE   = 3'd0;
    localparam T_WRITE_W = 3'd1;
    localparam T_READ    = 3'd2;
    localparam T_READ_W  = 3'd3;
    localparam T_DONE    = 3'd4;

    reg [2:0] tstate;
    reg [2:0] tidx;

    always @(posedge clk_21m or negedge rst_n_in) begin
        if (!rst_n_in) begin
            tstate   <= T_WRITE;
            tidx     <= 3'd0;
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
                        addr    <= test_addr(tidx);
                        wr_data <= test_data(tidx);
                        wr_mask <= 2'b11;
                        tstate  <= T_WRITE_W;
                    end
                end

                T_WRITE_W: begin
                    if (!busy) begin
                        if (tidx == 3'd7) begin
                            tidx   <= 3'd0;
                            tstate <= T_READ;
                        end else begin
                            tidx   <= tidx + 1'b1;
                            tstate <= T_WRITE;
                        end
                    end
                end

                T_READ: begin
                    if (!busy) begin
                        req    <= 1'b1;
                        we     <= 1'b0;
                        addr   <= test_addr(tidx);
                        tstate <= T_READ_W;
                    end
                end

                T_READ_W: begin
                    if (rd_valid) begin
                        if (rd_data != test_data(tidx)) begin
                            led    <= {4'h5, 1'b0, tidx};
                            tstate <= T_DONE;
                        end else if (tidx == 3'd7) begin
                            led    <= 8'hAA;
                            tstate <= T_DONE;
                        end else begin
                            tidx   <= tidx + 1'b1;
                            tstate <= T_READ;
                        end
                    end
                end

                T_DONE: ;

            endcase
        end
    end

endmodule
