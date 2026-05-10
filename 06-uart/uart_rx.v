// 8N1 UART receiver.
// Samples at the centre of each bit by waiting BAUD_DIV/2 from the falling
// edge of the start bit, then BAUD_DIV per subsequent bit.
// data_valid is a one-cycle pulse when a correctly-framed byte arrives.
module uart_rx #(
    parameter CLK_HZ = 21_477_270,
    parameter BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,
    output reg  [7:0] data,
    output reg        data_valid
);
    localparam BAUD_DIV  = CLK_HZ / BAUD;      // 186
    localparam HALF_DIV  = BAUD_DIV / 2;        // 93
    // Loading baud_cnt with this value means the first tick to BAUD_DIV-1
    // arrives exactly HALF_DIV cycles later — the centre of the start bit.
    localparam MID_INIT  = BAUD_DIV - HALF_DIV; // 93

    // 3-flop chain: rx_s (may be metastable), rx_q (stable sync'd), rx_d (prev)
    reg rx_s, rx_q, rx_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_s <= 1'b1; rx_q <= 1'b1; rx_d <= 1'b1;
        end else begin
            rx_s <= rx;
            rx_q <= rx_s;
            rx_d <= rx_q;
        end
    end
    wire falling = rx_d & ~rx_q;   // falling edge on the stable signal

    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;

    reg [1:0] state;
    reg [7:0] baud_cnt;
    reg [2:0] bit_cnt;
    reg [7:0] shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= S_IDLE;
            baud_cnt   <= 8'd0;
            bit_cnt    <= 3'd0;
            shift      <= 8'd0;
            data       <= 8'd0;
            data_valid <= 1'b0;
        end else begin
            data_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (falling) begin
                        baud_cnt <= MID_INIT[7:0];
                        state    <= S_START;
                    end
                end

                S_START: begin
                    if (baud_cnt == BAUD_DIV - 1) begin
                        baud_cnt <= 8'd0;
                        if (!rx_q) begin         // still low → real start bit
                            bit_cnt <= 3'd0;
                            state   <= S_DATA;
                        end else begin            // glitch, ignore
                            state   <= S_IDLE;
                        end
                    end else
                        baud_cnt <= baud_cnt + 8'd1;
                end

                S_DATA: begin
                    if (baud_cnt == BAUD_DIV - 1) begin
                        baud_cnt <= 8'd0;
                        shift    <= {rx_q, shift[7:1]};  // LSB first → shift right
                        if (bit_cnt == 3'd7)
                            state <= S_STOP;
                        else
                            bit_cnt <= bit_cnt + 3'd1;
                    end else
                        baud_cnt <= baud_cnt + 8'd1;
                end

                S_STOP: begin
                    if (baud_cnt == BAUD_DIV - 1) begin
                        baud_cnt <= 8'd0;
                        if (rx_q) begin          // valid stop bit
                            data       <= shift;
                            data_valid <= 1'b1;
                        end
                        state <= S_IDLE;
                    end else
                        baud_cnt <= baud_cnt + 8'd1;
                end
            endcase
        end
    end
endmodule
