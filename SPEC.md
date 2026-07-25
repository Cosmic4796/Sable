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
    Track.lua           shared segmented bar (helper, not an element)
    Label.lua  Button.lua  Divider.lua
    Section.lua Paragraph.lua Image.lua
    Toggle.lua Slider.lua ProgressBar.lua Input.lua
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

`WindowWidth 620` · `WindowHeight 660` · `TitleBar 34` · `TabStrip 30` ·
`RowHeight 26` · `RowGap 4` · `GroupPad 12` · `GroupGap 12` · `ColumnGap 12` ·
`GroupHeader 20` · `Outline 1` · `Tick 8` · `Text 13` · `TextSmall 12` ·
`TextTitle 14` · `Control 15` · `Track 9` · `Segments 16` · `Indicator 2` ·
`PickerSquare 144` · `PopupMinWidth 140` · `PopupMaxItems 9` · `ScrollBar 3` ·
`ScrollBarFaint 0.5` (transparency the bar fades *in* to) — with
`Motion.ScrollBarIdle 0.6` (seconds before it fades back out)

Elements derive their internal gaps from these rather than inventing new keys.
Half a `GroupPad` (`math.ceil(GroupPad / 2)`) is the library's inner gap unit —
label-to-control, field padding, popup gutters — the same way `Window.lua`
halves `ColumnGap`. `RowGap` is the between-things gap and doubles as leading
(`TextSmall + RowGap` is one line of readout). `Outline` is the hairline atom:
inner insets, cell gutters and marker overhangs are all counted in hairlines.

### Signature details

- **Corner ticks** — `Library:CornerTicks(frame, "Accent")` draws L-shaped marks
  at the four corners. Use on the **window frame and popups only**. Never on
  groupboxes; it becomes noise.
- **Interrupted group header** — a groupbox's top hairline is broken by its
  title. Implement as a `TextLabel` with an opaque `Background` fill and ~4px
  horizontal padding, positioned over the top edge with a higher `ZIndex`.
- **Quiet scrollbars** — the stock Roblox bar is the last default chrome in the
  design, so every `ScrollingFrame` goes through `Library:QuietScrollbar`:
  `ScrollBarImageTransparency` is 1 at rest, tweens to `Sizes.ScrollBarFaint`
  over `Motion.Fast` while the canvas moves or the cursor is over the frame, and
  back to 1 over `Motion.Slow` `Motion.ScrollBarIdle` seconds after both stop.
  It never appears while `AbsoluteCanvasSize` fits `AbsoluteWindowSize` on an
  axis `ScrollingDirection` actually scrolls, and it is re-evaluated when the
  canvas size changes, since groupboxes grow and shrink. Hover is the one state
  that holds the bar up with no fade queued, and `MouseLeave` never arrives when
  a frame is hidden under a still cursor, so hover is re-tested against the
  cursor rather than trusted — a bar can never be pinned on by a stale hover.
  The colour stays `Outline` through the registry — never `Accent`,
  which means on/active. `ScrollBarThickness` is never touched: a zero-width bar
  is also a zero-width drag target. `Library.QuietScrollbars = false`, set
  before the window is created, pins every bar at the faint value instead.
- **Segmented slider bar** — the track is `Library.Sizes.Segments` (16) equal
  frames in a horizontal `UIListLayout`. Value changes **recolour** segments
  (`Accent` filled / `PanelSunken` empty); they are never resized. The numeric
  readout carries the exact value. There is exactly **one** implementation of it,
  `elements/Track`, shared by Slider and ProgressBar — a second segmented bar
  would drift out of step with the first.

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
Library:QuietScrollbar(scrollingFrame)   -- REQUIRED on every ScrollingFrame
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
`MousePosition`, `MouseInGuiSpace`, `GuiInsetOffset`, `MouseOver`, `Tween`,
`Find`, `Count`, `DeepCopy`,
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

`Library.Toggles` — Toggle only. `Library.Options` — Slider, ProgressBar, Input,
Dropdown, ColorPicker, KeyPicker, Image. Label / Button / Divider / Section /
Paragraph are unregistered (pass `nil`).

Being in `Library.Options` is **not** the same as being saved. `SaveManager`'s
`serialize` dispatches on `element.Type` and ends in a bare `return nil`, which
drops every type it has no case for; `Collect` then skips it (`if ok and entry
then`), and `Apply` cannot match it either, because it requires
`element.Type == entry.type`. ProgressBar and Image are runtime state and depend
on exactly that — **do not add a case for either**.

---

## 6. Public element API (what a script author writes)

```lua
Groupbox:AddLabel(text, doesWrap) -> Label          -- :SetText, :AddColorPicker, :AddKeyPicker
Groupbox:AddButton(textOrTable)   -> Button         -- {Text, Func, DoubleClick, Tooltip, Disabled}
                                                    -- Button:AddButton(...) splits the row
Groupbox:AddDivider()

Groupbox:AddSection(text) -> Section
  -- A named break: chrome caption on the left, then a hairline out to the right
  -- edge on the caption's centre line. Taller than a control row, holds no
  -- value, not stored. :SetText(text) RE-MEASURES, so the rule still starts
  -- after the caption.

Groupbox:AddParagraph(title, body) -> Paragraph
  -- Explanatory copy: instructions, a changelog, a warning. Title in the label
  -- voice, body wrapped underneath in FontDim, ROW auto-sizing to the text. The
  -- body keeps the caller's own casing -- it is a sentence, not a label.
  -- .Body string · .Value == .Body · :SetText(title, body?) · :SetBody(body)
  -- Not stored. Reflows on :SetText/:SetBody and when the column changes width.

Groupbox:AddToggle(idx, { Text, Default=false, Tooltip, DisabledTooltip,
                          Risky=false, Disabled=false, Visible=true, Callback })
  -> .Value boolean · :SetValue(v, silent) · :AddColorPicker(idx, o) · :AddKeyPicker(idx, o)

Groupbox:AddSlider(idx, { Text, Default, Min, Max, Rounding=0, Suffix="",
                          Compact=false, Segments=16, Tooltip, Callback })
  -> .Value number · :SetValue(v, silent) · :SetMin(n) · :SetMax(n)

Groupbox:AddProgressBar(idx, { Text, Default=0, Min=0, Max=100, Rounding=0,
                               Suffix="%", Segments=16, Tooltip, Callback })
  -> .Value number · :SetValue(v, silent) · :SetMin(n) · :SetMax(n)
     The slider's segmented track and right-aligned readout, read ONLY: no hit
     button, no drag, and the readout stays FontDim because nothing the user
     does can move it. Registered in Library.Options so a script can drive it;
     never written to a config, because progress is runtime state.

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

Groupbox:AddImage(idx, { Image="rbxassetid://...", Height=RowHeight*4,
                         ScaleType=Enum.ScaleType.Fit, Transparency=0, Tooltip })
  -> .Value string (the asset id) · :SetImage(id, silent) · :SetValue(id, silent)
     :SetTransparency(n) · .ImageLabel
     A hairline-outlined sunken panel, full row width, holding one ImageLabel.
     Registered in Library.Options so a hub can swap the asset live; never
     written to a config.
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

Library.HudFolder                 -- defaults to Library.Name
Library:SetHudFolder(path)
Library:SaveHudLayout()  -> bool  -- writes <HudFolder>/hud.json
Library:LoadHudLayout()  -> bool  -- applies saved positions, clamped
Library:ResetHudLayout()          -- back to defaults, then saves
Library:GetHudLayout()   -> { Watermark = {X=,Y=}, KeybindList = {X=,Y=} }
```

Watermark sits in `HudHolder`, top-left, one line, monospace, with `Accent`
separators: `SABLE │ 142 FPS │ 38 MS │ 15:04:22`. It must survive the menu
being closed. Notifications stack in `NotificationHolder` on
`Library.NotifySide`, each a hairline panel with a 2px `Accent` (or `Risk`/
`Good`) left edge bar, sliding in over `Motion.Slow`.

### HUD placement

The watermark and the keybind list are **independently positioned children of
`HudHolder`** — never siblings under a shared `UIListLayout`, because a layout
owns its children's positions and neither panel could then be dragged. Defaults
put the watermark at a `GroupPad` margin and the keybind list one HUD gap below
it, which is where the old column put them; hiding one no longer reflows the
other.

Each panel is dragged by a `Library:HitButton` that tracks its rectangle (a
button inside the panel would be swept into that panel's own list layout). The
handle exists **only while `Library.Toggled`** — closed, it must not swallow a
click. Hovering it turns the panel's outline `Accent`; that is the entire
affordance, no new colours and no cursor changes. Positions are clamped inside
`HudHolder.AbsoluteSize` allowing for the panel's own `AbsoluteSize`, and
re-clamped when either changes, since both panels auto-size. Every re-clamp
works from where the panel was **put**, never from the result of the previous
clamp — clamping a clamp is a running minimum, so a panel parked against an
edge would creep inward each time it grew and never come back when it shrank.

Positions persist as plain numbers in `<HudFolder>/hud.json` through `Util.FS` —
never a `UDim2`, which `HttpService` cannot encode. A save happens when a drag
**ends**, not per frame. A missing or corrupt file degrades silently to the
defaults. `AddSettingsTab` calls `LoadHudLayout` after the addon folders are
defaulted, and offers a **Reset HUD positions** button.

---

## 8. Addons

```lua
Library.ThemeManager:SetLibrary(L) :SetFolder(path) :ApplyToTab(tab)
  :ApplyTheme(name) :LoadDefault() :SetDefault(name) .BuiltInThemes
  :ThemesFolder() :SaveCustomTheme(name) :LoadCustomTheme(name)
  :DeleteCustomTheme(name) :CustomThemeList() :RefreshCustomThemeList()
Library.SaveManager:SetLibrary(L) :SetFolder(path) :IgnoreThemeSettings()
  :SetIgnoreIndexes({...}) :BuildConfigSection(tab) :LoadAutoloadConfig()
  :Save(name) :Load(name) :Delete(name) :RefreshConfigList()
  :ExportConfig(name?) -> string?, err?    -- name: that file. no name: live state
  :CopyConfig(name?)   -> ok, text?, err?  -- export + clipboard + notify
  :ImportConfig(text, name?) -> ok, err?   -- decode + :Apply, and save when named
  :DecodeConfig(text)  -> table?, err?     -- pure; no elements, no files, no notify
```

Both are reached off `Library` (already `SetLibrary`'d by the spine); the
`SetLibrary` method stays for Linoria source compatibility and must be a safe
no-op when called again.

Configs serialise `Library.Toggles` and `Library.Options` by index to JSON
under `<folder>/settings/<name>.json` using `Util.FS`. Serialise per type:
Toggle→bool, Slider→number, Input→string, Dropdown→string or set,
ColorPicker→`{hex, transparency}`, KeyPicker→`{key, mode}`. Loading calls
`:SetValue(value)` (not silent) so callbacks run. Unknown indexes are skipped,
never errored on — and so are element **types** with no case in `serialize`
(ProgressBar, Image), which is how runtime-only readouts stay out of configs.
All filesystem access goes through `Util.FS`, which degrades to no-ops outside
an executor.

### Shareable configs

A config also travels as **one line of paste-safe text** so it can be handed to
someone else: `SABLE1:` followed by base64 of a payload. The version sits in the
**prefix**, so a build that cannot read a string says *why* instead of guessing;
the payload's **first byte** is the packing mode — `R` plain JSON, `Z` the
in-house LZW (12-bit codes, two to every three bytes, dictionary frozen at
4096 — a reset would have to be synchronised with a decoder that is always one
entry behind). The compressed form is **decoded and compared before it ships**;
if it does not round-trip, or did not shrink, the plain payload goes instead and
the mode byte says so. Compression is an optimisation, correctness is not.

`ExportConfig(name)` encodes that saved file; with no name it encodes
`:Collect()`, so a config can be shared without being saved first. `CopyConfig`
is export + `Util.SetClipboard` + `Notify`, and when the clipboard is
unavailable it **still returns the string** and reports that as the failure
rather than claiming a copy. `ImportConfig` applies through the same `:Apply`
path as a load, and with a name also writes the payload **verbatim** under the
sanitised name — the saved file is then byte-for-byte the config that was
shared, entries for elements this hub lacks included.

Import is the one place a user pastes arbitrary text, so **`DecodeConfig` never
errors — it returns `nil, reason`**, and every failure has its own wording:
missing prefix, unknown version, nothing after the prefix, unreadable base64,
unknown payload mode, a compressed body cut short, unreadable JSON, JSON that is
not a table, and a table that is not a config. Surrounding whitespace and
newlines a chat client wrapped in are stripped first. Unknown indexes are skipped
by `:Apply` as always.

The UI is in `:BuildConfigSection`, after the autoload row: a **Share** section,
a **COPY CONFIG** button (the selected config, or the live state when none is
selected), a paste **Input** (`SaveManager_ConfigShare`, `ClearTextOnFocus` off —
a field that empties on click loses the paste), and an **IMPORT** button that
applies it and saves it under whatever is in the config-name field. Reading the
clipboard is deliberately not attempted: `setclipboard` is near-universal among
executors, a working `getclipboard` is not. All three of SaveManager's own
indexes are in `SaveManager.Ignore`, so none of them can ride inside a config.

`ThemeManager.BuiltInThemes` must include the default (`"Sable"`) plus at
least: `Ember` (red), `Signal` (green), `Ice` (cyan), `Void` (violet, low
saturation), `Mono` (no accent — accent is a light grey). Each is a full
`Scheme` table; applying one calls `Library:SetScheme(table)`.

Themes the user saves themselves are one JSON per theme at
`<folder>/themes/<name>.json`, every scheme key written as a hex **string** —
`HttpService` cannot encode a `Color3`. Loading rebuilds them with
`Util.FromHex` and drops unknown or malformed keys instead of erroring. Names
are sanitised exactly as `SaveManager:Sanitize` does, so one can never escape
the folder; `default` is reserved, being the pointer file `:SetDefault` writes.
The controls live in a **Custom themes** groupbox that `:ApplyToTab` appends
after the theme editor, and their indexes are part of `ThemeManager.Indexes`,
so `SaveManager:IgnoreThemeSettings()` keeps them out of configs.

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
- `AbsolutePosition` is measured from just under the top bar while
  `GetMouseLocation()` is measured from the true top-left of the screen, so the
  two sit one `GuiService:GetGuiInset()` apart — in **both** inset modes.
  `IgnoreGuiInset` moves what the gui covers, not that origin, which is why an
  inset-ignoring gui reports a *negative* `AbsolutePosition.Y` at the top of the
  screen. Compare a cursor against an `AbsolutePosition` only through
  `Util.MouseInGuiSpace()`; raw `Util.MousePosition()` is for drag deltas, where
  the constant offset cancels. Mixing them errors nowhere — it just makes every
  hit test react one inset away from the cursor.
- The ScreenGui sets `IgnoreGuiInset = true`, so a holder's local `(0, 0)` is
  the true top of the screen and the menu and HUD panels can be **parked** over
  the top bar. Chrome that must *start* clear of it — HUD defaults,
  notifications — offsets itself by `Util.GuiInsetOffset()`. A grab point taken
  from an `AbsolutePosition` must be made holder-relative first, since the
  holder's own `AbsolutePosition` is no longer zero.
- `Enum.KeyCode.Unknown` is missing from the bundled type definitions even
  though it exists at runtime — compare `keyCode.Name == "Unknown"` instead.

## 10. Verification

```
powershell -ExecutionPolicy Bypass -File tools\check.ps1
```

Syntax-gates every module with `luau-compile`, then typechecks and lints the
tree against real Roblox API definitions. **It must exit clean.**
