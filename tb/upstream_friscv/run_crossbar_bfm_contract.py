#!/usr/bin/env python3
"""Reproduce the Lite BFM failure, repaired 32/128 runs and monitor mutations."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SVUT_SHA = "d75f9ee5a4adecbb92faa7295e3cfbd111bc4df3"
PATCHES = ["axi_crossbar_bfm_width.patch", "axi_crossbar_bfm_contract.patch"]


def main():
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    work = ROOT / "build/crossbar_bfm" / stamp
    report = ROOT / "reports/upstream_regression/crossbar-bfm" / stamp
    report.mkdir(parents=True)
    svut = ROOT / "build/deps/svut"
    actual = subprocess.check_output(["git", "-C", str(svut), "rev-parse", "HEAD"], text=True).strip()
    if actual != SVUT_SHA:
        raise SystemExit("Use the pinned SVUT installed by scripts/run_upstream_regression.py")
    for checkout in [svut, ROOT / "third_party/friscv/dep/axi-crossbar"]:
        dirty = subprocess.check_output(["git", "-C", str(checkout), "status", "--porcelain", "--untracked-files=no"], text=True)
        if dirty:
            raise SystemExit("Tracked upstream source changes: " + str(checkout))
    tree = work / "tree"
    xbar = tree / "dep/axi-crossbar"
    shutil.copytree(ROOT / "third_party/friscv/dep/axi-crossbar", xbar,
                    symlinks=True, ignore=shutil.ignore_patterns(".git"))
    with (report / "prepare.log").open("w") as log:
        subprocess.run(["python3", str(ROOT / "scripts/prepare_upstream.py"),
                        "--output", str(tree.relative_to(ROOT))], check=True,
                       stdout=log, stderr=subprocess.STDOUT)
    metadata = json.loads((tree / "manifest.json").read_text())
    metadata["bfm_patches"] = {
        name: hashlib.sha256((ROOT / "tb/upstream_friscv" / name).read_bytes()).hexdigest()
        for name in PATCHES
    }
    metadata["svut"] = actual
    (report / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    env = dict(os.environ, PATH=str(svut) + ":/usr/local/bin:/usr/bin:/bin")
    testdir = xbar / "test/svut"
    config32 = "axi4lite_-cdc_-or_-priority_+pipe_-route.cfg"
    config128 = "p2-width-128.cfg"
    template = (testdir / "tb_config" / config32).read_text()
    (testdir / "tb_config" / config128).write_text(
        template.replace("AXI_ADDR_W,16", "AXI_ADDR_W,32").replace("AXI_DATA_W,32", "AXI_DATA_W,128"))
    results = []

    def patch(name):
        with (ROOT / "tb/upstream_friscv" / name).open("rb") as source, (report / (name + ".log")).open("w") as log:
            subprocess.run(["patch", "--batch", "--forward", "-p1"], cwd=tree,
                           stdin=source, stdout=log, stderr=subprocess.STDOUT, check=True)

    def run(name, config, expected_pass, required=()):
        command = ["bash", "./run.sh", "--tc", "./tb_config/" + config,
                   "--max-traffic", "1024", "--timeout", "2000000", "--no-vcd", "--no-debug-log"]
        with (report / (name + ".log")).open("w") as log:
            result = subprocess.run(command, cwd=testdir, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=300)
        text = (report / (name + ".log")).read_text()
        errors = bool(re.search(r"ERROR:|FATAL:|%Fatal|%Error|Assertion failed", text))
        if expected_pass:
            okay = result.returncode == 0 and not errors and "9/9 test(s) passed" in text
        else:
            okay = result.returncode != 0 and "Error detected during execution" in text
        missing = [token for token in required if token not in text]
        okay = okay and not missing
        results.append(dict(name=name, exit_code=result.returncode, expected_pass=expected_pass,
                            passed=okay, missing=missing, command=command))
        (report / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(f"{'PASS' if okay else 'FAIL'} {name} exit={result.returncode}", flush=True)
        if not okay:
            raise SystemExit("BFM contract test failed; see " + str(report))

    patch(PATCHES[0])
    monitor = testdir / "src/slv_monitor.sv"
    original_monitor = monitor.read_text()
    diagnostic = original_monitor.replace(
        "if (awvalid && awready) begin",
        'if (awvalid && awready) begin\n'
        '                $display("AW_COMPARE mode=%0d actual_size=%h expected_size=%h actual_cache=%h expected_cache=%h", AXI_SIGNALING,awsize,exp_awsize,awcache,exp_awcache);')
    diagnostic = diagnostic.replace(
        "if (arvalid && arready) begin",
        'if (arvalid && arready) begin\n'
        '                $display("AR_COMPARE mode=%0d actual_PROT=%h expected_PROT=%h", AXI_SIGNALING,arprot,exp_arprot);')
    try:
        monitor.write_text(diagnostic)
        run("128-original-monitor-red", config128, False, required=(
            "AW_COMPARE mode=0 actual_size=0 expected_size=3 actual_cache=0 expected_cache=9",
            "AR_COMPARE mode=0 actual_PROT=1 expected_PROT=x",
        ))
    finally:
        monitor.write_text(original_monitor)
    patch(PATCHES[1])
    run("128-contract-fixed", config128, True)
    run("32-contract-fixed", config32, True)
    tb = testdir / "src/axicb_crossbar_top_testbench.sv"
    original_tb = tb.read_text()
    try:
        for name, signal, value in [
            ("negative-lite-attribute", "slv0_awsize", "3'b001"),
            ("negative-arprot", "slv0_arprot", "3'b000"),
            ("negative-unknown", "slv0_awsize", "3'bxxx"),
        ]:
            # Mutate the observed interface, never the assertion or expectation.
            tb.write_text(original_tb.replace("endmodule", f"initial force {signal} = {value};\nendmodule"))
            run(name, config128, False)
    finally:
        tb.write_text(original_tb)
    print("CROSSBAR_BFM_CONTRACT_PASS " + str(report.relative_to(ROOT)), flush=True)


if __name__ == "__main__":
    main()
