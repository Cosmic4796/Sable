# Sable

```
┌╴                                             ╶┐

   ███████  █████  ██████  ██      ███████
   ██      ██   ██ ██   ██ ██      ██
   ███████ ███████ ██████  ██      █████
        ██ ██   ██ ██   ██ ██      ██
   ███████ ██   ██ ██████  ███████ ███████

└╴            T A C T I C A L   U I            ╶┘
```

A from-scratch UI library for Roblox script hubs. Linoria-shaped API, original
code, and a visual identity that isn't a bootstrap theme: **tactical /
instrument** — warm dark grey, one amber accent, hard 1px hairlines, zero corner
radius, monospace throughout.

## Install

```lua
local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/Cosmic4796/Sable/main/Sable.lua"))()
```

One line. `ThemeManager` and `SaveManager` come attached — no extra loads.

**Try it first:** paste this for a full demo hub with every control, config
saving and themes.

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/Cosmic4796/Sable/main/examples/example.lua"))()
```

## Quick start

```lua
local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/Cosmic4796/Sable/main/Sable.lua"))()

local Window = Library:CreateWindow({ Title = "Sable", Center = true, AutoShow = true })
local Box = Window:AddTab("Main"):AddLeftGroupbox("Aimbot")

Box:AddToggle("AimbotEnabled", { Text = "Enabled", Default = false })
   :AddKeyPicker("AimbotKey", { Default = "MB2", Mode = "Hold", Text = "Aimbot" })

Box:AddSlider("AimbotFOV", { Text = "FOV", Default = 120, Min = 0, Max = 500 })

Window:AddSettingsTab()   -- themes, configs, keybind, unload — all wired

-- Read values anywhere:
if Toggles.AimbotEnabled.Value and Options.AimbotKey:GetState() then end
```

`Toggles`, `Options` and `Sable` are exported to `getgenv()`, and are also on
`Library.Toggles` / `Library.Options`.

Menu hotkey is **Insert**.

## What you get

| | |
|---|---|
| **13 controls** | toggles, sliders, dropdowns, colour/key pickers, inputs, progress bars, images, sections, paragraphs |
| **Settings tab in one call** | `Window:AddSettingsTab()` — themes, configs, keybind, unload |
| **6 themes + your own** | save named themes, set one as your startup default |
| **Shareable configs** | copy a config to your clipboard as one line, paste someone else's in |
| **Draggable HUD** | move the watermark and keybind list anywhere, position remembered |
| **Quiet scrollbars** | invisible until you scroll or hover |
| **Clean unload** | every connection tracked and torn down |

## Elements

```lua
Groupbox:AddLabel(text, doesWrap)
Groupbox:AddButton({ Text, Func, DoubleClick, Tooltip, Disabled })
Groupbox:AddDivider()
Groupbox:AddSection(text)                  -- named rule, breaks up a long groupbox
Groupbox:AddParagraph(title, body)         -- heading + wrapped copy, grows to fit

Groupbox:AddToggle(idx, opts)
Groupbox:AddSlider(idx, opts)
Groupbox:AddInput(idx, opts)
Groupbox:AddDropdown(idx, opts)
Groupbox:AddColorPicker(idx, opts)
Groupbox:AddKeyPicker(idx, opts)
Groupbox:AddProgressBar(idx, opts)         -- read-only
Groupbox:AddImage(idx, opts)               -- read-only
```

<details>
<summary><b>Options for each</b></summary>

```lua
AddToggle(idx, { Text, Default, Tooltip, DisabledTooltip, Risky, Disabled,
                 Visible, Callback })

AddSlider(idx, { Text, Default, Min, Max, Rounding, Suffix, Compact,
                 Segments, Callback })

AddInput(idx, { Text, Default, Placeholder, Numeric, Finished,
                ClearTextOnFocus, MaxLength, Callback })

AddDropdown(idx, { Text, Values, Default, Multi, AllowNull,
                   MaxVisibleDropdownItems, Searchable, Callback })

AddColorPicker(idx, { Default, Title, Transparency, Callback })

AddKeyPicker(idx, { Default, Text, Mode, SyncToggleState, NoUI,
                    Callback, ChangedCallback })   -- Mode: Toggle | Hold | Always

AddProgressBar(idx, { Text, Default, Min, Max, Rounding, Suffix,
                      Segments, Tooltip })

AddImage(idx, { Image, Height, ScaleType, Transparency, Tooltip })
```

</details>

Every element supports:

```lua
element.Value
element:SetValue(value, silent)     -- silent = true skips callbacks
element:OnChanged(fn, callNow)
element:SetVisible(bool)  :SetDisabled(bool)  :SetText(text)
element:SetTooltip(text, disabledText)
element:Destroy()
```

Extras: `Slider`/`ProgressBar` `:SetMin/:SetMax` · `Dropdown:SetValues` ·
`ColorPicker.Transparency` / `:SetValueRGB` · `KeyPicker:GetState()` /
`:OnClick(fn)` / `.Mode` · `Paragraph:SetText(title, body)` / `:SetBody` ·
`Image:SetImage(id)` / `:SetTransparency(n)` · `Button:AddButton(...)` splits the row.

**Inline pickers.** Toggles and Labels take a colour or key picker on the same row:

```lua
local esp = Box:AddToggle("Esp", { Text = "Boxes" })
esp:AddColorPicker("EspColor", { Default = Color3.fromRGB(233, 161, 59) })
esp:AddKeyPicker("EspKey", { Default = "B", Mode = "Toggle" })
```

These return **the picker**, not the host — so one can be chained off `AddToggle`,
but two cannot be chained together. Keep a reference, as above.

**Read-only elements.** `AddProgressBar` and `AddImage` live in `Options` so
scripts can drive them (`Options.Farm:SetValue(72)`), but are **never written to
a config** — progress and artwork are runtime state, not settings.

## Containers

```lua
Tab:AddLeftGroupbox(name)  /  Tab:AddRightGroupbox(name)
Tab:AddLeftTabbox()        /  Tab:AddRightTabbox()    -- Tabbox:AddTab(name) -> Groupbox

local dep = Groupbox:AddDependencyBox()
dep:AddSlider("Thickness", { ... })
dep:SetupDependencies({ { Toggles.ShowFOV, true } })  -- shown only when all match
```

## Library

```lua
Library:CreateWindow({ Title, Footer, Center, AutoShow, Size, Position, Resizable })
Library:Notify(textOrTable, duration)     -- { Title, Description, Time, Risk, Good }
Library:SetWatermark(text)  :SetWatermarkVisibility(bool)  :SetKeybindVisibility(bool)
Library:SetOpen(bool)  :Toggle()  :SetMenuKeybind("INS")
Library:SetScheme("Accent", Color3.fromRGB(...))    -- live retheme
Library:OnUnload(fn)  :Unload()
```

Hand every connection you make to the library so unloading takes it with you:

```lua
Library:GiveSignal(Library.RenderStepped:Connect(function(dt) end))
```

Scrollbars hide until scrolled or hovered. Set `Library.QuietScrollbars = false`
before `CreateWindow` for a constant faint bar, or call
`Library:QuietScrollbar(frame)` on your own `ScrollingFrame`.

## Themes and configs

```lua
local ThemeManager, SaveManager = Library.ThemeManager, Library.SaveManager

ThemeManager:SetFolder("Sable")
SaveManager:SetFolder("Sable/mygame")     -- per-hub, so hubs don't collide

Window:AddSettingsTab()                   -- builds the whole tab

ThemeManager:LoadDefault()
SaveManager:LoadAutoloadConfig()
```

`AddSettingsTab()` creates a **Menu** groupbox (keybind, watermark and
keybind-list toggles, reset HUD, unload), the **Theme** editor, and the
**Configuration** section. It excludes menu preferences from saved configs, and
leaves a folder you already chose alone.

Built-in themes: **Sable** (amber), **Ember**, **Signal**, **Ice**, **Void**,
**Mono**. All keep the warm dark base and move only the accent.

**Your own themes** — the Custom themes box saves whatever is on screen to a
named file:

```lua
ThemeManager:SaveCustomTheme("night ops")
ThemeManager:LoadCustomTheme("night ops")
ThemeManager:CustomThemeList()
```

`:SetDefault()` accepts a saved theme, so yours can be the one that loads.

### Sharing a config

```lua
SaveManager:CopyConfig()          -- to clipboard as "SABLE1:..."
SaveManager:ImportConfig(text)    -- apply someone else's
SaveManager:ExportConfig(name)    -- -> string
SaveManager:DecodeConfig(text)    -- -> table, no side effects
```

One paste-safe line: base64 of an LZW-compressed payload. A 48-value config is
~1900 characters. Export copies to the clipboard; import reads from a paste
field — executors expose `setclipboard` reliably but not `getclipboard`.

Import never errors, only reports: bad prefix, unknown version, invalid base64,
truncated payload, malformed JSON.

### Moving the HUD

Drag the watermark and keybind list **while the menu is open** — closed, they
ignore clicks entirely. Positions are saved when you let go.

```lua
Library:SetHudFolder("Sable")
Library:SaveHudLayout()  :LoadHudLayout()  :ResetHudLayout()
```

## Porting a Linoria script

1. Replace the three `loadstring` lines with one, then
   `local ThemeManager, SaveManager = Library.ThemeManager, Library.SaveManager`.
2. Element constructors and the `Toggles` / `Options` globals are unchanged.
3. Scheme keys accept the Linoria names — `MainColor`, `BackgroundColor`,
   `AccentColor`, `OutlineColor`, `FontColor`, `RiskColor`.
4. Optionally swap your hand-built settings tab for `Window:AddSettingsTab()`.

## Building

Source is in `src/`; `tools/build.py` bundles it into the single loadstring
artifact `Sable.lua` at the repo root.

```
powershell -ExecutionPolicy Bypass -File tools/bootstrap.ps1   # once, after cloning
powershell -ExecutionPolicy Bypass -File tools/check.ps1       # the gate
```

`check.ps1` must print `ALL CLEAN`. See [`tools/README.md`](tools/README.md) for
the harness and [`docs/SPEC.md`](docs/SPEC.md) for the build contract.

## Good to know

- **Callbacks do not fire on construction.** Building a menu would otherwise run
  every callback in your script during layout. Use `:OnChanged(fn, true)` if you
  want the initial value delivered. (Linoria differs here.)
- **`AllowNull` is single-select only.** A multi-select dropdown can always be
  emptied — otherwise the last item could never be unchecked.
- **Indexes are global.** `Toggles` and `Options` are keyed by the index string,
  so two controls sharing one index will overwrite each other. Prefix them if
  your hub is large.
- **Configs store settings, not state.** Progress bars and images are never
  written to a config file.
- The ScreenGui takes a randomised name, parents via `gethui()` when available
  (falling back to `CoreGui`, then `PlayerGui`), and is run through
  `syn.protect_gui` / `protect_gui` where present.
- Everything degrades outside an executor — filesystem calls become no-ops, so
  the menu still runs in Studio.

MIT licensed.
