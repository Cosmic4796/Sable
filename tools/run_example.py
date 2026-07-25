#!/usr/bin/env python3
"""Execute examples/example.lua headlessly against the built bundle.

The example is the artifact most people actually run, so it deserves the same
treatment as the library: assemble mock + bundle + example, run it under luau,
and assert the menu it produces is the one documented.

    python tools/run_example.py
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / "tools"
BUNDLE = ROOT / "dist" / "Sable.lua"
EXAMPLE = ROOT / "examples" / "example.lua"
OUT = TOOLS / "_example_combined.luau"

EXE = ".exe" if os.name == "nt" else ""
DEFAULT_LUAU = TOOLS / "luau" / f"luau{EXE}"

# The example loads the library over HTTP; the harness injects it instead.
LOADER = re.compile(r"^\s*local\s+Library\s*=\s*loadstring\(.*$", re.M)

ASSERTIONS = """
--==== ASSERTIONS ====
local failed = 0
local function check(name, ok, detail)
\tif not ok then
\t\tfailed += 1
\t\tprint("FAIL: " .. name .. (detail and ("  --  " .. tostring(detail)) or ""))
\tend
end

local window = Library.Windows[1]
check("a window exists", window ~= nil)
if window then
\tlocal names = {}
\tfor _, tab in window.Tabs do
\t\ttable.insert(names, tostring(tab.Name))
\tend
\tprint("tabs: " .. table.concat(names, ", "))

\tcheck("has a Settings tab", table.find(names, "Settings") ~= nil, table.concat(names, ", "))
\tcheck("settings tab is last", names[#names] == "Settings", names[#names])
end

-- The controls AddSettingsTab is documented to create.
check("MenuKeybind registered", Library.Options.MenuKeybind ~= nil)
check("watermark toggle registered", Library.Toggles.SableWatermark ~= nil)
check("keybind list toggle registered", Library.Toggles.SableKeybindList ~= nil)
check("theme list registered", Library.Options[Library.ThemeManager.ListIndex] ~= nil)

if failed == 0 then
\tprint("EXAMPLE OK")
else
\tprint(failed .. " EXAMPLE FAILURES")
end
"""


def main() -> int:
    luau = Path(os.environ.get("SABLE_LUAU", DEFAULT_LUAU))
    for path in (luau, BUNDLE, EXAMPLE):
        if not path.exists():
            print(f"missing: {path}", file=sys.stderr)
            return 2

    # Generated property whitelist goes first; the mock reads it as a global.
    api = (TOOLS / "mock_api.luau").read_text(encoding="utf-8")
    mock = api + "\n" + (TOOLS / "mock_roblox.luau").read_text(encoding="utf-8")
    bundle = BUNDLE.read_text(encoding="utf-8")
    example = EXAMPLE.read_text(encoding="utf-8")

    stripped, count = LOADER.subn("-- (loader line removed by run_example.py)", example)
    if count == 0:
        print("could not find the loadstring line in example.lua", file=sys.stderr)
        return 2

    combined = (
        "--!nocheck\n"
        + mock
        + "\n--==== BUNDLE ====\n"
        + "local Library = (function()\n"
        + bundle
        + "\nend)()\n"
        + "--==== EXAMPLE ====\n"
        + stripped
        + ASSERTIONS
    )
    OUT.write_text(combined, encoding="utf-8", newline="\n")

    proc = subprocess.run([str(luau), str(OUT)], capture_output=True, text=True)
    if proc.stdout:
        print(proc.stdout.rstrip())
    if proc.stderr:
        print(proc.stderr.rstrip(), file=sys.stderr)

    if proc.returncode != 0:
        print(f"\nexample errored (luau exit {proc.returncode})", file=sys.stderr)
        return 1
    if "EXAMPLE OK" not in proc.stdout:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
