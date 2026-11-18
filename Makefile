# rv32-emu-verif : UVM + DPI-C verification of an RV32I 5-stage core.
#
#   make sim     build the system-level UVM bench and run one test (TEST=..., SEED=...)
#   make alu     block-level UVM bench for the ALU
#   make regress N seeds x all tests in parallel, summary in results/
#   make cov     regression on the coverage build, coverage summary in results/
#   make synth   yosys synthesis of the HDL partition (cell count in results/)
#   make buggy REV=<commit>  rerun the regression on riscv_core.v from an older
#                commit (see BUGS.md) to watch the bench catch a fixed bug
#   make clean

VERILATOR ?= verilator
YOSYS     ?= yosys
PYTHON    ?= python3
JOBS      ?= $(shell getconf _NPROCESSORS_ONLN)
TEST      ?= rand_mix
SEED      ?= 1
SEEDS     ?= 50

UVM_HOME   := third_party/uvm/src
UVM_REPO   := https://github.com/chipsalliance/uvm-verilator
UVM_COMMIT := 5a37baacfed0722b523b05decc9b94fe3e9efbe4   # branch uvm-2017-1.0-vlt

RTL := rtl/alu.v rtl/regfile.v rtl/imm_gen.v rtl/control_unit.v rtl/riscv_core.v
HDL := hdl/rv_load_xactor.v hdl/rv_retire_xactor.v hdl/rv_checker.v hdl/rv_hdl_core.v
HVL := hvl/rv_bfm.sv sva/core_sva.sv hvl/rv_pkg.sv hvl/hdl_top.sv hvl/hvl_top.sv hvl/dpi/rv32i_iss.c

# Full UVM, including UVM's own DPI (uvm_dpi.cc needs VPI).
VFLAGS := --binary --timing --vpi --assert -j $(JOBS) --build-jobs $(JOBS) \
          -Wno-fatal -Wno-lint -Wno-style -Wno-MULTITOP -Irtl \
          +incdir+$(UVM_HOME) $(UVM_HOME)/uvm_pkg.sv $(UVM_HOME)/dpi/uvm_dpi.cc
ifeq ($(shell uname),Darwin)
VFLAGS += -CFLAGS -I$(CURDIR)/tools/shim
endif

SYS_BIN := build/sys/Vsim
COV_BIN := build/cov/Vsim
ALU_BIN := build/alu/Valu

.PHONY: sim alu regress cov synth buggy uvm clean distclean

uvm: $(UVM_HOME)/uvm_pkg.sv
$(UVM_HOME)/uvm_pkg.sv:
	git clone -q $(UVM_REPO) third_party/uvm
	git -C third_party/uvm checkout -q $(UVM_COMMIT)

$(SYS_BIN): $(RTL) $(HDL) $(HVL) | uvm
	$(VERILATOR) $(VFLAGS) --trace $(RTL) $(HDL) $(HVL) -Mdir build/sys -o Vsim > build/sys.log 2>&1 \
	  || (mkdir -p build; tail -30 build/sys.log; false)

$(COV_BIN): $(RTL) $(HDL) $(HVL) | uvm
	$(VERILATOR) $(VFLAGS) --coverage-line --coverage-user $(RTL) $(HDL) $(HVL) -Mdir build/cov -o Vsim > build/cov.log 2>&1 \
	  || (tail -30 build/cov.log; false)

$(ALU_BIN): rtl/alu.v block/alu/alu_if.sv block/alu/alu_pkg.sv block/alu/alu_tb_top.sv | uvm
	$(VERILATOR) $(VFLAGS) $^ --top-module alu_tb_top -Mdir build/alu -o Valu > build/alu.log 2>&1 \
	  || (tail -30 build/alu.log; false)

build:
	mkdir -p build
$(SYS_BIN) $(COV_BIN) $(ALU_BIN): | build

sim: $(SYS_BIN)
	$(PYTHON) scripts/regress.py --bin $(SYS_BIN) --tests $(TEST) --seeds 1 --first-seed $(SEED) --out results/sim --waves

alu: $(ALU_BIN)
	cd build/alu && VERILATOR_SOLVER="z3 --in" ./Valu +UVM_TESTNAME=alu_test +UVM_NO_RELNOTES | tee ../alu_run.log | grep -E "SCB|RESULT|UVM_(ERROR|FATAL) :"

regress: $(SYS_BIN) $(ALU_BIN)
	$(PYTHON) scripts/regress.py --bin $(SYS_BIN) --alu-bin $(ALU_BIN) --seeds $(SEEDS) --jobs $(JOBS) --out results/regress

cov: $(COV_BIN)
	$(PYTHON) scripts/regress.py --bin $(COV_BIN) --seeds $(SEEDS) --jobs $(JOBS) --out results/cov --coverage

synth:
	@mkdir -p results
	$(YOSYS) -q -l results/synth.log -p "read_verilog -Irtl $(RTL) $(HDL); synth -top rv_hdl_core; tee -o results/synth_stat.txt stat"
	@grep -E "^=== |cells$$" results/synth_stat.txt

buggy: | uvm build
	@test -n "$(REV)" || (echo "usage: make buggy REV=<commit>  (see BUGS.md)"; false)
	mkdir -p build/buggy_rtl
	git show $(REV):rtl/riscv_core.v > build/buggy_rtl/riscv_core.v
	$(VERILATOR) $(VFLAGS) $(filter-out rtl/riscv_core.v,$(RTL)) build/buggy_rtl/riscv_core.v $(HDL) $(HVL) \
	  -Mdir build/buggy -o Vsim > build/buggy.log 2>&1 || (tail -30 build/buggy.log; false)
	-$(PYTHON) scripts/regress.py --bin build/buggy/Vsim --seeds $(SEEDS) --jobs $(JOBS) --out results/buggy

clean:
	rm -rf build results

distclean: clean
	rm -rf third_party/uvm
