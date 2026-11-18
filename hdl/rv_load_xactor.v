// rv_load_xactor.v : HDL-side program-load transactor (synthesizable).
//
//   The HVL side sends one "load" message per instruction word and then one
//   "go" message. This block turns those messages into imem writes and holds
//   the core in reset until "go", so the program is in place before the first
//   fetch. On an emulator this is the input-pipe endpoint: the testbench never
//   wiggles core pins itself, it only sends transactions.
`timescale 1ns / 1ps
`default_nettype none

module rv_load_xactor (
    input  wire        clk,
    input  wire        rst_n,        // system reset
    // message from the HVL side
    input  wire        ld_valid,
    input  wire [31:0] ld_addr,      // word address
    input  wire [31:0] ld_data,
    input  wire        go,
    // to the core
    output reg         imem_we,
    output reg  [31:0] imem_waddr,
    output reg  [31:0] imem_wdata,
    output reg         core_rst_n
);
    always @(posedge clk) begin
        if (!rst_n) begin
            imem_we    <= 1'b0;
            imem_waddr <= 32'd0;
            imem_wdata <= 32'd0;
            core_rst_n <= 1'b0;
        end else begin
            imem_we    <= ld_valid;
            imem_waddr <= ld_addr;
            imem_wdata <= ld_data;
            if (go) core_rst_n <= 1'b1;   // stays released until the next system reset
        end
    end
endmodule

`default_nettype wire
