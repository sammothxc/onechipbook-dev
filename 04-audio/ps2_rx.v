// PS/2 byte receiver.
// Synchronizes ps2_clk/ps2_data through 2-flop chains, detects falling
// edges on ps2_clk, and shifts in 11-bit frames (start + 8 data + parity
// + stop). Validates odd parity and stop bit before asserting data_valid
// for one clock cycle.
module ps2_rx (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       ps2_clk_raw,
    input  wire       ps2_data_raw,
    output reg  [7:0] data,
    output reg        data_valid
);

    // 2-flop synchronizers — PS/2 lines are asynchronous to system clock
    reg clk_s0,  clk_s1;
    reg data_s0, data_s1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clk_s0  <= 1'b1;
            clk_s1  <= 1'b1;
            data_s0 <= 1'b1;
            data_s1 <= 1'b1;
        end else begin
            clk_s0  <= ps2_clk_raw;
            clk_s1  <= clk_s0;
            data_s0 <= ps2_data_raw;
            data_s1 <= data_s0;
        end
    end

    wire ps2_clk_s  = clk_s1;
    wire ps2_data_s = data_s1;

    // Falling edge detector on synchronized PS/2 clock
    reg  ps2_clk_prev;
    wire ps2_fall = ps2_clk_prev & ~ps2_clk_s;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ps2_clk_prev <= 1'b1;
        else        ps2_clk_prev <= ps2_clk_s;
    end

    // Frame receiver: 11 bits total
    //   bit 0      = start bit (must be 0)
    //   bits 1-8   = data D0-D7, LSB first
    //   bit 9      = parity (odd: XOR of all 9 bits == 1)
    //   bit 10     = stop bit (must be 1)
    reg [3:0] bit_count;
    reg [7:0] shift_reg;
    reg       parity_acc;   // running XOR; should equal 1 after parity bit

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_count  <= 4'd0;
            shift_reg  <= 8'h00;
            parity_acc <= 1'b0;
            data       <= 8'h00;
            data_valid <= 1'b0;
        end else begin
            data_valid <= 1'b0;

            if (ps2_fall) begin
                if (bit_count == 4'd0) begin
                    // Start bit -- must be 0; ignore spurious edges
                    if (ps2_data_s == 1'b0) begin
                        parity_acc <= 1'b0;
                        bit_count  <= 4'd1;
                    end
                end else if (bit_count <= 4'd8) begin
                    // Data bits D0-D7, arriving LSB first.
                    // Right-shift into shift_reg so D0 ends up in bit 0.
                    shift_reg  <= {ps2_data_s, shift_reg[7:1]};
                    parity_acc <= parity_acc ^ ps2_data_s;
                    bit_count  <= bit_count + 1'b1;
                end else if (bit_count == 4'd9) begin
                    // Parity bit -- fold into accumulator
                    parity_acc <= parity_acc ^ ps2_data_s;
                    bit_count  <= 4'd10;
                end else begin
                    // Stop bit (bit_count == 10).
                    // Valid frame: stop=1, odd parity (parity_acc==1).
                    bit_count <= 4'd0;
                    if (ps2_data_s == 1'b1 && parity_acc == 1'b1) begin
                        data       <= shift_reg;
                        data_valid <= 1'b1;
                    end
                end
            end
        end
    end

endmodule
