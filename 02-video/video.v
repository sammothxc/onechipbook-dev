module video (
    input wire clk_21m,
    input wire rst_n_in,
    output wire led1,
    output wire hsync,
    output wire vsync,
    output wire [5:0] r,
    output wire [5:0] g,
    output wire [5:0] b
);

    wire pixel_clk;
    wire pll_locked;
    wire visible;
    wire [10:0] pixel_x;
    wire [9:0] pixel_y;
    

    // vga25mhz_pll pll_inst (
    vga40mhz_pll pll_inst (
    // vga65mhz_pll pll_inst (
        .inclk0 (clk_21m),
        .c0 (pixel_clk),
        .locked (pll_locked)
    );
    
    // Reset the timing generator only after PLL is locked
    wire rst_n = rst_n_in & pll_locked;
    
    timing timing_inst (
        .pixel_clk (pixel_clk),
        .rst_n (rst_n),
        .hsync (hsync),
        .vsync (vsync),
        .visible (visible),
        .pixel_x (pixel_x),
        .pixel_y (pixel_y)
    );
    
    text_renderer renderer_inst (
        .pixel_clk (pixel_clk),
        .pixel_x (pixel_x),
        .pixel_y (pixel_y),
        .visible (visible),
        .r (r),
        .g (g),
        .b (b)
    );
    
    assign led1 = pll_locked;

endmodule