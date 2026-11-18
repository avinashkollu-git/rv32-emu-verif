#!/usr/bin/env python3
"""Regression runner: tests x seeds in parallel, summary + triage.

For each run it makes a directory <out>/runs/<test>_s<seed>/ with the program
(.asm/.hex), the simulator log and, on rerun, waves.vcd. Then it writes:
  <out>/summary.md   pass/fail table, failure signatures, coverage
  <out>/junit.xml    for CI dashboards
Failures are grouped by signature: the first error line of the log with
numbers and hex values masked, so 30 failing seeds with the same root cause
show up as one row. The first failing seed of each signature is rerun with
+waves and its reproduce command is printed.

Exit status is 0 only if every run passed.
"""
import argparse, concurrent.futures as cf, glob, os, re, shutil, subprocess, sys, time
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from assemble import assemble
from rvgen import MIXES

DIRECTED = sorted(os.path.splitext(os.path.basename(p))[0]
                  for p in glob.glob(os.path.join(ROOT, "tests/directed/*.asm")))
RANDOM = sorted(MIXES)
ERR_RE = re.compile(r"^(UVM_ERROR|UVM_FATAL) (?!:)|%Error")   # not the "UVM_ERROR :  0" summary


def prepare(test, seed, rundir):
    """Write the program for one run; return the .hex path."""
    os.makedirs(rundir, exist_ok=True)
    hexf = os.path.join(rundir, "program.hex")
    if test in DIRECTED:
        src = os.path.join(ROOT, "tests/directed", test + ".asm")
        shutil.copy(src, os.path.join(rundir, "program.asm"))
        words = assemble(open(src).read())
        with open(hexf, "w") as f:
            f.writelines(f"{w:08x}\n" for w in words)
    elif test != "alu_uvm":
        subprocess.run([sys.executable, os.path.join(ROOT, "tools/rvgen.py"), "--test", test,
                        "--seed", str(seed), "--out", os.path.join(rundir, "program.asm")], check=True)
    return hexf


def command(a, test, seed, waves):
    if test == "alu_uvm":
        return [os.path.abspath(a.alu_bin), "+UVM_TESTNAME=alu_test", "+UVM_NO_RELNOTES",
                f"+verilator+seed+{seed}"]
    cmd = [os.path.abspath(a.bin), "+UVM_TESTNAME=rv_program_test", "+PROGRAM=program.hex",
           "+UVM_NO_RELNOTES", f"+verilator+seed+{seed}"]
    return cmd + (["+waves"] if waves else [])


def signature(line):
    """Mask run-specific values so equal root causes compare equal."""
    s = re.sub(r"@ \d+", "@ <t>", line)
    s = re.sub(r"^\[\d+\] ", "", s)
    s = re.sub(r"\b[0-9a-fA-F]{8}\b", "<h>", s)
    s = re.sub(r"\b\d+\b", "<n>", s)
    return s.strip()[:160]


def run_one(a, test, seed, waves=False, tag=""):
    rundir = os.path.join(a.out, "runs", f"{test}_s{seed}{tag}")
    prepare(test, seed, rundir)
    cmd = command(a, test, seed, waves)
    t0 = time.time()
    env = dict(os.environ, VERILATOR_SOLVER=os.environ.get("VERILATOR_SOLVER", "z3 --in"))
    try:
        p = subprocess.run(cmd, cwd=rundir, capture_output=True, text=True, timeout=a.timeout, env=env)
        log, rc = p.stdout + p.stderr, p.returncode
    except subprocess.TimeoutExpired as e:
        log, rc = (e.stdout or b"").decode(errors="replace") + "\nTIMEOUT (wall clock)\n", -1
    open(os.path.join(rundir, "sim.log"), "w").write(log)
    first_err = next((l for l in log.splitlines() if ERR_RE.search(l)), None)
    passed = rc == 0 and "RESULT: PASS" in log and first_err is None
    if not passed and first_err is None:
        first_err = "no RESULT line (crash or wall-clock timeout)" if "RESULT:" not in log else "RESULT: FAIL"
    stats = dict(re.findall(r"(\w+)=(\d+)", next((l for l in log.splitlines() if l.startswith("STATS")), "")))
    return dict(test=test, seed=seed, passed=passed, secs=time.time() - t0, rundir=rundir,
                cmd=" ".join(cmd), first_err=first_err, stats=stats)


def coverage_summary(a, results):
    """Merge per-run coverage.dat files and summarize line + SVA cover points."""
    dats = [os.path.join(r["rundir"], "coverage.dat") for r in results
            if os.path.exists(os.path.join(r["rundir"], "coverage.dat"))]
    if not dats:
        return "No coverage.dat files were produced.\n"
    merged = os.path.join(a.out, "coverage_merged.dat")
    subprocess.run(["verilator_coverage", "--write", merged] + dats, check=True, capture_output=True)
    subprocess.run(["verilator_coverage", "--annotate", os.path.join(a.out, "coverage_annotated"),
                    merged], check=True, capture_output=True)
    files, covers = {}, []
    for ln in open(merged, errors="replace"):
        m = re.match(r"C '(.*)' (\d+)", ln.strip())
        if not m:
            continue
        kv = dict(f.split("\x02", 1) for f in m.group(1).split("\x01") if "\x02" in f)
        path, page, hit = kv.get("f", ""), kv.get("page", ""), int(m.group(2))
        if not (path.startswith("rtl/") or path.startswith("hdl/") or path.startswith("sva/")):
            continue
        if page.startswith("v_user"):
            covers.append((kv.get("o", "?"), hit))
        else:
            t = files.setdefault(path, [0, 0])
            t[0] += 1
            t[1] += hit > 0
    out = [f"Merged {len(dats)} runs.\n", "| File | Line/branch points | Hit | % |", "|---|---|---|---|"]
    tot = [0, 0]
    for f in sorted(files):
        n, h = files[f]
        tot[0] += n; tot[1] += h
        out.append(f"| {f} | {n} | {h} | {100.0 * h / n:.1f} |")
    out.append(f"| **total** | {tot[0]} | {tot[1]} | {100.0 * tot[1] / max(tot[0], 1):.1f} |\n")
    hitc = sum(1 for _, h in covers if h)
    out += [f"SVA cover points hit: {hitc}/{len(covers)}\n", "| Cover point | Count |", "|---|---|"]
    out += [f"| {o} | {h} |" for o, h in sorted(covers)]
    return "\n".join(out) + "\n"


def write_reports(a, results, reruns, cov_text, wall):
    npass = sum(r["passed"] for r in results)
    sigs = {}
    for r in results:
        if not r["passed"]:
            sigs.setdefault(signature(r["first_err"]), []).append(r)
    md = [f"# Regression summary\n",
          f"**{npass}/{len(results)} passed**, wall time {wall:.1f} s, {a.jobs} parallel jobs\n",
          "| Test | Runs | Pass | Fail | Retired / checks (sum) | Stalls (sum) | Flushes (sum) |",
          "|---|---|---|---|---|---|---|"]
    for t in sorted({r["test"] for r in results}):
        rs = [r for r in results if r["test"] == t]
        s = lambda k: sum(int(r["stats"].get(k, 0)) for r in rs)
        md.append(f"| {t} | {len(rs)} | {sum(r['passed'] for r in rs)} | "
                  f"{sum(not r['passed'] for r in rs)} | {s('retired')} | {s('stalls')} | {s('flushes')} |")
    md.append("\n## Failure signatures\n")
    if not sigs:
        md.append("None.\n")
    for sig, rs in sorted(sigs.items(), key=lambda kv: -len(kv[1])):
        md.append(f"- **{len(rs)} run(s)**: `{sig}`")
        md.append(f"  - first: {rs[0]['test']} seed {rs[0]['seed']} -> `{rs[0]['rundir']}/sim.log`")
        if sig in reruns:
            md.append(f"  - rerun with waves: `{reruns[sig]}`")
    if cov_text:
        md += ["\n## Coverage\n", cov_text]
    open(os.path.join(a.out, "summary.md"), "w").write("\n".join(md) + "\n")

    suite = ET.Element("testsuite", name="rv32-emu-verif", tests=str(len(results)),
                       failures=str(len(results) - npass), time=f"{wall:.1f}")
    for r in results:
        tc = ET.SubElement(suite, "testcase", classname=r["test"], name=f"seed{r['seed']}",
                           time=f"{r['secs']:.2f}")
        if not r["passed"]:
            ET.SubElement(tc, "failure", message=r["first_err"]).text = r["cmd"]
    ET.ElementTree(suite).write(os.path.join(a.out, "junit.xml"), encoding="utf-8", xml_declaration=True)
    return npass, sigs


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bin", required=True, help="system-level simulator binary")
    ap.add_argument("--alu-bin", help="block-level ALU UVM binary (adds test alu_uvm)")
    ap.add_argument("--tests", default="all", help="comma list, or all")
    ap.add_argument("--seeds", type=int, default=10, help="seeds per random test")
    ap.add_argument("--alu-seeds", type=int, default=10,
                    help="seeds for alu_uvm (each run takes ~25 s: Verilator calls z3 per randomize())")
    ap.add_argument("--first-seed", type=int, default=1)
    ap.add_argument("--jobs", type=int, default=os.cpu_count())
    ap.add_argument("--timeout", type=int, default=120, help="wall-clock seconds per run")
    ap.add_argument("--out", default="results/regress")
    ap.add_argument("--waves", action="store_true", help="dump waves for every run")
    ap.add_argument("--coverage", action="store_true", help="merge coverage.dat files")
    a = ap.parse_args()

    tests = (DIRECTED + RANDOM + (["alu_uvm"] if a.alu_bin else [])) if a.tests == "all" else a.tests.split(",")
    seeds = {t: range(a.first_seed, a.first_seed + a.seeds) for t in tests}
    seeds.update({t: [a.first_seed] for t in DIRECTED})
    seeds["alu_uvm"] = range(a.first_seed, a.first_seed + min(a.seeds, a.alu_seeds))
    jobs = [(t, s) for t in tests for s in seeds[t]]
    jobs.sort(key=lambda j: j[0] != "alu_uvm")   # start the slow runs first
    shutil.rmtree(a.out, ignore_errors=True)
    os.makedirs(a.out)

    t0 = time.time()
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        results = list(ex.map(lambda j: run_one(a, j[0], j[1], a.waves), jobs))
    wall = time.time() - t0

    # rerun the first failure of every signature with waves, for triage
    reruns = {}
    for r in results:
        sig = None if r["passed"] else signature(r["first_err"])
        if sig and sig not in reruns:
            rr = run_one(a, r["test"], r["seed"], waves=True, tag="_rerun")
            reruns[sig] = f"cd {rr['rundir']} && {rr['cmd']}  (waves.vcd)"

    cov_text = coverage_summary(a, results) if a.coverage else ""
    npass, sigs = write_reports(a, results, reruns, cov_text, wall)

    for r in results:
        if not r["passed"]:
            print(f"FAIL {r['test']} seed {r['seed']}: {r['first_err']}")
    print(f"\n{npass}/{len(results)} passed in {wall:.1f} s, {len(sigs)} failure signature(s)")
    print(f"summary: {os.path.join(a.out, 'summary.md')}  junit: {os.path.join(a.out, 'junit.xml')}")
    sys.exit(0 if npass == len(results) else 1)


if __name__ == "__main__":
    main()
