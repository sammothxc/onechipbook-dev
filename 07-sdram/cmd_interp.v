// Command interpreter for the SDRAM Stage B test harness.
//
// Reads ASCII characters from the PS/2 keyboard pipeline, accumulates them
// into a fixed-size input buffer, and on Enter dispatches one of two
// commands to the SDRAM via the sdram_if request port:
//
//   w XXXXXXX DDDD<Enter>   — write 16-bit DDDD to byte-address XXXXXXX
//   r XXXXXXX<Enter>        — read from byte-address XXXXXXX
//
// Any other input on Enter produces "ERR".  Successful writes produce "OK".
// Successful reads produce "RD=XXXX" where XXXX is the 16-bit data read.
//
// Replies are emitted as a synthetic stream of ascii_out / ascii_out_valid
// pulses, suitable for feeding into the same text-buffer cursor controller
// that handles live keystrokes.  This keeps the display path uniform.
//
// Strict grammar — keeps the parser tiny:
//   - Exactly one ASCII space between fields
//   - Exactly 7 hex digits for the address (28 bits; low 25 used)
//   - Exactly 4 hex digits for the data
//   - First char must be 'w' or 'r' (lowercase only)
module cmd_interp (
    input  wire        clk,
    input  wire        rst_n,

    // Live keyboard input
    input  wire  [7:0] ascii_in,
    input  wire        ascii_in_valid,

    // Echo stream to the display (live keys + auto-typed replies)
    output reg   [7:0] ascii_out,
    output reg         ascii_out_valid,

    // SDRAM request port (sdram_if expects one-cycle req pulse)
    output reg         sdram_req,
    output reg         sdram_we,
    output reg  [24:0] sdram_addr,
    output reg  [15:0] sdram_wr_data,
    output reg   [1:0] sdram_wr_mask,
    input  wire [15:0] sdram_rd_data,
    input  wire        sdram_done
);

    // ----------------------------------------------------------------
    //  Hex-char decode (combinational)
    //   nybble = 4-bit value, hex_ok = 1 if ascii_in is a valid hex digit
    // ----------------------------------------------------------------
    reg [3:0] nybble;
    reg       hex_ok;

    always @(*) begin
        hex_ok = 1'b1;
        case (ascii_in)
            "0": nybble = 4'h0;
            "1": nybble = 4'h1;
            "2": nybble = 4'h2;
            "3": nybble = 4'h3;
            "4": nybble = 4'h4;
            "5": nybble = 4'h5;
            "6": nybble = 4'h6;
            "7": nybble = 4'h7;
            "8": nybble = 4'h8;
            "9": nybble = 4'h9;
            "a","A": nybble = 4'hA;
            "b","B": nybble = 4'hB;
            "c","C": nybble = 4'hC;
            "d","D": nybble = 4'hD;
            "e","E": nybble = 4'hE;
            "f","F": nybble = 4'hF;
            default: begin nybble = 4'h0; hex_ok = 1'b0; end
        endcase
    end

    // ----------------------------------------------------------------
    //  Helper: encode a 4-bit nybble as an ASCII hex digit (0-9 A-F)
    // ----------------------------------------------------------------
    function [7:0] hex_char;
        input [3:0] n;
        hex_char = (n < 4'd10) ? (8'h30 + n) : (8'h41 + n - 4'd10);
    endfunction

    // ----------------------------------------------------------------
    //  Parser state
    //
    //  cmd_kind: 0=none, 1='w', 2='r'
    //  field:    which field we're collecting
    //  pos:      digit position within the current field
    // ----------------------------------------------------------------
    localparam K_NONE = 2'd0;
    localparam K_W    = 2'd1;
    localparam K_R    = 2'd2;

    localparam F_OPCODE = 3'd0;  // waiting for 'w'/'r'
    localparam F_SP1    = 3'd1;  // waiting for first space
    localparam F_ADDR   = 3'd2;  // collecting 7 addr digits
    localparam F_SP2    = 3'd3;  // waiting for second space (write only)
    localparam F_DATA   = 3'd4;  // collecting 4 data digits (write only)
    localparam F_READY  = 3'd5;  // waiting for Enter
    localparam F_BAD    = 3'd6;  // syntax error; ignore until Enter

    reg [1:0]  cmd_kind;
    reg [2:0]  field;
    reg [3:0]  pos;          // 0..6 for addr, 0..3 for data
    reg [27:0] addr_acc;
    reg [15:0] data_acc;
    reg [15:0] rd_latch;     // for displaying after a read

    // ----------------------------------------------------------------
    //  Reply auto-typer
    //
    //  When a command completes (or errors), we emit a short string by
    //  sequencing rep_state through fixed positions.  The text-buffer
    //  cursor controller in the top level consumes ascii_out the same way
    //  it consumes live keystrokes.
    // ----------------------------------------------------------------
    localparam R_IDLE   = 4'd0;
    localparam R_OK_1   = 4'd1;   // 'O'
    localparam R_OK_2   = 4'd2;   // 'K'
    localparam R_OK_3   = 4'd3;   // CR
    localparam R_ERR_1  = 4'd4;   // 'E'
    localparam R_ERR_2  = 4'd5;   // 'R'
    localparam R_ERR_3  = 4'd6;   // 'R'
    localparam R_ERR_4  = 4'd7;   // CR
    localparam R_RD_1   = 4'd8;   // 'R'
    localparam R_RD_2   = 4'd9;   // 'D'
    localparam R_RD_3   = 4'd10;  // '='
    localparam R_RD_4   = 4'd11;  // hex digit 3
    localparam R_RD_5   = 4'd12;  // hex digit 2
    localparam R_RD_6   = 4'd13;  // hex digit 1
    localparam R_RD_7   = 4'd14;  // hex digit 0
    localparam R_RD_8   = 4'd15;  // CR

    reg [3:0] rep_state;

    // ----------------------------------------------------------------
    //  Pending-execution flag
    //   1 = Enter was pressed for a valid command; waiting on sdram_done
    // ----------------------------------------------------------------
    reg pending;
    reg pending_we;

    // ----------------------------------------------------------------
    //  Main always block
    // ----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ascii_out       <= 8'h00;
            ascii_out_valid <= 1'b0;
            sdram_req       <= 1'b0;
            sdram_we        <= 1'b0;
            sdram_addr      <= 25'd0;
            sdram_wr_data   <= 16'd0;
            sdram_wr_mask   <= 2'b11;
            cmd_kind        <= K_NONE;
            field           <= F_OPCODE;
            pos             <= 4'd0;
            addr_acc        <= 28'd0;
            data_acc        <= 16'd0;
            rd_latch        <= 16'd0;
            rep_state       <= R_IDLE;
            pending         <= 1'b0;
            pending_we      <= 1'b0;
        end else begin
            ascii_out_valid <= 1'b0;
            sdram_req       <= 1'b0;

            // ----------------------------------------------------------------
            //  Reply emission (one char per cycle of rep_state advance).
            //  Highest priority — if a reply is in progress, don't consume
            //  new keystrokes.
            // ----------------------------------------------------------------
            case (rep_state)
                R_IDLE: ; // nothing
                R_OK_1: begin
                    ascii_out <= "O"; ascii_out_valid <= 1'b1;
                    rep_state <= R_OK_2;
                end
                R_OK_2: begin
                    ascii_out <= "K"; ascii_out_valid <= 1'b1;
                    rep_state <= R_OK_3;
                end
                R_OK_3: begin
                    ascii_out <= 8'h0D; ascii_out_valid <= 1'b1;
                    rep_state <= R_IDLE;
                end
                R_ERR_1: begin
                    ascii_out <= "E"; ascii_out_valid <= 1'b1;
                    rep_state <= R_ERR_2;
                end
                R_ERR_2: begin
                    ascii_out <= "R"; ascii_out_valid <= 1'b1;
                    rep_state <= R_ERR_3;
                end
                R_ERR_3: begin
                    ascii_out <= "R"; ascii_out_valid <= 1'b1;
                    rep_state <= R_ERR_4;
                end
                R_ERR_4: begin
                    ascii_out <= 8'h0D; ascii_out_valid <= 1'b1;
                    rep_state <= R_IDLE;
                end
                R_RD_1: begin
                    ascii_out <= "R"; ascii_out_valid <= 1'b1;
                    rep_state <= R_RD_2;
                end
                R_RD_2: begin
                    ascii_out <= "D"; ascii_out_valid <= 1'b1;
                    rep_state <= R_RD_3;
                end
                R_RD_3: begin
                    ascii_out <= "="; ascii_out_valid <= 1'b1;
                    rep_state <= R_RD_4;
                end
                R_RD_4: begin
                    ascii_out <= hex_char(rd_latch[15:12]);
                    ascii_out_valid <= 1'b1;
                    rep_state <= R_RD_5;
                end
                R_RD_5: begin
                    ascii_out <= hex_char(rd_latch[11:8]);
                    ascii_out_valid <= 1'b1;
                    rep_state <= R_RD_6;
                end
                R_RD_6: begin
                    ascii_out <= hex_char(rd_latch[7:4]);
                    ascii_out_valid <= 1'b1;
                    rep_state <= R_RD_7;
                end
                R_RD_7: begin
                    ascii_out <= hex_char(rd_latch[3:0]);
                    ascii_out_valid <= 1'b1;
                    rep_state <= R_RD_8;
                end
                R_RD_8: begin
                    ascii_out <= 8'h0D; ascii_out_valid <= 1'b1;
                    rep_state <= R_IDLE;
                end
            endcase

            // ----------------------------------------------------------------
            //  SDRAM completion
            // ----------------------------------------------------------------
            if (pending && sdram_done) begin
                pending  <= 1'b0;
                rd_latch <= sdram_rd_data;
                if (pending_we) begin
                    rep_state <= R_OK_1;
                end else begin
                    rep_state <= R_RD_1;
                end
            end

            // ----------------------------------------------------------------
            //  Live keystroke handling (only when no reply or pending exec)
            // ----------------------------------------------------------------
            if (ascii_in_valid && rep_state == R_IDLE && !pending) begin
                // Echo every key to the display
                ascii_out       <= ascii_in;
                ascii_out_valid <= 1'b1;

                // ---- Parse ----
                if (ascii_in == 8'h0D) begin
                    // Enter — dispatch if ready
                    case (field)
                        F_READY: begin
                            sdram_req     <= 1'b1;
                            sdram_addr    <= addr_acc[24:0];
                            sdram_we      <= (cmd_kind == K_W);
                            sdram_wr_data <= data_acc;
                            sdram_wr_mask <= 2'b11;
                            pending       <= 1'b1;
                            pending_we    <= (cmd_kind == K_W);
                        end
                        default: begin
                            rep_state <= R_ERR_1;
                        end
                    endcase
                    // Reset parser regardless
                    cmd_kind <= K_NONE;
                    field    <= F_OPCODE;
                    pos      <= 4'd0;
                    addr_acc <= 28'd0;
                    data_acc <= 16'd0;
                end else if (ascii_in == 8'h08) begin
                    // Backspace — wipe parser state, force re-entry
                    cmd_kind <= K_NONE;
                    field    <= F_BAD;   // any further chars ignored until Enter
                end else begin
                    case (field)
                        F_OPCODE: begin
                            if (ascii_in == "w") begin
                                cmd_kind <= K_W;
                                field    <= F_SP1;
                            end else if (ascii_in == "r") begin
                                cmd_kind <= K_R;
                                field    <= F_SP1;
                            end else begin
                                field <= F_BAD;
                            end
                        end
                        F_SP1: begin
                            if (ascii_in == " ") begin
                                field <= F_ADDR;
                                pos   <= 4'd0;
                            end else begin
                                field <= F_BAD;
                            end
                        end
                        F_ADDR: begin
                            if (hex_ok) begin
                                addr_acc <= {addr_acc[23:0], nybble};
                                if (pos == 4'd6) begin
                                    if (cmd_kind == K_W) field <= F_SP2;
                                    else                 field <= F_READY;
                                    pos <= 4'd0;
                                end else begin
                                    pos <= pos + 1'b1;
                                end
                            end else begin
                                field <= F_BAD;
                            end
                        end
                        F_SP2: begin
                            if (ascii_in == " ") begin
                                field <= F_DATA;
                                pos   <= 4'd0;
                            end else begin
                                field <= F_BAD;
                            end
                        end
                        F_DATA: begin
                            if (hex_ok) begin
                                data_acc <= {data_acc[11:0], nybble};
                                if (pos == 4'd3) begin
                                    field <= F_READY;
                                end else begin
                                    pos <= pos + 1'b1;
                                end
                            end else begin
                                field <= F_BAD;
                            end
                        end
                        F_READY: begin
                            // Already complete; any non-Enter char is bad
                            field <= F_BAD;
                        end
                        F_BAD: ; // swallow until Enter
                    endcase
                end
            end
        end
    end

endmodule
