// SD card controller — SPI mode init + single-block read of sector 0.
//
// On reset, the FSM walks the standard SPI-mode init sequence:
//   1. ≥80 dummy clocks with CS high          (S_POWER)
//   2. CMD0  GO_IDLE_STATE       → R1=0x01    (S_CMD0)
//   3. CMD8  SEND_IF_COND(0x1AA) → R7         (S_CMD8)
//        — illegal-cmd bit set → v1.x SDSC
//        — echo 0xAA            → v2.0+
//   4. CMD55 + ACMD41 loop until R1 == 0x00   (S_CMD55 / S_ACMD41)
//        — v2 sends ACMD41 with HCS bit (arg=0x40000000)
//        — v1 sends ACMD41 with arg=0
//   5. CMD58 READ_OCR (v2 only) → CCS bit
//        — CCS=1 → SDHC (block addressing)
//        — CCS=0 → SDSC (byte addressing)
//   6. CMD17 READ_SINGLE_BLOCK(0) → 0xFE + 512 bytes + 2 CRC bytes
//   7. Stay in S_DONE forever, ready=1
//
// The buffer port (buf_addr/buf_data/buf_we) writes one byte per spi_done
// during the data phase. Caller wires this to a 512×8 dual-port BRAM whose
// read port lives on the pixel clock.
//
// Debug: state_dbg = current FSM state, err_dbg = last failure reason.
//   err codes: 0xS1 = R1 timeout in state S
//              0xS2 = R1 came back with bit-7 set (invalid)
//              0xS3 = unexpected R1 value (e.g. CMD0 didn't return 0x01)
//              0xS4 = ACMD41 retry budget exceeded
//              0x75 = data start token wasn't 0xFE
//              0x76 = data token timeout
module sd_ctrl (
    input  wire        clk,
    input  wire        rst_n,

    // SD card SPI pins
    output reg         sd_cs_n,
    output wire        sd_clk,
    output wire        sd_mosi,
    input  wire        sd_miso,

    // Block-buffer write port (1 byte/word, 512 entries)
    output reg  [13:0] buf_addr,
    output reg   [7:0] buf_data,
    output reg         buf_we,

    // Debug / status
    output reg   [3:0] state_dbg,
    output reg   [7:0] err_dbg,
    output reg         ready
);

    // ---- SPI master ----
    reg  [7:0] spi_div;
    reg  [7:0] spi_tx_data;
    reg        spi_start;
    wire [7:0] spi_rx_data;
    wire       spi_busy;
    wire       spi_done;

    spi_master spi (
        .clk     (clk),
        .rst_n   (rst_n),
        .clk_div (spi_div),
        .start   (spi_start),
        .tx      (spi_tx_data),
        .rx      (spi_rx_data),
        .busy    (spi_busy),
        .done    (spi_done),
        .sclk    (sd_clk),
        .mosi    (sd_mosi),
        .miso    (sd_miso)
    );

    // ---- Clock divider settings ----
    // 21.477 MHz / (2*32) ≈ 336 kHz (init, ≤400 kHz)
    // 21.477 MHz / (2*2)  ≈ 5.37 MHz (run — conservative; 1GB cards rate ≤25)
    localparam [7:0] DIV_INIT = 8'd32;
    localparam [7:0] DIV_RUN  = 8'd2;

    // ---- States ----
    localparam [3:0] S_POWER  = 4'd0;
    localparam [3:0] S_CMD0   = 4'd1;
    localparam [3:0] S_CMD8   = 4'd2;
    localparam [3:0] S_CMD55  = 4'd3;
    localparam [3:0] S_ACMD41 = 4'd4;
    localparam [3:0] S_CMD58  = 4'd5;
    localparam [3:0] S_CMD17  = 4'd7;
    localparam [3:0] S_DONE   = 4'd8;
    localparam [3:0] S_ERROR  = 4'hF;

    // ---- Phases within a command state ----
    localparam [3:0] P_PREP      = 4'd0;
    localparam [3:0] P_TX        = 4'd1;
    localparam [3:0] P_POLL_R1   = 4'd2;
    localparam [3:0] P_EXTRA     = 4'd3;
    localparam [3:0] P_DATA_WAIT = 4'd4;  // CMD17: poll for 0xFE
    localparam [3:0] P_DATA_READ = 4'd5;  // CMD17: shift 512 bytes into buffer
    localparam [3:0] P_DATA_CRC  = 4'd6;  // CMD17: shift 2 CRC bytes (ignore)
    localparam [3:0] P_CLEANUP   = 4'd7;  // deassert CS, send 8 dummy clocks
    localparam [3:0] P_CLEANUP2  = 4'd8;  // wait for cleanup byte to finish

    // ---- Limits ----
    localparam [10:0] POLL_R1_MAX     = 11'd16;     // bytes to wait for R1
    localparam [12:0] ACMD41_MAX      = 13'd8000;   // ACMD41 retry budget
    localparam [13:0] DATA_TOKEN_MAX  = 14'd16383;  // bytes to wait for 0xFE
    localparam [3:0]  POWER_DUMMY_BYTES = 4'd10;    // 80 clocks (>74 spec min)

    // ---- Working registers ----
    reg [3:0]  state;
    reg [3:0]  phase;
    reg [3:0]  byte_idx;        // 0..5 within a 6-byte command
    reg [3:0]  extra_idx;       // 0..3 within R3/R7
    reg [13:0] poll_cnt;        // shared poll counter
    reg [12:0] acmd41_cnt;      // ACMD41 retry counter
    reg [9:0]  data_idx;        // 0..511 within data block

    reg [7:0]  r1;
    reg [31:0] extra_buf;       // captures R7 / R3 (OCR) payload

    reg        v2_card;
    reg        sdhc;            // CCS=1 → SDHC/SDXC (latched from CMD58 OCR bit 30)

    reg  [4:0] sector_idx;     // which sector we are currently reading (0..31)
    // Unsized integer — 32 doesn't fit in 5 bits so never give this a [4:0] width.
    localparam BOOT_SECTORS  = 32;
    localparam [4:0] LAST_SECTOR = 5'd31;  // BOOT_SECTORS - 1, pre-computed

    // CMD17 argument for the current sector.
    // SDSC: byte address = sector × 512. SDHC/SDXC: block address = sector.
    wire [31:0] rd_arg = sdhc ? {27'b0, sector_idx}
                               : {18'b0, sector_idx, 9'b0};

    // ---- Command-byte ROM (combinational, depends on state + flags) ----
    // SPI-mode CRC is checked only on CMD0 and CMD8; other commands use a stub.
    reg [7:0] cmd_b0, cmd_b1, cmd_b2, cmd_b3, cmd_b4, cmd_b5;
    always @* begin
        case (state)
            S_CMD0: begin
                cmd_b0 = 8'h40;
                cmd_b1 = 8'h00; cmd_b2 = 8'h00; cmd_b3 = 8'h00; cmd_b4 = 8'h00;
                cmd_b5 = 8'h95;
            end
            S_CMD8: begin
                cmd_b0 = 8'h48;
                cmd_b1 = 8'h00; cmd_b2 = 8'h00; cmd_b3 = 8'h01; cmd_b4 = 8'hAA;
                cmd_b5 = 8'h87;
            end
            S_CMD55: begin
                cmd_b0 = 8'h77;     // 0x40 | 55
                cmd_b1 = 8'h00; cmd_b2 = 8'h00; cmd_b3 = 8'h00; cmd_b4 = 8'h00;
                cmd_b5 = 8'h01;
            end
            S_ACMD41: begin
                cmd_b0 = 8'h69;     // 0x40 | 41
                cmd_b1 = v2_card ? 8'h40 : 8'h00;  // HCS bit (only for v2)
                cmd_b2 = 8'h00; cmd_b3 = 8'h00; cmd_b4 = 8'h00;
                cmd_b5 = 8'h01;
            end
            S_CMD58: begin
                cmd_b0 = 8'h7A;     // 0x40 | 58
                cmd_b1 = 8'h00; cmd_b2 = 8'h00; cmd_b3 = 8'h00; cmd_b4 = 8'h00;
                cmd_b5 = 8'h01;
            end
            S_CMD17: begin
                // SDSC: byte address = sector × 512. SDHC/SDXC: block address.
                // rd_arg is the 32-bit CMD17 argument; sdhc selects addressing mode.
                cmd_b0 = 8'h51;     // 0x40 | 17
                cmd_b1 = rd_arg[31:24];
                cmd_b2 = rd_arg[23:16];
                cmd_b3 = rd_arg[15:8];
                cmd_b4 = rd_arg[7:0];
                cmd_b5 = 8'h01;
            end
            default: begin
                cmd_b0 = 8'hFF; cmd_b1 = 8'hFF; cmd_b2 = 8'hFF;
                cmd_b3 = 8'hFF; cmd_b4 = 8'hFF; cmd_b5 = 8'hFF;
            end
        endcase
    end

    // Number of extra bytes after R1 (for R3/R7 responses).
    reg [3:0] extra_n;
    always @* begin
        case (state)
            S_CMD8, S_CMD58: extra_n = 4'd4;
            default:         extra_n = 4'd0;
        endcase
    end

    // ---- Main FSM ----
    always @(posedge clk) begin
        if (!rst_n) begin
            state       <= S_POWER;
            phase       <= P_PREP;
            byte_idx    <= 4'd0;
            extra_idx   <= 4'd0;
            poll_cnt    <= 14'd0;
            acmd41_cnt  <= 13'd0;
            data_idx    <= 10'd0;
            r1          <= 8'h00;
            extra_buf   <= 32'h0;
            v2_card     <= 1'b0;
            sdhc        <= 1'b0;
            sd_cs_n     <= 1'b1;
            spi_start   <= 1'b0;
            spi_tx_data <= 8'hFF;
            spi_div     <= DIV_INIT;
            sector_idx  <= 5'd0;
            buf_addr    <= 14'd0;
            buf_data    <= 8'd0;
            buf_we      <= 1'b0;
            ready       <= 1'b0;
            err_dbg     <= 8'h00;
            state_dbg   <= S_POWER;
        end else begin
            // Defaults — pulses
            spi_start <= 1'b0;
            buf_we    <= 1'b0;
            state_dbg <= state;

            case (state)
            // ------------------------------------------------------------
            S_POWER: begin
                sd_cs_n <= 1'b1;
                case (phase)
                    P_PREP: begin
                        byte_idx    <= 4'd0;
                        spi_tx_data <= 8'hFF;
                        spi_start   <= 1'b1;
                        phase       <= P_TX;
                    end
                    P_TX: begin
                        if (spi_done) begin
                            if (byte_idx == POWER_DUMMY_BYTES - 4'd1) begin
                                // Power-up done → start CMD0.
                                state    <= S_CMD0;
                                phase    <= P_PREP;
                                byte_idx <= 4'd0;
                            end else begin
                                byte_idx    <= byte_idx + 4'd1;
                                spi_tx_data <= 8'hFF;
                                spi_start   <= 1'b1;
                            end
                        end
                    end
                    default: phase <= P_PREP;
                endcase
            end

            // ------------------------------------------------------------
            // Generic command states share the same TX→POLL_R1→[EXTRA]→CLEANUP
            // skeleton; per-state divergences live in P_CLEANUP transitions.
            S_CMD0, S_CMD8, S_CMD55, S_ACMD41, S_CMD58, S_CMD17: begin
                case (phase)
                    P_PREP: begin
                        sd_cs_n     <= 1'b0;
                        byte_idx    <= 4'd0;
                        extra_idx   <= 4'd0;
                        poll_cnt    <= 14'd0;
                        data_idx    <= 10'd0;
                        extra_buf   <= 32'h0;
                        spi_tx_data <= cmd_b0;
                        spi_start   <= 1'b1;
                        phase       <= P_TX;
                    end

                    P_TX: begin
                        if (spi_done) begin
                            if (byte_idx == 4'd5) begin
                                // 6 cmd bytes sent; start polling for R1.
                                spi_tx_data <= 8'hFF;
                                spi_start   <= 1'b1;
                                poll_cnt    <= 14'd0;
                                phase       <= P_POLL_R1;
                            end else begin
                                byte_idx <= byte_idx + 4'd1;
                                // cmd_byte_at_idx is combinational on byte_idx,
                                // so present the *next* byte explicitly.
                                case (byte_idx)
                                    4'd0: spi_tx_data <= cmd_b1;
                                    4'd1: spi_tx_data <= cmd_b2;
                                    4'd2: spi_tx_data <= cmd_b3;
                                    4'd3: spi_tx_data <= cmd_b4;
                                    default: spi_tx_data <= cmd_b5;
                                endcase
                                spi_start <= 1'b1;
                            end
                        end
                    end

                    P_POLL_R1: begin
                        if (spi_done) begin
                            if (spi_rx_data != 8'hFF) begin
                                // Got a response byte. Bit 7 must be 0 in valid R1.
                                r1 <= spi_rx_data;
                                if (spi_rx_data[7]) begin
                                    err_dbg <= {state, 4'h2};
                                    state   <= S_ERROR;
                                end else if (extra_n != 4'd0) begin
                                    spi_tx_data <= 8'hFF;
                                    spi_start   <= 1'b1;
                                    extra_idx   <= 4'd0;
                                    phase       <= P_EXTRA;
                                end else if (state == S_CMD17 && spi_rx_data == 8'h00) begin
                                    // Read accepted — wait for data start token.
                                    spi_tx_data <= 8'hFF;
                                    spi_start   <= 1'b1;
                                    poll_cnt    <= 14'd0;
                                    phase       <= P_DATA_WAIT;
                                end else begin
                                    phase <= P_CLEANUP;
                                end
                            end else if (poll_cnt == POLL_R1_MAX - 14'd1) begin
                                err_dbg <= {state, 4'h1};
                                state   <= S_ERROR;
                            end else begin
                                poll_cnt    <= poll_cnt + 14'd1;
                                spi_tx_data <= 8'hFF;
                                spi_start   <= 1'b1;
                            end
                        end
                    end

                    P_EXTRA: begin
                        if (spi_done) begin
                            extra_buf <= {extra_buf[23:0], spi_rx_data};
                            if (extra_idx == extra_n - 4'd1) begin
                                phase <= P_CLEANUP;
                            end else begin
                                extra_idx   <= extra_idx + 4'd1;
                                spi_tx_data <= 8'hFF;
                                spi_start   <= 1'b1;
                            end
                        end
                    end

                    // ----- CMD17 data phases -----
                    P_DATA_WAIT: begin
                        if (spi_done) begin
                            if (spi_rx_data == 8'hFE) begin
                                spi_tx_data <= 8'hFF;
                                spi_start   <= 1'b1;
                                data_idx    <= 10'd0;
                                phase       <= P_DATA_READ;
                            end else if (spi_rx_data != 8'hFF) begin
                                // Anything else non-FF that isn't the start token
                                // is a data error token (range 0x01..0x0F).
                                err_dbg <= 8'h75;
                                state   <= S_ERROR;
                            end else if (poll_cnt == DATA_TOKEN_MAX - 14'd1) begin
                                err_dbg <= 8'h76;
                                state   <= S_ERROR;
                            end else begin
                                poll_cnt    <= poll_cnt + 14'd1;
                                spi_tx_data <= 8'hFF;
                                spi_start   <= 1'b1;
                            end
                        end
                    end

                    P_DATA_READ: begin
                        if (spi_done) begin
                            // Capture this byte into the buffer.
                            buf_addr <= {sector_idx, data_idx[8:0]};
                            buf_data <= spi_rx_data;
                            buf_we   <= 1'b1;
                            if (data_idx == 10'd511) begin
                                // 512 bytes done — read 2 CRC bytes.
                                spi_tx_data <= 8'hFF;
                                spi_start   <= 1'b1;
                                data_idx    <= 10'd0;
                                phase       <= P_DATA_CRC;
                            end else begin
                                data_idx    <= data_idx + 10'd1;
                                spi_tx_data <= 8'hFF;
                                spi_start   <= 1'b1;
                            end
                        end
                    end

                    P_DATA_CRC: begin
                        if (spi_done) begin
                            if (data_idx == 10'd1) begin
                                phase <= P_CLEANUP;
                            end else begin
                                data_idx    <= data_idx + 10'd1;
                                spi_tx_data <= 8'hFF;
                                spi_start   <= 1'b1;
                            end
                        end
                    end

                    // ----- Common cleanup + per-state transition -----
                    P_CLEANUP: begin
                        // CS high, send 1 dummy byte (8 clocks).
                        sd_cs_n     <= 1'b1;
                        spi_tx_data <= 8'hFF;
                        spi_start   <= 1'b1;
                        phase       <= P_CLEANUP2;
                    end

                    P_CLEANUP2: begin
                        if (spi_done) begin
                            // Decide next state based on which command just ran.
                            case (state)
                                S_CMD0: begin
                                    if (r1 == 8'h01) begin
                                        state <= S_CMD8;
                                        phase <= P_PREP;
                                    end else begin
                                        err_dbg <= {state, 4'h3};
                                        state   <= S_ERROR;
                                    end
                                end

                                S_CMD8: begin
                                    if (r1[2]) begin
                                        // Illegal-cmd bit set → v1.x card.
                                        v2_card <= 1'b0;
                                        state   <= S_CMD55;
                                        phase   <= P_PREP;
                                    end else if (extra_buf[7:0] == 8'hAA) begin
                                        // Voltage echo matched → v2.0+ card.
                                        v2_card <= 1'b1;
                                        state   <= S_CMD55;
                                        phase   <= P_PREP;
                                    end else begin
                                        err_dbg <= {state, 4'h3};
                                        state   <= S_ERROR;
                                    end
                                end

                                S_CMD55: begin
                                    // R1 must still show idle (0x01) so ACMD41
                                    // can follow.
                                    if (r1 == 8'h01 || r1 == 8'h00) begin
                                        state <= S_ACMD41;
                                        phase <= P_PREP;
                                    end else begin
                                        err_dbg <= {state, 4'h3};
                                        state   <= S_ERROR;
                                    end
                                end

                                S_ACMD41: begin
                                    if (r1 == 8'h00) begin
                                        // Initialised. v2 cards still need CMD58
                                        // to learn SDSC vs SDHC; v1 skips it
                                        // (always SDSC, byte addressing).
                                        if (v2_card) begin
                                            state <= S_CMD58;
                                            phase <= P_PREP;
                                        end else begin
                                            sdhc    <= 1'b0;
                                            spi_div <= DIV_RUN;
                                            state   <= S_CMD17;
                                            phase   <= P_PREP;
                                        end
                                    end else if (r1 == 8'h01) begin
                                        // Still busy; retry CMD55+ACMD41.
                                        if (acmd41_cnt == ACMD41_MAX - 13'd1) begin
                                            err_dbg <= {state, 4'h4};
                                            state   <= S_ERROR;
                                        end else begin
                                            acmd41_cnt <= acmd41_cnt + 13'd1;
                                            state      <= S_CMD55;
                                            phase      <= P_PREP;
                                        end
                                    end else begin
                                        err_dbg <= {state, 4'h3};
                                        state   <= S_ERROR;
                                    end
                                end

                                S_CMD58: begin
                                    // OCR bit 30 (CCS) lives in extra_buf[30],
                                    // which is bit 6 of the first OCR byte
                                    // (extra_buf[31:24]).
                                    sdhc    <= extra_buf[30];
                                    spi_div <= DIV_RUN;
                                    state   <= S_CMD17;
                                    phase   <= P_PREP;
                                end

                                S_CMD17: begin
                                    // All BOOT_SECTORS read → done.
                                    // Otherwise increment and re-issue CMD17.
                                    if (sector_idx == LAST_SECTOR) begin
                                        state <= S_DONE;
                                    end else begin
                                        sector_idx <= sector_idx + 5'd1;
                                        phase      <= P_PREP;
                                    end
                                    phase <= P_PREP;
                                end

                                default: state <= S_ERROR;
                            endcase
                        end
                    end

                    default: phase <= P_PREP;
                endcase
            end

            // ------------------------------------------------------------
            S_DONE: begin
                ready <= 1'b1;
            end

            // ------------------------------------------------------------
            S_ERROR: begin
                // Park here; err_dbg + state_dbg already latched.
            end

            default: state <= S_ERROR;
            endcase
        end
    end

endmodule
