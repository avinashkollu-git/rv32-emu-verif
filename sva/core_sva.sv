// core_sva.sv : white-box assertions and cover points for riscv_core.
//
//   Bound into every riscv_core instance (see the bind at the bottom), so the
//   RTL stays untouched. The assertions restate the pipeline rules from the
//   spec side, not by copying the RTL equations:
//     - a taken redirect squashes the two younger instructions (flush)
//     - a load-use stall freezes PC and IF/ID and sends a bubble into EX
//     - a stall only happens when the ID instruction really reads the loaded
//       register (otherwise it is a wasted cycle)
//     - an EX operand that matches an older in-flight write gets the newest
//       value (forwarding priority), and never a load's address
//   The cover points feed `make cov` (Verilator --coverage-user).
`timescale 1ns / 1ps

module core_sva (
    input logic        clk,
    input logic        rst_n,
    input logic        stall,
    input logic        pcsrc,
    input logic [31:0] pc,
    input logic [31:0] ifid_instr,
    input logic        ifid_valid,
    input logic        idex_valid,
    input logic [31:0] idex_instr,
    input logic [4:0]  idex_rs1,
    input logic [4:0]  idex_rs2,
    input logic        idex_mem_read,
    input logic [4:0]  idex_rd,
    input logic        idex_branch,
    input logic        idex_jump,
    input logic        idex_jalr,
    input logic        idex_alu_a_pc,
    input logic        exmem_reg_write,
    input logic        exmem_mem_read,
    input logic        exmem_mem_write,
    input logic [4:0]  exmem_rd,
    input logic [31:0] exmem_alu,
    input logic        wb_reg_write,
    input logic [4:0]  wb_rd,
    input logic [31:0] wb_data,
    input logic [31:0] fwd_rs1,
    input logic [31:0] fwd_rs2,
    input logic        branch_taken
);
    // Which source registers an instruction really reads (RV32I formats).
    function automatic logic uses_rs1(logic [31:0] i);
        return !(i[6:0] inside {7'b0110111, 7'b0010111, 7'b1101111});   // LUI, AUIPC, JAL
    endfunction
    function automatic logic uses_rs2(logic [31:0] i);
        return i[6:0] inside {7'b0110011, 7'b0100011, 7'b1100011};      // R-type, store, branch
    endfunction

    wire ex_rs1 = idex_valid && uses_rs1(idex_instr) && !idex_alu_a_pc && idex_rs1 != 5'd0;
    wire ex_rs2 = idex_valid && uses_rs2(idex_instr) && idex_rs2 != 5'd0;
    wire hit1_mem = exmem_reg_write && exmem_rd == idex_rs1;
    wire hit2_mem = exmem_reg_write && exmem_rd == idex_rs2;
    wire hit1_wb  = wb_reg_write && wb_rd == idex_rs1;
    wire hit2_wb  = wb_reg_write && wb_rd == idex_rs2;

    default clocking @(posedge clk); endclocking
    default disable iff (!rst_n);

    // ---- flush ----
    a_flush_ifid: assert property (pcsrc |=> !ifid_valid);
    a_flush_idex: assert property (pcsrc |=> !idex_valid);

    // ---- load-use stall ----
    a_stall_pc_hold:   assert property (stall && !pcsrc |=> pc == $past(pc));
    a_stall_ifid_hold: assert property (stall && !pcsrc |=> ifid_instr == $past(ifid_instr));
    a_stall_bubble:    assert property (stall |=> !idex_valid);
    a_stall_needed:    assert property (stall |-> ifid_valid &&
                           ((uses_rs1(ifid_instr) && ifid_instr[19:15] == idex_rd) ||
                            (uses_rs2(ifid_instr) && ifid_instr[24:20] == idex_rd)));

    // ---- forwarding ----
    a_fwd1_mem: assert property (ex_rs1 && hit1_mem |-> fwd_rs1 == exmem_alu);
    a_fwd2_mem: assert property (ex_rs2 && hit2_mem |-> fwd_rs2 == exmem_alu);
    a_fwd1_wb:  assert property (ex_rs1 && !hit1_mem && hit1_wb |-> fwd_rs1 == wb_data);
    a_fwd2_wb:  assert property (ex_rs2 && !hit2_mem && hit2_wb |-> fwd_rs2 == wb_data);
    // a load's result is not ready in EX/MEM: the stall must prevent this case
    a_no_load_fwd: assert property (!(exmem_mem_read && ((ex_rs1 && hit1_mem) || (ex_rs2 && hit2_mem))));

    // ---- pc ----
    a_pc_aligned: assert property (pc[1:0] == 2'b00);

    // ---- coverage: the hazard scenarios the tests are meant to reach ----
    c_stall:            cover property (stall);
    c_stall_rs2:        cover property (stall && uses_rs2(ifid_instr) && ifid_instr[24:20] == idex_rd);
    c_stall_store_data: cover property (stall && ifid_instr[6:0] == 7'b0100011 && ifid_instr[24:20] == idex_rd);
    c_stall_branch:     cover property (stall && ifid_instr[6:0] == 7'b1100011);
    c_stall_jalr:       cover property (stall && ifid_instr[6:0] == 7'b1100111);
    c_fwd1_mem:         cover property (ex_rs1 && hit1_mem);
    c_fwd2_mem:         cover property (ex_rs2 && hit2_mem);
    c_fwd1_wb:          cover property (ex_rs1 && !hit1_mem && hit1_wb);
    c_fwd2_wb:          cover property (ex_rs2 && !hit2_mem && hit2_wb);
    c_fwd_both_mem:     cover property (ex_rs1 && hit1_mem && ex_rs2 && hit2_mem);
    c_fwd_store_data:   cover property (ex_rs2 && idex_instr[6:0] == 7'b0100011 && (hit2_mem || hit2_wb));
    c_fwd_branch:       cover property (idex_branch && ex_rs1 && (hit1_mem || hit1_wb));
    c_fwd_jalr:         cover property (idex_jalr && ex_rs1 && (hit1_mem || hit1_wb));
    c_branch_taken:     cover property (branch_taken);
    c_branch_not_taken: cover property (idex_valid && idex_branch && !branch_taken);
    c_jal:              cover property (idex_jump && !idex_jalr);
    c_jalr:             cover property (idex_jalr);
    // load at a branch target, used by the next instruction. The stall can
    // only come 3 cycles after the redirect: at +2 the EX stage still holds
    // the bubble from the flush, so a "##2 stall" cover would be unreachable.
    c_load_at_target:   cover property (pcsrc ##3 stall);
    c_back2back_taken:  cover property (pcsrc ##3 pcsrc);
    c_store_load_raw:   cover property (exmem_mem_write ##1 exmem_mem_read);
endmodule

bind riscv_core core_sva u_sva (
    .clk(clk), .rst_n(rst_n), .stall(stall), .pcsrc(pcsrc), .pc(pc),
    .ifid_instr(ifid_instr), .ifid_valid(ifid_valid),
    .idex_valid(idex_valid), .idex_instr(idex_instr),
    .idex_rs1(idex_rs1), .idex_rs2(idex_rs2), .idex_mem_read(idex_mem_read),
    .idex_rd(idex_rd), .idex_branch(idex_branch), .idex_jump(idex_jump),
    .idex_jalr(idex_jalr), .idex_alu_a_pc(idex_alu_a_pc),
    .exmem_reg_write(exmem_reg_write), .exmem_mem_read(exmem_mem_read),
    .exmem_mem_write(exmem_mem_write), .exmem_rd(exmem_rd), .exmem_alu(exmem_alu),
    .wb_reg_write(wb_reg_write), .wb_rd(wb_rd), .wb_data(wb_data),
    .fwd_rs1(fwd_rs1), .fwd_rs2(fwd_rs2), .branch_taken(branch_taken)
);
