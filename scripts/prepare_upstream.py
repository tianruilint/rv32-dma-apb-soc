#!/usr/bin/env python3
"""Copy pinned upstream RTL and apply audited patches without editing submodules."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PINS = {
    "third_party/friscv": "5bf6d1d0e63c99278763eb3803e7fc717ea2f1ba",
    "third_party/friscv/dep/axi-crossbar": "7738a3811623ef4b5610082347bfecce35d95dd2",
}
PATCHES = [
    "tb/upstream_friscv/friscv_io_same_cycle_write.patch",
    "tb/upstream_friscv/friscv_warning_hardening.patch",
    "tb/upstream_friscv/friscv_fetch_fault.patch",
    "tb/upstream_friscv/friscv_memfy_fault.patch",
    "tb/upstream_friscv/friscv_cache_write_handshake.patch",
    "tb/upstream_friscv/friscv_cache_write_response.patch",
    "tb/upstream_friscv/friscv_control_retirement.patch",
]

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", default="build/p2_upstream_hardened")
    args = parser.parse_args()
    dest = (ROOT / args.output).resolve()
    if not dest.is_relative_to((ROOT / "build").resolve()):
        raise SystemExit("Overlay must stay inside this repository's build directory")
    for name, expected in PINS.items():
        actual = subprocess.check_output(["git", "-C", str(ROOT/name), "rev-parse", "HEAD"], text=True).strip()
        if actual != expected:
            raise SystemExit(f"Unexpected {name} pin: {actual}; expected {expected}")
        subprocess.run(["git", "-C", str(ROOT/name), "diff", "--exit-code", "HEAD", "--", "rtl"], check=True)
    upstream = ROOT / "third_party/friscv"
    # Overwrite only files in the reviewed source directories; no recursive delete.
    files = []
    for folder in ("rtl", "dep/axi-crossbar/rtl"):
        for source in sorted((upstream/folder).glob("*")):
            if source.is_file():
                relative = source.relative_to(upstream)
                target = dest / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
                files.append(relative)
    for relative in PATCHES:
        with (ROOT / relative).open("rb") as stream:
            subprocess.run(["patch", "--batch", "--forward", "-p1", "-d", str(dest)], stdin=stream, check=True)
    manifest = {
        "pins": PINS,
        "patches": [{"path": p, "sha256": sha(ROOT/p)} for p in PATCHES],
        "files": [{"path": str(p), "upstream_sha256": sha(upstream/p), "overlay_sha256": sha(dest/p)} for p in files],
    }
    (dest / "manifest.json").write_text(json.dumps(manifest, indent=2)+"\n")
    print(f"UPSTREAM_OVERLAY_READY {dest.relative_to(ROOT)}; {len(files)} files; {len(PATCHES)} patches")

if __name__ == "__main__":
    main()
