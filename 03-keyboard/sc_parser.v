// PS/2 Set 2 scan code parser (stages C + D).
//
// Consumes raw bytes from ps2_rx and handles the E0/F0 prefix protocol:
//   make:            XX
//   break:           F0 XX
//   extended make:   E0 XX
//   extended break:  E0 F0 XX
//
// Tracks left/right shift state and maps non-extended make codes to ASCII.
// Asserts ascii_valid for one clock cycle when a printable (or control)
// key is pressed.  Extended keys (arrows, F-keys, etc.) are silently ignored.
module sc_parser (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] rx_data,    // raw byte from ps2_rx
    input  wire       rx_valid,   // 1-cycle pulse
    output reg  [7:0] ascii,      // ASCII of last pressed key
    output reg        ascii_valid // 1-cycle pulse on key press
);

    reg extended_r;  // set after 0xE0 prefix
    reg release_r;   // set after 0xF0 prefix
    reg shift_held;  // true while either shift key is down

    // ---- Combinational scan-code -> ASCII lookup ----
    // Outputs are based on rx_data and are valid whenever rx_valid is high.

    reg [7:0] ascii_base;
    reg [7:0] ascii_shift;

    always @(*) begin
        case (rx_data)
            // Letters (lowercase / uppercase)
            8'h1C: begin ascii_base = "a"; ascii_shift = "A"; end
            8'h32: begin ascii_base = "b"; ascii_shift = "B"; end
            8'h21: begin ascii_base = "c"; ascii_shift = "C"; end
            8'h23: begin ascii_base = "d"; ascii_shift = "D"; end
            8'h24: begin ascii_base = "e"; ascii_shift = "E"; end
            8'h2B: begin ascii_base = "f"; ascii_shift = "F"; end
            8'h34: begin ascii_base = "g"; ascii_shift = "G"; end
            8'h33: begin ascii_base = "h"; ascii_shift = "H"; end
            8'h43: begin ascii_base = "i"; ascii_shift = "I"; end
            8'h3B: begin ascii_base = "j"; ascii_shift = "J"; end
            8'h42: begin ascii_base = "k"; ascii_shift = "K"; end
            8'h4B: begin ascii_base = "l"; ascii_shift = "L"; end
            8'h3A: begin ascii_base = "m"; ascii_shift = "M"; end
            8'h31: begin ascii_base = "n"; ascii_shift = "N"; end
            8'h44: begin ascii_base = "o"; ascii_shift = "O"; end
            8'h4D: begin ascii_base = "p"; ascii_shift = "P"; end
            8'h15: begin ascii_base = "q"; ascii_shift = "Q"; end
            8'h2D: begin ascii_base = "r"; ascii_shift = "R"; end
            8'h1B: begin ascii_base = "s"; ascii_shift = "S"; end
            8'h2C: begin ascii_base = "t"; ascii_shift = "T"; end
            8'h3C: begin ascii_base = "u"; ascii_shift = "U"; end
            8'h2A: begin ascii_base = "v"; ascii_shift = "V"; end
            8'h1D: begin ascii_base = "w"; ascii_shift = "W"; end
            8'h22: begin ascii_base = "x"; ascii_shift = "X"; end
            8'h35: begin ascii_base = "y"; ascii_shift = "Y"; end
            8'h1A: begin ascii_base = "z"; ascii_shift = "Z"; end
            // Numbers / symbols
            8'h45: begin ascii_base = "0"; ascii_shift = ")"; end
            8'h16: begin ascii_base = "1"; ascii_shift = "!"; end
            8'h1E: begin ascii_base = "2"; ascii_shift = "@"; end
            8'h26: begin ascii_base = "3"; ascii_shift = "#"; end
            8'h25: begin ascii_base = "4"; ascii_shift = "$"; end
            8'h2E: begin ascii_base = "5"; ascii_shift = "%"; end
            8'h36: begin ascii_base = "6"; ascii_shift = "^"; end
            8'h3D: begin ascii_base = "7"; ascii_shift = "&"; end
            8'h3E: begin ascii_base = "8"; ascii_shift = "*"; end
            8'h46: begin ascii_base = "9"; ascii_shift = "("; end
            // Punctuation
            8'h0E: begin ascii_base = 8'h60; ascii_shift = "~"; end  // ` ~
            8'h4E: begin ascii_base = "-";   ascii_shift = "_"; end
            8'h55: begin ascii_base = "=";   ascii_shift = "+"; end
            8'h54: begin ascii_base = "[";   ascii_shift = "{"; end
            8'h5B: begin ascii_base = "]";   ascii_shift = "}"; end
            8'h5D: begin ascii_base = 8'h5C; ascii_shift = 8'h7C; end  // \ |
            8'h4C: begin ascii_base = ";";   ascii_shift = ":"; end
            8'h52: begin ascii_base = "'";   ascii_shift = 8'h22; end  // ' "
            8'h41: begin ascii_base = ",";   ascii_shift = "<"; end
            8'h49: begin ascii_base = ".";   ascii_shift = ">"; end
            8'h4A: begin ascii_base = "/";   ascii_shift = "?"; end
            // Whitespace / control
            8'h29: begin ascii_base = " ";    ascii_shift = " ";    end  // space
            8'h5A: begin ascii_base = 8'h0D;  ascii_shift = 8'h0D;  end  // enter
            8'h66: begin ascii_base = 8'h08;  ascii_shift = 8'h08;  end  // backspace
            8'h0D: begin ascii_base = 8'h09;  ascii_shift = 8'h09;  end  // tab
            8'h76: begin ascii_base = 8'h1B;  ascii_shift = 8'h1B;  end  // escape
            default: begin ascii_base = 8'h00; ascii_shift = 8'h00; end
        endcase
    end

    wire [7:0] ascii_resolved = shift_held ? ascii_shift : ascii_base;

    // ---- Sequential: prefix tracking, shift state, ASCII output ----

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            extended_r  <= 1'b0;
            release_r   <= 1'b0;
            shift_held  <= 1'b0;
            ascii       <= 8'h00;
            ascii_valid <= 1'b0;
        end else begin
            ascii_valid <= 1'b0;

            if (rx_valid) begin
                if (rx_data == 8'hE0) begin
                    extended_r <= 1'b1;
                end else if (rx_data == 8'hF0) begin
                    release_r <= 1'b1;
                end else begin
                    if (!extended_r) begin
                        if (rx_data == 8'h12 || rx_data == 8'h59) begin
                            // Left/right shift
                            shift_held <= !release_r;
                        end else if (!release_r && ascii_resolved != 8'h00) begin
                            ascii       <= ascii_resolved;
                            ascii_valid <= 1'b1;
                        end
                    end
                    // Extended keys (arrows, F-keys, etc.) ignored for now
                    extended_r <= 1'b0;
                    release_r  <= 1'b0;
                end
            end
        end
    end

endmodule
