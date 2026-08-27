#!/usr/bin/env python3
"""Bind a successful complete regression to its exact local source files."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
RECORD = ROOT / "reports/p2_soc/verification-manifest.json"

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def check_upstream(manifest):
    for path, expected in manifest["pins"].items():
        actual = subprocess.check_output(["git", "-C", str(ROOT/path), "rev-parse", "HEAD"], text=True).strip()
        if actual != expected:
            raise SystemExit("Source pin changed: " + path)
        subprocess.run(["git", "-C", str(ROOT/path), "diff", "--exit-code", "HEAD"], check=True)
    for source in manifest["files"]:
        path = ROOT/"third_party/friscv"/source["path"]
        if not path.is_file() or sha(path) != source["upstream_sha256"]:
            raise SystemExit("Upstream source changed: " + str(path))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check:
        record = json.loads(RECORD.read_text())
        bad = [name for name, digest in record["files"].items()
               if not (ROOT/name).is_file() or sha(ROOT/name) != digest]
        if bad:
            raise SystemExit("VERIFICATION_SOURCE_CHANGED\n" + "\n".join(bad))
        manifest = json.loads((ROOT/"reports/p2_soc/upstream-manifest.json").read_text())
        if manifest["pins"] != record["pins"]:
            raise SystemExit("Recorded source pins differ")
        check_upstream(manifest)
        print(f"VERIFICATION_SOURCE_MATCH files={len(record['files'])}")
        return
    log = ROOT / "reports/p2_soc/final-verify.log"
    if not log.read_text().rstrip().endswith("RELEASE_VERIFY_EXIT=0"):
        raise SystemExit("A successful complete run_release.sh log is required")
    scenarios = json.loads((ROOT/"reports/p2_soc/system-stress/summary.json").read_text())
    if len(scenarios) != 9 or not all(x["passed"] for x in scenarios):
        raise SystemExit("All nine system scenarios are required")
    reports = [line.split("report=", 1)[1].strip() for line in log.read_text().splitlines()
               if line.startswith("UPSTREAM_REGRESSION PASS report=")]
    if len(reports) != 1:
        raise SystemExit("Missing complete upstream regression")
    summary = (Path(reports[0])/"summary.json").resolve()
    if not summary.is_relative_to((ROOT/"reports/upstream_regression").resolve()):
        raise SystemExit("Upstream report is outside this repository")
    upstream = json.loads(summary.read_text())
    expected_groups = {"wba-original", "wba-patched", "isa-rv32ui", "isa-rv32um",
                       "app-repl", "app-coremark", "crossbar-32", "crossbar-128"}
    if (not upstream["passed"] or len(upstream["results"]) != len(expected_groups) or
            {x["name"] for x in upstream["results"]} != expected_groups or
            not all(x["passed"] for x in upstream["results"])):
        raise SystemExit("Latest upstream regression is incomplete or failed")
    metadata_path = summary.with_name("metadata.json")
    metadata = json.loads(metadata_path.read_text())
    patch_inputs = []
    for name, digest in metadata["patches"].items():
        patch = (ROOT/name).resolve()
        if not patch.is_relative_to(ROOT.resolve()) or not patch.is_file() or sha(patch) != digest:
            raise SystemExit("Upstream regression patch changed: " + name)
        patch_inputs.append(patch)
    files = [ROOT/"Makefile", ROOT/"docs/warning_waivers.json", log, metadata_path,
             ROOT/"reports/p2_soc/system-stress/summary.json", summary,
             ROOT/"reports/p2_soc/upstream-manifest.json"]
    files.extend(patch_inputs)
    files.extend(summary.parent/(item["name"]+".log") for item in upstream["results"])
    for folder in ("rtl", "tb", "scripts", "firmware/soc"):
        files.extend(p for p in (ROOT/folder).rglob("*") if p.is_file() and
                     (p.suffix in {".sv", ".c", ".S", ".ld", ".py", ".sh", ".patch"} or p.name == "Makefile"))
    manifest = json.loads((ROOT/"reports/p2_soc/upstream-manifest.json").read_text())
    check_upstream(manifest)
    pins = manifest["pins"]
    record = {"recorded_utc": datetime.now(timezone.utc).isoformat(),
              "command": "bash scripts/run_release.sh (runs make verify)",
              "exit_code": 0, "pins": pins,
              "upstream_summary": str(summary.relative_to(ROOT)),
              "system_scenarios": len(scenarios),
              "files": {p.relative_to(ROOT).as_posix(): sha(p) for p in sorted(set(files))}}
    RECORD.write_text(json.dumps(record, indent=2)+"\n")
    print(f"VERIFICATION_MANIFEST_PASS files={len(record['files'])} upstream={summary.relative_to(ROOT)}")

if __name__ == "__main__":
    main()
