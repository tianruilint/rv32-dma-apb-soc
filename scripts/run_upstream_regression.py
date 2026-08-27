#!/usr/bin/env python3
"""Run pinned upstream tests in fresh, isolated copies and retain every log."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import shutil
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
FRISCV_SHA = "5bf6d1d0e63c99278763eb3803e7fc717ea2f1ba"
SVUT_SHA = "d75f9ee5a4adecbb92faa7295e3cfbd111bc4df3"
XBAR_SHA = "7738a3811623ef4b5610082347bfecce35d95dd2"


def output(args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--groups", nargs="+", choices=["wba", "isa", "apps", "crossbar"],
                        default=["wba", "isa", "apps", "crossbar"])
    parser.add_argument("--svut", type=Path, default=None,
                        help="Optional existing SVUT checkout; its exact commit and clean source are verified")
    args = parser.parse_args()
    if sys.platform != "linux":
        raise SystemExit("Run inside WSL/Linux to preserve upstream symlinks.")
    if args.svut is None:
        args.svut = ROOT / "build/deps/svut"
        if not args.svut.exists():
            args.svut.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["git", "clone", "--no-checkout", "https://github.com/dpretet/svut.git", str(args.svut)], check=True)
            subprocess.run(["git", "-C", str(args.svut), "checkout", "--detach", SVUT_SHA], check=True)
    upstream = ROOT / "third_party/friscv"
    for path, sha in [(upstream, FRISCV_SHA), (upstream / "dep/axi-crossbar", XBAR_SHA), (args.svut, SVUT_SHA)]:
        actual = output(["git", "-C", str(path), "rev-parse", "HEAD"])
        if actual != sha:
            raise SystemExit(f"Pinned source mismatch: {path}: {actual} != {sha}")
        if output(["git", "-C", str(path), "status", "--porcelain", "--untracked-files=no"]):
            raise SystemExit(f"Tracked source modifications in {path}; refusing ambiguous reproduction")
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    work = ROOT / "build/upstream_regression" / stamp
    report = ROOT / "reports/upstream_regression" / stamp
    work.mkdir(parents=True)
    report.mkdir(parents=True)
    env = dict(os.environ, PATH=f"{args.svut}:/usr/local/bin:/usr/bin:/bin", NO_VCD="1")
    for trace in ("CONTROL", "CACHE", "BLOCKS", "FETCHER", "PUSHER", "TB_RAM", "REGISTERS"):
        env["TRACE_" + trace] = "0"
    # A fresh source tree means compiler output always belongs to this run.
    fixed = work / "fixed"
    print(f"Preparing fresh isolated sources in {work}", flush=True)
    shutil.copytree(upstream, fixed, symlinks=True, ignore=shutil.ignore_patterns(".git"))
    # Use the exact RTL patch list selected by the P2 system build, then add
    # application/toolchain and upstream-test-model compatibility fixes.
    system_patches = runpy.run_path(str(ROOT / "scripts/prepare_upstream.py"))["PATCHES"]
    patches = [ROOT / "reports/upstream_friscv/app_compat.patch",
               ROOT / "reports/upstream_friscv/app_runner_compat.patch"]
    patches += [ROOT / name for name in system_patches]
    patches += [ROOT / "tb/upstream_friscv/axi_crossbar_bfm_width.patch",
                ROOT / "tb/upstream_friscv/axi_crossbar_bfm_contract.patch"]
    for patch in patches:
        with patch.open("rb") as source, (report / (patch.stem + "-apply.log")).open("wb") as log:
            subprocess.run(["patch", "--batch", "--forward", "-p1"], cwd=fixed, stdin=source,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
    results = []
    metadata = {"started_utc": stamp, "friscv": FRISCV_SHA, "axi_crossbar": XBAR_SHA,
                "svut": SVUT_SHA, "groups": args.groups,
                "patches": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in patches},
                "tools": {tool: output(command) for tool, command in {
                    "python": ["python3", "--version"],
                    "verilator": ["verilator", "--version"],
                    "gcc": ["riscv64-unknown-elf-gcc", "-dumpfullversion"]}.items()}}
    metadata["tools"]["iverilog"] = subprocess.check_output(
        ["iverilog", "-V"], stderr=subprocess.STDOUT, text=True).splitlines()[0]
    (report / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")

    def run(name, cwd, command, expected, pattern, stdin=None, timeout=300, required=()):
        print(f"RUN {name}: {' '.join(command)}", flush=True)
        start = time.monotonic()
        with (report / (name + ".log")).open("wb") as log:
            proc = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.PIPE,
                                    stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            timed_out = False
            try:
                proc.communicate(None if stdin is None else stdin.encode(), timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait()
        text = (report / (name + ".log")).read_text(errors="replace")
        passed = len(re.findall(pattern, text))
        errors = re.findall(r"(?:ERROR:|ERROR!|FATAL:|%Fatal|%Error|Assertion failed|❌|Errors detected|[0-9]+/[0-9]+ test\(s\) failed)", text)
        missing = [token for token in required if token not in text]
        okay = proc.returncode == 0 and not timed_out and passed == expected and not errors and not missing
        result = dict(name=name, command=command, cwd=str(cwd.relative_to(ROOT)), exit_code=proc.returncode,
                      timeout=timed_out, expected=expected, observed=passed, error_markers=len(errors),
                      missing=missing, passed=okay, elapsed_s=round(time.monotonic()-start, 3))
        results.append(result)
        (report / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(f"{'PASS' if okay else 'FAIL'} {name} exit={proc.returncode} cases={passed}/{expected} elapsed={result['elapsed_s']}s", flush=True)

    if "wba" in args.groups:
        original = work / "original"
        shutil.copytree(upstream, original, symlinks=True, ignore=shutil.ignore_patterns(".git"))
        for label, tree in [("original", original), ("patched", fixed)]:
            tests = sorted((tree / "test/wba_testsuite/tests").glob("rv32ui-p-test*.v"))
            if len(tests) != 11:
                raise RuntimeError(f"Expected 11 WBA programs, found {len(tests)}")
            run("wba-" + label, tree / "test/wba_testsuite",
                ["bash", "./run.sh", "--tb", "platform", "--simulator", "icarus", "--novcd"],
                11, r"STATUS: 1/1 test\(s\) passed")
    if "isa" in args.groups:
        for prefix, expected in [("rv32ui", 39), ("rv32um", 8)]:
            tests = sorted((fixed / "test/riscv-tests/tests").glob(prefix + "-p*.v"))
            if len(tests) != expected:
                raise RuntimeError(f"Expected {expected} {prefix} programs, found {len(tests)}")
            # Upstream's valueless --novcd handler shifts twice, so it must be
            # last; otherwise it swallows --tc and rejects its following path.
            run("isa-" + prefix, fixed / "test/riscv-tests",
                ["bash", "./run.sh", "--tb", "platform", "--simulator", "icarus", "--tc", "./tests/" + prefix + "-p*.v", "--novcd"],
                expected, r"STATUS: 1/1 test\(s\) passed", timeout=600)
    if "apps" in args.groups:
        for app in ["repl", "coremark"]:
            run("app-" + app, fixed / "test/apps", ["bash", "./run.sh", "--tc", f"tests/{app}.v"],
                1, r"SUCCESS: Test passed", stdin="repl.script\n" if app == "repl" else None, timeout=600,
                required=("Welcome to FRISCV", "Exiting... See you!") if app == "repl" else ("Correct operation validated",))
    if "crossbar" in args.groups:
        testdir = fixed / "dep/axi-crossbar/test/svut"
        template = (testdir / "tb_config/axi4lite_-cdc_-or_-priority_+pipe_-route.cfg").read_text()
        for width in (32, 128):
            # Build both configurations from the original template, so the
            # standard-width regression also protects the shared BFM fixes.
            config = template.replace("AXI_ADDR_W,16", "AXI_ADDR_W,32").replace("AXI_DATA_W,32", f"AXI_DATA_W,{width}")
            config_name = f"p2-width-{width}.cfg"
            (testdir / "tb_config" / config_name).write_text(config)
            (report / config_name).write_text(config)
            run(f"crossbar-{width}", testdir, ["bash", "./run.sh", "--tc", f"./tb_config/{config_name}",
                                              "--max-traffic", "1024", "--timeout", "2000000", "--no-vcd", "--no-debug-log"],
                9, r"SUCCESS: << Test [0-8]:[^\n]+ >> pass", timeout=600,
                required=("STATUS: 9/9 test(s) passed",))
    failures = [r["name"] for r in results if not r["passed"]]
    for patch in patches:
        if hashlib.sha256(patch.read_bytes()).hexdigest() != metadata["patches"][str(patch.relative_to(ROOT))]:
            failures.append("patch-changed-during-run:" + str(patch.relative_to(ROOT)))
    if runpy.run_path(str(ROOT / "scripts/prepare_upstream.py"))["PATCHES"] != system_patches:
        failures.append("system-patch-list-changed-during-run")
    (report / "summary.json").write_text(json.dumps({"passed": not failures, "failures": failures,
                                                    "results": results}, indent=2) + "\n")
    print(f"UPSTREAM_REGRESSION {'PASS' if not failures else 'FAIL'} report={report}", flush=True)
    return bool(failures)


if __name__ == "__main__":
    raise SystemExit(main())
