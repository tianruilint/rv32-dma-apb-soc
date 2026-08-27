#!/usr/bin/env python3
"""Run the same independent SoC checks under reproducible bus delay/reset stress."""
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "reports/p2_soc/system-stress"
EVIDENCE = ROOT / "reports/evidence"
SCENARIOS = [("baseline", 0, False, False), ("seed1", 1, False, False),
             ("seed7", 7, False, False), ("seed23", 23, False, False),
             ("seed97", 97, False, False), ("seed20260925", 20260925, False, False),
             ("reset_during_dma", 7, True, False),
             ("irq_baseline", 0, False, True), ("irq_seed7", 7, False, True)]

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    EVIDENCE.mkdir(parents=True, exist_ok=True)
    results = []
    for name, seed, restart, irq in SCENARIOS:
        firmware = "p2_irq_demo" if irq else "p2_dma_demo"
        command = [str(ROOT / "build/p2_soc_obj/Vsoc_system_test"),
                   f"+PROGRAM_HEX=build/p2_soc_fw/{firmware}.mem",
                   f"+RAM_STALL_SEED={seed}"]
        if irq:
            command.append("+IRQ_MODE")
        if restart:
            command.append("+RESET_DURING_DMA")
        if name in ("baseline", "seed7"):
            command.append(f"+TRACE_CSV=reports/evidence/system-{name}.csv")
        if name == "seed7":
            command.append("+VCD=build/p2-system-seed7.vcd")
        log = OUT / f"{name}.log"
        with log.open("w") as stream:
            try:
                completed = subprocess.run(command, cwd=ROOT, stdout=stream,
                                           stderr=subprocess.STDOUT, timeout=120)
                code = completed.returncode
            except subprocess.TimeoutExpired:
                code = 124
                stream.write("SYSTEM_RUNNER_TIMEOUT 120 seconds\n")
        content = log.read_text()
        marker = next((line for line in content.splitlines()
                       if line.startswith("SOC_SYSTEM_PASS")), "")
        errors = re.findall(r"%Fatal|%Error|FATAL:|Assertion failed|SYSTEM_RUNNER_TIMEOUT", content)
        passed = (code == 0 and not errors and bool(marker) and
                  (not restart or "SOC_RESET_DURING_DMA" in content) and
                  (not irq or "SOC_IRQ_PASS" in content))
        row = {"name": name, "seed": seed, "reset_during_dma": restart,
               "irq_mode": irq, "command": command, "exit_code": code, "passed": passed,
               "log": str(log.relative_to(ROOT)), "marker": marker,
               "error_markers": len(errors)}
        if marker:
            row["cycles"] = int(re.search(r"cycles=(\d+)", marker).group(1))
        results.append(row)
        print(f"SYSTEM_SCENARIO {name} {'PASS' if passed else 'FAIL'} exit={code}", flush=True)
    (OUT / "summary.json").write_text(json.dumps(results, indent=2)+"\n")
    # Retain the familiar baseline log path without discarding scenario logs.
    (ROOT / "reports/p2_soc/system-test.log").write_text((OUT / "baseline.log").read_text())
    if not all(item["passed"] for item in results):
        return 1
    print(f"SYSTEM_MATRIX_PASS {len(results)}/{len(results)}", flush=True)
    return 0

if __name__ == "__main__":
    sys.exit(main())
