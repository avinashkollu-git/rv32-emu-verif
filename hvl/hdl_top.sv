// hdl_top.sv : HDL top. Holds the clock, the system reset, the synthesizable
//   partition (rv_hdl_core) and the BFM interface. In an acceleration flow
//   everything here runs on the emulator; the clock generator below would be
//   replaced by the emulator's own clock.
`timescale 1ns / 1ps

module hdl_top;
    import uvm_pkg::*;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;
    initial begin
        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
    end

    rv_bfm bfm (.clk(clk), .rst_n(rst_n));

    rv_hdl_core u_hdl (
        .clk(clk), .rst_n(rst_n),
        .ld_valid(bfm.ld_valid), .ld_addr(bfm.ld_addr), .ld_data(bfm.ld_data), .go(bfm.go),
        .ret_valid(bfm.ret_valid),
        .ret_pc(bfm.ret.pc), .ret_insn(bfm.ret.insn),
        .ret_rd_we(bfm.ret.rd_we), .ret_rd(bfm.ret.rd), .ret_rd_wdata(bfm.ret.rd_wdata),
        .ret_mem_we(bfm.ret.mem_we), .ret_mem_addr(bfm.ret.mem_addr),
        .ret_mem_wdata(bfm.ret.mem_wdata), .ret_cycle(bfm.ret.cycle),
        .chk_err(bfm.status.err), .chk_err_code(bfm.status.code), .chk_err_pc(bfm.status.pc),
        .chk_n_retired(bfm.status.n_retired), .chk_n_stall(bfm.status.n_stall),
        .chk_n_flush(bfm.status.n_flush)
    );

    initial begin
        uvm_config_db #(virtual rv_bfm)::set(null, "uvm_test_top.*", "bfm", bfm);
        if ($test$plusargs("waves")) begin
            $dumpfile("waves.vcd");
            $dumpvars(0, hdl_top);
        end
    end
endmodule
