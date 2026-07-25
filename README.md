# Sable

A from-scratch Roblox UI library for executor script hubs. Linoria-shaped API,
original code, and a deliberate visual identity: **tactical / instrument**.

Warm dark grey, one amber accent, hard 1px hairlines, zero corner radius,
uppercase letterspaced chrome, monospace numerals, corner ticks on the window
frame, and a segmented slider track. Dense on purpose — it reads like equipment
firmware, not a dashboard.

```
┌╴                                        ╶┐
   S A B L E                       SYS 1.0
└╴                                        ╶┘
   M A I N    V I S U A L S    P L A Y E R
   ▔▔▔▔▔▔▔
 ┌ AIMBOT ─────────┐ ┌ ESP ───────────────┐
 │ ENABLED     [▪] │ │ BOXES          [▪] │
 │ TEAM CHECK  [ ] │ │ NAMES          [ ] │
 │ FOV  ▬▬▬▬▭▭ 120 │ │ TRACERS        [▪] │
 │ BONE   HEAD   ▾ │ │ FILL   ▬▬▭▭▭    40 │
 └─────────────────┘ └────────────────────┘
```

## Quick start

```lua
local Library = loadstring(game:HttpGet("<your-raw-url>/dist/Sable.lua"))()

local Window = Library:CreateWindow({
    Title = "Sable",
    Footer = "sys 1.0",
    Center = true,
    AutoShow = true,
})

local Tabs = { Main = Window:AddTab("Main") }
local Box = Tabs.Main:AddLeftGroupbox("Aimbot")

Box:AddToggle("AimbotEnabled", { Text = "Enabled", Default = false })
   :AddKeyPicker("AimbotKey", { Default = "MB2", Mode = "Hold", Text = "Aimbot" })

Box:AddSlider("AimbotFOV", { Text = "FOV", Default = 120, Min = 0, Max = 500 })

-- Read values anywhere:
if Toggles.AimbotEnabled.Value and Options.AimbotKey:GetState() then
    -- ...
end
```

`Toggles`, `Options` and `Sable` are exported to `getgenv()`, and are also
available as `Library.Toggles` / `Library.Options`.

A full hub exercising every element is in [`examples/example.lua`](examples/example.lua).

## Elements

```lua
Groupbox:AddLabel(text, doesWrap)
Groupbox:AddButton({ Text, Func, DoubleClick, Tooltip, Disabled })
Groupbox:AddDivider()

Groupbox:AddToggle(idx, { Text, Default, Tooltip, DisabledTooltip,
                          Risky, Disabled, Visible, Callback })
Groupbox:AddSlider(idx, { Text, Default, Min, Max, Rounding, Suffix,
                          Compact, Segments, Callback })
Groupbox:AddInput(idx,  { Text, Default, Placeholder, Numeric, Finished,
                          ClearTextOnFocus, MaxLength, Callback })
Groupbox:AddDropdown(idx, { Text, Values, Default, Multi, AllowNull,
                            MaxVisibleDropdownItems, Searchable, Callback })
Groupbox:AddColorPicker(idx, { Default, Title, Transparency, Callback })
Groupbox:AddKeyPicker(idx, { Default, Text, Mode, SyncToggleState, NoUI,
                             Callback, ChangedCallback })
```

Toggles and Labels accept inline pickers, which render to the left of the
control on the same row:

```lua
local esp = Box:AddToggle("Esp", { Text = "Boxes" })
esp:AddColorPicker("EspColor", { Default = Color3.fromRGB(233, 161, 59) })
esp:AddKeyPicker("EspKey", { Default = "B", Mode = "Toggle" })
```

`:AddColorPicker` / `:AddKeyPicker` return **the picker**, not the host, so a
single one can be chained off `AddToggle` but two cannot be chained together —
keep a reference to the toggle as above.

Every element supports:

```lua
element.Value
element:SetValue(value, silent)   -- silent = true skips callbacks
element:OnChanged(fn, callNow)
element:SetVisible(bool)
element:SetDisabled(bool)
element:SetText(text)
element:SetTooltip(text, disabledText)
element:Destroy()
```

Type-specific extras: `Slider:SetMin/SetMax`, `Dropdown:SetValues`,
`ColorPicker.Transparency` / `:SetValueRGB`, `KeyPicker:GetState()` /
`:OnClick(fn)` / `.Mode`, `Button:AddButton(...)` (splits the row).

### Containers

```lua
Tab:AddLeftGroupbox(name) / Tab:AddRightGroupbox(name)
Tab:AddLeftTabbox() / Tab:AddRightTabbox()   -- Tabbox:AddTab(name) -> Groupbox

local dep = Groupbox:AddDependencyBox()
dep:AddSlider("Thickness", { ... })
dep:SetupDependencies({ { Toggles.ShowFOV, true } })   -- visible only when all match
```

### Library

```lua
Library:CreateWindow(config)
Library:Notify(textOrTable, duration)      -- { Title, Description, Time, Risk, Good }
Library:SetWatermark(text) / :SetWatermarkVisibility(bool)
Library:SetKeybindVisibility(bool)
Library:SetOpen(bool) / :Toggle() / :SetMenuKeybind("INS")
Library:SetScheme("Accent", Color3.fromRGB(...))   -- live retheme
Library:OnUnload(fn) / Library:Unload()
```

Menu hotkey defaults to `Insert`.

## Themes and configs

```lua
local ThemeManager, SaveManager = Library.ThemeManager, Library.SaveManager

SaveManager:IgnoreThemeSettings()
SaveManager:SetIgnoreIndexes({ "MenuKeybind" })

ThemeManager:SetFolder("Sable")
SaveManager:SetFolder("Sable/mygame")

SaveManager:BuildConfigSection(Tabs.Settings)
ThemeManager:ApplyToTab(Tabs.Settings)
SaveManager:LoadAutoloadConfig()
```

Built-in themes: **Sable** (default amber), **Ember**, **Signal**, **Ice**,
**Void**, **Mono**. All keep the warm dark neutral base and only move the
accent — the palette is a system, not a colour picker.

Configs are JSON under `<folder>/settings/`, themes under `<folder>/themes/`.
Outside an executor every filesystem call degrades to a no-op instead of
erroring, so the menu still runs in Studio.

## Porting a Linoria script

Mostly mechanical:

1. Replace the three `loadstring` lines with one, then
   `local ThemeManager, SaveManager = Library.ThemeManager, Library.SaveManager`.
2. `Library:CreateWindow{}` config keys are the same; `Footer` replaces the
   version text.
3. Element constructors and the `Toggles` / `Options` globals are unchanged.
4. Scheme keys accept the Linoria names as aliases — `MainColor`,
   `BackgroundColor`, `AccentColor`, `OutlineColor`, `FontColor`, `RiskColor`
   all map onto Sable's palette.

## Building

Source lives in `src/` as separate modules; `tools/build.py` bundles them into
the single loadstring artifact `dist/Sable.lua` (a local `require` shim, so
module bodies are copied verbatim and line numbers map through
`dist/Sable.map.json`).

```
python tools/build.py                                     # bundle only
python tools/smoke.py                                     # headless run of the bundle
powershell -ExecutionPolicy Bypass -File tools/check.ps1  # everything
```

`check.ps1` is the one command that matters. It runs four gates and fails on any
of them:

| gate | tool | what it catches |
|------|------|-----------------|
| syntax | `luau-compile` | parse errors, per module |
| src typecheck + lint | `luau-lsp` + `tools/globalTypes.d.luau` | wrong property names, bad enums, dead code |
| bundle typecheck | same, on `dist/Sable.lua` | authoritative — it is what ships |
| smoke | `luau` + `tools/mock_roblox.luau` | **runtime** faults: nil indexes, load order, config round-trips, teardown |

The smoke gate is the important one. `tools/mock_roblox.luau` stands in for the
Roblox API so `luau` can actually *execute* the built bundle headlessly — it
constructs a menu with every element type, round-trips a config through JSON,
applies every theme, and unloads. Typechecking cannot see any of that. See
`tools/README.md`.

## Layout

```
src/init.lua              root Library, ScreenGui, input signals, popup layer, primitives
src/Util.lua              helpers: instances, colour, text, input naming, filesystem
src/Signal.lua            pcall-isolated signals
src/Theme.lua             palette, metrics, fonts, colour registry
src/Window.lua            window / tab / groupbox / tabbox / dependency box
src/Overlays.lua          watermark, notifications, keybind list
src/elements/             Base + the nine controls (see src/elements/README.md)
src/addons/               ThemeManager, SaveManager
tools/                    build, verification, headless mock (see tools/README.md)
examples/example.lua      full hub exercising every element
```

`SPEC.md` is the internal build contract — read it before changing anything.

## Notes

- The ScreenGui takes a randomised name and is parented via `gethui()` when the
  executor provides it, falling back to `CoreGui` then `PlayerGui`, and is run
  through `syn.protect_gui` / `protect_gui` when available.
- `IgnoreGuiInset` is deliberately `false`: it puts `AbsolutePosition` in the
  same coordinate space as `UserInputService:GetMouseLocation()`, which every
  hit test depends on. Do not change it.
- Every connection the library makes is tracked and torn down by
  `Library:Unload()`.
- **Callbacks do not fire on construction.** Building a menu would otherwise run
  every callback in your script during layout. Use `:OnChanged(fn, true)` when
  you want the initial value delivered. (Linoria differs here.)
- **`AllowNull` governs single-select only.** A multi-select dropdown can always
  be emptied — otherwise the last item could never be unchecked.
- The watermark separator is ASCII `|`, not `│`: `Enum.Font.Code` has no
  box-drawing glyphs and a missing one renders as tofu. It is a single named
  constant in `src/Overlays.lua` if you want it changed.
