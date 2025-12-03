`timescale 1ns / 1ps
// Created by David J. Marion
// Date 7.22.2022
// For NexysA7 Accelerometer Reading

// Outputs accelerometer reading into SSD.

module seg7_control(
    input CLK100MHZ,
    input [15:0] score,
    output reg [6:0] seg,
    output reg dp,
    output reg [7:0] an
    );
    
    // Take sign bits out of accelerometer data
    function [6:0] encode_digit;
        input [3:0] value;
        begin
            case (value)
                4'd0: encode_digit = ZERO;
                4'd1: encode_digit = ONE;
                4'd2: encode_digit = TWO;
                4'd3: encode_digit = THREE;
                4'd4: encode_digit = FOUR;
                4'd5: encode_digit = FIVE;
                4'd6: encode_digit = SIX;
                4'd7: encode_digit = SEVEN;
                4'd8: encode_digit = EIGHT;
                4'd9: encode_digit = NINE;
                default: encode_digit = NULL;
            endcase
        end
    endfunction

    wire [3:0] digit0 = score[3:0];
    wire [3:0] digit1 = score[7:4];
    wire [3:0] digit2 = score[11:8];
    wire [3:0] digit3 = score[15:12];

    wire show_digit1 = (digit1 != 4'd0) || (digit2 != 4'd0) || (digit3 != 4'd0);
    wire show_digit2 = (digit2 != 4'd0) || (digit3 != 4'd0);
    wire show_digit3 = (digit3 != 4'd0);
    
    // Parameters for segment patterns
    parameter ZERO  = 7'b000_0001;  // 0
    parameter ONE   = 7'b100_1111;  // 1
    parameter TWO   = 7'b001_0010;  // 2 
    parameter THREE = 7'b000_0110;  // 3
    parameter FOUR  = 7'b100_1100;  // 4
    parameter FIVE  = 7'b010_0100;  // 5
    parameter SIX   = 7'b010_0000;  // 6
    parameter SEVEN = 7'b000_1111;  // 7
    parameter EIGHT = 7'b000_0000;  // 8
    parameter NINE  = 7'b000_0100;  // 9
    parameter NULL  = 7'b111_1111;  // all OFF
    
    // To select each anode in turn
    reg [2:0] anode_select = 3'b0;     // 3 bit counter for selecting each of 8 anodes
    reg [16:0] anode_timer = 17'b0;    // counter for anode refresh
    
    // Logic for controlling anode select and anode timer
    always @(posedge CLK100MHZ) begin               // 1ms x 8 displays = 8ms refresh period                             
        if(anode_timer == 99_999) begin             // The period of 100MHz clock is 10ns (1/100,000,000 seconds)
            anode_timer <= 0;                       // 10ns x 100,000 = 1ms
            anode_select <=  anode_select + 1;
        end
        else
            anode_timer <=  anode_timer + 1;
    end
    
    // Logic for driving the 8 bit anode output based on anode select
    always @(anode_select) begin
        case(anode_select) 
            3'b000 : an = 8'b1111_1110;   
            3'b001 : an = 8'b1111_1101;  
            3'b010 : an = 8'b1111_1011;  
            3'b011 : an = 8'b1111_0111;
            3'b100 : an = 8'b1110_1111;   
            3'b101 : an = 8'b1101_1111;  
            3'b110 : an = 8'b1011_1111;  
            3'b111 : an = 8'b0111_1111; 
        endcase
    end
    
    // Logic for driving segments based on which anode is selected
    always @*
        case(anode_select)
            3'b000: seg = encode_digit(digit0);
            3'b001: seg = show_digit1 ? encode_digit(digit1) : NULL;
            3'b010: seg = show_digit2 ? encode_digit(digit2) : NULL;
            3'b011: seg = show_digit3 ? encode_digit(digit3) : NULL;
            default: seg = NULL;
        endcase 
    
endmodule

