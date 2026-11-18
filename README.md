# rv32-emu-verif

Verification of my RV32I 5-stage pipelined core
([riscv-5stage-core](../hdl-portfolio/riscv-5stage-core)), built the way
emulation and acceleration teams structure a testbench:

- **UVM from scratch**, at two levels: a block-level ALU bench and a
  system-level core bench (instruction-stream sequence, commit monitor).
- **A C reference model through DPI-C.** Every retired instruction is compared
  on pc, instruction, rd, write data, and store address/data.
- **HDL/HVL split.** A synthesizable HDL partition (core, transactors, an
  in-circuit checker) is driven only through BFM task calls. Yosys proves that
  it synthesizes.
- **SVA bound to the core** for forwarding, load-use stall and flush, plus 20
  cover points.
- **A constrained-random program generator**, directed hazard tests, and a
  regression runner (1 worker by default, `JOBS=N` for parallel) with failure-signature triage, JUnit output and
  merged coverage.

It found two real bugs in the core. Both are fixed; see [BUGS.md](BUGS.md).

## Architecture

```
 HVL side (classes, untimed; runs on the host)            HDL side (synthesizable; would run on the emulator)
 ─────────────────────────────────────────────            ───────────────────────────────────────────────────
                                                           hdl_top
 hvl_top: run_test()                                       ├─ clock + system reset   (emulator clock in a real flow)
 rv_program_test                                           ├─ rv_bfm  (interface: load_word / start / get_retire / get_status)
 └─ rv_env                                                 └─ rv_hdl_core   <── yosys synth -top rv_hdl_core
    ├─ rv_agent                                               ├─ rv_load_xactor    load msgs -> imem writes, holds core reset until "go"
    │  ├─ rv_sequencer <── rv_program_seq (+PROGRAM=x.hex)    ├─ riscv_core        IF ID EX MEM WB + retire trace (rvfi_*)
    │  ├─ rv_driver ──────── bfm.load_word(), start() ──────► │    └─ core_sva (bind: assertions + cover points)
    │  └─ rv_commit_monitor ◄── bfm.get_retire() ◄──────────  ├─ rv_retire_xactor  one message per retired instruction (+cycle)
    └─ rv_scoreboard                                          └─ rv_checker        alignment, pc continuity, store flag,
          │  DPI-C: rm_reset / rm_load / rm_step                                   hang watchdog, stall/flush counters
          ▼
       rv32i_iss.c (C reference model)

 tools/rvgen.py (constrained random) ─┐
 tests/directed/*.asm ── assemble.py ─┴─► program.hex ─► +PROGRAM
 scripts/regress.py: tests x seeds (JOBS workers) ─► summary.md, junit.xml, signatures, rerun with waves, coverage
```

The rule that makes this "acceleration-ready": **HVL classes never touch a
signal.** They only call BFM tasks, and each call is one transaction. On
Veloce or Palladium the BFM tasks would be compiled into the emulator (XRTL),
and every call becomes one host-to-emulator message instead of a
signal-level handshake every clock. Checks that would need cycle-level
visibility (pc continuity, hang detection, event counters) live in
`rv_checker`, inside the HDL partition, so they cost no host round trips.

Block level: `block/alu/` has its own agent (driver, monitor, sequencer), an
exhaustive corner sequence (16 ops × 6×6 corner operands), a
constrained-random sequence (`dist` constraints), and a scoreboard with a
reference function written from the spec. The test fails if any legal op is
never checked.

## UVM on Verilator: what works

I tested this first, before writing the bench.

- **Full UVM runs on Verilator 5.050.** The library is UVM 2017-1.0 (IEEE
  1800.2-2017) from `chipsalliance/uvm-verilator`, branch `uvm-2017-1.0-vlt`,
  pinned to commit `5a37baa`. `make` fetches it into `third_party/uvm`.
  - UVM's own DPI (`uvm_dpi.cc`) is built too. That needs `--vpi`, and on
    macOS a one-line `malloc.h` shim (`tools/shim/`). With it,
    `+UVM_TESTNAME` works. Without the DPI (`+define+UVM_NO_DPI`) it also
    runs, but `+UVM_TESTNAME` is ignored.
  - Randomization with constraints (`dist`, ranges) works. Verilator hands
    the constraints to z3, so each `randomize()` is slow: an ALU run with
    ~3,600 items takes about 7 s on one core.
- **Covergroups compile but do not collect.** In a small test on 5.050,
  `get_coverage()` returned 0.00 after sampling 50 values. So functional
  coverage here uses SVA `cover property` (collected by
  `--coverage-user`) plus the ALU scoreboard's per-op hit table.
- **Clocking blocks.** Driving clocking-block outputs from tasks inside an
  interface did not propagate on 5.050 (BUGS.md, testbench bug 4). The BFM
  drives and samples on the falling edge instead.
- The UVM code uses only standard UVM API (no Verilator-specific
  workarounds). So it should also run on commercial simulators and EDA
  Playground, but **I have not run it on one.**

## How to run

Needs: Verilator 5.050, z3 (constraint solver for Verilator), Yosys, Python 3,
git (to fetch UVM).

```sh
make sim                        # build + one test with waves (TEST=rand_mix SEED=1 by default)
make sim TEST=load_use          # any directed test: isa_basic raw_hazard load_use branches jal_jalr subword
make sim TEST=rand_mem SEED=7   # any random test: rand_alu rand_mem rand_branch rand_mix
make alu                        # block-level ALU UVM bench
make regress                    # 6 directed + 4 random tests x 10 seeds + ALU x 10 seeds, 1 worker
make regress SEEDS=50 JOBS=8    # more seeds, 8 parallel workers
make cov                        # regression on a coverage build, merged coverage summary
make synth                      # yosys synth of the HDL partition, cell counts
make buggy REV=c3acc8a          # replay the regression on the core before a bug fix (BUGS.md)
make clean                      # remove build/ and results/
```

Outputs:
- `results/regress/summary.md`: pass/fail table and failure signatures.
- `results/regress/junit.xml`: JUnit report.
- `results/regress/runs/<test>_s<seed>/`: `program.asm`, `program.hex`,
  `sim.log`, and `waves.vcd` for reruns.
- `results/cov/summary.md`: merged coverage.
- `results/synth_stat.txt`: yosys statistics.

Run one program by hand:

```sh
python3 tools/rvgen.py --test rand_mix --seed 42 --out /tmp/p.asm      # writes /tmp/p.asm and /tmp/p.hex
cd /tmp && ~/developer/rv32-emu-verif/build/sys/Vsim +UVM_TESTNAME=rv_program_test \
    +PROGRAM=p.hex +UVM_VERBOSITY=UVM_HIGH +waves                         # prints every COMMIT
```

## Results (copied from actual runs, macOS)

All numbers below are copied from the runs. Snapshots are in `docs/results/`.

### `make regress` (defaults: 10 seeds, 1 worker): 56/56 passed, 72.8 s wall

| Test | Runs | Pass | Fail | Retired / checks (sum) | Stalls (sum) | Flushes (sum) |
|---|---|---|---|---|---|---|
| alu_uvm (block level) | 10 | 10 | 0 | 35770 | 0 | 0 |
| branches | 1 | 1 | 0 | 38 | 0 | 15 |
| isa_basic | 1 | 1 | 0 | 47 | 0 | 11 |
| jal_jalr | 1 | 1 | 0 | 17 | 0 | 9 |
| load_use | 1 | 1 | 0 | 32 | 9 | 6 |
| rand_alu | 10 | 10 | 0 | 2100 | 0 | 20 |
| rand_branch | 10 | 10 | 0 | 1551 | 0 | 341 |
| rand_mem | 10 | 10 | 0 | 2100 | 84 | 20 |
| rand_mix | 10 | 10 | 0 | 1789 | 21 | 223 |
| raw_hazard | 1 | 1 | 0 | 31 | 0 | 4 |
| subword | 1 | 1 | 0 | 24 | 2 | 2 |

That is 7,729 retired instructions checked against the C model, plus 35,770
ALU checks. Stall and flush counts come from the HDL-side checker's counters.

An earlier run with `SEEDS=50 JOBS=10` passed 216/216 in 28.8 s (37,967
retired instructions checked). Its summary is in `docs/results/regress_summary.md`.

### `make cov SEEDS=50`: 206 runs merged

Line coverage on the design and the HDL partition: **163/172 points (94.8%)**.
`riscv_core.v` is 76/76.

| File | Points | Hit | % |
|---|---|---|---|
| rtl/riscv_core.v | 76 | 76 | 100.0 |
| rtl/control_unit.v | 35 | 33 | 94.3 |
| rtl/alu.v | 17 | 16 | 94.1 |
| rtl/imm_gen.v | 7 | 7 | 100.0 |
| rtl/regfile.v | 9 | 9 | 100.0 |
| hdl/rv_checker.v | 18 | 12 | 66.7 |
| hdl/rv_load_xactor.v | 5 | 5 | 100.0 |
| hdl/rv_retire_xactor.v | 3 | 3 | 100.0 |

The 9 missed points are all unreachable by construction:
- The ALU `default` arm: the decoder never produces codes 11-15. The block
  bench covers it.
- Two `default` arms in a 3-bit `funct3` case where all 8 values are listed.
- The checker's error branches, which only fire on a real error.

**SVA cover points: 20/20 hit.** Examples: `c_fwd1_mem` 9087,
`c_fwd2_wb` 2049, `c_stall` 638, `c_stall_store_data` 199,
`c_stall_branch` 46, `c_load_at_target` 33, `c_stall_jalr` 1 (only the
directed test reaches it). The full table is in `docs/results/cov_summary.md`.

### `make synth`: Yosys 0.67, `synth -top rv_hdl_core`

| Module | Cells |
|---|---|
| **rv_hdl_core (total)** | **61,687** |
| riscv_core (own logic + imem/dmem) | 55,567 |
| regfile | 3,767 |
| alu | 1,326 |
| imm_gen | 92 |
| control_unit | 48 |
| rv_checker | 527 |
| rv_retire_xactor | 294 |
| rv_load_xactor | 66 |

16,384 of the core's cells are `$_DFFE_PP_`: the 256-word instruction and
data memories (2 × 256 × 32 bits) mapped to flip-flops, because generic
`synth` has no RAM macros. The verification logic in the HDL partition
(transactors + checker) is 887 cells.

### Bench sanity (mutation check, done once by hand)

To make sure the benches can fail, I built them once against a mutated copy
of the RTL in /tmp: SRA changed to SRL, and EX/MEM vs MEM/WB forwarding
priority swapped for rs1.
- The ALU bench failed (`MISMATCH ctrl=7 a=80000000 b=00000001 y=40000000 ... exp y=c0000000`).
- The system bench failed 32 of 46 runs (10 seeds).

This is not part of `make regress`.

## Repository layout

```
rtl/             the core (copied, with a retire trace port, program load port and two bug fixes)
hdl/             synthesizable HDL partition: rv_hdl_core, load/retire transactors, rv_checker
hvl/             hdl_top, hvl_top, rv_bfm (boundary interface), rv_pkg (UVM env), dpi/rv32i_iss.c
sva/             core_sva.sv, bound into riscv_core
block/alu/       block-level UVM bench
tests/directed/  hazard-focused assembly tests
tools/           assemble.py (from the core repo, + sub-word ops), rvgen.py, shim/malloc.h
scripts/         regress.py
docs/results/    snapshots of the result files quoted above
.github/         CI workflow (written, not run locally)
```

## Limitations

- **No real emulator.**
  - There are no SCE-MI pipes or DPI-based transactors. The BFM is a plain
    SystemVerilog interface with timed tasks; on Veloce or Palladium those
    tasks would need the vendor's XRTL compiler.
  - Yosys proves that the HDL partition (`rv_hdl_core` and below)
    synthesizes. It does not cover the BFM interface or the clock/reset
    generator in `hdl_top`.
- **No UPF / power-aware verification.** No power intent, no isolation or
  retention checks.
- **No formal.** SymbiYosys is not installed here. The SVA runs in simulation
  only.
- **The core has no traps**: no illegal-instruction or misaligned-access
  exceptions, and no CSRs, FENCE, ECALL or EBREAK. The model flags these
  cases, and the generator avoids them (BUGS.md).
- **Generator limits.**
  - Random branches and jumps only go forward. Loops are only in the
    directed tests.
  - Programs fit in the 256-word instruction memory.
  - jalr targets come from `auipc x30` pairs. Load-to-jalr is only covered by
    the directed test (`c_stall_jalr` = 1).
- **Memories are asynchronous-read register arrays.** In synthesis they
  become flip-flops (see the cell counts). The register file writes on the
  falling clock edge. That is the original design's choice; it is fine in
  simulation, but it is a half-cycle timing path on real silicon or an
  emulator.
- **Coverage.** Verilator covergroups do not collect, so there is no
  covergroup-based functional coverage on Verilator. Toggle coverage is not
  collected.
- **CI.** `.github/workflows/regress.yml` is written but has not run (local
  repo, never pushed).
