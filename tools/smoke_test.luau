--!nocheck
-- Sable :: headless smoke test
-- Runs against the real built bundle with tools/mock_roblox.luau standing in
-- for the Roblox API. `Library` is injected by tools/smoke.py.
--
-- This does not check pixels. It checks that the library CONSTRUCTS, that
-- values round-trip, and that teardown is clean -- the failures a typechecker
-- cannot see.

local passed, failed = 0, 0
local failures = {}

local function check(name, ok, detail)
	if ok then
		passed += 1
	else
		failed += 1
		table.insert(failures, name .. (detail and ("  --  " .. tostring(detail)) or ""))
	end
end

local function step(name, fn)
	local ok, err = pcall(fn)
	check(name, ok, err)
	return ok
end

local drain = __drainDeferred

--==============================================================
-- construction
--==============================================================

-- Meta-checks on the harness itself. A mock that quietly stops validating
-- turns every later assertion into a false pass -- which is exactly how
-- `ScrollBarImage = ""` reached a real executor. Verify the net exists before
-- trusting anything it catches.
check("MOCK_API loaded", type(MOCK_API) == "table" and MOCK_API.ScrollingFrame ~= nil)
check("mock REJECTS an invalid property", not (pcall(function()
	Instance.new("ScrollingFrame").ScrollBarImage = ""
end)), "property validation is not active")
check("mock ALLOWS a valid property", (pcall(function()
	Instance.new("ScrollingFrame").ScrollBarImageColor3 = Color3.new(1, 1, 1)
end)), "validation is rejecting real properties")
check("mock REJECTS an invalid enum member", not (pcall(function()
	return Enum.KeyCode.NotARealKey
end)), "enum validation is not active")
check(
	"mock compares UDim2 by VALUE",
	UDim2.new(1, 2, 3, 4) == UDim2.new(1, 2, 3, 4),
	"identity comparison would make every `a.Size ~= b.Size` a false pass"
)
check("mock still tells two UDim2s apart", UDim2.new(1, 2, 3, 4) ~= UDim2.new(1, 2, 3, 5))

check("library loaded", type(Library) == "table")
check("version present", type(Library.Version) == "string")
check("ThemeManager attached", type(Library.ThemeManager) == "table")
check("SaveManager attached", type(Library.SaveManager) == "table")
check("KeybindList installed", type(Library.KeybindList) == "table")
check("Notify installed", type(Library.Notify) == "function")
check("SetWatermark installed", type(Library.SetWatermark) == "function")

local Window
step("CreateWindow", function()
	Window = Library:CreateWindow({
		Title = "Sable",
		Footer = "sys " .. Library.Version,
		Center = true,
		AutoShow = true,
	})
end)

if not Window then
	print(("SMOKE ABORTED: window construction failed\n  %s"):format(table.concat(failures, "\n  ")))
	return
end

check("window registered", #Library.Windows == 1)
check("window has SetVisible", type(Window.SetVisible) == "function")

local Tabs = {}
step("AddTab x3", function()
	Tabs.Main = Window:AddTab("Main")
	Tabs.Visuals = Window:AddTab("Visuals")
	Tabs.Settings = Window:AddTab("Settings")
end)

local Left, Right
step("groupboxes", function()
	Left = Tabs.Main:AddLeftGroupbox("Aimbot")
	Right = Tabs.Main:AddRightGroupbox("Misc")
end)

check("container shape .Container", Left and typeof(Left.Container) == "Instance")
check("container shape .Elements", Left and type(Left.Elements) == "table")
check("container shape :Resize", Left and type(Left.Resize) == "function")
check("container shape .Library", Left and Left.Library == Library)

--==============================================================
-- every element type
--==============================================================

step("AddLabel", function()
	Left:AddLabel("Plain label")
	Left:AddLabel("A much longer label that has to wrap across more than one line", true)
end)
step("AddDivider", function()
	Left:AddDivider()
end)
step("AddButton + sub-button", function()
	local b = Left:AddButton({ Text = "Do thing", Func = function() end })
	b:AddButton({ Text = "Other", Func = function() end })
	Left:AddButton({ Text = "Dangerous", DoubleClick = true, Func = function() end })
end)
step("AddToggle", function()
	Left:AddToggle("Enabled", { Text = "Enabled", Default = false, Tooltip = "master switch" })
end)
step("AddToggle risky + disabled", function()
	Left:AddToggle("Risky", { Text = "Silent aim", Default = false, Risky = true })
	Left:AddToggle("Off", { Text = "Unavailable", Default = false, Disabled = true, DisabledTooltip = "nope" })
end)
step("AddSlider", function()
	Left:AddSlider("Fov", { Text = "FOV", Default = 120, Min = 0, Max = 500, Rounding = 0, Suffix = "px" })
	Left:AddSlider("Smooth", { Text = "Smoothing", Default = 0.35, Min = 0, Max = 1, Rounding = 2 })
end)
step("AddSlider degenerate Min==Max", function()
	Left:AddSlider("Flat", { Text = "Flat", Default = 5, Min = 5, Max = 5 })
end)
step("AddInput", function()
	Right:AddInput("Name", { Text = "Name", Default = "hello", Placeholder = "type here" })
	Right:AddInput("Num", { Text = "Count", Default = "10", Numeric = true, Finished = true })
end)
step("AddDropdown single", function()
	Right:AddDropdown("Bone", { Text = "Bone", Values = { "Head", "Torso", "Root" }, Default = 1 })
end)
step("AddDropdown multi", function()
	Right:AddDropdown("Parts", {
		Text = "Parts",
		Values = { "Head", "Torso", "Arms" },
		Multi = true,
		Default = { Head = true },
	})
end)
step("AddDropdown empty values", function()
	Right:AddDropdown("Empty", { Text = "Empty", Values = {}, AllowNull = true })
end)
step("AddColorPicker standalone", function()
	Right:AddColorPicker("Col", { Default = Color3.fromRGB(233, 161, 59), Title = "Colour" })
	Right:AddColorPicker("ColA", { Default = Color3.fromRGB(10, 20, 30), Transparency = 0 })
end)
step("AddKeyPicker standalone", function()
	Right:AddKeyPicker("Bind", { Default = "F", Mode = "Toggle", Text = "Bind" })
end)
step("inline pickers on toggle", function()
	local t = Left:AddToggle("Esp", { Text = "ESP", Default = true })
	t:AddColorPicker("EspCol", { Default = Color3.fromRGB(1, 2, 3) })
	t:AddKeyPicker("EspKey", { Default = "MB2", Mode = "Hold", Text = "ESP" })
end)
step("inline picker on label", function()
	local l = Left:AddLabel("Tracer")
	l:AddColorPicker("TracerCol", { Default = Color3.fromRGB(9, 9, 9) })
end)
step("options with NO optional keys", function()
	Right:AddToggle("Bare", {})
	Right:AddSlider("BareSlider", {})
	Right:AddInput("BareInput", {})
end)

local SectionEl, ParagraphEl
step("AddSection", function()
	SectionEl = Left:AddSection("Targeting")
end)
step("AddParagraph", function()
	ParagraphEl = Left:AddParagraph("Notes", "Short body.")
end)
step("AddProgressBar", function()
	Left:AddProgressBar("Farm", { Text = "Farm progress", Default = 0, Min = 0, Max = 100, Suffix = "%" })
end)
step("AddImage", function()
	Right:AddImage("Banner", { Image = "rbxassetid://1234567", Height = 80, Tooltip = "hub banner" })
end)
step("read-only elements with NO optional keys", function()
	Right:AddSection()
	Right:AddParagraph("Bare")
	Right:AddProgressBar("BareBar", {})
	Right:AddImage("BareImage", {})
end)

step("tabbox", function()
	local tb = Tabs.Visuals:AddLeftTabbox()
	local a = tb:AddTab("One")
	local b = tb:AddTab("Two")
	a:AddToggle("TabA", { Text = "A", Default = true })
	b:AddSlider("TabB", { Text = "B", Default = 1, Min = 0, Max = 10 })
end)

step("dependency box", function()
	local dep = Left:AddDependencyBox()
	dep:AddSlider("DepSlider", { Text = "Thickness", Default = 1, Min = 1, Max = 5 })
	dep:SetupDependencies({ { Library.Toggles.Esp, true } })
end)

drain()

--==============================================================
-- stores + values
--==============================================================

local T, O = Library.Toggles, Library.Options

check("toggle in Toggles", T.Enabled ~= nil)
check("toggle NOT in Options", O.Enabled == nil)
check("slider in Options", O.Fov ~= nil)
check("input in Options", O.Name ~= nil)
check("dropdown in Options", O.Bone ~= nil)
check("colorpicker in Options", O.Col ~= nil)
check("keypicker in Options", O.Bind ~= nil)

check("toggle default", T.Enabled and T.Enabled.Value == false)
check("slider default", O.Fov and O.Fov.Value == 120)
check("input default", O.Name and O.Name.Value == "hello")
check("dropdown default resolved to string", O.Bone and O.Bone.Value == "Head")
check("multi dropdown default is a set", O.Parts and type(O.Parts.Value) == "table" and O.Parts.Value.Head == true)
check("keypicker default", O.Bind and O.Bind.Value == "F")
check("colorpicker default", O.Col and typeof(O.Col.Value) == "Color3")

local fired = {}
step("OnChanged fires", function()
	T.Enabled:OnChanged(function(v)
		fired.toggle = v
	end)
	T.Enabled:SetValue(true)
end)
check("OnChanged delivered value", fired.toggle == true)
check("toggle value applied", T.Enabled.Value == true)

step("silent SetValue skips callback", function()
	fired.toggle = nil
	T.Enabled:SetValue(false, true)
end)
check("silent honoured", fired.toggle == nil, "callback ran despite silent = true")
check("silent still applied value", T.Enabled.Value == false)

step("slider clamps above max", function()
	O.Fov:SetValue(99999)
end)
check("slider clamped to Max", O.Fov.Value == 500, O.Fov.Value)
step("slider clamps below min", function()
	O.Fov:SetValue(-99999)
end)
check("slider clamped to Min", O.Fov.Value == 0, O.Fov.Value)
step("slider rounds", function()
	O.Smooth:SetValue(0.126)
end)
check("slider rounding=2", math.abs(O.Smooth.Value - 0.13) < 1e-6, O.Smooth.Value)

step("degenerate slider survives", function()
	O.Flat:SetValue(3)
end)

step("dropdown SetValue string", function()
	O.Bone:SetValue("Torso")
end)
check("dropdown value", O.Bone.Value == "Torso")
step("dropdown SetValues drops stale selection", function()
	O.Bone:SetValues({ "Head", "Root" })
end)
check("stale selection resolved", O.Bone.Value ~= "Torso", O.Bone.Value)

step("multi dropdown SetValue set", function()
	O.Parts:SetValue({ Head = true, Arms = true })
end)
check("multi set applied", O.Parts.Value.Arms == true)

step("keypicker GetState", function()
	local _ = O.Bind:GetState()
end)
check("keypicker GetState is boolean", type(O.Bind:GetState()) == "boolean")

step("colorpicker SetValue", function()
	O.Col:SetValue(Color3.fromRGB(255, 0, 0))
end)
check("colorpicker applied", math.abs(O.Col.Value.R - 1) < 1e-3)

step("SetVisible / SetDisabled / SetText", function()
	T.Risky:SetVisible(false)
	T.Risky:SetVisible(true)
	T.Risky:SetDisabled(true)
	T.Risky:SetDisabled(false)
	T.Risky:SetText("Renamed")
end)

--==============================================================
-- read-only elements
--==============================================================

--- Segments actually painted with the accent, read off the cell frames rather
--- than off any bookkeeping the element keeps. A bar that stops repainting has
--- to FAIL here, not pass because its own counter is still correct.
local function litSegments(element)
	local accent = Library:GetColor("Accent")
	local lit = 0
	for _, record in element.Bar.Segments do
		if record.Frame.BackgroundColor3 == accent then
			lit += 1
		end
	end
	return lit
end

check("progress bar in Options", O.Farm ~= nil)
check("progress bar has no hit target", O.Farm and O.Farm.Hit == nil, "a ProgressBar must not be draggable")
check("progress bar starts empty", O.Farm and litSegments(O.Farm) == 0, O.Farm and litSegments(O.Farm))
-- Slider shares the same track implementation, so it has to keep painting.
check("slider still lights its own track", litSegments(O.Smooth) > 0, litSegments(O.Smooth))

step("progress bar clamps above Max", function()
	O.Farm:SetValue(9999)
end)
check("progress clamped to Max", O.Farm.Value == 100, O.Farm.Value)
check("a full bar lights every segment", litSegments(O.Farm) == O.Farm.Segments, litSegments(O.Farm))

step("progress bar clamps below Min", function()
	O.Farm:SetValue(-9999)
end)
check("progress clamped to Min", O.Farm.Value == 0, O.Farm.Value)
check("an empty bar lights nothing", litSegments(O.Farm) == 0, litSegments(O.Farm))

step("progress bar tracks the value", function()
	O.Farm:SetValue(50)
end)
check("half a bar is half lit", litSegments(O.Farm) == O.Farm.Segments / 2, litSegments(O.Farm))
step("one point of progress lights one cell", function()
	O.Farm:SetValue(1)
end)
check("a barely-started bar is not empty", litSegments(O.Farm) == 1, litSegments(O.Farm))
check("the readout carries the exact value", O.Farm.Row:FindFirstChild("Readout").Text == "1%", O.Farm.Row:FindFirstChild("Readout").Text)

step("progress bar SetMax re-clamps", function()
	O.Farm:SetValue(100)
	O.Farm:SetMax(50)
end)
check("value clamped by the new Max", O.Farm.Value == 50, O.Farm.Value)
check("bar full at the new Max", litSegments(O.Farm) == O.Farm.Segments, litSegments(O.Farm))
step("progress bar SetMin re-clamps", function()
	O.Farm:SetMin(60)
end)
check("value pulled up to the new Min", O.Farm.Value == 60, O.Farm.Value)
step("progress bar bounds restored", function()
	O.Farm:SetMin(0)
	O.Farm:SetMax(100)
	O.Farm:SetValue(40)
end)

-- FontDim at rest and never anything brighter. A slider's readout lifts to Font
-- while it is being dragged; there is no drag here, so a readout that brightened
-- would promise an interaction that does not exist. The only other colour it may
-- ever take is the disabled one.
local farmReadout = O.Farm.Row:FindFirstChild("Readout")
check("the readout is dim at rest", farmReadout.TextColor3 == Library:GetColor("FontDim"), tostring(farmReadout.TextColor3))
step("a disabled progress bar dims further, then comes back", function()
	O.Farm:SetDisabled(true)
	check("disabled readout goes faint", farmReadout.TextColor3 == Library:GetColor("FontFaint"), tostring(farmReadout.TextColor3))
	O.Farm:SetDisabled(false)
	check("re-enabled readout is dim again", farmReadout.TextColor3 == Library:GetColor("FontDim"), tostring(farmReadout.TextColor3))
end)

-- Percent is the documented default, because the overwhelmingly common progress
-- readout is one. A bar built with no options at all still has to say so.
check(
	"a bare progress bar reads as a percentage",
	O.BareBar.Row:FindFirstChild("Readout").Text == "0%",
	O.BareBar.Row:FindFirstChild("Readout").Text
)

-- A caller's typo must never reach table.create: a requested segment count is
-- folded into the range a bar can actually draw, not trusted.
step("silly segment counts are folded into range", function()
	local none = Left:AddProgressBar("SegNone", { Text = "s", Segments = 0 })
	local many = Left:AddProgressBar("SegMany", { Text = "s", Segments = 200 })
	check("a zero segment count still draws one cell", none.Segments == 1 and #none.Bar.Segments == 1, none.Segments)
	check("an absurd segment count is capped", many.Segments == 64 and #many.Bar.Segments == 64, many.Segments)
	none:Destroy()
	many:Destroy()
end)

check("section is not stored", O.Targeting == nil and T.Targeting == nil)
step("section re-measures on SetText", function()
	local before = SectionEl.Rule.Position.X.Offset
	check("the rule starts after the caption", before > 0, before)
	check("the rule fills the rest of the row", SectionEl.Rule.Size.X.Offset == -before, SectionEl.Rule.Size.X.Offset)

	-- Measured independently, from the string that is actually RENDERED.
	-- Library:Chrome interleaves spaces, so the caption on screen is about twice
	-- the width of the text the caller passed in; measuring the caller's string
	-- would start the rule underneath its own caption, and every assertion above
	-- would still hold.
	local rendered = math.ceil(Library.Util.TextSize(SectionEl.Label.Text, Library.Sizes.TextSmall, Library.Fonts.Title).X)
	check("the caption column fits the letterspaced text", SectionEl.Label.Size.X.Offset >= rendered, ("%d < %d"):format(SectionEl.Label.Size.X.Offset, rendered))
	check("the rule starts clear of the rendered caption", before >= rendered, ("%d < %d"):format(before, rendered))

	SectionEl:SetText("A considerably longer section caption")
	local after = SectionEl.Rule.Position.X.Offset
	check("a longer caption pushes the rule right", after > before, ("%d -> %d"):format(before, after))
	check("the rule shrank to match", SectionEl.Rule.Size.X.Offset == -after, SectionEl.Rule.Size.X.Offset)

	SectionEl:SetText("Targeting")
	check("and it measures back down again", SectionEl.Rule.Position.X.Offset == before, SectionEl.Rule.Position.X.Offset)
end)

check("paragraph title is cased like a label", ParagraphEl.Label.Text == "NOTES", ParagraphEl.Label.Text)
check("paragraph body keeps its own casing", ParagraphEl.BodyLabel.Text == "Short body.", ParagraphEl.BodyLabel.Text)
check("paragraph body wraps", ParagraphEl.BodyLabel.TextWrapped == true)
check("paragraph row auto-sizes", ParagraphEl.Row.AutomaticSize == Enum.AutomaticSize.Y)

step("a paragraph reflows on text and on width", function()
	local short = ParagraphEl.Row.Size.Y.Offset

	ParagraphEl:SetBody(("A sentence of explanatory copy that keeps going. "):rep(6))
	local wide = ParagraphEl.Row.Size.Y.Offset
	check("the row grew with the copy", wide > short, ("%d -> %d"):format(short, wide))

	-- Same copy, less than half the column: the wrap must produce a taller row.
	ParagraphEl.Row.AbsoluteSize = Vector2.new(120, 20)
	local narrow = ParagraphEl.Row.Size.Y.Offset
	check("a narrower column means a taller paragraph", narrow > wide, ("%d -> %d"):format(wide, narrow))

	ParagraphEl.Row.AbsoluteSize = Vector2.new(300, 20)
	check("widening the column reflows it back", ParagraphEl.Row.Size.Y.Offset == wide, ParagraphEl.Row.Size.Y.Offset)

	ParagraphEl:SetBody("Short body.")
	check("shorter copy shrinks the row again", ParagraphEl.Row.Size.Y.Offset == short, ParagraphEl.Row.Size.Y.Offset)
	-- The constructor writes the body straight onto the label; every LATER write
	-- goes through Display, which is the path that could quietly start casing it.
	check("a rewritten body still keeps its own casing", ParagraphEl.BodyLabel.Text == "Short body.", ParagraphEl.BodyLabel.Text)
end)

step("paragraph SetText rewrites both lines", function()
	ParagraphEl:SetText("Changelog", "v1.1 -- first public build")
end)
check("paragraph title updated", ParagraphEl.Label.Text == "CHANGELOG", ParagraphEl.Label.Text)
check("paragraph body updated", ParagraphEl.Value == "v1.1 -- first public build", ParagraphEl.Value)
check("the body LABEL keeps the caller's casing", ParagraphEl.BodyLabel.Text == "v1.1 -- first public build", ParagraphEl.BodyLabel.Text)
step("paragraph SetText with only a title keeps the body", function()
	ParagraphEl:SetText("Notes")
end)
check("body survived a title-only edit", ParagraphEl.Value == "v1.1 -- first public build", ParagraphEl.Value)
check("paragraph is not stored", O.Notes == nil and T.Notes == nil)

check("image in Options", O.Banner ~= nil)
check("image value is the asset id", O.Banner and O.Banner.Value == "rbxassetid://1234567", O.Banner and O.Banner.Value)
check("image defaults to Fit", O.Banner and O.Banner.ImageLabel.ScaleType == Enum.ScaleType.Fit)
check("image row honours Height", O.Banner and O.Banner.Row.Size.Y.Offset == 80, O.Banner and O.Banner.Row.Size.Y.Offset)

step("SetImage swaps the asset live", function()
	O.Banner:SetImage("rbxassetid://7654321")
end)
check("image value updated", O.Banner.Value == "rbxassetid://7654321", O.Banner.Value)
check("the ImageLabel actually changed", O.Banner.ImageLabel.Image == "rbxassetid://7654321", O.Banner.ImageLabel.Image)
step("image round-trips through SetValue", function()
	O.Banner:SetValue("rbxassetid://1234567")
end)
check("image value restored", O.Banner.Value == "rbxassetid://1234567", O.Banner.Value)
check("the ImageLabel followed it back", O.Banner.ImageLabel.Image == "rbxassetid://1234567", O.Banner.ImageLabel.Image)

step("SetTransparency reaches the ImageLabel", function()
	O.Banner:SetTransparency(0.5)
	check("transparency reached the bitmap", math.abs(O.Banner.ImageLabel.ImageTransparency - 0.5) < 1e-6, O.Banner.ImageLabel.ImageTransparency)
	O.Banner:SetTransparency(0)
	check("and back to opaque", O.Banner.ImageLabel.ImageTransparency == 0, O.Banner.ImageLabel.ImageTransparency)
end)

step("a disabled image fades, and a repaint does not undo it", function()
	local rest = O.Banner.ImageLabel.ImageTransparency

	O.Banner:SetDisabled(true)
	check("disabled image faded", O.Banner.ImageLabel.ImageTransparency > rest, O.Banner.ImageLabel.ImageTransparency)

	O.Banner:SetImage("rbxassetid://1234567")
	check("still faded after a repaint", O.Banner.ImageLabel.ImageTransparency > rest, O.Banner.ImageLabel.ImageTransparency)

	O.Banner:SetDisabled(false)
	check("re-enabling restores it", O.Banner.ImageLabel.ImageTransparency == rest, O.Banner.ImageLabel.ImageTransparency)
end)

--==============================================================
-- registry hygiene (the bug class that was fixed)
--==============================================================

local before = #Library.Registry
step("repeated SetDisabled does not grow registry", function()
	for _ = 1, 25 do
		T.Risky:SetDisabled(true)
		T.Risky:SetDisabled(false)
	end
end)
check("registry stable across 50 state flips", #Library.Registry == before, ("%d -> %d"):format(before, #Library.Registry))

--==============================================================
-- quiet scrollbars
--==============================================================

-- The bar is stock Roblox chrome, so it is driven entirely by transparency:
-- thickness must stay put (it is the drag target) and the frame must stay
-- scrollable. Every assertion below reads the property the helper owns, so
-- deleting the helper fails the section rather than quietly passing it.
local FAINT = Library.Sizes.ScrollBarFaint
check("faint transparency is a real fade", type(FAINT) == "number" and FAINT > 0 and FAINT < 1, tostring(FAINT))
check("idle delay is a real wait", type(Library.Motion.ScrollBarIdle) == "number" and Library.Motion.ScrollBarIdle > 0)
check("QuietScrollbar installed", type(Library.QuietScrollbar) == "function")

local column = Tabs.Main.Left
check("column keeps its thickness", column.ScrollBarThickness == Library.Sizes.ScrollBar, column.ScrollBarThickness)
check("column stays interactive", column.Active == true)
check("column is hidden at rest", column.ScrollBarImageTransparency == 1, column.ScrollBarImageTransparency)

-- Content that FITS. Poking it every way the helper listens must leave the bar
-- invisible -- a bar you cannot use is the loudest thing on a still menu.
column.AbsoluteWindowSize = Vector2.new(300, 400)
column.AbsoluteCanvasSize = Vector2.new(300, 220)
check("a fitting column is hidden", column.ScrollBarImageTransparency == 1, column.ScrollBarImageTransparency)
column.MouseEnter:Fire()
check("a fitting column stays hidden on hover", column.ScrollBarImageTransparency == 1, column.ScrollBarImageTransparency)
column.CanvasPosition = Vector2.new(0, 12)
check("a fitting column stays hidden on scroll", column.ScrollBarImageTransparency == 1, column.ScrollBarImageTransparency)
column.MouseLeave:Fire()
__drainDelayed()
check("a fitting column queued nothing", column.ScrollBarImageTransparency == 1, column.ScrollBarImageTransparency)

-- Groupboxes grow: the same column now overflows.
column.AbsoluteCanvasSize = Vector2.new(300, 1200)
check("overflow alone does not show the bar", column.ScrollBarImageTransparency == 1, column.ScrollBarImageTransparency)

column.CanvasPosition = Vector2.new(0, 40)
check("scrolling fades the bar in faintly", column.ScrollBarImageTransparency == FAINT, column.ScrollBarImageTransparency)
__drainDelayed()
check("the bar fades out again once idle", column.ScrollBarImageTransparency == 1, column.ScrollBarImageTransparency)

column.MouseEnter:Fire()
check("hovering the column shows the bar", column.ScrollBarImageTransparency == FAINT, column.ScrollBarImageTransparency)
__drainDelayed()
check("hover holds the bar open", column.ScrollBarImageTransparency == FAINT, column.ScrollBarImageTransparency)

-- A fade queued by a scroll must lose to whatever renewed interest after it,
-- or the bar blinks out from under the cursor.
column.MouseLeave:Fire()
column.CanvasPosition = Vector2.new(0, 80)
column.MouseEnter:Fire()
__drainDelayed()
check("a stale fade cannot fire", column.ScrollBarImageTransparency == FAINT, column.ScrollBarImageTransparency)

column.MouseLeave:Fire()
check("the bar survives the cursor leaving", column.ScrollBarImageTransparency == FAINT, column.ScrollBarImageTransparency)
__drainDelayed()
check("the bar hides after the cursor leaves", column.ScrollBarImageTransparency == 1, column.ScrollBarImageTransparency)

-- Content that shrinks back under the window takes the visible bar with it.
column.MouseEnter:Fire()
column.AbsoluteCanvasSize = Vector2.new(300, 100)
check("a shrinking canvas hides the bar", column.ScrollBarImageTransparency == 1, column.ScrollBarImageTransparency)
column.MouseLeave:Fire()
__drainDelayed()

-- A Y-only column whose canvas is a hair WIDER than its window has nothing to
-- scroll -- the sideways slack is the scrollbar inset itself. A bar that cannot
-- be dragged anywhere is exactly the chrome this helper exists to remove.
column.AbsoluteCanvasSize = Vector2.new(900, 220)
column.MouseEnter:Fire()
check("sideways overflow does not light a Y-only bar", column.ScrollBarImageTransparency == 1, column.ScrollBarImageTransparency)
column.MouseLeave:Fire()
__drainDelayed()

-- MouseEnter/MouseLeave are driven by cursor MOVEMENT, so a frame that goes out
-- from under a STILL cursor -- a popup closing on the click that chose a row,
-- the menu toggling off -- never delivers a MouseLeave. Hover is the one state
-- that holds the bar up with NO fade queued, so a hover flag left standing
-- there would pin the bar on screen for the rest of the session.
local savedMouse = __getMouse()
column.AbsoluteCanvasSize = Vector2.new(300, 1200)
__setMouse(100, 46) -- inside the column once the gui inset is taken off
column.MouseEnter:Fire()
check("a real hover shows the bar", column.ScrollBarImageTransparency == FAINT, column.ScrollBarImageTransparency)
column.CanvasPosition = Vector2.new(0, 60)
__drainDelayed()
check("a real hover holds the bar open", column.ScrollBarImageTransparency == FAINT, column.ScrollBarImageTransparency)
__setMouse(savedMouse) -- cursor is elsewhere now, and no MouseLeave ever came
column.AbsoluteCanvasSize = Vector2.new(300, 1400)
__drainDelayed()
check("a stranded hover cannot pin the bar on", column.ScrollBarImageTransparency == 1, column.ScrollBarImageTransparency)
column.MouseLeave:Fire()
__drainDelayed()

-- The dropdown popup list is the other ScrollingFrame, and must behave the same.
local dropdownList = O.Bone and O.Bone.List
check("dropdown list exists", dropdownList ~= nil)
if dropdownList then
	check("dropdown bar is hidden at rest", dropdownList.ScrollBarImageTransparency == 1, dropdownList.ScrollBarImageTransparency)
	check("dropdown bar keeps its thickness", dropdownList.ScrollBarThickness == Library.Sizes.ScrollBar)
	dropdownList.AbsoluteWindowSize = Vector2.new(160, 120)
	dropdownList.AbsoluteCanvasSize = Vector2.new(160, 500)
	dropdownList.CanvasPosition = Vector2.new(0, 30)
	check("dropdown bar fades in on scroll", dropdownList.ScrollBarImageTransparency == FAINT, dropdownList.ScrollBarImageTransparency)
	__drainDelayed()
	check("dropdown bar fades out again", dropdownList.ScrollBarImageTransparency == 1, dropdownList.ScrollBarImageTransparency)
end

-- Opt-out: a constant affordance for scripts that want one.
step("QuietScrollbars = false keeps the bar on", function()
	Library.QuietScrollbars = false
	local constant = Instance.new("ScrollingFrame")
	Library:QuietScrollbar(constant)
	check("opt-out bar starts faint", constant.ScrollBarImageTransparency == FAINT, constant.ScrollBarImageTransparency)
	constant.AbsoluteWindowSize = Vector2.new(300, 400)
	constant.AbsoluteCanvasSize = Vector2.new(300, 1200)
	constant.CanvasPosition = Vector2.new(0, 40)
	constant.MouseEnter:Fire()
	constant.MouseLeave:Fire()
	__drainDelayed()
	check("opt-out bar never fades out", constant.ScrollBarImageTransparency == FAINT, constant.ScrollBarImageTransparency)
	Library.QuietScrollbars = true
end)

--==============================================================
-- overlays
--==============================================================

step("Notify string", function()
	Library:Notify("hello", 3)
end)
step("Notify table", function()
	Library:Notify({ Title = "Title", Description = "Body", Time = 2, Risk = true })
	Library:Notify({ Title = "Good", Description = "Body", Time = 2, Good = true })
end)
step("the notification stack clears the top bar", function()
	-- The holder's local origin is the true top of the screen while the gui
	-- ignores the inset, so a bare margin slides the first notification in
	-- behind Roblox's own top bar -- and unlike a HUD panel, a notification
	-- cannot be dragged out from under it.
	local first = Library.NotificationHolder:GetChildren()[1]
	check("a notification was built", first ~= nil)
	if not first then
		return
	end
	check(
		"the first notification starts below the top bar",
		first.Position.Y.Offset >= game:GetService("GuiService"):GetGuiInset().Y,
		first.Position.Y.Offset
	)
end)
step("watermark", function()
	Library:SetWatermark("SABLE")
	Library:SetWatermarkVisibility(true)
	Library:SetWatermarkVisibility(false)
	Library:SetWatermarkVisibility(true)
end)
step("keybind visibility", function()
	Library:SetKeybindVisibility(false)
	Library:SetKeybindVisibility(true)
end)
step("KeybindList Set/Remove", function()
	Library.KeybindList:Set("smoke", { Text = "Test", Key = "F", Mode = "Toggle", Active = true })
	Library.KeybindList:Set("smoke", { Text = "Test", Key = "G", Mode = "Hold", Active = false })
	Library.KeybindList:Remove("smoke")
end)

step("render frames", function()
	for _ = 1, 5 do
		__RunService.RenderStepped:Fire(1 / 60)
	end
end)

--==============================================================
-- hud layout (independent placement, dragging, persistence)
--==============================================================

-- A shared UIListLayout owns its children's positions, which is exactly why
-- neither panel could be dragged before. Assert the structure, not just the
-- behaviour: re-introducing the column would break dragging silently.
local HudHolder = Library.HudHolder
local watermarkFrame = Library.Watermark
local keybindFrame = Library.KeybindPanel

local function hasListLayout(instance)
	for _, child in instance:GetChildren() do
		if child.ClassName == "UIListLayout" then
			return true
		end
	end
	return false
end

check("watermark is a direct child of HudHolder", watermarkFrame ~= nil and watermarkFrame.Parent == HudHolder)
check("keybind panel is a direct child of HudHolder", keybindFrame ~= nil and keybindFrame.Parent == HudHolder)
check("the two panels are separate instances", watermarkFrame ~= keybindFrame)
check("no list layout owns the hud panels", not hasListLayout(HudHolder), "hud panels are back under a list layout")

check("SetHudFolder installed", type(Library.SetHudFolder) == "function")
check("SaveHudLayout installed", type(Library.SaveHudLayout) == "function")
check("LoadHudLayout installed", type(Library.LoadHudLayout) == "function")
check("ResetHudLayout installed", type(Library.ResetHudLayout) == "function")
check("GetHudLayout installed", type(Library.GetHudLayout) == "function")
check("HudFolder defaults to the library name", Library.HudFolder == Library.Name, Library.HudFolder)

-- The mock reports one placeholder AbsoluteSize for every instance; give the
-- holder and both panels real numbers so the clamp has edges to bite on.
local VIEW_W, VIEW_H = 1920, 1080
local MARK_W, MARK_H = 240, 26
local BIND_W, BIND_H = 180, 60

step("hud layout test viewport", function()
	HudHolder.AbsoluteSize = Vector2.new(VIEW_W, VIEW_H)
	watermarkFrame.AbsoluteSize = Vector2.new(MARK_W, MARK_H)
	keybindFrame.AbsoluteSize = Vector2.new(BIND_W, BIND_H)
	Library:SetHudFolder("SableSmoke/hud")
	Library:ResetHudLayout()
end)

local hudDefaults = Library:GetHudLayout()
check("layout is plain numbers", type(hudDefaults.Watermark) == "table" and type(hudDefaults.Watermark.X) == "number")
check("watermark defaults to the top-left margin", hudDefaults.Watermark.X > 0 and hudDefaults.Watermark.Y > 0)
-- The gui ignores the top bar inset, so HudHolder reaches up behind the top bar.
-- Dragging a panel up there is the point of that; STARTING there is not -- the
-- default watermark would sit on Roblox's own menu button.
check(
	"the hud starts clear of the top bar",
	hudDefaults.Watermark.Y >= game:GetService("GuiService"):GetGuiInset().Y,
	hudDefaults.Watermark.Y
)
check(
	"keybind list defaults directly below the watermark",
	hudDefaults.KeybindList.X == hudDefaults.Watermark.X and hudDefaults.KeybindList.Y > hudDefaults.Watermark.Y,
	("%d,%d vs %d,%d"):format(
		hudDefaults.Watermark.X, hudDefaults.Watermark.Y,
		hudDefaults.KeybindList.X, hudDefaults.KeybindList.Y
	)
)

step("out-of-range positions are clamped into the viewport", function()
	Library.Util.FS.WriteJSON("SableSmoke/hud/hud.json", {
		Watermark = { X = 99999, Y = -500 },
		KeybindList = { X = -40, Y = 99999 },
	})
	check("LoadHudLayout applied the file", Library:LoadHudLayout() == true)
end)

local clamped = Library:GetHudLayout()
check("clamped to the right edge", clamped.Watermark.X == VIEW_W - MARK_W, clamped.Watermark.X)
check("clamped to the top edge", clamped.Watermark.Y == 0, clamped.Watermark.Y)
check("clamped to the left edge", clamped.KeybindList.X == 0, clamped.KeybindList.X)
check("clamped to the bottom edge", clamped.KeybindList.Y == VIEW_H - BIND_H, clamped.KeybindList.Y)
check("frame position follows the layout", watermarkFrame.Position.X.Offset == clamped.Watermark.X)

step("a panel that grows is pulled back into view", function()
	keybindFrame.AbsoluteSize = Vector2.new(BIND_W, BIND_H * 4)
	check(
		"re-clamped after the content changed",
		Library:GetHudLayout().KeybindList.Y == VIEW_H - BIND_H * 4,
		Library:GetHudLayout().KeybindList.Y
	)
	keybindFrame.AbsoluteSize = Vector2.new(BIND_W, BIND_H)
end)

-- A re-clamp has to work from where the panel was PUT, never from the result of
-- the previous clamp: clamping a clamp is a running minimum, so a panel parked
-- against an edge creeps inward every time it grows and never comes back. The
-- watermark changes width with every FPS digit, so this is the common case.
step("a panel that shrinks again returns to where it was parked", function()
	Library.Util.FS.WriteJSON("SableSmoke/hud/hud.json", {
		Watermark = { X = 400, Y = 300 },
		KeybindList = { X = 0, Y = VIEW_H - BIND_H },
	})
	Library:LoadHudLayout()
	check("parked flush against the bottom", Library:GetHudLayout().KeybindList.Y == VIEW_H - BIND_H)

	keybindFrame.AbsoluteSize = Vector2.new(BIND_W, BIND_H * 4)
	check("growth pushed it up", Library:GetHudLayout().KeybindList.Y == VIEW_H - BIND_H * 4)

	keybindFrame.AbsoluteSize = Vector2.new(BIND_W, BIND_H)
	check(
		"shrinking put it back where it was parked",
		Library:GetHudLayout().KeybindList.Y == VIEW_H - BIND_H,
		Library:GetHudLayout().KeybindList.Y
	)
end)

step("hud positions round-trip through the file", function()
	Library.Util.FS.WriteJSON("SableSmoke/hud/hud.json", {
		Watermark = { X = 400, Y = 300 },
		KeybindList = { X = 640, Y = 720 },
	})
	Library:LoadHudLayout()
end)

local moved = Library:GetHudLayout()
check("loaded watermark position", moved.Watermark.X == 400 and moved.Watermark.Y == 300)
check("loaded keybind position", moved.KeybindList.X == 640 and moved.KeybindList.Y == 720)

step("SaveHudLayout writes plain numbers", function()
	Library.Util.FS.Delete("SableSmoke/hud/hud.json")
	check("SaveHudLayout reports success", Library:SaveHudLayout() == true)

	local raw = Library.Util.FS.ReadJSON("SableSmoke/hud/hud.json")
	check("hud.json was written", type(raw) == "table")
	check("stored X is a number, not a UDim2", raw and type(raw.Watermark.X) == "number", raw and typeof(raw.Watermark.X))
	check("stored value matches the layout", raw and raw.KeybindList.Y == 720, raw and raw.KeybindList.Y)
end)

step("a second folder clobbers the positions", function()
	Library.Util.FS.WriteJSON("SableSmoke/hud2/hud.json", {
		Watermark = { X = 10, Y = 10 },
		KeybindList = { X = 20, Y = 20 },
	})
	Library:SetHudFolder("SableSmoke/hud2")
	check("second layout applied", Library:LoadHudLayout() == true)
	check("positions clobbered", Library:GetHudLayout().Watermark.X == 10)
end)

step("the saved layout loads back", function()
	Library:SetHudFolder("SableSmoke/hud")
	check("LoadHudLayout returns true", Library:LoadHudLayout() == true)
end)

local restored = Library:GetHudLayout()
check("RT watermark position", restored.Watermark.X == 400 and restored.Watermark.Y == 300, restored.Watermark.X)
check("RT keybind position", restored.KeybindList.X == 640 and restored.KeybindList.Y == 720, restored.KeybindList.Y)

step("dragging a panel moves it and saves on release", function()
	local handle = HudHolder:FindFirstChild("WatermarkDrag")
	check("watermark has a drag handle", handle ~= nil)
	if not handle then
		return
	end

	Library:SetOpen(false)
	check("handle is inert while the menu is closed", handle.Visible == false, "closed menu would swallow the click")

	Library:SetOpen(true)
	check("handle is live while the menu is open", handle.Visible == true)
	check("handle covers the panel", handle.Size.X.Offset == MARK_W and handle.Size.Y.Offset == MARK_H)

	__setMouse(500, 500)

	local press = Instance.new("InputObject")
	press.UserInputType = Enum.UserInputType.MouseButton1
	handle.InputBegan:Fire(press)

	__setMouse(560, 540)
	local move = Instance.new("InputObject")
	move.UserInputType = Enum.UserInputType.MouseMovement
	__UserInputService.InputChanged:Fire(move, false)

	local dragged = Library:GetHudLayout()
	check(
		"panel followed the cursor",
		dragged.Watermark.X == 460 and dragged.Watermark.Y == 340,
		("%d,%d"):format(dragged.Watermark.X, dragged.Watermark.Y)
	)
	check("handle followed the panel", handle.Position.X.Offset == dragged.Watermark.X)
	check("the other panel did not move", Library:GetHudLayout().KeybindList.X == 640)

	-- Saving mid-drag would write a file per mouse-move; the release is the
	-- only moment that should touch the filesystem.
	Library.Util.FS.Delete("SableSmoke/hud/hud.json")
	__UserInputService.InputChanged:Fire(move, false)
	check("no save during the drag", Library.Util.FS.IsFile("SableSmoke/hud/hud.json") == false)

	__UserInputService.InputEnded:Fire(press, false)
	local saved = Library.Util.FS.ReadJSON("SableSmoke/hud/hud.json")
	check("drag end saved the layout", type(saved) == "table" and saved.Watermark.X == dragged.Watermark.X)

	-- Released: further movement must not drag the panel any more.
	__setMouse(900, 900)
	__UserInputService.InputChanged:Fire(move, false)
	check("release ended the drag", Library:GetHudLayout().Watermark.X == dragged.Watermark.X)

	__setMouse(400, 300)
end)

step("dragging is impossible while the menu is closed", function()
	local handle = HudHolder:FindFirstChild("KeybindListDrag")
	if not handle then
		check("keybind list has a drag handle", false)
		return
	end

	local before = Library:GetHudLayout().KeybindList.X
	Library:SetOpen(false)

	-- The cursor really does move between press and release; only the closed
	-- menu should be stopping this.
	__setMouse(100, 100)

	local press = Instance.new("InputObject")
	press.UserInputType = Enum.UserInputType.MouseButton1
	handle.InputBegan:Fire(press)

	__setMouse(300, 400)
	local move = Instance.new("InputObject")
	move.UserInputType = Enum.UserInputType.MouseMovement
	__UserInputService.InputChanged:Fire(move, false)
	__UserInputService.InputEnded:Fire(press, false)

	check("closed menu refuses the drag", Library:GetHudLayout().KeybindList.X == before, Library:GetHudLayout().KeybindList.X)

	__setMouse(400, 300)
	Library:SetOpen(true)
end)

-- Press and release without moving is a click, not a drag. There is nothing to
-- persist, and an executor's writefile is synchronous.
step("a click that never became a drag writes nothing", function()
	local handle = HudHolder:FindFirstChild("WatermarkDrag")
	if not handle then
		check("watermark still has a drag handle", false)
		return
	end

	local before = Library:GetHudLayout().Watermark.X
	Library.Util.FS.Delete("SableSmoke/hud/hud.json")

	local press = Instance.new("InputObject")
	press.UserInputType = Enum.UserInputType.MouseButton1
	handle.InputBegan:Fire(press)
	__UserInputService.InputEnded:Fire(press, false)

	check("no file written for a click", Library.Util.FS.IsFile("SableSmoke/hud/hud.json") == false)
	check("the panel did not move", Library:GetHudLayout().Watermark.X == before)
end)

step("corrupt hud.json degrades to whatever is on screen", function()
	Library.Util.FS.Write("SableSmoke/hud/hud.json", "{not json")
	local before = Library:GetHudLayout()
	check("LoadHudLayout refuses garbage", Library:LoadHudLayout() == false)
	check("positions untouched", Library:GetHudLayout().Watermark.X == before.Watermark.X)
end)

step("a missing hud.json degrades", function()
	Library:SetHudFolder("SableSmoke/hud-nothing-here")
	check("LoadHudLayout returns false", Library:LoadHudLayout() == false)
	Library:SetHudFolder("SableSmoke/hud")
end)

step("ResetHudLayout restores and persists the defaults", function()
	check("reset returns the library", Library:ResetHudLayout() == Library)
end)

local reset = Library:GetHudLayout()
check("reset watermark", reset.Watermark.X == hudDefaults.Watermark.X and reset.Watermark.Y == hudDefaults.Watermark.Y)
check("reset keybind list", reset.KeybindList.X == hudDefaults.KeybindList.X and reset.KeybindList.Y == hudDefaults.KeybindList.Y)
check("reset moved the frame", watermarkFrame.Position.Y.Offset == hudDefaults.Watermark.Y)
check(
	"reset was saved",
	(Library.Util.FS.ReadJSON("SableSmoke/hud/hud.json") or {}).Watermark.X == hudDefaults.Watermark.X
)

--==============================================================
-- menu toggle + input
--==============================================================

step("SetOpen toggles", function()
	Library:SetOpen(false)
	Library:SetOpen(true)
	Library:Toggle()
	Library:Toggle()
end)
check("CapturingInput starts false", Library.CapturingInput == false)

-- The menu hotkey must actually respond to a real key press. Asserting only
-- that SetOpen/Toggle work is what let a permanently dead default bind ship:
-- Library.MenuKeybind was "INSERT" while Util.InputName reports "INS".
local Util = Library.Util

check("bind names canonicalise", Util.CanonicalName("INSERT") == "INS", Util.CanonicalName("INSERT"))
check("canonical name is idempotent", Util.CanonicalName("INS") == "INS")
check("title case canonicalises", Util.CanonicalName("Insert") == "INS", Util.CanonicalName("Insert"))
check("KeyCodeFromName resolves non-canonical", Util.KeyCodeFromName("INSERT") ~= nil)
check("KeyCodeFromName rejects nonsense", Util.KeyCodeFromName("NotAKey") == nil)

local function pressKey(keyName)
	local input = Instance.new("InputObject")
	input.UserInputType = Enum.UserInputType.Keyboard
	input.KeyCode = Enum.KeyCode[keyName]
	__UserInputService.InputBegan:Fire(input, false)
	__UserInputService.InputEnded:Fire(input, false)
end

check("InputName of Insert is INS", (function()
	local input = Instance.new("InputObject")
	input.UserInputType = Enum.UserInputType.Keyboard
	input.KeyCode = Enum.KeyCode.Insert
	return Util.InputName(input)
end)() == "INS")

step("menu hotkey responds to a real press", function()
	Library:SetOpen(true)
	local before = Library.Toggled
	pressKey("Insert")
	check("default menu keybind toggles the menu", Library.Toggled ~= before, "hotkey did nothing")
	pressKey("Insert")
	check("menu keybind toggles back", Library.Toggled == before)
end)

step("menu hotkey works when set with a non-canonical name", function()
	Library:SetMenuKeybind("INSERT")
	local before = Library.Toggled
	pressKey("Insert")
	check("non-canonical keybind still matches", Library.Toggled ~= before, "hotkey did nothing")
	Library:SetMenuKeybind("INS")
	Library:SetOpen(true)
end)

--==============================================================
-- cursor space vs AbsolutePosition space
--==============================================================

-- AbsolutePosition is measured from just under the top bar; GetMouseLocation is
-- measured from the true top-left of the screen. They are one inset apart, and
-- IgnoreGuiInset does NOT close the gap -- it only lets the gui draw above the
-- bar, which is why an inset-ignoring gui reports negative AbsolutePosition.Y at
-- the top of the screen. A missing (or backwards) conversion errors nowhere: it
-- just makes every hit test react an inset away from the real cursor, so the
-- user has to aim off the control. It has to be asserted head on.

local inset = game:GetService("GuiService"):GetGuiInset()
check("harness reports a non-zero gui inset", inset.Y > 0, inset.Y)
check("ScreenGui ignores the gui inset", Library.ScreenGui.IgnoreGuiInset == true)
check("Util follows the ScreenGui", Util.GuiInsetIgnored == true)
check("MouseInGuiSpace exists", type(Util.MouseInGuiSpace) == "function")

-- Rectangle: x 100..300, y 100..150, in AbsolutePosition space.
local probe = Instance.new("Frame")
probe.AbsolutePosition = Vector2.new(100, 100)
probe.AbsoluteSize = Vector2.new(200, 50)

--- Puts the RAW cursor where the library should SEE it at (x, y) in
--- AbsolutePosition space. Written out rather than derived from the library's
--- own helper, so a helper that changed direction could not drag the
--- expectations along with it.
local function cursorAtGuiPoint(x, y)
	__setMouse(x + inset.X, y + inset.Y)
end

local function overAt(x, y, expand)
	cursorAtGuiPoint(x, y)
	return Util.MouseOver(probe, expand)
end

-- Both modes, because the conversion is unconditional: a hit test must not
-- change its answer when the placement flag flips. Reintroduce a dependency on
-- Util.GuiInsetIgnored here and one of these two passes fails.
for _, ignored in { true, false } do
	local mode = ignored and "inset ignored" or "inset honoured"
	Util.GuiInsetIgnored = ignored

	check(mode .. ": centre is inside", overAt(200, 125) == true)
	check(mode .. ": top-left corner is inside", overAt(100, 100) == true)
	check(mode .. ": bottom-right corner is inside", overAt(300, 150) == true)
	check(mode .. ": a pixel above is outside", overAt(200, 99) == false)
	check(mode .. ": a pixel below is outside", overAt(200, 151) == false)
	check(mode .. ": a pixel left is outside", overAt(99, 125) == false)
	check(mode .. ": a pixel right is outside", overAt(301, 125) == false)
	check(mode .. ": expand grows the rectangle", overAt(200, 151, 4) == true)
	check(mode .. ": expand is not unbounded", overAt(200, 200, 4) == false)
end

Util.GuiInsetIgnored = Library.ScreenGui.IgnoreGuiInset == true

-- The value checks, stated in raw coordinates so they pin the DIRECTION. Delete
-- the conversion, or flip its sign, and these are what report it.
__setMouse(200, 125 + inset.Y) -- raw: below the frame. converted: dead centre.
check(
	"a converted cursor lands inside",
	Util.MouseOver(probe) == true,
	"raw cursor coordinates are being compared against AbsolutePosition"
)
check("MouseInGuiSpace takes the inset off", Util.MouseInGuiSpace().Y == 125, Util.MouseInGuiSpace().Y)
check("MousePosition stays raw", Util.MousePosition().Y == 125 + inset.Y, Util.MousePosition().Y)

__setMouse(200, 125) -- raw: dead centre. converted: above the frame.
check(
	"an unconverted cursor lands outside",
	Util.MouseOver(probe) == false,
	"the gui inset is not being taken off the cursor"
)

__setMouse(200, 125 - inset.Y) -- the sign-flip case: converted, this is 2 insets off.
check(
	"an inverted conversion lands outside",
	Util.MouseOver(probe) == false,
	"the gui inset is being ADDED to the cursor instead of subtracted"
)

probe:Destroy()
__setMouse(400, 300)

-- A window's grab point. Position is holder-relative but AbsolutePosition is
-- not, and while the gui ignores the inset the holder's own AbsolutePosition.Y
-- is negative -- so a grab that forgets to subtract it snaps the window up by an
-- inset before the cursor has moved a pixel.
step("grabbing a window does not jump it", function()
	local viewport = Library.ScreenGui.AbsoluteSize
	Library.ScreenGui.AbsoluteSize = Vector2.new(1920, 1080)

	local holder = Instance.new("Frame")
	holder.AbsolutePosition = Vector2.new(0, -inset.Y)

	local target = Instance.new("Frame")
	target.Parent = holder
	target.Position = UDim2.fromOffset(120, 200)
	target.Size = UDim2.fromOffset(400, 300)
	target.AbsoluteSize = Vector2.new(400, 300)
	-- Sitting at holder-local (120, 200), i.e. one inset up in absolute terms.
	target.AbsolutePosition = Vector2.new(120, 200 - inset.Y)

	local handle = Instance.new("Frame")
	Library:MakeDraggable(handle, target)

	__setMouse(700, 700)
	local press = Instance.new("InputObject")
	press.UserInputType = Enum.UserInputType.MouseButton1
	handle.InputBegan:Fire(press)

	-- Not one pixel of movement: whatever comes out must be where it started.
	local move = Instance.new("InputObject")
	move.UserInputType = Enum.UserInputType.MouseMovement
	__UserInputService.InputChanged:Fire(move, false)

	check(
		"a zero-distance drag leaves the window alone",
		target.Position.Y.Offset == 200 and target.Position.X.Offset == 120,
		("%d,%d"):format(target.Position.X.Offset, target.Position.Y.Offset)
	)

	__setMouse(760, 740)
	__UserInputService.InputChanged:Fire(move, false)
	check(
		"the window follows the cursor one for one",
		target.Position.X.Offset == 180 and target.Position.Y.Offset == 240,
		("%d,%d"):format(target.Position.X.Offset, target.Position.Y.Offset)
	)

	__UserInputService.InputEnded:Fire(press, false)
	Library.ScreenGui.AbsoluteSize = viewport
	__setMouse(400, 300)
end)

--==============================================================
-- destroying a host must take its inline pickers with it
--==============================================================

step("host destroy cascades to inline pickers", function()
	local box = Tabs.Main:AddRightGroupbox("Teardown")
	local host = box:AddToggle("HostToggle", { Text = "Host", Default = false })
	host:AddColorPicker("HostCol", { Default = Color3.fromRGB(1, 2, 3) })
	host:AddKeyPicker("HostKey", { Default = "V", Mode = "Toggle", Text = "orphan" })

	check("inline pickers registered", O.HostCol ~= nil and O.HostKey ~= nil)
	host:Destroy()

	check("host removed from store", T.HostToggle == nil)
	check("inline ColorPicker removed from store", O.HostCol == nil, "orphaned ColorPicker")
	check("inline KeyPicker removed from store", O.HostKey == nil, "orphaned KeyPicker")
end)

-- A destroyed bind must go quiet. Library signals are plain Lua signals, so
-- destroying the instances does not disconnect the handlers on its own.
step("destroyed KeyPicker stops firing", function()
	local box = Tabs.Main:AddRightGroupbox("Ghost")
	local hits = 0
	local picker = box:AddKeyPicker("GhostKey", {
		Default = "P",
		Mode = "Toggle",
		Text = "ghost",
		Callback = function()
			hits += 1
		end,
	})

	pressKey("P")
	local afterLive = hits
	check("live bind fires", afterLive > 0, "bind never fired while alive")

	picker:Destroy()
	pressKey("P")
	check("destroyed bind is silent", hits == afterLive, ("callback ran %d more time(s) after Destroy"):format(hits - afterLive))
end)

step("stray input does not error", function()
	local input = Instance.new("InputObject")
	input.UserInputType = Enum.UserInputType.Keyboard
	input.KeyCode = Enum.KeyCode.J
	__UserInputService.InputBegan:Fire(input, false)
	__UserInputService.InputEnded:Fire(input, false)
end)

--==============================================================
-- themes
--==============================================================

step("ThemeManager SetFolder", function()
	Library.ThemeManager:SetFolder("SableSmoke")
end)
step("ThemeManager ApplyToTab", function()
	Library.ThemeManager:ApplyToTab(Tabs.Settings)
end)
local themeNames = {}
step("BuiltInThemes present", function()
	for name in Library.ThemeManager.BuiltInThemes do
		table.insert(themeNames, name)
	end
	table.sort(themeNames)
end)
check("has >= 5 built-in themes", #themeNames >= 5, table.concat(themeNames, ", "))
step("apply every built-in theme", function()
	for _, name in themeNames do
		Library.ThemeManager:ApplyTheme(name)
	end
end)
check("accent still a Color3 after theming", typeof(Library.Scheme.Accent) == "Color3")
check("AccentDim still a Color3", typeof(Library.Scheme.AccentDim) == "Color3")

step("live SetScheme", function()
	Library:SetScheme("Accent", Color3.fromRGB(0, 255, 128))
	Library:UpdateColorsUsingRegistry()
end)

--==============================================================
-- saved themes (custom theme round-trip)
--==============================================================

local TM = Library.ThemeManager

step("theme name sanitising", function()
	check("rejects empty name", TM:Sanitize("") == nil)
	check("rejects the reserved default", TM:Sanitize("default") == nil)
	check("strips path separators", TM:Sanitize("../../evil") == "evil", TM:Sanitize("../../evil"))
	check("keeps a plain name", TM:Sanitize("night ops") == "night ops")
end)

step("apply Ember then save it as a theme", function()
	TM:ApplyTheme("Ember")
	Library:SetScheme("Accent", Color3.fromRGB(11, 22, 33))
end)
check("SaveCustomTheme returns true", TM:SaveCustomTheme("smoke-theme") == true)
check("save refuses a nameless theme", TM:SaveCustomTheme("") == false)
check("save refuses the reserved name", TM:SaveCustomTheme("default") == false)

local customList = TM:CustomThemeList()
check("theme appears in the list", table.find(customList, "smoke-theme") ~= nil, table.concat(customList, ", "))
check("list excludes the default pointer", table.find(customList, "default") == nil)

step("clobber the scheme", function()
	TM:ApplyTheme("Ice")
end)
check("scheme was clobbered", Library.Scheme.Accent ~= Color3.fromRGB(11, 22, 33))

check("LoadCustomTheme returns true", TM:LoadCustomTheme("smoke-theme") == true)
check("saved accent restored", Library.Scheme.Accent == Color3.fromRGB(11, 22, 33), tostring(Library.Scheme.Accent))
check("saved panel restored", Library.Scheme.Panel == Library.ThemeManager.BuiltInThemes.Ember.Panel)
check("CustomTheme tracked", TM.CustomTheme == "smoke-theme", tostring(TM.CustomTheme))
check("load refuses a missing theme", TM:LoadCustomTheme("no-such-theme") == false)

step("custom theme survives as the startup default", function()
	check("SetDefault accepts a saved theme", TM:SetDefault("smoke-theme") == true)
	TM:ApplyTheme("Void")
	check("LoadDefault restores it", TM:LoadDefault() == "smoke-theme")
	check("default accent restored", Library.Scheme.Accent == Color3.fromRGB(11, 22, 33))
end)

check("DeleteCustomTheme returns true", TM:DeleteCustomTheme("smoke-theme") == true)
check("delete is not repeatable", TM:DeleteCustomTheme("smoke-theme") == false)
check("theme left the list", table.find(TM:CustomThemeList(), "smoke-theme") == nil)
check("stale default falls back", TM:LoadDefault() == "Sable", TM.Theme)

check("theme indexes are ignorable", table.find(TM.Indexes, TM.CustomListIndex) ~= nil)
check("name index is ignorable", table.find(TM.Indexes, TM.CustomNameIndex) ~= nil)

step("back to a known theme", function()
	TM:ApplyTheme("Sable")
end)

--==============================================================
-- config round-trip (the highest-risk path)
--==============================================================

step("SaveManager setup", function()
	Library.SaveManager:SetFolder("SableSmoke/game")
	Library.SaveManager:IgnoreThemeSettings()
	Library.SaveManager:SetIgnoreIndexes({ "Bare" })
	Library.SaveManager:BuildConfigSection(Tabs.Settings)
end)

-- Known state to save.
step("seed state", function()
	T.Enabled:SetValue(true)
	O.Fov:SetValue(321)
	O.Smooth:SetValue(0.42)
	O.Name:SetValue("round-trip")
	O.Bone:SetValue("Root")
	O.Parts:SetValue({ Head = true, Arms = true })
	O.Col:SetValue(Color3.fromRGB(12, 34, 56))
	O.Bind:SetValue("MB2")
	T.Bare:SetValue(true)
	-- Runtime-only elements. Both live in Options, so only serialize() dropping
	-- their type keeps them out of the file below.
	O.Farm:SetValue(77)
	O.Banner:SetImage("rbxassetid://999")
end)

step("Save config", function()
	Library.SaveManager:Save("smoke")
end)
drain()

-- Clobber everything.
step("clobber state", function()
	T.Enabled:SetValue(false)
	O.Fov:SetValue(0)
	O.Smooth:SetValue(0)
	O.Name:SetValue("clobbered")
	O.Bone:SetValue("Head")
	O.Parts:SetValue({})
	O.Col:SetValue(Color3.fromRGB(200, 200, 200))
	O.Bind:SetValue("K")
	T.Bare:SetValue(false)
	O.Farm:SetValue(0)
	O.Banner:SetImage("rbxassetid://111")
end)

step("Load config", function()
	Library.SaveManager:Load("smoke")
end)
drain()

check("RT toggle", T.Enabled.Value == true, tostring(T.Enabled.Value))
check("RT slider int", O.Fov.Value == 321, tostring(O.Fov.Value))
check("RT slider decimal", math.abs(O.Smooth.Value - 0.42) < 1e-6, tostring(O.Smooth.Value))
check("RT input", O.Name.Value == "round-trip", tostring(O.Name.Value))
check("RT dropdown single", O.Bone.Value == "Root", tostring(O.Bone.Value))
check(
	"RT dropdown multi",
	type(O.Parts.Value) == "table" and O.Parts.Value.Head == true and O.Parts.Value.Arms == true,
	type(O.Parts.Value) == "table" and __jsonEncode(O.Parts.Value) or type(O.Parts.Value)
)
check("RT colorpicker", math.abs(O.Col.Value.R - 12 / 255) < 0.01, tostring(O.Col.Value))
check("RT keypicker", O.Bind.Value == "MB2", tostring(O.Bind.Value))
check("ignored index NOT restored", T.Bare.Value == false, "SetIgnoreIndexes did not exclude 'Bare'")

-- Progress and images are runtime state, not settings. serialize() has no case
-- for either type, so Collect() drops them and Apply() has nothing to restore.
local savedConfig = Library.Util.FS.Read("SableSmoke/game/settings/smoke.json") or ""
check("config file was written", #savedConfig > 0)
check("progress bar never reached the file", savedConfig:find("Farm", 1, true) == nil, savedConfig:sub(1, 160))
check("image never reached the file", savedConfig:find("Banner", 1, true) == nil, savedConfig:sub(1, 160))
check("progress bar NOT restored by a load", O.Farm.Value == 0, O.Farm.Value)
check("image NOT restored by a load", O.Banner.Value == "rbxassetid://111", O.Banner.Value)

-- The empty multi-select set: JSONEncode turns {} into "[]", which decodes as
-- an array. If that is not handled, the value comes back the wrong shape.
step("save/load with EMPTY multi set", function()
	O.Parts:SetValue({})
	Library.SaveManager:Save("emptyset")
	O.Parts:SetValue({ Head = true })
	Library.SaveManager:Load("emptyset")
end)
drain()
check(
	"RT empty multi set stays a table",
	type(O.Parts.Value) == "table",
	"got " .. type(O.Parts.Value)
)
check(
	"RT empty multi set is actually empty",
	type(O.Parts.Value) == "table" and next(O.Parts.Value) == nil,
	type(O.Parts.Value) == "table" and __jsonEncode(O.Parts.Value) or "?"
)

step("config list refresh", function()
	Library.SaveManager:RefreshConfigList()
end)
step("delete config", function()
	Library.SaveManager:Delete("emptyset")
end)
step("load missing config degrades", function()
	Library.SaveManager:Load("does-not-exist")
end)
step("LoadAutoloadConfig with none set", function()
	Library.SaveManager:LoadAutoloadConfig()
end)

--==============================================================
-- shareable configs
--==============================================================

local SM = Library.SaveManager

-- Deliberately different from every value the file round-trip above used, so a
-- stale element cannot pass this section by accident.
step("seed share state", function()
	T.Enabled:SetValue(true)
	O.Fov:SetValue(287)
	O.Smooth:SetValue(0.73)
	-- Config strings travel through base64 as BYTES; non-ASCII has to survive.
	O.Name:SetValue("shared \u{00e9}\u{4e2d}\u{6587}")
	-- Bone's value list was narrowed to { Head, Root } earlier in this file.
	O.Bone:SetValue("Root")
	O.Parts:SetValue({ Torso = true, Arms = true })
	O.Col:SetValue(Color3.fromRGB(9, 180, 231))
	O.ColA:SetValue(Color3.fromRGB(3, 4, 5))
	O.ColA:SetTransparency(0.5)
	O.Bind:SetValue({ "MB3", "Hold" })
	O.Farm:SetValue(64)
	O.Banner:SetImage("rbxassetid://424242")
	T.Bare:SetValue(true)
end)
drain()

local shared
step("ExportConfig of the live state", function()
	local text, reason = SM:ExportConfig()
	shared = text
	check("export produced a string", type(text) == "string", reason)
end)

shared = type(shared) == "string" and shared or ""
check("share string is a single line", shared:find("[\r\n]") == nil)
check("share string carries the versioned prefix", shared:sub(1, 7) == "SABLE1:", shared:sub(1, 16))
check("share string is paste-safe", shared:match("^SABLE1:[A-Za-z0-9%+/=]+$") ~= nil, shared:sub(1, 48))

-- Compression is only worth carrying if it actually pays. Base64 alone costs
-- 4 characters per 3 bytes, so a shared string SHORTER than the raw JSON it
-- carries can only mean the compressor ran and won.
local liveJson = __jsonEncode({ version = 1, objects = SM:Collect() })
check("compression beat plain JSON", #shared < #liveJson, ("%d chars vs %d of JSON"):format(#shared, #liveJson))

local decodedShare, decodeReason = SM:DecodeConfig(shared)
check("DecodeConfig returns the payload", type(decodedShare) == "table", decodeReason)
check(
	"decoded payload carries objects",
	type(decodedShare) == "table" and type(decodedShare.objects) == "table",
	decodeReason
)

local sharedTypes = {}
if type(decodedShare) == "table" and type(decodedShare.objects) == "table" then
	for _, entry in decodedShare.objects do
		if type(entry) == "table" then
			sharedTypes[tostring(entry.idx)] = tostring(entry.type)
		end
	end
end
check("shared payload carries the toggle", sharedTypes.Enabled == "Toggle", sharedTypes.Enabled)
check("progress bar never entered a shared string", sharedTypes.Farm == nil, sharedTypes.Farm)
check("image never entered a shared string", sharedTypes.Banner == nil, sharedTypes.Banner)
check("the paste box never enters a shared string", sharedTypes.SaveManager_ConfigShare == nil)
check("ignored index never entered a shared string", sharedTypes.Bare == nil)

step("clobber every shared value", function()
	T.Enabled:SetValue(false)
	O.Fov:SetValue(3)
	O.Smooth:SetValue(0.01)
	O.Name:SetValue("clobbered")
	O.Bone:SetValue("Head")
	O.Parts:SetValue({ Head = true })
	O.Col:SetValue(Color3.fromRGB(200, 200, 200))
	O.ColA:SetValue(Color3.fromRGB(250, 250, 250))
	O.ColA:SetTransparency(0)
	O.Bind:SetValue({ "K", "Toggle" })
	O.Farm:SetValue(0)
	O.Banner:SetImage("rbxassetid://111")
	-- Ignored, so the import must leave it exactly here.
	T.Bare:SetValue(false)
end)
drain()

local importedOk
step("ImportConfig applies the string", function()
	importedOk = SM:ImportConfig(shared)
end)
drain()

check("import reported success", importedOk == true)
check("share RT toggle", T.Enabled.Value == true, tostring(T.Enabled.Value))
check("share RT slider int", O.Fov.Value == 287, tostring(O.Fov.Value))
check("share RT slider decimal", math.abs(O.Smooth.Value - 0.73) < 1e-6, tostring(O.Smooth.Value))
check("share RT input keeps non-ASCII", O.Name.Value == "shared \u{00e9}\u{4e2d}\u{6587}", O.Name.Value)
check("share RT dropdown single", O.Bone.Value == "Root", tostring(O.Bone.Value))
check(
	"share RT dropdown multi",
	type(O.Parts.Value) == "table" and O.Parts.Value.Torso == true and O.Parts.Value.Arms == true and O.Parts.Value.Head == nil,
	type(O.Parts.Value) == "table" and __jsonEncode(O.Parts.Value) or type(O.Parts.Value)
)
check("share RT colorpicker", math.abs(O.Col.Value.G - 180 / 255) < 0.01, tostring(O.Col.Value))
check("share RT colorpicker transparency", math.abs(O.ColA.Transparency - 0.5) < 1e-6, tostring(O.ColA.Transparency))
check("share RT keypicker key", O.Bind.Value == "MB3", tostring(O.Bind.Value))
check("share RT keypicker mode", O.Bind.Mode == "Hold", tostring(O.Bind.Mode))
check("share import left the progress bar alone", O.Farm.Value == 0, O.Farm.Value)
check("share import left the image alone", O.Banner.Value == "rbxassetid://111", O.Banner.Value)
check("share import honoured the ignore list", T.Bare.Value == false, "an ignored index came back")

-- Nobody pastes a clean string. Chat clients add a trailing newline, and a long
-- one comes back wrapped.
step("a pasted string survives whitespace and wrapping", function()
	local padded = "\n  " .. shared .. "  \n"
	local wrapped = shared:sub(1, 40) .. "\n" .. shared:sub(41)

	local paddedData = SM:DecodeConfig(padded)
	local wrappedData = SM:DecodeConfig(wrapped)

	check("leading/trailing whitespace is trimmed", type(paddedData) == "table")
	check("a wrapped string still decodes", type(wrappedData) == "table")
	check(
		"a wrapped string decodes to the same config",
		type(wrappedData) == "table" and type(paddedData) == "table" and #wrappedData.objects == #paddedData.objects
	)
end)

-- Exporting a NAME must read that file, not whatever is on screen. The saved
-- "smoke" config holds Fov = 321; the live slider is sitting on 287.
step("ExportConfig of a SAVED config", function()
	local text, reason = SM:ExportConfig("smoke")
	check("saved-config export produced a string", type(text) == "string", reason)

	local data = SM:DecodeConfig(type(text) == "string" and text or "")
	check("saved-config export decodes", type(data) == "table" and type(data.objects) == "table")
	check("saved-config export is named", type(data) == "table" and data.name == "smoke", type(data) == "table" and tostring(data.name))

	local exported
	if type(data) == "table" and type(data.objects) == "table" then
		for _, entry in data.objects do
			if type(entry) == "table" and entry.idx == "Fov" then
				exported = entry.value
			end
		end
	end
	check("saved-config export carries the FILE's values, not the live ones", exported == 321, tostring(exported))
end)

-- A string that carries nothing is not worth handing to anyone, and saying so is
-- cheaper than letting the far end report "that decoded, but it is not a config".
step("a config with no values in it refuses to export", function()
	local hollow = "SableSmoke/game/settings/hollow.json"
	Library.Util.FS.WriteJSON(hollow, { name = "hollow", version = 1, objects = {} })

	local text, reason = SM:ExportConfig("hollow")
	check("an empty config produced no string", text == nil, tostring(text))
	check("and it said why", type(reason) == "string" and #reason > 0, tostring(reason))

	Library.Util.FS.Delete(hollow)
end)

-- The LZW stream packs two 12-bit codes into three bytes, so an odd number of
-- codes leaves a lone code in the last two. Payload size decides that parity,
-- so only a RANGE of sizes puts both through the encoder. Each probe is padded
-- with repetition heavy enough that compression must win -- which makes the
-- length check below a real test of the packing, not just of the decode: a
-- payload the encoder cannot re-read falls back to plain text and grows.
step("shared strings survive every payload size", function()
	local probe = "SableSmoke/game/settings/probe.json"

	for count = 1, 16 do
		local objects = {}
		for index = 1, count do
			table.insert(objects, { type = "Input", idx = "Probe" .. index, value = ("sable"):rep(20 + index) })
		end
		Library.Util.FS.WriteJSON(probe, { name = "probe", version = 1, objects = objects })

		local text = SM:ExportConfig("probe")
		local data = type(text) == "string" and SM:DecodeConfig(text) or nil
		local last = type(data) == "table" and type(data.objects) == "table" and data.objects[count]
		local fileSize = #(Library.Util.FS.Read(probe) or "")

		check(
			("payload of %d entries round-trips"):format(count),
			type(last) == "table" and #data.objects == count and last.value == ("sable"):rep(20 + count),
			type(data) == "table" and #data.objects or "did not decode"
		)
		-- What the same config would cost with the compressor skipped: the prefix
		-- plus base64's flat 4 characters per 3 bytes. Eight characters of slack
		-- absorbs the small difference between the file's JSON and the payload's.
		local plain = math.ceil((fileSize + 1) / 3) * 4 + 7
		check(
			("payload of %d entries stayed compressed"):format(count),
			type(text) == "string" and #text + 8 < plain,
			("%d chars, plain would be %d"):format(type(text) == "string" and #text or -1, plain)
		)
	end

	Library.Util.FS.Delete(probe)
end)

-- Every probe above fits comfortably inside the 12-bit code space. A hub with a
-- few hundred controls does not: past 3840 dictionary entries the encoder stops
-- adding, and the decoder must stop at exactly the same code or the two walk
-- apart. Nothing else in this file reaches that far, so nothing else can tell
-- whether the freeze is honoured at both ends.
step("a config large enough to freeze the LZW dictionary still round-trips", function()
	local probe = "SableSmoke/game/settings/big.json"

	local objects = {}
	for index = 1, 900 do
		-- Varied on purpose: a config that replayed the same handful of strings
		-- would never mint enough dictionary entries to reach the ceiling.
		table.insert(objects, {
			type = "Input",
			idx = "Big" .. index,
			value = ("%d-%s"):format(index * 7919 % 100003, ("qz"):rep(index % 11 + 1)),
		})
	end
	Library.Util.FS.WriteJSON(probe, { name = "big", version = 1, objects = objects })

	local fileSize = #(Library.Util.FS.Read(probe) or "")
	local text = SM:ExportConfig("big")
	check("the big config exported", type(text) == "string", tostring(text))

	local data = type(text) == "string" and SM:DecodeConfig(text) or nil
	local last = type(data) == "table" and type(data.objects) == "table" and data.objects[900]
	check(
		"all 900 entries survived a frozen dictionary",
		type(last) == "table" and #data.objects == 900 and last.value == objects[900].value,
		type(data) == "table" and type(data.objects) == "table" and #data.objects or "did not decode"
	)

	-- packPayload re-reads its own output before shipping it, so a decoder frozen
	-- at a different code than the encoder cannot corrupt anything -- it falls
	-- back to plain text instead, and the string balloons. Size is the only
	-- visible symptom of that, so size is what is asserted.
	local plain = math.ceil((fileSize + 1) / 3) * 4 + 7
	check(
		"and it is still compressed, not silently fallen back to raw",
		type(text) == "string" and #text * 2 < plain,
		("%d chars, plain would be %d"):format(type(text) == "string" and #text or -1, plain)
	)

	Library.Util.FS.Delete(probe)
end)

--- Every failure mode has to come back as a distinct, human-readable reason --
--- and never as an error, because this is the one input a user pastes into.
local reasons = {}
local reasonCount = 0
local function rejects(label, text)
	-- pcall passes every return through, so this proves "no error" and reads
	-- the reason in one call.
	local ok, value, why = pcall(SM.DecodeConfig, SM, text)

	check(label .. ": did not error", ok, value)
	if not ok then
		return
	end

	check(label .. ": rejected", value == nil, "decoded anyway")
	check(label .. ": gave a reason", type(why) == "string" and #why > 0, tostring(why))

	if type(why) == "string" then
		reasons[label] = why
		reasonCount += 1
	end
end

rejects("nil input", nil)
rejects("empty input", "   \n  ")
rejects("plain text", "hey look at my config")
rejects("prefix only", "SABLE1:")
rejects("unknown version", "SABLE7:UnsiYSI6MX0=")
rejects("invalid base64", "SABLE1:not base64!!")
-- Hand-built payloads, base64 of: "R{not json", 'R"just text"', 'R{"a":1}',
-- 'Q{"objects":[]}' (unknown mode byte) and "Z\0\0\0\9" (a compressed body
-- whose header promises nine codes and then stops).
rejects("malformed json", "SABLE1:Untub3QganNvbg==")
rejects("json that is not a table", "SABLE1:UiJqdXN0IHRleHQi")
rejects("table that is not a config", "SABLE1:UnsiYSI6MX0=")
rejects("unknown payload mode", "SABLE1:UXsib2JqZWN0cyI6W119")
rejects("truncated compressed payload", "SABLE1:WgAAAAk=")

local seenReasons = {}
for label, reason in reasons do
	-- "nil input" and "empty input" are the same fault reached two ways, so they
	-- deliberately share wording. Everything else must stand alone, or a user
	-- cannot tell a mistyped prefix from a truncated paste.
	if label ~= "empty input" then
		check(
			("reason for %q is its own"):format(label),
			seenReasons[reason] == nil,
			("shares wording with %s: %s"):format(tostring(seenReasons[reason]), reason)
		)
		seenReasons[reason] = label
	end
end
check("every rejection produced a reason", reasonCount == 11, reasonCount)

-- Two deliberate asymmetries in the base64 reader that no assertion above can
-- see: it is lenient where leniency costs nothing, strict where strictness is
-- information.
step("base64 is lenient about spelling and strict about length", function()
	-- Chat clients and forums rewrite "+/" into the url-safe "-_". Sable never
	-- emits those spellings; it does have to read them back. The live config's
	-- own string is short enough that it need not contain either symbol, and an
	-- assertion that might exercise nothing is not an assertion -- so grow a
	-- config until its shared string does.
	local alphabet = "SableSmoke/game/settings/alphabet.json"
	local subject, swaps = nil, 0
	for size = 40, 400, 40 do
		local objects = {}
		for index = 1, size do
			table.insert(objects, { type = "Input", idx = "Sym" .. index, value = ("%d"):format(index * 6151 % 65521) })
		end
		Library.Util.FS.WriteJSON(alphabet, { name = "alphabet", version = 1, objects = objects })

		local text = SM:ExportConfig("alphabet")
		if type(text) == "string" then
			local _, plus = text:gsub("%+", "")
			local _, slash = text:gsub("/", "")
			if plus + slash > 0 then
				subject, swaps = text, plus + slash
				break
			end
		end
	end
	Library.Util.FS.Delete(alphabet)

	check("found a shared string that uses the url-unsafe symbols", swaps > 0, swaps)
	local urlSafe = subject and (subject:gsub("%+", "-"):gsub("/", "_")) or ""
	check("a url-safe respelling still decodes", type(SM:DecodeConfig(urlSafe)) == "table")
	check("and the original spelling decodes too", type(SM:DecodeConfig(subject or "")) == "table")

	-- Four base64 digits carry three bytes, so a lone leftover digit carries
	-- none. Accepting it would decode to zero bytes and report the WRONG fault --
	-- "nothing after the prefix", when what actually happened is a truncated
	-- paste.
	local decoded, whyLone = SM:DecodeConfig("SABLE1:U")
	check("a lone base64 digit is rejected", decoded == nil)
	check("and it is reported as damage, not as an empty body", whyLone == reasons["invalid base64"], tostring(whyLone))
end)

-- A refused import must be inert, not half-applied.
step("a rejected import changes nothing", function()
	local before = O.Fov.Value
	local ok, reason = SM:ImportConfig("SABLE1:not base64!!")
	drain()
	check("import returned false", ok == false)
	check("import handed back the reason", type(reason) == "string", tostring(reason))
	check("import touched no values", O.Fov.Value == before, O.Fov.Value)
end)

step("ImportConfig of junk never errors", function()
	SM:ImportConfig(nil)
	SM:ImportConfig("")
	SM:ImportConfig(42)
	SM:ImportConfig("SABLE1:")
end)

--==============================================================
-- clipboard + named import
--==============================================================

step("CopyConfig writes the clipboard", function()
	__clipboard = nil
	local ok, text = SM:CopyConfig()
	check("copy reported success", ok == true)
	check("copy returned the string", type(text) == "string" and text:sub(1, 7) == "SABLE1:", tostring(text):sub(1, 16))
	check("clipboard holds exactly that string", __clipboard == text, tostring(__clipboard):sub(1, 24))
end)

step("CopyConfig reports a dead clipboard instead of claiming success", function()
	__clipboard = nil
	__clipboardFails = true
	local ok, text = SM:CopyConfig()
	__clipboardFails = false

	check("copy reported failure", ok == false)
	check("copy STILL handed back the string", type(text) == "string" and text:sub(1, 7) == "SABLE1:", tostring(text):sub(1, 16))
	check("nothing reached the clipboard", __clipboard == nil, tostring(__clipboard))
end)

step("CopyConfig of a config that does not exist", function()
	__clipboard = nil
	local ok, text, reason = SM:CopyConfig("no-such-config")
	check("copy of a missing config failed", ok == false)
	check("no string was produced", text == nil, tostring(text))
	check("a reason was produced", type(reason) == "string", tostring(reason))
	check("clipboard untouched", __clipboard == nil)
end)

step("import under a name persists it", function()
	local ok = SM:ImportConfig(shared, "from friend")
	check("named import succeeded", ok == true)
end)
drain()

check("named import wrote a file", (Library.Util.FS.Read("SableSmoke/game/settings/from friend.json") or "") ~= "")
check("named import shows up in the list", table.find(SM:ConfigList(), "from friend") ~= nil)

step("the file a named import wrote is loadable", function()
	O.Fov:SetValue(11)
	O.Name:SetValue("wiped")
	SM:Load("from friend")
end)
drain()
check("imported file restored the slider", O.Fov.Value == 287, O.Fov.Value)
check("imported file restored the input", O.Name.Value == "shared \u{00e9}\u{4e2d}\u{6587}", O.Name.Value)

-- A pasted name is as untrusted as a pasted config: it is sanitised, not
-- rejected, exactly as :Save does.
step("a named import cannot escape the settings folder", function()
	SM:ImportConfig(shared, "../../evil")
end)
drain()
check("traversal collapsed to a plain name", Library.Util.FS.IsFile("SableSmoke/game/settings/evil.json"))
for path in __files do
	check("nothing was written outside the folder", path:find("%.%.") == nil, path)
end

-- The file a named import writes is the decoded payload VERBATIM, not a
-- re-collect of what landed. For a config this hub can apply in full the two are
-- indistinguishable -- which is exactly why this probe carries indexes the hub
-- does NOT have. A re-collect would quietly strip them and hand the next person
-- a lesser config than the one that was shared.
step("a named import saves the payload verbatim, foreign entries included", function()
	local foreign = "SableSmoke/game/settings/foreign.json"
	Library.Util.FS.WriteJSON(foreign, {
		name = "foreign",
		version = 1,
		objects = {
			{ type = "Toggle", idx = "NotInThisHub", value = true },
			{ type = "Slider", idx = "AlsoMissingHere", value = 7 },
			{ type = "Input", idx = "StrangerStill", value = "kept" },
		},
	})

	local text = SM:ExportConfig("foreign")
	check("a config of foreign entries exports", type(text) == "string", tostring(text))
	check("and imports under a name", SM:ImportConfig(type(text) == "string" and text or "", "relayed") == true)

	local written = Library.Util.FS.ReadJSON("SableSmoke/game/settings/relayed.json")
	local objects = type(written) == "table" and type(written.objects) == "table" and written.objects or nil

	local kept = {}
	for _, entry in objects or {} do
		if type(entry) == "table" then
			kept[tostring(entry.idx)] = true
		end
	end

	check("the saved file is the payload, not a re-collect", objects ~= nil and #objects == 3, objects and #objects or "unreadable")
	check(
		"indexes this hub does not have survived the save",
		kept.NotInThisHub == true and kept.AlsoMissingHere == true and kept.StrangerStill == true,
		table.concat(Library.Util.SortedKeys(kept), ",")
	)

	Library.Util.FS.Delete(foreign)
end)
drain()

--==============================================================
-- share controls in the config groupbox
--==============================================================

local shareBox = SM.Objects.Share
check("config section built a paste field", type(shareBox) == "table" and shareBox.Type == "Input", type(shareBox))
check(
	"the paste field does not empty itself when clicked",
	type(shareBox) == "table" and shareBox.Box.ClearTextOnFocus == false,
	"a paste field that clears on focus loses the paste"
)
check("the paste field is ignored by configs", SM.Ignore.SaveManager_ConfigShare == true)
check("the paste field is listed in Indexes", table.find(SM.Indexes, "SaveManager_ConfigShare") ~= nil)

local copyButton, importButton
step("find the share buttons", function()
	for _, box in Tabs.Settings.Boxes do
		if type(box.Elements) == "table" then
			for _, element in box.Elements do
				if element.Type == "Button" and element.Text == "Copy config" then
					copyButton = element
				elseif element.Type == "Button" and element.Text == "Import" then
					importButton = element
				end
			end
		end
	end
	check("config section offers COPY CONFIG", copyButton ~= nil)
	check("config section offers IMPORT", importButton ~= nil)
end)

step("the COPY button copies", function()
	if not copyButton then
		return
	end
	__clipboard = nil
	copyButton.Hit.MouseButton1Click:Fire()
	drain()
	check("copy button reached the clipboard", type(__clipboard) == "string" and __clipboard:sub(1, 7) == "SABLE1:", tostring(__clipboard):sub(1, 16))
end)

step("the IMPORT button reads the paste field and the name field", function()
	if not importButton or not shareBox then
		return
	end

	O.Fov:SetValue(5)
	shareBox:SetValue(shared)
	SM.Objects.Name:SetValue("via button")

	importButton.Hit.MouseButton1Click:Fire()
	drain()

	check("import button applied the pasted string", O.Fov.Value == 287, O.Fov.Value)
	check("import button saved under the typed name", Library.Util.FS.IsFile("SableSmoke/game/settings/via button.json"))
end)

step("the IMPORT button reports a bad paste", function()
	if not importButton or not shareBox then
		return
	end
	shareBox:SetValue("garbage")
	SM.Objects.Name:SetValue("")
	importButton.Hit.MouseButton1Click:Fire()
	drain()
	check("a rejected paste left the values alone", O.Fov.Value == 287, O.Fov.Value)
end)

--==============================================================
-- AddSettingsTab
--==============================================================

-- Runs last: it rebuilds ThemeManager.Objects / SaveManager.Objects against a
-- new tab, so anything above that reads those would be looking at the wrong
-- controls afterwards.
-- A saved layout is only useful if something restores it, and AddSettingsTab is
-- where that happens. Park a layout on disk, move the panels somewhere else,
-- and let the tab build put them back.
step("seed a saved hud layout, then clobber the live one", function()
	Library.Util.FS.WriteJSON("SableSmoke/hud/hud.json", {
		Watermark = { X = 300, Y = 200 },
		KeybindList = { X = 300, Y = 260 },
	})

	Library:SetHudFolder("SableSmoke/hud2")
	Library:LoadHudLayout()
	check("live positions clobbered", Library:GetHudLayout().Watermark.X == 10)

	Library:SetHudFolder("SableSmoke/hud")
end)

local settingsTab
step("AddSettingsTab", function()
	settingsTab = Window:AddSettingsTab()
end)
drain()

local afterSettings = Library:GetHudLayout()
check("settings tab restored the saved hud layout", afterSettings.Watermark.X == 300, afterSettings.Watermark.X)
check("restored both panels", afterSettings.KeybindList.Y == 260, afterSettings.KeybindList.Y)

local resetButton
step("find the Reset HUD positions button", function()
	for _, box in settingsTab.Boxes do
		if type(box.Elements) == "table" then
			for _, element in box.Elements do
				if element.Type == "Button" and element.Text == "Reset HUD positions" then
					resetButton = element
				end
			end
		end
	end
	check("settings tab offers a HUD reset", resetButton ~= nil)
end)

step("the reset button moves the panels home", function()
	if not resetButton then
		return
	end
	resetButton.Hit.MouseButton1Click:Fire()
	drain()
	check("button reset the layout", Library:GetHudLayout().Watermark.X == hudDefaults.Watermark.X)
	check("button persisted the reset", (Library.Util.FS.ReadJSON("SableSmoke/hud/hud.json") or {}).Watermark.Y == hudDefaults.Watermark.Y)
end)

check("settings tab returned", type(settingsTab) == "table")
check("settings tab named", settingsTab and settingsTab.Name == "Settings", settingsTab and settingsTab.Name)
check("settings tab registered", settingsTab and table.find(Window.Tabs, settingsTab) ~= nil)

check("menu keybind registered", type(O.MenuKeybind) == "table")
check("menu keybind default", O.MenuKeybind and O.MenuKeybind.Value == Library.MenuKeybind, O.MenuKeybind and O.MenuKeybind.Value)
check("menu keybind mode", O.MenuKeybind and O.MenuKeybind.Mode == "Toggle")
check("menu keybind hidden from list", O.MenuKeybind and O.MenuKeybind.NoUI == true)
check("watermark toggle registered", type(T.SableWatermark) == "table")
check("keybind list toggle registered", type(T.SableKeybindList) == "table")
check("watermark toggle default", T.SableWatermark and T.SableWatermark.Value == true)
check("keybind list toggle default", T.SableKeybindList and T.SableKeybindList.Value == true)

step("menu keybind drives SetMenuKeybind", function()
	O.MenuKeybind:SetValue("F4")
end)
drain()
check("menu keybind applied", Library.MenuKeybind == "F4", Library.MenuKeybind)
step("menu keybind restored", function()
	O.MenuKeybind:SetValue("INS")
end)
drain()

step("watermark toggle drives visibility", function()
	T.SableWatermark:SetValue(false)
end)
drain()
check("watermark hidden", Library.WatermarkVisible == false)
step("watermark toggle restored", function()
	T.SableWatermark:SetValue(true)
end)
drain()

step("keybind list toggle drives visibility", function()
	T.SableKeybindList:SetValue(false)
end)
drain()
check("keybind list hidden", Library.KeybindsVisible == false)
step("keybind list toggle restored", function()
	T.SableKeybindList:SetValue(true)
end)
drain()

local ignore = Library.SaveManager.Ignore
check("menu keybind ignored", ignore.MenuKeybind == true)
check("watermark ignored", ignore.SableWatermark == true)
check("keybind list ignored", ignore.SableKeybindList == true)
check("theme indexes ignored", ignore[Library.ThemeManager.ListIndex] == true)
-- The whole point of appending: an ignore list the script set earlier must not
-- be replaced by the one AddSettingsTab installs.
check("pre-existing ignore survived", ignore.Bare == true)

check("config section built", type(Library.SaveManager.Objects.List) == "table")
check("theme section built", type(Library.ThemeManager.Objects.List) == "table")

-- SetFolder was called before this, so AddSettingsTab must have left both alone.
check("save folder untouched", Library.SaveManager.Folder == "SableSmoke/game", Library.SaveManager.Folder)
check("theme folder untouched", Library.ThemeManager.Folder == "SableSmoke", Library.ThemeManager.Folder)

--==============================================================
-- teardown
--==============================================================

local signalCount = #Library.Signals
check("signals were tracked", signalCount > 0, signalCount)

-- A column scrolled a frame before Unload leaves a fade in flight; by the time
-- it lands the ScreenGui has been destroyed under it. Queue one here, then
-- check below that it never writes to the dead frame.
local dyingColumn = Tabs.Main.Left
dyingColumn.AbsoluteWindowSize = Vector2.new(300, 400)
dyingColumn.AbsoluteCanvasSize = Vector2.new(300, 2000)
dyingColumn.CanvasPosition = Vector2.new(0, 150)
check("a scroll before unload leaves the bar up", dyingColumn.ScrollBarImageTransparency == FAINT, dyingColumn.ScrollBarImageTransparency)

step("Unload", function()
	Library:Unload()
end)
check("unloaded flag", Library.Unloaded == true)
check("signals cleared", #Library.Signals == 0, #Library.Signals)
check("windows cleared", #Library.Windows == 0)
check("CapturingInput reset", Library.CapturingInput == false)

step("Notify after unload is a no-op", function()
	Library:Notify("should not error", 1)
end)
step("hud layout api no-ops after unload", function()
	check("SaveHudLayout returns false", Library:SaveHudLayout() == false)
	check("LoadHudLayout returns false", Library:LoadHudLayout() == false)
	check("ResetHudLayout is inert", Library:ResetHudLayout() == Library)
	check("GetHudLayout still answers", type(Library:GetHudLayout().Watermark) == "table")
	check("SetHudFolder still answers", Library:SetHudFolder("SableSmoke/after-unload") == Library)
end)
step("a stray drag release after unload does not save", function()
	local press = Instance.new("InputObject")
	press.UserInputType = Enum.UserInputType.MouseButton1
	__UserInputService.InputEnded:Fire(press, false)
	check("nothing written after unload", Library.Util.FS.IsFile("SableSmoke/after-unload/hud.json") == false)
end)
step("Unload is idempotent", function()
	Library:Unload()
end)
step("input after unload does not error", function()
	local input = Instance.new("InputObject")
	input.UserInputType = Enum.UserInputType.Keyboard
	input.KeyCode = Enum.KeyCode.J
	__UserInputService.InputBegan:Fire(input, false)
	__RunService.RenderStepped:Fire(1 / 60)
end)
step("delayed timers after unload do not error", function()
	__drainDelayed()
	__RunService.RenderStepped:Fire(1 / 60)
end)
-- The scrollbar fade is the one timer that outlives the gui it writes to: the
-- column above was scrolled a frame before Unload, so this is where that fade
-- lands -- on a destroyed instance, with the registry already cleared.
step("a fade queued before unload does not touch the destroyed column", function()
	__drainDelayed()
	check(
		"the pending fade was skipped",
		dyingColumn.ScrollBarImageTransparency == FAINT,
		dyingColumn.ScrollBarImageTransparency
	)
	-- Poking a dead column must be inert too: its connections went with Unload.
	dyingColumn.CanvasPosition = Vector2.new(0, 400)
	dyingColumn.MouseEnter:Fire()
	dyingColumn.MouseLeave:Fire()
	__drainDelayed()
end)

--==============================================================
-- report
--==============================================================

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then
	print("\nFAILURES:")
	for _, f in failures do
		print("  " .. f)
	end
	print("\nSMOKE FAILED")
else
	print("SMOKE PASSED")
end
