# tools/

Build and verification for Sable. Nothing here ships — `dist/Sable.lua` is the
only artifact a user loads.

```
powershell -ExecutionPolicy Bypass -File tools/check.ps1
```

That is the one command. It runs all four gates below and exits non-zero on any
failure.

## Files

| file | role |
|------|------|
| `build.py` | bundles `src/**/*.lua` → `dist/Sable.lua` + `dist/Sable.map.json` |
| `check.ps1` | the full gate: syntax → src typecheck → bundle typecheck → smoke |
| `smoke.py` | assembles mock + bundle + test into one chunk and runs it under `luau` |
| `mock_roblox.luau` | headless Roblox API mock |
| `smoke_test.luau` | assertions run against the real bundle (`check.ps1` prints the count) |
| `globalTypes.d.luau` | Roblox API type definitions for `luau-lsp` |

## The bundler

Each module becomes `__modules["<path>"] = function() ... end` and `require` is a
**local shim** in the bundle, so module bodies are copied verbatim. Module names
are the path under `src/` without `.lua`, forward slashes — so `src/elements/init.lua`
is `require("elements/init")`, *not* `require("elements")`. The shim does an exact
table lookup with no directory resolution.

Because bodies are copied verbatim, a line in the bundle maps back to source by a
fixed per-module offset recorded in `dist/Sable.map.json`. To trace an analyzer or
stack-trace line:

```python
import json
m = json.load(open('dist/Sable.map.json'))
for name, info in m.items():
    if info['offset'] < line <= info['offset'] + info['lines']:
        print(info['path'], line - info['offset'])
```

For a line from `_smoke_combined.luau`, subtract the mock offset first — `smoke.py`
prints where the mock ends on every run.

## The headless mock

`mock_roblox.luau` implements enough of the Roblox surface to *execute* the
library outside Roblox: `Instance` with a property bag, children, attributes and
`GetPropertyChangedSignal`; `Color3` / `UDim2` / `UDim` / `Vector2` / `TweenInfo` /
`ColorSequence`; an identity-stable `Enum` (so enum items work as table keys);
`TweenService` (applies props instantly so final state is observable);
`UserInputService` and `RunService` signals you can `:Fire()` by hand; a real JSON
encoder/decoder; `task`; and an in-memory filesystem behind `writefile`/`readfile`/
`listfiles`/`getgenv`.

It is not pixel-accurate and is not meant to be. It catches nil indexes, load-order
faults, re-entrancy, broken value round-trips and unclean teardown — the failures
a typechecker structurally cannot see. Layout, clipping and how the design
actually reads on screen still require a live executor test.

**Two fidelity rules, both learned by chasing phantom bugs:**

1. **Supply real Roblox property defaults.** `Frame.ZIndex` is `1` when never
   assigned, so `frame.ZIndex < 6` is valid Roblox. A mock returning `nil` there
   invents a crash that cannot happen. See the `DEFAULTS` table.
2. **`typeof` must not guess structurally.** Roblox's
   `typeof({R = 1, G = 1, B = 1})` is `"table"`, not `"Color3"`. An earlier
   heuristic reported such tables as `Color3` and manufactured a failure in code
   that was correct.

When the mock and the library disagree, work out which one is wrong before
changing either. Roughly half the initial smoke failures were mock defects.

## Requirements

Nothing here is needed to *use* Sable — only to build and verify it.

```
powershell -ExecutionPolicy Bypass -File tools/bootstrap.ps1
```

That fetches the toolchain into `tools/luau/` and `tools/globalTypes.d.luau`,
both gitignored. You also need `python` on PATH. Override the location with the
`SABLE_LUAU_DIR` (PowerShell) or `SABLE_LUAU` (Python) environment variables if
you already have Luau installed elsewhere.

Sources, if you would rather fetch them by hand:

- `luau-compile` / `luau` — `luau-lang/luau` releases, `luau-windows.zip`
- `luau-lsp` — `JohnnyMorganz/luau-lsp` releases, `luau-lsp-win64.zip`
- `globalTypes.d.luau` — **not** a release asset (that URL 404s); it lives at
  `raw.githubusercontent.com/JohnnyMorganz/luau-lsp/main/scripts/globalTypes.d.luau`

Plain `luau-analyze` has no `--definitions` flag; only `luau-lsp analyze` loads
Roblox types. Executor globals are declared in `.luaurc` so they are not reported
as unknown.
