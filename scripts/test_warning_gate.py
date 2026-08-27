#!/usr/bin/env python3
"""Exercise warning-gate failure paths without changing any RTL."""
from pathlib import Path
import json
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/warning_gate_negative"
OUT.mkdir(parents=True, exist_ok=True)
log = ROOT / "reports/p2_soc/system-lint.log"
inventory = ROOT / "docs/warning_waivers.json"
text = log.read_text()

def rejected(name, content, expected, data=None):
    candidate = OUT / f"{name}.log"
    candidate.write_text(content)
    inv = inventory
    if data is not None:
        inv = OUT / f"{name}.json"
        inv.write_text(json.dumps(data))
    result = subprocess.run([sys.executable, str(ROOT/"scripts/check_warnings.py"), "system", str(candidate), "--inventory", str(inv)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (OUT/f"{name}-result.txt").write_text(result.stdout)
    if result.returncode != 1 or expected not in result.stdout:
        raise SystemExit(f"WARNING_GATE_NEGATIVE_FAIL {name}: code={result.returncode}\n{result.stdout}")
    print(f"WARNING_GATE_REJECTED {name}")

rejected("new-unused-warning", text + "\n%Warning-UNUSEDSIGNAL: tb/soc_system_test.sv:1:1: Signal is not used: 'unexpected_new_wire'\n", "UNREVIEWED")
rejected("missing-warning", "\n".join(line for line in text.splitlines() if not line.startswith("%Warning")), "STALE_WAIVER")
altered = json.loads(inventory.read_text())
source = next(iter(altered["profiles"]["system"]["source_sha256"]))
altered["profiles"]["system"]["source_sha256"][source] = "0"*64
rejected("source-drift", text, "REVIEWED_SOURCE_CHANGED", altered)
functional = json.loads(inventory.read_text())
functional["profiles"]["system"]["warnings"].append({"kind":"UNDRIVEN", "file":"tb/soc_system_test.sv", "line":1, "column":1, "message":"Signal is not driven: 'bad_net'", "count":1, "reason":"Attempt to allow a functional defect"})
rejected("forbidden-functional-waiver", text + "\n%Warning-UNDRIVEN: tb/soc_system_test.sv:1:1: Signal is not driven: 'bad_net'\n", "Functional diagnostic cannot be waived", functional)
print("WARNING_GATE_NEGATIVE_PASS 4 rejection cases; no RTL modified")
