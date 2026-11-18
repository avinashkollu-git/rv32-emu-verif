// rv_hdl_core.v : the complete synthesizable HDL partition.
//
//   core + load transactor + retire transactor + checker. Everything below
//   this module is plain synthesizable Verilog (no delays, no classes, no
//   $display), which is what an emulator compiler needs. `make synth` runs
//   yosys on this module to prove it. The HVL side talks to it only through
//   the ports below, via the BFM tasks in hvl/rv_bfm.sv.
`timescale 1ns / 1ps
`default_nettype none

module rv_hdl_core (
    input  wire        clk,
    input  wire        rst_n,
    // load messages in
    input  wire        ld_valid,
    input  wire [31:0] ld_addr,
    input  wire [31:0] ld_data,
    input  wire        go,
    // retire messages out
    output wire        ret_valid,
    output wire [31:0] ret_pc,
    output wire [31:0] ret_insn,
    output wire        ret_rd_we,
    output wire [4:0]  ret_rd,
    output wire [31:0] ret_rd_wdata,
    output wire        ret_mem_we,
    output wire [31:0] ret_mem_addr,
    output wire [31:0] ret_mem_wdata,
    output wire [31:0] ret_cycle,
    // checker status out
    output wire        chk_err,
    output wire [3:0]  chk_err_code,
    output wire [31:0] chk_err_pc,
    output wire [31:0] chk_n_retired,
    output wire [31:0] chk_n_stall,
    output wire [31:0] chk_n_flush
);
    wire        imem_we, core_rst_n;
    wire [31:0] imem_waddr, imem_wdata;
    wire        rvfi_valid, rvfi_rd_we, rvfi_mem_we, stall, flush;
    wire [31:0] rvfi_pc, rvfi_insn, rvfi_rd_wdata, rvfi_mem_addr, rvfi_mem_wdata;
    wire [4:0]  rvfi_rd;

    rv_load_xactor u_load (
        .clk(clk), .rst_n(rst_n),
        .ld_valid(ld_valid), .ld_addr(ld_addr), .ld_data(ld_data), .go(go),
        .imem_we(imem_we), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
        .core_rst_n(core_rst_n)
    );

    riscv_core u_core (
        .clk(clk), .rst_n(core_rst_n),
        .imem_we(imem_we), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
        .rvfi_valid(rvfi_valid), .rvfi_pc(rvfi_pc), .rvfi_insn(rvfi_insn),
        .rvfi_rd_we(rvfi_rd_we), .rvfi_rd(rvfi_rd), .rvfi_rd_wdata(rvfi_rd_wdata),
        .rvfi_mem_we(rvfi_mem_we), .rvfi_mem_addr(rvfi_mem_addr),
        .rvfi_mem_wdata(rvfi_mem_wdata),
        .dbg_stall(stall), .dbg_flush(flush)
    );

    rv_retire_xactor u_retire (
        .clk(clk), .rst_n(core_rst_n),
        .rvfi_valid(rvfi_valid), .rvfi_pc(rvfi_pc), .rvfi_insn(rvfi_insn),
        .rvfi_rd_we(rvfi_rd_we), .rvfi_rd(rvfi_rd), .rvfi_rd_wdata(rvfi_rd_wdata),
        .rvfi_mem_we(rvfi_mem_we), .rvfi_mem_addr(rvfi_mem_addr),
        .rvfi_mem_wdata(rvfi_mem_wdata),
        .ret_valid(ret_valid), .ret_pc(ret_pc), .ret_insn(ret_insn),
        .ret_rd_we(ret_rd_we), .ret_rd(ret_rd), .ret_rd_wdata(ret_rd_wdata),
        .ret_mem_we(ret_mem_we), .ret_mem_addr(ret_mem_addr),
        .ret_mem_wdata(ret_mem_wdata), .ret_cycle(ret_cycle)
    );

    rv_checker u_chk (
        .clk(clk), .rst_n(core_rst_n),
        .rvfi_valid(rvfi_valid), .rvfi_pc(rvfi_pc), .rvfi_insn(rvfi_insn),
        .rvfi_mem_we(rvfi_mem_we), .stall(stall), .flush(flush),
        .err(chk_err), .err_code(chk_err_code), .err_pc(chk_err_pc),
        .n_retired(chk_n_retired), .n_stall(chk_n_stall), .n_flush(chk_n_flush)
    );
endmodule

`default_nettype wire
