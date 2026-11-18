# Bugs found

Bugs found in the RV32I core (copied from `riscv-5stage-core`) by this
environment, and how each one was found, root-caused and fixed. Each fix is
its own commit, so `make buggy REV=<commit before the fix>` replays the
regression on the old RTL and shows the bench catching it.

## Bug 1: spurious load-use stall on immediate bits (performance)

| | |
|---|---|
| Found by | SVA `a_stall_needed` (sva/core_sva.sv), first regression run |
| First repro | `rand_mem` seed 2 (generator version at commit 66a9069), pc 0x154 |
| Fixed in | c3acc8a |
| Replay | `make buggy REV=49fee33`: 21/46 runs fail at the default 10 seeds. That commit also has bug 2, so most fail on `MISMATCH`; `a_stall_needed` fires first in `rand_mem` seed 5 |

**Symptom.** The assertion says: a stall may only happen when the instruction
in ID really reads the register the load in EX is writing. It fired with

```
EX: lw  x4,  -144(x31)    f70fa203
ID: lw  x17, -476(x31)    e24fa883   bits [24:20] = 00100 = x4
```

The second `lw` has no rs2. Bits [24:20] are part of its 12-bit immediate,
and they happen to be 4, the first load's rd.

**Root cause.** The hazard unit compared the load's rd with bits [19:15] and
[24:20] of every instruction, whatever its format:

```verilog
assign stall = idex_mem_read && (idex_rd != 5'd0) &&
               ((idex_rd == rs1) || (idex_rd == rs2));
```

For I-type (loads, ALU-immediate, jalr) bits [24:20] are immediate bits. For
LUI/AUIPC/JAL both fields are immediate bits.

**Impact.** Results were still correct, so the scoreboard (which compares
architectural state) passed every run. Only the assertion saw it. The cost was
cycles: over 50 `rand_mem` seeds, total stalls went from 513 to 477 after
the fix. 7% of the stalls in that test had been wasted.

**Fix.** Decode which source fields the format really uses:

```verilog
wire uses_rs1 = !(opcode == `OP_LUI || opcode == `OP_AUIPC || opcode == `OP_JAL);
wire uses_rs2 = (opcode == `OP_RTYPE) || (opcode == `OP_STORE) || (opcode == `OP_BRANCH);
assign stall = idex_mem_read && (idex_rd != 5'd0) &&
               ((uses_rs1 && idex_rd == rs1) || (uses_rs2 && idex_rd == rs2));
```

Is the forwarding unit still safe? It also matches on raw fields, so an
unused operand can now pick up a load's address from EX/MEM. That value is
never used, because the operand is unused. `a_no_load_fwd` checks this for
used operands only, and it holds in every run.

**Lesson.** A reference-model scoreboard only catches wrong results. A
performance bug needs an assertion or a performance counter (the HDL checker
also counts stalls).

## Bug 2: byte/halfword loads and stores executed as word accesses

| | |
|---|---|
| Found by | a hand-written probe, then the C model + random sub-word programs |
| First repro | probe below; with today's generator: `rand_mem` seed 1, pc 0x104 |
| Fixed in | d7666d6 |
| Replay | `make buggy REV=c3acc8a`: 21/46 runs fail at the default 10 seeds (20 `MISMATCH mem_wdata`, 1 `MISMATCH rd_wdata`) |

**Symptom.** The core's README says "Full RV32I integer subset". The C model
was written from the RISC-V spec, so it was given LB/LH/LBU/LHU/SB/SH. A probe
program showed:

```
sw  x2, 0(x1)        x2 = 0x12345678
lb  x3, 1(x1)        core: x3 = 0x12345678     spec: x3 = 0x00000056
```

The random generator was then extended to emit all load/store widths. On the
old RTL every `rand_mem` and `rand_mix` seed fails, for example:

```
MISMATCH mem_wdata: pc=00000104 insn=19a01c23 got=11ad575e exp=0000575e
          (sh x26, 408(x0): the store overwrote the whole word)
MISMATCH rd_wdata:  pc=00000010 insn=00008183 got=81828384 exp=ffffff84
          (subword test, lb x3, 0(x1): no lane select, no sign extension)
```

**Root cause.** funct3 (the access width) was never carried past ID for
loads and stores. Data memory always wrote the full 32-bit word, and WB always
returned the full word. Every load was LW and every store was SW.

**Fix.**
- Carry funct3 through EX/MEM and MEM/WB.
- Stores: replicate the data across byte lanes, build a byte-enable mask from
  the address low bits, and merge it with the current word. The read port is
  asynchronous, so the read-modify-write fits in one cycle.
- Loads: shift the addressed lane down in WB and sign or zero extend it.
  Forwarding from MEM/WB uses the extended value automatically, because it
  forwards `wb_data`.
- The retire trace reports the whole word after a store, so the C model also
  checks the lane merge.

## Spec deviations found but not fixed (documented limitations)

The same probe showed these. They are missing features, not bugs in existing
logic, and fixing them means adding a trap/CSR architecture:

- **No illegal-instruction trap.** `mul x4, x2, x2` (M extension) executes as
  `add`. FENCE, ECALL, EBREAK and CSR instructions also do something
  undefined instead of trapping. The C model flags all of them (`MODEL rc=1`),
  and the generator never emits them.
- **No misaligned-access trap.** For a misaligned address, the core ignores
  the low address bits. The C model flags it (`MODEL rc=2`), and the generator
  only emits naturally aligned addresses.

## Testbench bugs found along the way

The environment has to be debugged too:

1. **My own directed test was wrong.** In `load_use.asm`, a store overwrote the
   pointer that the next load used. The C model reported a misaligned load
   (`MODEL rc=2`), and the RTL silently ignored the low bits. This is why the
   model reports illegal and misaligned cases instead of copying RTL behavior.
2. **Unreachable cover point.** `pcsrc ##2 stall` never hit in 86 runs. Two
   cycles after a redirect, EX holds the flush bubble, so it cannot be a load.
   The right cover is `pcsrc ##3 stall` (a load at the branch target, used by
   the next instruction). It hits 33 times in the 206-run coverage regression.
3. **Generator off-by-one.** Branch labels were placed one instruction early,
   because the branch's own emit counted down its skip window. The jalr landing
   window was also shortened by one. Both were found by reading a generated
   program, before any run failed.
4. **Clocking-block drives from interface tasks did not propagate on
   Verilator 5.050.** The BFM loaded 53 words, but `ld_valid` never toggled in
   the VCD. The BFM now drives and samples on the falling edge, which is
   race-free because the HDL partition is purely posedge.
