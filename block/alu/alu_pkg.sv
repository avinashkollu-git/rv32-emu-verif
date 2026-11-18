// -----------------------------------------------------------------------------
// alu_pkg.sv : block-level UVM environment for the core's ALU.
//
//   Two sequences: an exhaustive corner sequence (every op x every pair of
//   corner operands) and a constrained-random sequence. The scoreboard has
//   its own reference function written from the RV32I spec, and keeps a small
//   hit table per op so the test fails if any legal op was never checked.
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

package alu_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // ALU control codes (rtl/riscv_defs.vh)
    typedef enum logic [3:0] {
        ADD = 0, SUB = 1, AND = 2, OR = 3, XOR = 4, SLL = 5, SRL = 6, SRA = 7,
        SLT = 8, SLTU = 9, PASSB = 10
    } alu_op_e;
    localparam int NUM_OPS = 11;

    localparam logic [31:0] CORNERS[6] = '{32'h0, 32'h1, 32'h1f, 32'h7fff_ffff,
                                           32'h8000_0000, 32'hffff_ffff};

    class alu_item extends uvm_sequence_item;
        rand logic [3:0]  ctrl;
        rand logic [31:0] a, b;
        logic [31:0]      y;      // filled in by the monitor
        logic             zero;

        // mostly legal ops, sometimes an unused code (the ALU must output 0)
        constraint c_ctrl { ctrl dist { [0:10] :/ 95, [11:15] :/ 5 }; }
        // operands: corner values 50% of the time, any value otherwise
        constraint c_a { a dist { 32'h0 := 1, 32'h1 := 1, 32'h7fff_ffff := 1,
                                  32'h8000_0000 := 1, 32'hffff_ffff := 1, [0:32'hffff_ffff] :/ 5 }; }
        constraint c_b { b dist { 32'h0 := 1, 32'h1f := 1, 32'h20 := 1,
                                  32'h8000_0000 := 1, 32'hffff_ffff := 1, [0:32'hffff_ffff] :/ 5 }; }

        `uvm_object_utils(alu_item)
        function new(string name = "alu_item");
            super.new(name);
        endfunction
        function string convert2string();
            return $sformatf("ctrl=%0d a=%08h b=%08h y=%08h zero=%0b", ctrl, a, b, y, zero);
        endfunction
    endclass

    class alu_rand_seq extends uvm_sequence #(alu_item);
        `uvm_object_utils(alu_rand_seq)
        int unsigned n = 3000;
        function new(string name = "alu_rand_seq");
            super.new(name);
        endfunction
        task body();
            repeat (n) begin
                alu_item it = alu_item::type_id::create("it");
                start_item(it);
                if (!it.randomize()) `uvm_fatal("SEQ", "randomize failed")
                finish_item(it);
            end
        endtask
    endclass

    class alu_corner_seq extends uvm_sequence #(alu_item);
        `uvm_object_utils(alu_corner_seq)
        function new(string name = "alu_corner_seq");
            super.new(name);
        endfunction
        task body();
            for (int op = 0; op < 16; op++)
                foreach (CORNERS[i])
                    foreach (CORNERS[j]) begin
                        alu_item it = alu_item::type_id::create("it");
                        start_item(it);
                        it.ctrl = op; it.a = CORNERS[i]; it.b = CORNERS[j];
                        finish_item(it);
                    end
        endtask
    endclass

    typedef uvm_sequencer #(alu_item) alu_sequencer;

    class alu_driver extends uvm_driver #(alu_item);
        `uvm_component_utils(alu_driver)
        virtual alu_if vif;
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        function void build_phase(uvm_phase phase);
            if (!uvm_config_db #(virtual alu_if)::get(this, "", "vif", vif))
                `uvm_fatal("DRV", "vif not set")
        endfunction
        task run_phase(uvm_phase phase);
            forever begin
                seq_item_port.get_next_item(req);
                @(negedge vif.clk);
                vif.ctrl = req.ctrl; vif.a = req.a; vif.b = req.b;
                seq_item_port.item_done();
            end
        endtask
    endclass

    class alu_monitor extends uvm_monitor;
        `uvm_component_utils(alu_monitor)
        virtual alu_if vif;
        uvm_analysis_port #(alu_item) ap;
        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction
        function void build_phase(uvm_phase phase);
            if (!uvm_config_db #(virtual alu_if)::get(this, "", "vif", vif))
                `uvm_fatal("MON", "vif not set")
        endfunction
        task run_phase(uvm_phase phase);
            @(negedge vif.clk);   // skip the first edge, before any operands are driven
            forever begin
                alu_item t;
                @(posedge vif.clk);
                t = alu_item::type_id::create("t");
                t.ctrl = vif.ctrl; t.a = vif.a; t.b = vif.b; t.y = vif.y; t.zero = vif.zero;
                ap.write(t);
            end
        endtask
    endclass

    class alu_agent extends uvm_agent;
        `uvm_component_utils(alu_agent)
        alu_sequencer sqr;
        alu_driver    drv;
        alu_monitor   mon;
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        function void build_phase(uvm_phase phase);
            sqr = alu_sequencer::type_id::create("sqr", this);
            drv = alu_driver::type_id::create("drv", this);
            mon = alu_monitor::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    class alu_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(alu_scoreboard)
        uvm_analysis_imp #(alu_item, alu_scoreboard) imp;
        int unsigned checks = 0, errors = 0;
        int unsigned op_hits[16];

        function new(string name, uvm_component parent);
            super.new(name, parent);
            imp = new("imp", this);
        endfunction

        // Reference written from the RV32I spec, not from the RTL.
        static function logic [31:0] ref_y(logic [3:0] ctrl, logic [31:0] a, logic [31:0] b);
            case (ctrl)
                ADD:   return a + b;
                SUB:   return a - b;
                AND:   return a & b;
                OR:    return a | b;
                XOR:   return a ^ b;
                SLL:   return a << b[4:0];
                SRL:   return a >> b[4:0];
                SRA:   return $unsigned($signed(a) >>> b[4:0]);
                SLT:   return {31'd0, $signed(a) < $signed(b)};
                SLTU:  return {31'd0, a < b};
                PASSB: return b;
                default: return 32'd0;
            endcase
        endfunction

        function void write(alu_item t);
            logic [31:0] exp = ref_y(t.ctrl, t.a, t.b);
            checks++;
            op_hits[t.ctrl]++;
            if (t.y !== exp || t.zero !== (exp == 0)) begin
                errors++;
                `uvm_error("SCB", $sformatf("MISMATCH %s exp y=%08h", t.convert2string(), exp))
            end
        endfunction

        function void report_phase(uvm_phase phase);
            string s = "";
            for (int op = 0; op < NUM_OPS; op++) begin
                s = {s, $sformatf(" %s=%0d", alu_op_e'(op), op_hits[op])};
                if (op_hits[op] == 0) `uvm_error("COV", $sformatf("op %s never checked", alu_op_e'(op)))
            end
            `uvm_info("SCB", $sformatf("checks=%0d errors=%0d op hits:%s", checks, errors, s), UVM_LOW)
        endfunction
    endclass

    class alu_env extends uvm_env;
        `uvm_component_utils(alu_env)
        alu_agent      agent;
        alu_scoreboard scb;
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        function void build_phase(uvm_phase phase);
            agent = alu_agent::type_id::create("agent", this);
            scb   = alu_scoreboard::type_id::create("scb", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            agent.mon.ap.connect(scb.imp);
        endfunction
    endclass

    class alu_test extends uvm_test;
        `uvm_component_utils(alu_test)
        alu_env env;
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        function void build_phase(uvm_phase phase);
            env = alu_env::type_id::create("env", this);
        endfunction
        task run_phase(uvm_phase phase);
            alu_corner_seq corner = alu_corner_seq::type_id::create("corner");
            alu_rand_seq   rnd    = alu_rand_seq::type_id::create("rnd");
            phase.raise_objection(this);
            corner.start(env.agent.sqr);
            rnd.start(env.agent.sqr);
            @(posedge env.agent.drv.vif.clk);   // let the monitor see the last item
            @(posedge env.agent.drv.vif.clk);
            phase.drop_objection(this);
        endtask
        function void report_phase(uvm_phase phase);
            uvm_report_server rs = uvm_report_server::get_server();
            int errs = rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL);
            $display("STATS retired=%0d", env.scb.checks);
            $display("RESULT: %s", errs == 0 ? "PASS" : "FAIL");
        endfunction
    endclass

endpackage
