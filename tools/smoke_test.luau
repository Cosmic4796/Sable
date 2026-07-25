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
-- overlays
--==============================================================

step("Notify string", function()
	Library:Notify("hello", 3)
end)
step("Notify table", function()
	Library:Notify({ Title = "Title", Description = "Body", Time = 2, Risk = true })
	Library:Notify({ Title = "Good", Description = "Body", Time = 2, Good = true })
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

	local mouse = Vector2.new(500, 500)
	__UserInputService.GetMouseLocation = function()
		return mouse
	end

	local press = Instance.new("InputObject")
	press.UserInputType = Enum.UserInputType.MouseButton1
	handle.InputBegan:Fire(press)

	mouse = Vector2.new(560, 540)
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
	mouse = Vector2.new(900, 900)
	__UserInputService.InputChanged:Fire(move, false)
	check("release ended the drag", Library:GetHudLayout().Watermark.X == dragged.Watermark.X)

	__UserInputService.GetMouseLocation = function()
		return Vector2.new(400, 300)
	end
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
	local mouse = Vector2.new(100, 100)
	__UserInputService.GetMouseLocation = function()
		return mouse
	end

	local press = Instance.new("InputObject")
	press.UserInputType = Enum.UserInputType.MouseButton1
	handle.InputBegan:Fire(press)

	mouse = Vector2.new(300, 400)
	local move = Instance.new("InputObject")
	move.UserInputType = Enum.UserInputType.MouseMovement
	__UserInputService.InputChanged:Fire(move, false)
	__UserInputService.InputEnded:Fire(press, false)

	check("closed menu refuses the drag", Library:GetHudLayout().KeybindList.X == before, Library:GetHudLayout().KeybindList.X)

	__UserInputService.GetMouseLocation = function()
		return Vector2.new(400, 300)
	end
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
