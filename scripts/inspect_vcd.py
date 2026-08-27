#!/usr/bin/env python3
"""Print last values of selected signals from an actual simulator VCD."""
import argparse
import re

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("file")
p.add_argument("pattern")
args = p.parse_args()
pattern = re.compile(args.pattern)
names, values, stack = {}, {}, []
time = 0
with open(args.file) as f:
    for line in f:
        tokens = line.split()
        if not tokens: continue
        if tokens[0] == "$scope": stack.append(tokens[2])
        elif tokens[0] == "$upscope": stack.pop()
        elif tokens[0] == "$var":
            name = ".".join(stack + [tokens[4]])
            if pattern.search(name): names.setdefault(tokens[3], []).append(name)
        elif tokens[0] == "$enddefinitions": break
    for line in f:
        line = line.strip()
        if not line: continue
        if line[0] == "#": time = int(line[1:])
        elif line[0] in "bBrR":
            value, code = line.split()
            if code in names: values[code] = (time, value[1:])
        elif line[0] in "01xXzZ" and line[1:] in names:
            values[line[1:]] = (time, line[0])
for code, paths in names.items():
    if code not in values: continue
    t, value = values[code]
    for name in paths:
        shown = hex(int(value, 2)) if set(value) <= {"0", "1"} else value
        print(f"{name}: {shown} (last changed at {t} ps)")
