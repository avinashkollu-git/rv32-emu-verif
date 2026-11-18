// -----------------------------------------------------------------------------
// rv_pkg.sv : system-level UVM environment for the RV32I core (HVL side).
//
//   rv_program_seq --(rv_instr_item)--> rv_driver --bfm.load_word/start--> core
//                                           |
//                                           +--ap (program)--> scoreboard --DPI--> C model
//   core --retire msg--> bfm.get_retire --> rv_commit_monitor --ap--> scoreboard
//
//   The scoreboard steps the C reference model once per retired instruction
//   and compares pc, instruction, rd, rd write data, and store address/data.
//   The test ends when the halt instruction (jal x0, 0) retires, then reads
//   the HDL-side checker status (errors + pipeline event counters).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

package rv_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"
    import rv_types_pkg::*;

    localparam int IMEM_WORDS = 256;      // must match riscv_core
    localparam int DMEM_WORDS = 256;
    localparam logic [31:0] HALT_INSN = 32'h0000_006f;   // jal x0, 0

    // C reference model (hvl/dpi/rv32i_iss.c)
    import "DPI-C" function void rm_reset(int iwords, int dwords);
    import "DPI-C" function void rm_load(int word_addr, int data);
    import "DPI-C" function int  rm_step(output int pc, output int insn,
                                         output int rd_we, output int rd,
                                         output int rd_wdata, output int mem_we,
                                         output int mem_addr, output int mem_wdata);

    // -------------------------------------------------------------------------
    // Items
    // -------------------------------------------------------------------------
    typedef enum { LOAD, START } instr_kind_e;

    class rv_instr_item extends uvm_sequence_item;
        instr_kind_e kind = LOAD;
        bit [31:0]   addr;    // word address
        bit [31:0]   data;    // instruction word
        `uvm_object_utils(rv_instr_item)
        function new(string name = "rv_instr_item");
            super.new(name);
        endfunction
    endclass

    class rv_retire_item extends uvm_sequence_item;
        retire_t r;
        `uvm_object_utils(rv_retire_item)
        function new(string name = "rv_retire_item");
            super.new(name);
        endfunction
        function string convert2string();
            return $sformatf("pc=%08h insn=%08h rd_we=%0b x%0d=%08h mem_we=%0b [%08h]=%08h @%0d",
                             r.pc, r.insn, r.rd_we, r.rd, r.rd_wdata, r.mem_we,
                             r.mem_addr, r.mem_wdata, r.cycle);
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Instruction-stream sequence: streams a program image (+PROGRAM=<file.hex>,
    // written by tools/rvgen.py or tools/assemble.py) word by word, then START.
    // -------------------------------------------------------------------------
    class rv_program_seq extends uvm_sequence #(rv_instr_item);
        `uvm_object_utils(rv_program_seq)
        string path;
        function new(string name = "rv_program_seq");
            super.new(name);
        endfunction

        task body();
            int fd, n = 0;
            bit [31:0] w;
            rv_instr_item it;
            fd = $fopen(path, "r");
            if (fd == 0) `uvm_fatal("SEQ", {"cannot open program ", path})
            while ($fscanf(fd, "%h", w) == 1) begin
                if (n >= IMEM_WORDS) `uvm_fatal("SEQ", "program larger than IMEM")
                it = rv_instr_item::type_id::create("it");
                start_item(it);
                it.kind = LOAD; it.addr = n; it.data = w;
                finish_item(it);
                n++;
            end
            $fclose(fd);
            it = rv_instr_item::type_id::create("start");
            start_item(it);
            it.kind = START;
            finish_item(it);
            `uvm_info("SEQ", $sformatf("loaded %0d words from %s", n, path), UVM_LOW)
        endtask
    endclass

    typedef uvm_sequencer #(rv_instr_item) rv_sequencer;

    // -------------------------------------------------------------------------
    // Driver: one BFM call per item. Also broadcasts each loaded word so the
    // scoreboard can load the same program into the C model.
    // -------------------------------------------------------------------------
    class rv_driver extends uvm_driver #(rv_instr_item);
        `uvm_component_utils(rv_driver)
        virtual rv_bfm bfm;
        uvm_analysis_port #(rv_instr_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db #(virtual rv_bfm)::get(this, "", "bfm", bfm))
                `uvm_fatal("DRV", "bfm not set")
        endfunction

        task run_phase(uvm_phase phase);
            bfm.wait_reset_done();
            forever begin
                seq_item_port.get_next_item(req);
                if (req.kind == LOAD) bfm.load_word(req.addr, req.data);
                else                  bfm.start();
                ap.write(req);
                seq_item_port.item_done();
            end
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Commit monitor: one transaction per retired instruction.
    // -------------------------------------------------------------------------
    class rv_commit_monitor extends uvm_monitor;
        `uvm_component_utils(rv_commit_monitor)
        virtual rv_bfm bfm;
        uvm_analysis_port #(rv_retire_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            if (!uvm_config_db #(virtual rv_bfm)::get(this, "", "bfm", bfm))
                `uvm_fatal("MON", "bfm not set")
        endfunction

        task run_phase(uvm_phase phase);
            rv_retire_item t;
            forever begin
                t = rv_retire_item::type_id::create("t");
                bfm.get_retire(t.r);
                `uvm_info("COMMIT", t.convert2string(), UVM_HIGH)
                ap.write(t);
            end
        endtask
    endclass

    class rv_agent extends uvm_agent;
        `uvm_component_utils(rv_agent)
        rv_sequencer      sqr;
        rv_driver         drv;
        rv_commit_monitor mon;
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        function void build_phase(uvm_phase phase);
            sqr = rv_sequencer::type_id::create("sqr", this);
            drv = rv_driver::type_id::create("drv", this);
            mon = rv_commit_monitor::type_id::create("mon", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Scoreboard: lock-step compare against the C model through DPI.
    // -------------------------------------------------------------------------
    `uvm_analysis_imp_decl(_prog)
    `uvm_analysis_imp_decl(_ret)

    class rv_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(rv_scoreboard)
        uvm_analysis_imp_prog #(rv_instr_item,  rv_scoreboard) prog_imp;
        uvm_analysis_imp_ret  #(rv_retire_item, rv_scoreboard) ret_imp;

        int unsigned n_checked = 0;
        int unsigned n_errors  = 0;
        uvm_event    halted;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            prog_imp = new("prog_imp", this);
            ret_imp  = new("ret_imp", this);
            halted   = new("halted");
            rm_reset(IMEM_WORDS, DMEM_WORDS);
        endfunction

        function void write_prog(rv_instr_item it);
            if (it.kind == LOAD) rm_load(it.addr, it.data);
        endfunction

        // Report one field mismatch. The message starts with a fixed
        // "MISMATCH <field>" tag so the regression script can group failures.
        function void fail(string field, retire_t r, int unsigned got, int unsigned exp);
            n_errors++;
            `uvm_error("SCB", $sformatf("MISMATCH %s: pc=%08h insn=%08h got=%08h exp=%08h",
                                        field, r.pc, r.insn, got, exp))
        endfunction

        function void write_ret(rv_retire_item t);
            int pc, insn, rd_we, rd, wd, mwe, ma, mwd, rc;
            retire_t r = t.r;
            if (halted.is_on()) return;           // ignore the halt loop
            rc = rm_step(pc, insn, rd_we, rd, wd, mwe, ma, mwd);
            n_checked++;
            if (rc != 0)
                `uvm_error("SCB", $sformatf("MODEL rc=%0d (1=illegal 2=misaligned) at pc=%08h insn=%08h",
                                            rc, pc, insn))
            if (r.pc   !== pc)        fail("pc",    r, r.pc, pc);
            else if (r.insn !== insn) fail("insn",  r, r.insn, insn);
            else if (r.rd_we !== rd_we[0]) fail("rd_we", r, r.rd_we, rd_we);
            else if (rd_we && r.rd !== rd) fail("rd", r, r.rd, rd);
            else if (rd_we && r.rd_wdata !== wd) fail("rd_wdata", r, r.rd_wdata, wd);
            else if (r.mem_we !== mwe[0]) fail("mem_we", r, r.mem_we, mwe);
            else if (mwe && r.mem_addr  !== ma)  fail("mem_addr",  r, r.mem_addr, ma);
            else if (mwe && r.mem_wdata !== mwd) fail("mem_wdata", r, r.mem_wdata, mwd);
            if (r.insn === HALT_INSN) halted.trigger();
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SCB", $sformatf("checked=%0d mismatches=%0d", n_checked, n_errors), UVM_LOW)
        endfunction
    endclass

    class rv_env extends uvm_env;
        `uvm_component_utils(rv_env)
        rv_agent      agent;
        rv_scoreboard scb;
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        function void build_phase(uvm_phase phase);
            agent = rv_agent::type_id::create("agent", this);
            scb   = rv_scoreboard::type_id::create("scb", this);
        endfunction
        function void connect_phase(uvm_phase phase);
            agent.drv.ap.connect(scb.prog_imp);
            agent.mon.ap.connect(scb.ret_imp);
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Test: run one program until it halts (or times out), then check the
    // HDL-side checker. Plusargs: +PROGRAM=<hex> [+MAX_CYCLES=<n>]
    // -------------------------------------------------------------------------
    class rv_program_test extends uvm_test;
        `uvm_component_utils(rv_program_test)
        rv_env env;
        status_t st;
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        function void build_phase(uvm_phase phase);
            env = rv_env::type_id::create("env", this);
        endfunction

        task run_phase(uvm_phase phase);
            rv_program_seq seq = rv_program_seq::type_id::create("seq");
            int max_cycles = 20000;
            phase.raise_objection(this);
            if (!$value$plusargs("PROGRAM=%s", seq.path)) `uvm_fatal("TEST", "+PROGRAM=<file.hex> required")
            void'($value$plusargs("MAX_CYCLES=%d", max_cycles));
            seq.start(env.agent.sqr);
            fork
                env.scb.halted.wait_on();
                begin
                    repeat (max_cycles) env.agent.drv.bfm.get_status(st);
                    `uvm_error("TIMEOUT", $sformatf("halt not reached in %0d cycles", max_cycles))
                end
            join_any
            disable fork;
            env.agent.drv.bfm.get_status(st);
            if (st.err)
                `uvm_error("HWCHK", $sformatf("HDL checker error code %0d at pc=%08h", st.code, st.pc))
            phase.drop_objection(this);
        endtask

        function void report_phase(uvm_phase phase);
            uvm_report_server rs = uvm_report_server::get_server();
            int errs = rs.get_severity_count(UVM_ERROR) + rs.get_severity_count(UVM_FATAL);
            if (env.scb.n_checked == 0) errs++;
            $display("STATS retired=%0d stalls=%0d flushes=%0d", env.scb.n_checked, st.n_stall, st.n_flush);
            $display("RESULT: %s", errs == 0 ? "PASS" : "FAIL");
        endfunction
    endclass

endpackage
