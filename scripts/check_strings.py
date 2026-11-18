#!/usr/bin/env python3
"""Check the localisation tables for missing / inconsistent strings.

Verifies, for Resources/{en,zh-Hans,zh-Hant}.lproj:
  * Localizable.strings and InfoPlist.strings parse, and every key exists in all three languages
  * format specifiers (%@, %d, %ld ...) are identical across languages for each key
  * no value is empty
  * every literal key passed to L("...") / LF("...") in Sources/ exists in the table
Exit status is 1 on any problem, so it can gate a release.
"""
import glob
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANGS = ["en", "zh-Hans", "zh-Hant"]
PAIR = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')
SPEC = re.compile(r"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h)?[@dDiuUxXfeEgGcCsSp]")


def load(path: Path) -> dict:
    out = {}
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("/*") or line.startswith("//"):
            continue
        m = PAIR.match(line)
        if not m:
            sys.exit(f"{path}:{n}: cannot parse: {line}")
        if m.group(1) in out:
            sys.exit(f"{path}:{n}: duplicate key {m.group(1)!r}")
        out[m.group(1)] = m.group(2)
    return out


problems = []
for table in ["Localizable", "InfoPlist"]:
    data = {l: load(ROOT / "Resources" / f"{l}.lproj" / f"{table}.strings") for l in LANGS}
    allkeys = set().union(*[set(d) for d in data.values()])
    print(f"{table}.strings: {len(allkeys)} keys; " + ", ".join(f"{l}={len(d)}" for l, d in data.items()))
    for k in sorted(allkeys):
        for l in LANGS:
            if k not in data[l]:
                problems.append(f"{table}: key missing in {l}: {k!r}")
            elif not data[l][k].strip():
                problems.append(f"{table}: empty value in {l}: {k!r}")
        base = sorted(SPEC.findall(data["en"].get(k, "")))
        for l in LANGS[1:]:
            if k in data[l] and sorted(SPEC.findall(data[l][k])) != base:
                problems.append(f"{table}: format specifiers differ in {l}: {k!r}")
    if table == "Localizable":
        loc_keys = allkeys

used = set()
for f in glob.glob(str(ROOT / "Sources" / "**" / "*.swift"), recursive=True):
    for m in re.finditer(r'\bLF?\(\s*"((?:[^"\\]|\\.)*)"', Path(f).read_text(encoding="utf-8")):
        used.add(m.group(1).replace('\\"', '"'))
for k in sorted(used - loc_keys):
    problems.append(f"source uses L(\"{k}\") but no table defines it")
print(f"source references: {len(used)} literal keys")

if problems:
    print("\nPROBLEMS:")
    print("\n".join(" - " + p for p in problems))
    sys.exit(1)
print("OK: every key is present in en, zh-Hans and zh-Hant")
