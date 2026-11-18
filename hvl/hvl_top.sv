// hvl_top.sv : HVL top. Only starts UVM; it has no signals of its own.
`timescale 1ns / 1ps

module hvl_top;
    import uvm_pkg::*;
    import rv_pkg::*;
    initial run_test();
endmodule
