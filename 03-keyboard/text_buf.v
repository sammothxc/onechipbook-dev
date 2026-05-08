// 128x48 character text buffer (6144 chars, addressed as {row[5:0], col[6:0]}).
// Address space is 8192 (13-bit) for simple power-of-2 indexing.
// Initialized to ASCII space so the screen starts blank.
// Infers Altera M4K block RAM: synchronous read (1-cycle latency), synchronous write.
module text_buf (
    input  wire        clk,
    // Read port — renderer
    input  wire [12:0] rd_addr,
    output reg  [7:0]  rd_data,
    // Write port — cursor controller
    input  wire [12:0] wr_addr,
    input  wire [7:0]  wr_data,
    input  wire        wr_en
);
    reg [7:0] mem [0:8191];

    integer i;
    initial begin
        for (i = 0; i < 8192; i = i + 1)
            mem[i] = 8'h20;  // space
    end

    always @(posedge clk) begin
        if (wr_en)
            mem[wr_addr] <= wr_data;
        rd_data <= mem[rd_addr];
    end

endmodule
