// 8N1 UART transmitter.
// tx_start must be asserted for exactly one cycle when tx_busy is low.
// Frame: start(0) + 8 data bits LSB-first + stop(1) = 10 × BAUD_DIV clocks.
module uart_tx #(
    parameter CLK_HZ = 21_477_270,
    parameter BAUD   = 115_200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] tx_data,
    input  wire       tx_start,
    output reg        tx,
    output reg        tx_busy
);
    localparam BAUD_DIV = CLK_HZ / BAUD;  // 186 @ 115200

    reg [7:0] baud_cnt;
    reg [3:0] bit_cnt;   // 0–8: data; 9: stop-bit wait
    reg [7:0] shift;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx       <= 1'b1;
            tx_busy  <= 1'b0;
            baud_cnt <= 8'd0;
            bit_cnt  <= 4'd0;
            shift    <= 8'd0;
        end else if (!tx_busy) begin
            if (tx_start) begin
                tx       <= 1'b0;   // start bit
                tx_busy  <= 1'b1;
                baud_cnt <= 8'd0;
                bit_cnt  <= 4'd0;
                shift    <= tx_data;
            end
        end else begin
            if (baud_cnt == BAUD_DIV - 1) begin
                baud_cnt <= 8'd0;
                if (bit_cnt == 4'd9) begin
                    tx_busy <= 1'b0;
                end else begin
                    bit_cnt <= bit_cnt + 4'd1;
                    if (bit_cnt == 4'd8) begin
                        tx <= 1'b1;                   // stop bit
                    end else begin
                        tx    <= shift[0];            // data, LSB first
                        shift <= {1'b0, shift[7:1]};
                    end
                end
            end else begin
                baud_cnt <= baud_cnt + 8'd1;
            end
        end
    end
endmodule
