// rv_bfm.sv : the HDL/HVL boundary.
//
//   rv_types_pkg holds the message formats that cross the boundary.
//   rv_bfm is the bus-functional-model interface: it is instantiated in
//   hdl_top next to the synthesizable partition, and the HVL side reaches it
//   only through a virtual interface and only by calling its tasks
//   (load_word, start, get_retire, get_status). HVL classes never touch a
//   signal directly. That rule is what lets the same testbench move from a
//   simulator to an emulator: on Veloce/Palladium these tasks are compiled
//   into the emulator (XRTL) and each call is one host<->emulator message.
`timescale 1ns / 1ps

package rv_types_pkg;
    typedef struct packed {
        logic [31:0] pc;
        logic [31:0] insn;
        logic        rd_we;
        logic [4:0]  rd;
        logic [31:0] rd_wdata;
        logic        mem_we;
        logic [31:0] mem_addr;
        logic [31:0] mem_wdata;
        logic [31:0] cycle;
    } retire_t;

    typedef struct packed {
        logic        err;
        logic [3:0]  code;
        logic [31:0] pc;
        logic [31:0] n_retired;
        logic [31:0] n_stall;
        logic [31:0] n_flush;
    } status_t;
endpackage

interface rv_bfm (input logic clk, input logic rst_n);
    import rv_types_pkg::*;

    // to the HDL partition
    logic        ld_valid;
    logic [31:0] ld_addr;
    logic [31:0] ld_data;
    logic        go;
    // from the HDL partition
    retire_t     ret;
    logic        ret_valid;
    status_t     status;

    // The BFM drives and samples on the falling edge. The HDL partition is
    // purely posedge, so everything is stable half a cycle away from its
    // edges: no races, no clocking-block skew to reason about. (A clocking
    // block driven from inside interface tasks did not propagate its outputs
    // on Verilator 5.050, so this is also the portable choice.)

    // Idle values for the outputs; then wait for the system reset to finish.
    task automatic wait_reset_done();
        ld_valid = 1'b0;
        go       = 1'b0;
        do @(negedge clk); while (!rst_n);
    endtask

    // One program word into instruction memory (core is held in reset).
    task automatic load_word(input logic [31:0] word_addr, input logic [31:0] data);
        ld_valid = 1'b1;
        ld_addr  = word_addr;
        ld_data  = data;
        @(negedge clk);
        ld_valid = 1'b0;
    endtask

    // Release the core from reset; it starts fetching at pc 0.
    task automatic start();
        go = 1'b1;
        @(negedge clk);
        go = 1'b0;
    endtask

    // Block until the next retire message, then return it.
    task automatic get_retire(output retire_t r);
        do @(negedge clk); while (!ret_valid);
        r = ret;
    endtask

    task automatic get_status(output status_t s);
        @(negedge clk);
        s = status;
    endtask
endinterface
