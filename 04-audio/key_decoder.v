// Strips PS/2 Set 2 prefix bytes (0xE0 = extended, 0xF0 = release) and
// emits a single-cycle pulse with the underlying scan code + is_release.
// Extended keys (E0-prefixed) are suppressed entirely — none of them are
// in our piano range (Q/A/Z rows are all single-byte codes).
module key_decoder (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] rx_data,
    input  wire       rx_valid,
    output reg  [7:0] scan_code,
    output reg        is_release,
    output reg        valid
);
    reg saw_e0, saw_f0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            saw_e0     <= 1'b0;
            saw_f0     <= 1'b0;
            scan_code  <= 8'h00;
            is_release <= 1'b0;
            valid      <= 1'b0;
        end else begin
            valid <= 1'b0;
            if (rx_valid) begin
                if (rx_data == 8'hE0) begin
                    saw_e0 <= 1'b1;
                end else if (rx_data == 8'hF0) begin
                    saw_f0 <= 1'b1;
                end else begin
                    if (!saw_e0) begin
                        scan_code  <= rx_data;
                        is_release <= saw_f0;
                        valid      <= 1'b1;
                    end
                    saw_e0 <= 1'b0;
                    saw_f0 <= 1'b0;
                end
            end
        end
    end

endmodule
