#!/usr/bin/env python3
"""Require the intended success marker and reject failure text, even after PASS."""
import argparse
from pathlib import Path
import re

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("log", type=Path)
parser.add_argument("marker")
args = parser.parse_args()
text = args.log.read_text(errors="replace")
failures = re.findall(r"%Fatal|%Error|FATAL:|ERROR:|Assertion failed|Aborting", text)
if args.marker not in text or failures:
    raise SystemExit(f"SIM_LOG_FAIL {args.log}: marker={args.marker in text} error_markers={len(failures)}")
print(f"SIM_LOG_PASS {args.log}: {args.marker}")
