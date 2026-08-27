#!/usr/bin/env python3
"""Reject all Verilator diagnostics except exact, individually reviewed entries.

The inventory is data reviewed in docs/WARNING_AUDIT.md. There is deliberately no
accept/update command: a changed warning or source file requires another audit.
Raw diagnostics stay in the build log; no lint class is disabled by this gate.
"""
from collections import Counter
from pathlib import Path
import argparse
import hashlib
import json
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
LINE = re.compile(r"^%Warning-([A-Z0-9_]+): (.+?):(\d+):(\d+): (.*)$")
FORBIDDEN = {"UNDRIVEN", "WIDTHEXPAND", "WIDTHTRUNC", "WIDTH", "LATCH", "MULTIDRIVEN", "UNOPTFLAT", "CASEINCOMPLETE", "CASEOVERLAP", "PINMISSING", "IMPLICIT", "ALWCOMBORDER"}
REVIEWABLE = {"PINCONNECTEMPTY", "UNUSEDSIGNAL", "UNUSEDPARAM", "GENUNNAMED", "UNUSEDGENVAR", "VARHIDDEN", "BLKSEQ", "PROCASSINIT", "SYNCASYNCNET", "UNSIGNED"}

def diagnostics(text):
    parsed = []
    for line in text.splitlines():
        match = LINE.match(line)
        if match:
            kind, file, row, col, message = match.groups()
            parsed.append({"kind": kind, "file": file.replace('\\','/'), "line": int(row), "column": int(col), "message": message})
        elif line.startswith("%Warning") or line.startswith("%Error") or re.search(r"\bwarning:", line, re.I):
            raise ValueError("Unparsed diagnostic: " + line)
    return parsed

def key(entry):
    return (entry["kind"], entry["file"], entry["line"], entry["column"], entry["message"])

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", choices=["system", "upstream-crossbar"])
    parser.add_argument("log", type=Path)
    parser.add_argument("--inventory", type=Path, default=ROOT/"docs/warning_waivers.json")
    args = parser.parse_args()
    inventory = json.loads(args.inventory.read_text())
    profile = inventory["profiles"][args.profile]
    log_text = args.log.read_text(errors="replace")
    observed = diagnostics(log_text)
    observed_count = Counter(key(e) for e in observed)
    expected_count = Counter({key(e): e["count"] for e in profile["warnings"]})
    unexpected = observed_count - expected_count
    missing = expected_count - observed_count
    problems = []
    version = re.search(r"Verilator (\d+\.\d+)", log_text)
    if not version or version.group(1) != inventory["verilator"]:
        problems.append("COMPILER_VERSION_CHANGED_OR_MISSING: require the reviewed Verilator version in the complete log")
    if "- Verilator: Walltime" not in log_text:
        problems.append("INCOMPLETE_LINT_LOG: missing final Verilator completion report")
    for item, count in unexpected.items():
        problems.append(f"UNREVIEWED x{count}: {item}")
    for item, count in missing.items():
        problems.append(f"STALE_WAIVER x{count}: {item}")
    for entry in profile["warnings"]:
        if entry["kind"] in FORBIDDEN:
            problems.append(f"Functional diagnostic cannot be waived: {entry['kind']}")
        elif entry["kind"] not in REVIEWABLE:
            problems.append(f"Diagnostic class is not eligible for this reviewed inventory: {entry['kind']}")
        if not entry.get("reason"):
            problems.append(f"Missing reason: {key(entry)}")
    for filename, expected in profile["source_sha256"].items():
        path = ROOT / filename
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            problems.append("REVIEWED_SOURCE_CHANGED: " + filename)
    if not observed and expected_count:
        problems.append("No diagnostics found: require a fresh complete build log")
    if problems:
        print("WARNING_AUDIT_FAIL " + args.profile)
        print("\n".join(problems))
        return 1
    print(f"WARNING_AUDIT_PASS profile={args.profile} raw={len(observed)} exact_reviewed={sum(expected_count.values())} functional=0")
    print("Remaining diagnostics are visible and individually justified; this is not zero raw warnings.")
    return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError) as exc:
        print("WARNING_AUDIT_FAIL " + str(exc))
        sys.exit(1)
