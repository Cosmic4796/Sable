# src/elements/

The nine controls, plus the shared base and the installer.

`SPEC.md` §5 and §6 in the repo root are authoritative — this file is the short
version for adding or editing an element.

| file | store | notes |
|------|-------|-------|
| `Base.lua` | — | **spine, frozen.** Shared element behaviour |
| `init.lua` | — | **spine, frozen.** Installs `Add*` onto the container metatable |
| `Label.lua` | none | supports inline pickers via `element.Right` |
| `Button.lua` | none | `:AddButton(...)` splits the row into equal columns |
| `Divider.lua` | none | |
| `Toggle.lua` | `Library.Toggles` | supports inline pickers via `element.Right` |
| `Slider.lua` | `Library.Options` | segmented track — recolours, never resizes |
| `Input.lua` | `Library.Options` | |
| `Dropdown.lua` | `Library.Options` | single, multi, searchable |
| `ColorPicker.lua` | `Library.Options` | `New` + `Attach` |
| `KeyPicker.lua` | `Library.Options` | `New` + `Attach` |

## Shape of an element module

```lua
local Base = require("elements/Base")

local Toggle = {}

function Toggle.New(Library, container, index, options)
	local element = Base.Create(Library, container, "Toggle", index, options)
	-- build visuals; set element.Row, element.Value, element.Label, element.Hit
	function element:SetValue(value, silent) end   -- apply + repaint, Fire() unless silent
	function element:Display() end                 -- repaint from element.Value
	return Base.Finish(element, Library.Toggles)
end

return Toggle
```

Requires resolve through the bundler's shim, so the name is the full path under
`src/` — `require("elements/Base")`, never a relative path.

## Rules that bite

- **`silent` must be honoured.** `SaveManager` loads configs relying on
  `:SetValue(value)` firing and `:SetValue(value, true)` not.
- **Never call `Library:AddToRegistry` twice for the same instance to repaint.**
  It merges rather than appending now, but the intent-revealing call for a state
  change is `Library:Retheme`.
- **No hardcoded `Color3`.** The only exception is a value that *is* a colour —
  the ColorPicker swatch and its HSV gradients.
- **No `UICorner`, no non-zero `BorderSizePixel`.** Outlines come from
  `Library:Panel` or `Util.Stroke`.
- Every `:Connect` goes through `Library:GiveSignal`; every user callback goes
  through `Library:SafeCallback`.
- Popups belong to the spine: use `Library:OpenPopup` / `:ClosePopup`. Do not
  roll your own outside-click handling or popup layer.
- Elements that accept inline pickers must create `element.Right` exactly as
  SPEC §5 describes, with their own control at `LayoutOrder = 100` so attached
  pickers (10 + n) land to its left.

## Adding an element

1. Write the module in this directory.
2. Register the constructor in `elements/init.lua` (spine — the one place that
   knows the full roster).
3. Add a case to `serialize` / `deserialize` in `src/addons/SaveManager.lua` if
   it holds state worth persisting.
4. Exercise it in `tools/smoke_test.luau` **and** `examples/example.lua`.
5. `powershell -ExecutionPolicy Bypass -File tools/check.ps1` must come back
   `ALL CLEAN`.
