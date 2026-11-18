// rv_checker.v : synthesizable in-circuit checker for the retire stream.
//
//   Runs inside the HDL partition, so on an emulator these checks cost no
//   host round trips. It does not know the ISA results (that is the C model's
//   job on the HVL side); it checks structural rules that must hold for any
//   program, and keeps event counters that act as cheap hardware coverage:
//
//     err 1  retired pc not 4-byte aligned
//     err 2  control flow broken: a non-jump, non-branch instruction was not
//            followed by pc+4
//     err 3  store flag on a non-store, or missing on a store
//     err 4  hang: no instruction retired for HANG_CYCLES cycles while running
//
//   The first error is latched (code + pc) and stays until reset.
`timescale 1ns / 1ps
`default_nettype none

module rv_checker #(
    parameter integer HANG_CYCLES = 32
) (
    input  wire        clk,
    input  wire        rst_n,        // core reset (checker idles while the core is held)
    input  wire        rvfi_valid,
    input  wire [31:0] rvfi_pc,
    input  wire [31:0] rvfi_insn,
    input  wire        rvfi_mem_we,
    input  wire        stall,
    input  wire        flush,
    output reg         err,
    output reg  [3:0]  err_code,
    output reg  [31:0] err_pc,
    output reg  [31:0] n_retired,
    output reg  [31:0] n_stall,
    output reg  [31:0] n_flush
);
    wire [6:0] opc       = rvfi_insn[6:0];
    wire       is_store  = (opc == 7'b0100011);
    wire       is_ctrl   = (opc == 7'b1100011) || (opc == 7'b1101111) || (opc == 7'b1100111);

    reg        have_prev, prev_ctrl;
    reg [31:0] prev_pc;
    reg [7:0]  idle;

    reg [3:0]  code;     // error detected this cycle (0 = none)
    always @(*) begin
        code = 4'd0;
        if (rvfi_valid && rvfi_pc[1:0] != 2'b00)                     code = 4'd1;
        else if (rvfi_valid && have_prev && !prev_ctrl &&
                 rvfi_pc != prev_pc + 32'd4)                          code = 4'd2;
        else if (rvfi_valid && (rvfi_mem_we != is_store))             code = 4'd3;
        else if (idle == HANG_CYCLES[7:0])                            code = 4'd4;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            have_prev <= 1'b0; prev_ctrl <= 1'b0; prev_pc <= 32'd0; idle <= 8'd0;
            err <= 1'b0; err_code <= 4'd0; err_pc <= 32'd0;
            n_retired <= 32'd0; n_stall <= 32'd0; n_flush <= 32'd0;
        end else begin
            if (rvfi_valid) begin
                have_prev <= 1'b1;
                prev_ctrl <= is_ctrl;
                prev_pc   <= rvfi_pc;
                n_retired <= n_retired + 32'd1;
                idle      <= 8'd0;
            end else if (idle != HANG_CYCLES[7:0]) begin
                idle <= idle + 8'd1;
            end
            if (stall) n_stall <= n_stall + 32'd1;
            if (flush) n_flush <= n_flush + 32'd1;
            if (code != 4'd0 && !err) begin
                err <= 1'b1; err_code <= code; err_pc <= rvfi_pc;
            end
        end
    end
endmodule

`default_nettype wire
