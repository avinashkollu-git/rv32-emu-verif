// rv_retire_xactor.v : HDL-side retire (commit) transactor (synthesizable).
//
//   Registers the core's retire trace into one message per retired
//   instruction and stamps it with the cycle number. The HVL commit monitor
//   only ever reads these messages; it never samples pipeline internals. On an
//   emulator this is the output-pipe endpoint: one transaction per retirement
//   crosses to the host instead of every signal on every clock.
`timescale 1ns / 1ps
`default_nettype none

module rv_retire_xactor (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rvfi_valid,
    input  wire [31:0] rvfi_pc,
    input  wire [31:0] rvfi_insn,
    input  wire        rvfi_rd_we,
    input  wire [4:0]  rvfi_rd,
    input  wire [31:0] rvfi_rd_wdata,
    input  wire        rvfi_mem_we,
    input  wire [31:0] rvfi_mem_addr,
    input  wire [31:0] rvfi_mem_wdata,
    output reg         ret_valid,
    output reg  [31:0] ret_pc,
    output reg  [31:0] ret_insn,
    output reg         ret_rd_we,
    output reg  [4:0]  ret_rd,
    output reg  [31:0] ret_rd_wdata,
    output reg         ret_mem_we,
    output reg  [31:0] ret_mem_addr,
    output reg  [31:0] ret_mem_wdata,
    output reg  [31:0] ret_cycle
);
    reg [31:0] cycle;
    always @(posedge clk) begin
        if (!rst_n) begin
            cycle     <= 32'd0;
            ret_valid <= 1'b0;
        end else begin
            cycle     <= cycle + 32'd1;
            ret_valid <= rvfi_valid;
        end
        // payload needs no reset: it is only read when ret_valid is set
        ret_pc        <= rvfi_pc;
        ret_insn      <= rvfi_insn;
        ret_rd_we     <= rvfi_rd_we;
        ret_rd        <= rvfi_rd;
        ret_rd_wdata  <= rvfi_rd_wdata;
        ret_mem_we    <= rvfi_mem_we;
        ret_mem_addr  <= rvfi_mem_addr;
        ret_mem_wdata <= rvfi_mem_wdata;
        ret_cycle     <= cycle;
    end
endmodule

`default_nettype wire
