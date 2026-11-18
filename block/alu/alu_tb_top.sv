// alu_tb_top.sv : block-level UVM top for rtl/alu.v.
`timescale 1ns / 1ps

module alu_tb_top;
    import uvm_pkg::*;
    import alu_pkg::*;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    alu_if vif (.clk(clk));
    alu dut (.a(vif.a), .b(vif.b), .ctrl(vif.ctrl), .y(vif.y), .zero(vif.zero));

    initial begin
        uvm_config_db #(virtual alu_if)::set(null, "uvm_test_top.*", "vif", vif);
        run_test("alu_test");
    end
endmodule
