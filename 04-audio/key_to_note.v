// Maps PS/2 Set 2 scan codes for 30 piano keys to:
//   - wave_sel    : which oscillator shape (sine / saw / square)
//   - ftw         : frequency tuning word for tone_gen DDS
//   - note_letter : ASCII letter ('A'..'G')
//   - note_octave : ASCII digit ('4' or '5')
//   - freq_h/t/u  : 3 BCD digits of the integer Hz value (rounded)
// Combinational lookup. `recognized` is high only for keys in the table.
//
// Layout — pentatonic C major (C D E G A) across 2 octaves per row:
//   Top row    Q W E R T  Y U I O P  -> sawtooth (wave_sel = 2'b01)
//   Home row   A S D F G  H J K L ;  -> sine     (wave_sel = 2'b00)
//   Bottom row Z X C V B  N M , . /  -> square   (wave_sel = 2'b10)
//
// FTWs computed for fclk = 21.47727 MHz, 32-bit phase: ftw = round(f * 2^32 / fclk).
module key_to_note (
    input  wire [7:0]  scan_code,
    output reg  [1:0]  wave_sel,
    output reg  [31:0] ftw,
    output reg  [7:0]  note_letter,
    output reg  [7:0]  note_octave,
    output reg  [3:0]  freq_h,
    output reg  [3:0]  freq_t,
    output reg  [3:0]  freq_u,
    output reg         recognized
);

    // Note encoding: a single 6-bit field {wave[1:0], note_idx[3:0]}
    // where note_idx selects {C4, D4, E4, G4, A4, C5, D5, E5, G5, A5}.
    // Done by mapping scan code to (wave_sel, note_idx) first, then
    // using note_idx to look up freq + name. Keeps the per-row tables
    // identical except for the wave_sel value.
    reg [3:0] note_idx;
    reg       valid_key;

    always @(*) begin
        valid_key = 1'b1;
        case (scan_code)
            // Top row Q W E R T Y U I O P  -> saw
            8'h15: begin wave_sel = 2'b01; note_idx = 4'd0; end  // Q
            8'h1D: begin wave_sel = 2'b01; note_idx = 4'd1; end  // W
            8'h24: begin wave_sel = 2'b01; note_idx = 4'd2; end  // E
            8'h2D: begin wave_sel = 2'b01; note_idx = 4'd3; end  // R
            8'h2C: begin wave_sel = 2'b01; note_idx = 4'd4; end  // T
            8'h35: begin wave_sel = 2'b01; note_idx = 4'd5; end  // Y
            8'h3C: begin wave_sel = 2'b01; note_idx = 4'd6; end  // U
            8'h43: begin wave_sel = 2'b01; note_idx = 4'd7; end  // I
            8'h44: begin wave_sel = 2'b01; note_idx = 4'd8; end  // O
            8'h4D: begin wave_sel = 2'b01; note_idx = 4'd9; end  // P

            // Home row A S D F G H J K L ;  -> sine
            8'h1C: begin wave_sel = 2'b00; note_idx = 4'd0; end  // A
            8'h1B: begin wave_sel = 2'b00; note_idx = 4'd1; end  // S
            8'h23: begin wave_sel = 2'b00; note_idx = 4'd2; end  // D
            8'h2B: begin wave_sel = 2'b00; note_idx = 4'd3; end  // F
            8'h34: begin wave_sel = 2'b00; note_idx = 4'd4; end  // G
            8'h33: begin wave_sel = 2'b00; note_idx = 4'd5; end  // H
            8'h3B: begin wave_sel = 2'b00; note_idx = 4'd6; end  // J
            8'h42: begin wave_sel = 2'b00; note_idx = 4'd7; end  // K
            8'h4B: begin wave_sel = 2'b00; note_idx = 4'd8; end  // L
            8'h4C: begin wave_sel = 2'b00; note_idx = 4'd9; end  // ;

            // Bottom row Z X C V B N M , . /  -> square
            8'h1A: begin wave_sel = 2'b10; note_idx = 4'd0; end  // Z
            8'h22: begin wave_sel = 2'b10; note_idx = 4'd1; end  // X
            8'h21: begin wave_sel = 2'b10; note_idx = 4'd2; end  // C
            8'h2A: begin wave_sel = 2'b10; note_idx = 4'd3; end  // V
            8'h32: begin wave_sel = 2'b10; note_idx = 4'd4; end  // B
            8'h31: begin wave_sel = 2'b10; note_idx = 4'd5; end  // N
            8'h3A: begin wave_sel = 2'b10; note_idx = 4'd6; end  // M
            8'h41: begin wave_sel = 2'b10; note_idx = 4'd7; end  // ,
            8'h49: begin wave_sel = 2'b10; note_idx = 4'd8; end  // .
            8'h4A: begin wave_sel = 2'b10; note_idx = 4'd9; end  // /

            default: begin
                wave_sel  = 2'b00;
                note_idx  = 4'd0;
                valid_key = 1'b0;
            end
        endcase
    end

    // note_idx -> (ftw, note_letter, note_octave, freq_bcd)
    always @(*) begin
        case (note_idx)
            //                          ftw       letter octave  H  T  U
            4'd0: begin ftw = 32'd52320;  note_letter = "C"; note_octave = "4"; freq_h = 4'd2; freq_t = 4'd6; freq_u = 4'd2; end  // C4 262
            4'd1: begin ftw = 32'd58725;  note_letter = "D"; note_octave = "4"; freq_h = 4'd2; freq_t = 4'd9; freq_u = 4'd4; end  // D4 294
            4'd2: begin ftw = 32'd65919;  note_letter = "E"; note_octave = "4"; freq_h = 4'd3; freq_t = 4'd3; freq_u = 4'd0; end  // E4 330
            4'd3: begin ftw = 32'd78391;  note_letter = "G"; note_octave = "4"; freq_h = 4'd3; freq_t = 4'd9; freq_u = 4'd2; end  // G4 392
            4'd4: begin ftw = 32'd87990;  note_letter = "A"; note_octave = "4"; freq_h = 4'd4; freq_t = 4'd4; freq_u = 4'd0; end  // A4 440
            4'd5: begin ftw = 32'd104638; note_letter = "C"; note_octave = "5"; freq_h = 4'd5; freq_t = 4'd2; freq_u = 4'd3; end  // C5 523
            4'd6: begin ftw = 32'd117453; note_letter = "D"; note_octave = "5"; freq_h = 4'd5; freq_t = 4'd8; freq_u = 4'd7; end  // D5 587
            4'd7: begin ftw = 32'd131835; note_letter = "E"; note_octave = "5"; freq_h = 4'd6; freq_t = 4'd5; freq_u = 4'd9; end  // E5 659
            4'd8: begin ftw = 32'd156780; note_letter = "G"; note_octave = "5"; freq_h = 4'd7; freq_t = 4'd8; freq_u = 4'd4; end  // G5 784
            4'd9: begin ftw = 32'd175980; note_letter = "A"; note_octave = "5"; freq_h = 4'd8; freq_t = 4'd8; freq_u = 4'd0; end  // A5 880
            default: begin
                ftw = 32'd0; note_letter = " "; note_octave = " ";
                freq_h = 4'd0; freq_t = 4'd0; freq_u = 4'd0;
            end
        endcase
    end

    always @(*) recognized = valid_key;

endmodule
