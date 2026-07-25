#!/usr/bin/env python3
"""Bundle src/*.lua into a single loadstring-able Sable.lua.

Each module becomes `__modules["<name>"] = function() ... end` and `require` is
a local shim, so module bodies are copied verbatim -- line numbers inside a
module shift by a known offset, which is written to tools/Sable.map.json for
mapping analyzer output back to source.

    python tools/build.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"
OUT = ROOT / "Sable.lua"
MAP = ROOT / "tools" / "Sable.map.json"

VERSION_RE = re.compile(r'^Library\.Version\s*=\s*"([^"]+)"', re.M)
DIRECTIVE_RE = re.compile(r"^\s*--!\S+\s*$")

PREAMBLE = """--!nonstrict
-- Sable v{version} - generated bundle. Do not edit; edit src/ and rebuild.
-- {count} modules, built by tools/build.py

local __modules = {{}}
local __cache = {{}}

local function require(name)
\tlocal cached = __cache[name]
\tif cached ~= nil then
\t\treturn cached
\tend

\tlocal factory = __modules[name]
\tif not factory then
\t\terror("[Sable] missing module: " .. tostring(name), 2)
\tend

\tlocal result = factory()
\tif result == nil then
\t\tresult = true
\tend

\t__cache[name] = result
\treturn result
end
"""


def module_name(path: Path) -> str:
    return "/".join(path.relative_to(SRC).with_suffix("").parts)


def strip_leading_directives(text: str) -> str:
    """Blank out `--!mode` lines. They only apply at the top of a real file;
    inside a wrapper function they are inert, and luau-lsp lints them."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if DIRECTIVE_RE.match(line):
            lines[i] = ""
    return "\n".join(lines)


def main() -> int:
    if not SRC.is_dir():
        print(f"no src directory at {SRC}", file=sys.stderr)
        return 2

    files = sorted(SRC.rglob("*.lua"), key=lambda p: module_name(p))
    if not files:
        print("no .lua files found under src/", file=sys.stderr)
        return 2

    names = [module_name(p) for p in files]
    if "init" not in names:
        print("src/init.lua is required (it is the bundle entry point)", file=sys.stderr)
        return 2

    version = "0.0.0"
    init_text = (SRC / "init.lua").read_text(encoding="utf-8")
    found = VERSION_RE.search(init_text)
    if found:
        version = found.group(1)

    chunks: list[str] = [PREAMBLE.format(version=version, count=len(files))]
    line_map: dict[str, dict[str, int]] = {}
    # +1 because line numbers are 1-based.
    cursor = PREAMBLE.format(version=version, count=len(files)).count("\n") + 1

    for path in files:
        name = module_name(path)
        body = strip_leading_directives(path.read_text(encoding="utf-8")).rstrip("\n")

        header = f'\n__modules["{name}"] = function()\n'
        chunks.append(header)
        cursor += header.count("\n")

        # First body line lands here; source line N maps to cursor + N - 1.
        line_map[name] = {
            "offset": cursor - 1,
            "lines": body.count("\n") + 1,
            "path": str(path.relative_to(ROOT)).replace("\\", "/"),
        }

        chunks.append(body + "\n")
        cursor += body.count("\n") + 1

        chunks.append("end\n")
        cursor += 1

    chunks.append('\nreturn require("init")\n')

    OUT.write_text("".join(chunks), encoding="utf-8", newline="\n")
    MAP.write_text(json.dumps(line_map, indent=2), encoding="utf-8", newline="\n")

    total = OUT.read_text(encoding="utf-8").count("\n")
    print(f"built {OUT.relative_to(ROOT)}  v{version}  {len(files)} modules  {total} lines")
    for name in names:
        info = line_map[name]
        print(f"  {name:<26} src 1..{info['lines']:<5} -> bundle {info['offset'] + 1}..{info['offset'] + info['lines']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
