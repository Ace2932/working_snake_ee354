`timescale 1ns / 1ps

module merged_top(
    input CLK100MHZ,
    input BtnC,
    input rst,

    // Accelerometer SPI signals
    input ACL_MISO,
    output ACL_MOSI,
    output ACL_SCLK,
    output ACL_CSN,

    // VGA signals
    output hSync,
    output vSync,
    output [3:0] vgaR,
    output [3:0] vgaG,
    output [3:0] vgaB,

    // Seven Segment Display
    output [6:0] SEG,
    output DP,
    output [7:0] AN,

    // Optional LED Debug (X, Y, Z bits)
    output [14:0] LED
);

    // Accelerometer Data (X[14:10], Y[9:5], Z[4:0])
    wire [14:0] acl_data;

    // Clock generation
    wire clk_4MHz;
    iclk_gen clkgen (
        .CLK100MHZ(CLK100MHZ),
        .clk_4MHz(clk_4MHz)
    );

    // SPI Master to read accelerometer
    spi_master spi (
        .iclk(clk_4MHz),
        .miso(ACL_MISO),
        .mosi(ACL_MOSI),
        .sclk(ACL_SCLK),
        .cs(ACL_CSN),
        .acl_data(acl_data)
    );

    // Display accelerometer data on 7-segment display
    seg7_control sseg (
        .CLK100MHZ(CLK100MHZ),
        .acl_data(acl_data),
        .seg(SEG),
        .dp(DP),
        .an(AN)
    );

    // VGA Timing Generation
    wire bright;
    wire [9:0] hCount, vCount;
    display_controller vga_disp (
        .clk(CLK100MHZ),
        .hSync(hSync),
        .vSync(vSync),
        .bright(bright),
        .hCount(hCount),
        .vCount(vCount)
    );

    // RGB color output
    wire [11:0] rgb;

    snake_game game (
        .clk(CLK100MHZ),
        .bright(bright),
        .rst(rst),
        .button(BtnC),
        .acl_data(acl_data),
        .hCount(hCount),
        .vCount(vCount),
        .rgb(rgb)
    );

    // VGA color mapping
    assign vgaR = rgb[11:8];
    assign vgaG = rgb[7:4];
    assign vgaB = rgb[3:0];

    // LED Debugging
    assign LED = acl_data;

endmodule

