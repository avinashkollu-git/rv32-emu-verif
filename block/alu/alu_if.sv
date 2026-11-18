// alu_if.sv : pin interface for the block-level ALU bench.
//   The ALU is combinational, so the bench supplies a clock only to pace
//   transactions: the driver applies operands on the falling edge and the
//   monitor samples operands + result on the rising edge, when they are stable.
`timescale 1ns / 1ps

interface alu_if (input logic clk);
    logic [31:0] a, b, y;
    logic [3:0]  ctrl;
    logic        zero;
endinterface
