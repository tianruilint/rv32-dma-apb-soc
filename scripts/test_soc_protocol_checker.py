#!/usr/bin/env python3
"""Check the SoC protocol monitor with legal traffic and deliberate violations."""
from pathlib import Path
import datetime
import hashlib
import json
import re
import resource
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CASES = {
    0: ("ordered_pairing_and_response_reordering", None),
    1: ("response_before_its_write_data", "unsolicited B id=02"),
    2: ("unsolicited_write_response", "unsolicited B id=07"),
    3: ("duplicate_read_response", "unsolicited R id=08"),
    4: ("undrained_read", "outstanding responses id=09 R=1 B=0"),
    5: ("unpaired_write_address", "unmatched write requests AW=1 W=0"),
    6: ("live_endpoint_may_finish_with_outstanding_read", None),
    7: ("reset_cancels_old_requests", None),
    8: ("write_data_before_address", None),
    9: ("write_payload_changes_while_stalled", "W changed under backpressure"),
    10: ("duplicate_write_response", "unsolicited B id=10"),
    11: ("multiple_writes_with_same_id", None),
    12: ("unpaired_write_data", "unmatched write requests AW=0 W=1"),
    13: ("undrained_write_response", "outstanding responses id=12 R=0 B=1"),
}


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def main():
    if sys.platform != "linux":
        raise SystemExit("Run this test inside WSL/Linux.")
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    out = ROOT / "reports/p2_soc/protocol-checker" / stamp
    build = ROOT / "build/protocol-checker" / stamp
    out.mkdir(parents=True, exist_ok=False)
    build.mkdir(parents=True, exist_ok=False)
    sources = ["rtl/soc/p2_axil_if.sv", "tb/soc_protocol_checker.sv",
               "tb/soc_protocol_checker_test.sv", "scripts/test_soc_protocol_checker.py"]
    report = {"started_utc": utc_now(), "source_sha256": {
        p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in sources
    }, "executions": [], "cases": []}

    def execute(command, label, timeout):
        started = utc_now()
        try:
            run = subprocess.run(command, cwd=ROOT, capture_output=True, timeout=timeout)
            code, stdout, stderr = run.returncode, run.stdout, run.stderr
        except subprocess.TimeoutExpired as error:
            code = 124
            stdout = error.stdout or b""
            stderr = (error.stderr or b"") + b"\nCHECKER_SELFTEST_TIMEOUT\n"
        stdout_path = out / (label + ".stdout.log")
        stderr_path = out / (label + ".stderr.log")
        stdout_path.write_bytes(stdout)
        stderr_path.write_bytes(stderr)
        record = {"command": command, "started_utc": started, "ended_utc": utc_now(),
                  "exit_code": code, "stdout": str(stdout_path.relative_to(ROOT)),
                  "stderr": str(stderr_path.relative_to(ROOT))}
        report["executions"].append(record)
        return record, (stdout + stderr).decode("utf-8", errors="replace")

    def save(passed):
        report["ended_utc"] = utc_now()
        report["passed"] = passed
        (out / "results.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"PROTOCOL_CHECKER_RESULTS {out.relative_to(ROOT)}", flush=True)

    version, text = execute(["verilator", "--version"], "verilator-version", 30)
    report["verilator"] = text.strip()
    if version["exit_code"]:
        save(False)
        return 1
    command = ["verilator", "--binary", "--timing", "--assert", "-j", "4",
               "-DCHECK_PROTOCOL_DRAIN", "--top-module", "soc_protocol_checker_test",
               "--Mdir", str(build.relative_to(ROOT)), *sources[:3]]
    compilation, _ = execute(command, "build", 180)
    if compilation["exit_code"]:
        save(False)
        return 1
    for number, (name, expected_error) in CASES.items():
        record, text = execute([str(build / "Vsoc_protocol_checker_test"), f"+CASE={number}"],
                               f"case-{number:02d}-{name}", 30)
        if expected_error is None:
            passed = (record["exit_code"] == 0 and f"CHECKER_CASE_END case={number}" in text
                      and not re.search(r"%Fatal|%Error|FATAL:|Assertion failed", text))
        else:
            passed = (record["exit_code"] not in (0, 124) and expected_error in text
                      and f"CHECKER_CASE_END case={number}" not in text)
        report["cases"].append({"case": number, "name": name,
                                "expected_error": expected_error, "passed": passed,
                                "execution": record})
        print(f"CHECKER_SELFTEST {name} {'PASS' if passed else 'FAIL'} exit={record['exit_code']}", flush=True)
    passed = all(case["passed"] for case in report["cases"])
    save(passed)
    if passed:
        expected_rejections = sum(error is not None for _, error in CASES.values())
        print(f"PROTOCOL_CHECKER_SELFTEST_PASS cases={len(CASES)} expected_rejections={expected_rejections}", flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
