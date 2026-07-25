#!/usr/bin/env python3
"""Assemble mock + built bundle + smoke test into one chunk and run it under luau.

    python tools/smoke.py

Exits non-zero if the smoke test reports failures or the chunk errors.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / "tools"
BUNDLE = ROOT / "dist" / "Sable.lua"
OUT = TOOLS / "_smoke_combined.luau"

EXE = ".exe" if os.name == "nt" else ""
DEFAULT_LUAU = TOOLS / "luau" / f"luau{EXE}"


def main() -> int:
    luau = Path(os.environ.get("SABLE_LUAU", DEFAULT_LUAU))
    if not luau.exists():
        print(f"luau not found at {luau}", file=sys.stderr)
        print("run tools/bootstrap.ps1, or set SABLE_LUAU", file=sys.stderr)
        return 2

    if not BUNDLE.exists():
        print("dist/Sable.lua missing - run tools/build.py first", file=sys.stderr)
        return 2

    mock = (TOOLS / "mock_roblox.luau").read_text(encoding="utf-8")
    bundle = BUNDLE.read_text(encoding="utf-8")
    test = (TOOLS / "smoke_test.luau").read_text(encoding="utf-8")

    mock_lines = mock.count("\n") + 1

    # The bundle ends in `return require("init")`, so wrapping it in an IIFE
    # hands us the Library without needing loadstring.
    combined = (
        "--!nocheck\n"
        + mock
        + "\n--==== BUNDLE ====\n"
        + "local Library = (function()\n"
        + bundle
        + "\nend)()\n"
        + "--==== TEST ====\n"
        + test
    )
    OUT.write_text(combined, encoding="utf-8", newline="\n")

    print(f"running smoke ({OUT.name}, mock ends line {mock_lines}, {combined.count(chr(10))} lines total)\n")
    proc = subprocess.run([str(luau), str(OUT)], capture_output=True, text=True)

    if proc.stdout:
        print(proc.stdout.rstrip())
    if proc.stderr:
        print("--- stderr ---", file=sys.stderr)
        print(proc.stderr.rstrip(), file=sys.stderr)

    if proc.returncode != 0:
        print(f"\nluau exited {proc.returncode}", file=sys.stderr)
        return 1
    if "SMOKE FAILED" in proc.stdout or "SMOKE ABORTED" in proc.stdout:
        return 1
    if "SMOKE PASSED" not in proc.stdout:
        print("\nsmoke test produced no verdict", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
