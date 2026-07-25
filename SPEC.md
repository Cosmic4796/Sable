# Sable — build contract

A from-scratch Roblox UI library for executor script hubs. Linoria-shaped API,
original code, **"tactical / instrument"** visual identity.

This document is the contract. The spine (`Util`, `Signal`, `Theme`, `init`,
`elements/Base`, `elements/init`) is already written and is **authoritative** —
if this doc and the spine disagree, the spine wins. Do not edit spine files.

---

## 1. Layout & module system

```
src/
  init.lua              root Library          [SPINE - do not edit]
  Util.lua              helpers               [SPINE - do not edit]
  Signal.lua            signals               [SPINE - do not edit]
  Theme.lua             palette + metrics     [SPINE - do not edit]
  Window.lua            window/tab/groupbox containers
  Overlays.lua          watermark, notifications, keybind list
  elements/
    Base.lua            element base          [SPINE - do not edit]
    init.lua            installer             [SPINE - do not edit]
    Label.lua  Button.lua  Divider.lua
    Toggle.lua Slider.lua  Input.lua
    Dropdown.lua ColorPicker.lua KeyPicker.lua
  addons/
    ThemeManager.lua  SaveManager.lua
tools/build.py          bundles src -> dist/Sable.lua
dist/Sable.lua          single-file loadstring artifact
```

Modules are bundled into one file by `tools/build.py`. Each file is wrapped in
`__modules["<name>"] = function() ... end` and `require` is a **local shim** in
the bundle, so inside any module you write:

```lua
local Util = require("Util")
local Base = require("elements/Base")
```

Module names are the path under `src/` without `.lua`, always forward slashes.
Requires are lazy and cached; ordering does not matter. **No cycles** — nothing
under `elements/` or `Window.lua` may `require("init")`. They receive `Library`
as a function argument instead.

---

## 2. Visual identity — "tactical / instrument"

Warm dark grey, one amber accent, hard hairlines, uppercase letterspaced
chrome, monospace numerals. Think equipment firmware, not a web dashboard.

### Hard rules (a reviewer will fail the file on any of these)

- **Zero corner radius.** No `UICorner`, ever.
- **No `BorderSizePixel`.** Always `BorderSizePixel = 0` + a `UIStroke` via
  `Util.Stroke` or `Library:Panel`.
- **No gradients as decoration.** `Util.Falloff` is allowed on window chrome
  only, and only as a barely-visible vertical falloff.
- No drop shadows, no glow, no blur, no translucent "glass".
- No emoji, and no icon fonts. Text and rectangles only.
- **Monospace everywhere** — `Library.Fonts.Label/Value/Title` are all
  `Enum.Font.Code`. Never hardcode a different font.
- **One accent.** `Accent` marks active/on state and nothing else. Inactive
  chrome is `FontDim`/`Outline`. Do not colour things for variety.
- Element labels are **uppercase, not letterspaced** (`Library:FormatLabel`).
  Chrome (window title, tab names, group headers) is **uppercase AND
  letterspaced** (`Library:Chrome`).
- Numeric readouts are **right-aligned**, `Library.Fonts.Value`, size
  `Library.Sizes.TextSmall`, colour `FontDim` at rest / `Font` when active.
- Motion is mechanical: only `Library.Motion.Fast` (0.09s) or
  `Library.Motion.Slow` (0.16s), Quad/Out. No bounce, elastic, or spring.

### Palette — `Library.Scheme` (never hardcode a `Color3`)

| key           | rgb            | use                                    |
|---------------|----------------|----------------------------------------|
| `Background`  | 18, 17, 15     | window body                            |
| `Panel`       | 26, 25, 22     | groupboxes, controls, popups           |
| `PanelRaised` | 34, 32, 29     | hover state, tooltips, popup rows      |
| `PanelSunken` | 13, 12, 11     | slider troughs, input fields           |
| `Outline`     | 52, 49, 44     | hairlines                              |
| `OutlineDim`  | 36, 34, 30     | internal dividers                      |
| `Accent`      | 233, 161, 59   | on/active only                         |
| `AccentDim`   | 126, 88, 34    | derived accent shade                   |
| `Font`        | 218, 213, 204  | primary text                           |
| `FontDim`     | 124, 117, 107  | secondary text, off state              |
| `FontFaint`   | 84, 79, 72     | disabled text                          |
| `Risk`        | 226, 78, 63    | `Risky = true` labels, error notifies   |
| `Good`        | 126, 176, 106  | success notifies                       |
| `Black`       | 0, 0, 0        | outermost outline                      |

Colours must go through `Library:Panel(props, fillKey, strokeKey)` or the
`Theme = { Prop = "SchemeKey" }` field on `Library:Create`, so live theme
switching works. **A hardcoded Color3 in an element is a bug.**

### Metrics — `Library.Sizes`

`WindowWidth 566` · `WindowHeight 604` · `TitleBar 30` · `TabStrip 26` ·
`RowHeight 20` · `RowGap 2` · `GroupPad 8` · `GroupGap 8` · `ColumnGap 8` ·
`GroupHeader 18` · `Outline 1` · `Tick 7` · `Text 12` · `TextSmall 11` ·
`TextTitle 13` · `Control 13` · `Track 8` · `Segments 16` · `Indicator 2` ·
`PopupMaxItems 9` · `ScrollBar 3`

### Signature details

- **Corner ticks** — `Library:CornerTicks(frame, "Accent")` draws L-shaped marks
  at the four corners. Use on the **window frame and popups only**. Never on
  groupboxes; it becomes noise.
- **Interrupted group header** — a groupbox's top hairline is broken by its
  title. Implement as a `TextLabel` with an opaque `Background` fill and ~4px
  horizontal padding, positioned over the top edge with a higher `ZIndex`.
- **Segmented slider bar** — the track is `Library.Sizes.Segments` (16) equal
  frames in a horizontal `UIListLayout`. Value changes **recolour** segments
  (`Accent` filled / `PanelSunken` empty); they are never resized. The numeric
  readout carries the exact value.

---

## 3. Library primitives available to you

Already implemented in the spine. Use these instead of rolling your own.

```lua
Library:Create(class, props)             -- props.Theme = {Prop="SchemeKey"} auto-registers
Library:Panel(props, fillKey, strokeKey) -- returns frame, stroke; strokeKey=false skips
Library:Label(props, colorKey)           -- monospace TextLabel, left aligned
Library:Row(container, height)           -- full-width row inside a container
Library:HitButton(parent, props)         -- invisible TextButton for hit testing
Library:CornerTicks(parent, colorKey, length, thickness)
Library:Tween(instance, props, info)
Library:BindHover(button, target, normalKey, hoverKey)
Library:MakeDraggable(handle, target)
Library:GiveTooltip(guiObject, text, disabledText)  -- returns update(text, disabledText)
Library:OpenPopup(frame, anchor, {Height=, Width=, Gap=, OnClose=})
Library:ClosePopup(popup?)
Library:GetColor(schemeKeyOrColor3)
Library:AddToRegistry(instance, {Prop="SchemeKey"}, isHud)   -- first registration only
Library:Retheme(instance, {Prop="SchemeKey"})               -- state changes: on/off, enabled/disabled
Library:RemoveFromRegistry(instance)
Library:UpdateColorsUsingRegistry()
Library:SetScheme(keyOrTable, color)
Library:FormatLabel(text)   -- uppercase
Library:Chrome(text)        -- uppercase + letterspaced
Library:SafeCallback(fn, ...)
Library:GiveSignal(connection)   -- REQUIRED for every connection you make
Library:OnUnload(fn)
Library:SetOpen(bool) / Library:Toggle() / Library:SetMenuKeybind(name)
```

Layers (all full-screen transparent frames): `Library.WindowHolder` (Z 1),
`HudHolder` (20), `PopupHolder` (100), `NotificationHolder` (200),
`TooltipHolder` (300). `ZIndexBehavior` is `Sibling`, so the holder's ZIndex
decides stacking between subtrees.

Signals: `Library.InputBegan / InputEnded / InputChanged / RenderStepped /
MenuToggled` — `:Connect(fn)` returns a connection; **always** pass it through
`Library:GiveSignal`.

`Library.CapturingInput` — set `true` by KeyPicker while waiting for a bind so
the menu hotkey does not fire on the captured keystroke. Every input handler
that acts on a bind must check it.

`Util` (via `require("Util")` or `Library.Util`) provides `Create`, `Stroke`,
`Falloff`, `Padding`, `ListLayout`, `Clamp`, `Lerp`, `Round`, `Alpha`,
`FormatNumber`, `ToHex`, `FromHex`, `Shift`, `Mix`, `Letterspace`, `TextSize`,
`Truncate`, `InputName`, `KeyCodeFromName`, `IsHeld`, `InputMatches`,
`MousePosition`, `MouseOver`, `Tween`, `Find`, `Count`, `DeepCopy`,
`SortedKeys`, `FS` (filesystem), `SetClipboard`, `ExecutorName`, `Global`.

---

## 4. Container contract (`Window.lua` provides, elements consume)

Every element container — groupbox, tabbox tab, dependency box — is an object
with **exactly** this shape:

```lua
container.Library    -- the Library
container.Container  -- Frame that rows parent into; has a vertical UIListLayout
container.Elements   -- array of element objects
container:Resize()   -- recompute height; safe to call any time
```

Groupboxes **auto-size** from their `UIListLayout.AbsoluteContentSize` — an
element never has to report its height. `Resize()` exists for explicit nudges
and must be safe to call when nothing changed.

### Window / Tab API

```lua
Library:CreateWindow({
  Title = "Sable", Footer = "v1.0", Center = true, AutoShow = true,
  Size = UDim2?, Position = UDim2?, Resizable = true, MenuFadeTime = 0.14,
}) -> Window

Window:AddTab(name) -> Tab
Window:SetTab(tab)
Window:SetTitle(text) / Window:SetFooter(text)
Window:SetVisible(bool)      -- REQUIRED: Library:SetOpen calls this
Window.Tabs                  -- array
Window.Frame                 -- root Frame in Library.WindowHolder

Tab:AddLeftGroupbox(name) -> Groupbox
Tab:AddRightGroupbox(name) -> Groupbox
Tab:AddLeftTabbox() -> Tabbox
Tab:AddRightTabbox() -> Tabbox
Tabbox:AddTab(name) -> Groupbox        -- a container, per the shape above

Groupbox:AddDependencyBox() -> DependencyBox   -- container + :SetupDependencies(list)
DependencyBox:SetupDependencies({ { Toggles.Foo, true }, { Options.Bar, "Head" } })
```

A dependency box is a container that is visible only while **every** pair
matches (`element.Value == expected`). It subscribes with `:OnChanged` and
calls `Resize()` on its parent when visibility flips.

---

## 5. Element contract

```lua
local Base = require("elements/Base")

local element = Base.Create(Library, container, "Toggle", index, options)
-- ... build visuals, set element.Row / element.Label / element.Hit / element.Value ...
return Base.Finish(element, Library.Toggles)   -- or Library.Options
```

`Base.Create` gives you `Library`, `Parent`, `Type`, `Index`, `Opts`,
`Callbacks`, `Text`, `Tooltip`, `DisabledTooltip`, `Disabled`, `Visible`,
`Risky` and appends to `container.Elements`.

You **must** set: `element.Row` (from `Library:Row`), `element.Value`.
You **should** set: `element.Label`, `element.Hit`. (You do *not* need to record
a row size for `SetVisible` — `UIListLayout` already skips invisible children,
so the groupbox re-sizes on its own.)
You **must** implement: `element:SetValue(value, silent)` and
`element:Display()`.

`SetValue` applies + clamps + repaints, then calls `self:Fire()` **unless**
`silent` is truthy. SaveManager loads configs with `silent = false` so
callbacks run on load.

Base already provides `OnChanged(fn, callNow)`, `Fire()`, `SetVisible`,
`SetDisabled`, `SetText`, `SetTooltip`, `Destroy`.

### Addon slot (inline pickers)

Toggle and Label **must** create `element.Right`:

```lua
element.Right = Library:Create("Frame", {
  Name = "Right", BackgroundTransparency = 1, AnchorPoint = Vector2.new(1, 0.5),
  Position = UDim2.new(1, 0, 0.5, 0), Size = UDim2.new(0, 0, 1, 0),
  AutomaticSize = Enum.AutomaticSize.X, Parent = row,
})
-- horizontal UIListLayout, VerticalAlignment Center, Padding 4, SortOrder LayoutOrder
```

The element's own control goes in `element.Right` at `LayoutOrder = 100`.
Attached ColorPickers/KeyPickers use `LayoutOrder = 10 + n`, so they render to
the **left** of the primary control.

### Store placement

`Library.Toggles` — Toggle only. `Library.Options` — Slider, Input, Dropdown,
ColorPicker, KeyPicker. Label / Button / Divider are unregistered (pass `nil`).

---

## 6. Public element API (what a script author writes)

```lua
Groupbox:AddLabel(text, doesWrap) -> Label          -- :SetText, :AddColorPicker, :AddKeyPicker
Groupbox:AddButton(textOrTable)   -> Button         -- {Text, Func, DoubleClick, Tooltip, Disabled}
                                                    -- Button:AddButton(...) splits the row
Groupbox:AddDivider()

Groupbox:AddToggle(idx, { Text, Default=false, Tooltip, DisabledTooltip,
                          Risky=false, Disabled=false, Visible=true, Callback })
  -> .Value boolean · :SetValue(v, silent) · :AddColorPicker(idx, o) · :AddKeyPicker(idx, o)

Groupbox:AddSlider(idx, { Text, Default, Min, Max, Rounding=0, Suffix="",
                          Compact=false, Segments=16, Tooltip, Callback })
  -> .Value number · :SetValue(v, silent) · :SetMin(n) · :SetMax(n)

Groupbox:AddInput(idx, { Text, Default="", Placeholder="", Numeric=false,
                         Finished=false, ClearTextOnFocus=true, MaxLength,
                         Tooltip, Callback })
  -> .Value string · :SetValue(v, silent)
     Finished=true fires only on Enter/focus-loss; otherwise every keystroke.

Groupbox:AddDropdown(idx, { Text, Values={}, Default=1, Multi=false,
                            AllowNull=false, MaxVisibleDropdownItems=9,
                            Searchable=false, Tooltip, Callback })
  -> .Value string|{[string]=true} · :SetValue(v, silent) · :SetValues(list)
     Multi=false -> Value is a string (or nil when AllowNull).
     Multi=true  -> Value is a set: { ["Head"] = true }.

Groupbox:AddColorPicker(idx, { Default=Color3, Title, Transparency=nil,
                               Tooltip, Callback })
  -> .Value Color3 · .Transparency number|nil · :SetValue(c, silent)
     :SetValueRGB(c) · popup = SV square + hue bar + hex field (+ alpha bar
     when Transparency is a number)

Groupbox:AddKeyPicker(idx, { Default="None", Text, Mode="Toggle"|"Hold"|"Always",
                             SyncToggleState=false, NoUI=false, Tooltip,
                             Callback, ChangedCallback })
  -> .Value string (bind name) · .Mode string · :GetState() -> boolean
     :SetValue({key, mode}, silent) · :OnClick(fn)
     Toggle: flips state on press. Hold: true while held. Always: always true.
     NoUI=false registers it in the keybind list overlay.
     SyncToggleState=true mirrors the parent Toggle's value.
```

---

## 7. Overlays API (`Overlays.lua` must install these)

```lua
Library:Notify(textOrTable, duration)
  -- table form: { Title, Description, Time=5, Risk=false, Good=false }
Library:SetWatermark(text)
Library:SetWatermarkVisibility(bool)
Library:SetKeybindVisibility(bool)

Library.KeybindList:Set(id, { Text=, Key=, Mode=, Active= })  -- create or update
Library.KeybindList:Remove(id)
```

Watermark sits in `HudHolder`, top-left, one line, monospace, with `Accent`
separators: `SABLE │ 142 FPS │ 38 MS │ 15:04:22`. It must survive the menu
being closed. Notifications stack in `NotificationHolder` on
`Library.NotifySide`, each a hairline panel with a 2px `Accent` (or `Risk`/
`Good`) left edge bar, sliding in over `Motion.Slow`.

---

## 8. Addons

```lua
Library.ThemeManager:SetLibrary(L) :SetFolder(path) :ApplyToTab(tab)
  :ApplyTheme(name) :LoadDefault() :SetDefault(name) .BuiltInThemes
Library.SaveManager:SetLibrary(L) :SetFolder(path) :IgnoreThemeSettings()
  :SetIgnoreIndexes({...}) :BuildConfigSection(tab) :LoadAutoloadConfig()
  :Save(name) :Load(name) :Delete(name) :RefreshConfigList()
```

Both are reached off `Library` (already `SetLibrary`'d by the spine); the
`SetLibrary` method stays for Linoria source compatibility and must be a safe
no-op when called again.

Configs serialise `Library.Toggles` and `Library.Options` by index to JSON
under `<folder>/settings/<name>.json` using `Util.FS`. Serialise per type:
Toggle→bool, Slider→number, Input→string, Dropdown→string or set,
ColorPicker→`{hex, transparency}`, KeyPicker→`{key, mode}`. Loading calls
`:SetValue(value)` (not silent) so callbacks run. Unknown indexes are skipped,
never errored on. All filesystem access goes through `Util.FS`, which degrades
to no-ops outside an executor.

`ThemeManager.BuiltInThemes` must include the default (`"Sable"`) plus at
least: `Ember` (red), `Signal` (green), `Ice` (cyan), `Void` (violet, low
saturation), `Mono` (no accent — accent is a light grey). Each is a full
`Scheme` table; applying one calls `Library:SetScheme(table)`.

---

## 9. Conventions

- Tabs for indentation. `--!nonstrict` on line 1 of every file.
- Comments explain **why**, not what. No banner art beyond the existing
  `--=====` section rules. No commented-out code.
- `local X = ...` at the top; no globals except the intentional `getgenv`
  exports in `init.lua`.
- Every `:Connect` goes through `Library:GiveSignal`.
- Every user callback goes through `Library:SafeCallback`.
- Guard against `Library.Unloaded` inside `RenderStepped` handlers.
- Never `wait()` or `spawn()`; use `task.wait` / `task.spawn` / `task.defer`.
- `Enum.KeyCode.Unknown` is missing from the bundled type definitions even
  though it exists at runtime — compare `keyCode.Name == "Unknown"` instead.

## 10. Verification

```
powershell -ExecutionPolicy Bypass -File tools\check.ps1
```

Syntax-gates every module with `luau-compile`, then typechecks and lints the
tree against real Roblox API definitions. **It must exit clean.**
