// 06-uart Stages A+B: UART TX + RX echo at 115200 8N1.
//
// On reset: sends "Hello!\r\n", then enters echo mode.
// Echo mode: every received byte is echoed back; LEDs show the last received byte.
// Bytes received while TX is busy are dropped (no FIFO — acceptable for a demo).
module uart (
    input  wire       clk_21m,
    input  wire       rst_n_in,
    output wire       uart_txd,
    input  wire       uart_rxd,
    output reg  [7:0] led
);
    // ----------------------------------------------------------------
    //  Hello string (Stage A) — combinational function avoids RAM inference
    // ----------------------------------------------------------------
    localparam HELLO_LEN = 8;

    function [7:0] hello_byte;
        input [3:0] idx;
        case (idx)
            4'd0: hello_byte = "H";
            4'd1: hello_byte = "e";
            4'd2: hello_byte = "l";
            4'd3: hello_byte = "l";
            4'd4: hello_byte = "o";
            4'd5: hello_byte = "!";
            4'd6: hello_byte = 8'h0D;
            4'd7: hello_byte = 8'h0A;
            default: hello_byte = 8'h00;
        endcase
    endfunction

    // ----------------------------------------------------------------
    //  UART instances
    // ----------------------------------------------------------------
    reg        tx_start;
    reg  [7:0] tx_data;
    wire       tx_busy;

    uart_tx #(.CLK_HZ(21_477_270), .BAUD(115_200)) tx_inst (
        .clk      (clk_21m),
        .rst_n    (rst_n_in),
        .tx_data  (tx_data),
        .tx_start (tx_start),
        .tx       (uart_txd),
        .tx_busy  (tx_busy)
    );

    wire [7:0] rx_byte;
    wire       rx_valid;

    uart_rx #(.CLK_HZ(21_477_270), .BAUD(115_200)) rx_inst (
        .clk        (clk_21m),
        .rst_n      (rst_n_in),
        .rx         (uart_rxd),
        .data       (rx_byte),
        .data_valid (rx_valid)
    );

    // ----------------------------------------------------------------
    //  Top-level FSM
    // ----------------------------------------------------------------
    localparam S_SEND = 1'b0;   // transmitting hello string
    localparam S_ECHO = 1'b1;   // echo received bytes

    reg       state;
    reg [3:0] str_idx;

    always @(posedge clk_21m or negedge rst_n_in) begin
        if (!rst_n_in) begin
            state    <= S_SEND;
            str_idx  <= 4'd0;
            tx_start <= 1'b0;
            tx_data  <= 8'd0;
            led      <= 8'd0;
        end else begin
            tx_start <= 1'b0;

            if (rx_valid)
                led <= rx_byte;   // always update LED on receive

            case (state)
                S_SEND: begin
                    // Guard !tx_start: uart_tx latches on the cycle AFTER we
                    // assert tx_start, so tx_busy is still 0 for one more cycle —
                    // without this guard we'd fire twice on the same character.
                    if (!tx_busy && !tx_start) begin
                        tx_data  <= hello_byte(str_idx);
                        tx_start <= 1'b1;
                        if (str_idx == HELLO_LEN - 1) begin
                            state   <= S_ECHO;
                            str_idx <= 4'd0;
                        end else begin
                            str_idx <= str_idx + 4'd1;
                        end
                    end
                end

                S_ECHO: begin
                    if (rx_valid && !tx_busy) begin
                        tx_data  <= rx_byte;
                        tx_start <= 1'b1;
                    end
                end
            endcase
        end
    end
endmodule
