// SPI Master — Mode 0 (CPOL=0, CPHA=0), MSB-first, 8 bits per transfer.
//
// SCLK idles low. MOSI is updated on falling edges; MISO is sampled on rising
// edges. After each byte SCLK ends low so the next byte can start cleanly.
//
// `clk_div` sets the SPI half-period in system-clock cycles. SCLK frequency
// is therefore clk / (2 * clk_div). Examples for a 21.477 MHz system clock:
//   clk_div =  1  → SCLK ≈ 10.74 MHz   (run mode)
//   clk_div = 32  → SCLK ≈ 336 kHz     (init mode, ≤ 400 kHz spec ceiling)
//
// Handshake: pulse `start` for one cycle while !busy. `busy` rises the next
// cycle and stays high until the byte completes; `done` pulses for one cycle
// when `rx` is valid.
module spi_master (
    input  wire        clk,
    input  wire        rst_n,
    input  wire  [7:0] clk_div,    // half-period in clk cycles (must be ≥ 1)

    input  wire        start,
    input  wire  [7:0] tx,
    output reg   [7:0] rx,
    output reg         busy,
    output reg         done,

    output reg         sclk,
    output wire        mosi,
    input  wire        miso
);

    reg  [7:0] tx_shift;
    reg  [7:0] rx_shift;
    reg  [7:0] div_cnt;
    reg  [4:0] half_cnt;          // 0..16 (16 = wrap to idle)

    assign mosi = tx_shift[7];

    always @(posedge clk) begin
        if (!rst_n) begin
            sclk     <= 1'b0;
            busy     <= 1'b0;
            done     <= 1'b0;
            tx_shift <= 8'hFF;
            rx_shift <= 8'h00;
            rx       <= 8'h00;
            div_cnt  <= 8'd0;
            half_cnt <= 5'd0;
        end else begin
            done <= 1'b0;

            if (!busy) begin
                if (start) begin
                    busy     <= 1'b1;
                    tx_shift <= tx;
                    rx_shift <= 8'h00;
                    sclk     <= 1'b0;
                    div_cnt  <= 8'd0;
                    half_cnt <= 5'd0;
                end
            end else begin
                if (div_cnt + 8'd1 >= clk_div) begin
                    div_cnt <= 8'd0;

                    if (half_cnt[0] == 1'b0) begin
                        // Even half-period → rising edge: sample MISO (MSB-first
                        // means the first sample lands in rx_shift[7] after 7
                        // more left-shifts).
                        sclk     <= 1'b1;
                        rx_shift <= {rx_shift[6:0], miso};
                    end else begin
                        // Odd half-period → falling edge: present next MOSI bit.
                        sclk     <= 1'b0;
                        tx_shift <= {tx_shift[6:0], 1'b0};
                    end

                    if (half_cnt == 5'd15) begin
                        // 16th half-period (final falling edge): byte complete.
                        // The 8th sample landed in rx_shift on the previous
                        // (14th) rising edge, so rx_shift already holds the
                        // full byte.
                        busy <= 1'b0;
                        done <= 1'b1;
                        rx   <= rx_shift;
                        sclk <= 1'b0;
                    end

                    half_cnt <= half_cnt + 5'd1;
                end else begin
                    div_cnt <= div_cnt + 8'd1;
                end
            end
        end
    end

endmodule
