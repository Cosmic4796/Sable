--!nonstrict
-- Sable :: Util
-- Dependency-free helpers. Nothing in here may require() another Sable module.

local TweenService = game:GetService("TweenService")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")

local Util = {}

Util.Services = {
	Tween = TweenService,
	Text = TextService,
	Input = UserInputService,
	Players = Players,
	Http = HttpService,
	CoreGui = CoreGui,
	Run = RunService,
}

--==============================================================
-- environment
--==============================================================

-- Captured by ordinary global lookup at load time, which is the only method
-- that works everywhere: not every executor mirrors these into getgenv()'s
-- table, and Roblox's _G is a separate shared table that never holds them.
-- Referencing a global that does not exist yields nil rather than erroring.
local Captured = {
	getgenv = getgenv,
	gethui = gethui,
	get_hidden_gui = get_hidden_gui,
	protect_gui = protect_gui,
	syn = syn,
	identifyexecutor = identifyexecutor,
	getexecutorname = getexecutorname,
	setclipboard = setclipboard,
	toclipboard = toclipboard,
	writefile = writefile,
	readfile = readfile,
	appendfile = appendfile,
	isfile = isfile,
	isfolder = isfolder,
	makefolder = makefolder,
	delfile = delfile,
	delfolder = delfolder,
	listfiles = listfiles,
}

--- Reads an executor global by name without exploding when it is absent.
--- Falls back to getgenv()'s table for hosts that populate it late.
function Util.Global(name)
	local captured = Captured[name]
	if captured ~= nil then
		return captured
	end

	local ok, env = pcall(function()
		return getgenv and getgenv() or nil
	end)
	if ok and type(env) == "table" then
		local value = rawget(env, name)
		if value ~= nil then
			return value
		end
	end

	return nil
end

--- Best-effort executor name, used for the watermark and diagnostics.
function Util.ExecutorName()
	local identify = Util.Global("identifyexecutor") or Util.Global("getexecutorname")
	if type(identify) == "function" then
		local ok, name = pcall(identify)
		if ok and type(name) == "string" and #name > 0 then
			return name
		end
	end
	if Util.Global("syn") then
		return "Synapse"
	end
	if not Util.Global("writefile") then
		return "Studio"
	end
	return "Unknown"
end

function Util.IsExecutor()
	return type(Util.Global("writefile")) == "function"
end

--==============================================================
-- gui hosting
--==============================================================

--- Returns the safest available parent for our ScreenGui.
function Util.GetGuiParent()
	local hui = Util.Global("gethui")
	if type(hui) == "function" then
		local ok, container = pcall(hui)
		if ok and typeof(container) == "Instance" then
			return container
		end
	end

	local hidden = Util.Global("get_hidden_gui")
	if type(hidden) == "function" then
		local ok, container = pcall(hidden)
		if ok and typeof(container) == "Instance" then
			return container
		end
	end

	-- CoreGui access throws for unprivileged contexts; probe before committing.
	local ok = pcall(function()
		return CoreGui:GetChildren()
	end)
	if ok then
		return CoreGui
	end

	local player = Players.LocalPlayer
	if player then
		local playerGui = player:FindFirstChildOfClass("PlayerGui")
		if playerGui then
			return playerGui
		end
		return player:WaitForChild("PlayerGui")
	end

	return CoreGui
end

--- Hides the gui from generic `game.CoreGui:GetChildren()` style detections.
function Util.ProtectGui(gui)
	local syn = Util.Global("syn")
	if type(syn) == "table" and type(syn.protect_gui) == "function" then
		pcall(syn.protect_gui, gui)
	end

	local protect = Util.Global("protect_gui")
	if type(protect) == "function" then
		pcall(protect, gui)
	end

	return gui
end

--==============================================================
-- instances
--==============================================================

--- Instance.new + property table. `Parent` is applied last so we never
--- render a half-configured instance.
function Util.Create(className, props)
	local instance = Instance.new(className)
	local parent = nil

	if props then
		for key, value in props do
			if key == "Parent" then
				parent = value
			elseif type(key) == "number" then
				value.Parent = instance
			else
				instance[key] = value
			end
		end
	end

	if parent then
		instance.Parent = parent
	end

	return instance
end

--- 1px hairline border. Sable never uses BorderSizePixel (it renders inside
--- the frame and fights with layouts) -- always a UIStroke.
function Util.Stroke(parent, color, thickness, transparency)
	return Util.Create("UIStroke", {
		Name = "Stroke",
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Color = color or Color3.new(0, 0, 0),
		Thickness = thickness or 1,
		Transparency = transparency or 0,
		LineJoinMode = Enum.LineJoinMode.Miter,
		Parent = parent,
	})
end

--- Very subtle vertical falloff. Used on chrome only, never on controls.
function Util.Falloff(parent, topScale, bottomScale, rotation)
	topScale = topScale or 1
	bottomScale = bottomScale or 0.92

	return Util.Create("UIGradient", {
		Name = "Falloff",
		Rotation = rotation or 90,
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Color3.new(topScale, topScale, topScale)),
			ColorSequenceKeypoint.new(1, Color3.new(bottomScale, bottomScale, bottomScale)),
		}),
		Parent = parent,
	})
end

function Util.Padding(parent, top, right, bottom, left)
	return Util.Create("UIPadding", {
		Name = "Padding",
		PaddingTop = UDim.new(0, top or 0),
		PaddingRight = UDim.new(0, right or top or 0),
		PaddingBottom = UDim.new(0, bottom or top or 0),
		PaddingLeft = UDim.new(0, left or right or top or 0),
		Parent = parent,
	})
end

function Util.ListLayout(parent, padding, sortOrder)
	return Util.Create("UIListLayout", {
		Name = "List",
		FillDirection = Enum.FillDirection.Vertical,
		SortOrder = sortOrder or Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, padding or 0),
		Parent = parent,
	})
end

--==============================================================
-- math
--==============================================================

function Util.Clamp(value, min, max)
	if value < min then
		return min
	elseif value > max then
		return max
	end
	return value
end

function Util.Lerp(a, b, alpha)
	return a + (b - a) * alpha
end

--- Rounds half away from zero: 2.5 -> 3, -2.5 -> -3.
--- `math.floor(v + 0.5)` alone is wrong for negatives -- it renders -5 as -6.
local function roundHalfAway(value)
	if value >= 0 then
		return math.floor(value + 0.5)
	end
	return math.ceil(value - 0.5)
end

--- Rounds to `decimals` places. decimals = 0 gives an integer.
function Util.Round(value, decimals)
	local mult = 10 ^ (decimals or 0)
	return roundHalfAway(value * mult) / mult
end

function Util.Alpha(value, min, max)
	if max == min then
		return 0
	end
	return Util.Clamp((value - min) / (max - min), 0, 1)
end

--- Formats a number for the right-aligned monospace readouts.
function Util.FormatNumber(value, decimals)
	decimals = decimals or 0
	if decimals <= 0 then
		return tostring(roundHalfAway(value))
	end
	return string.format("%." .. decimals .. "f", value)
end

--==============================================================
-- color
--==============================================================

function Util.ToHex(color)
	return string.format(
		"%02X%02X%02X",
		math.floor(color.R * 255 + 0.5),
		math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5)
	)
end

function Util.FromHex(hex)
	if type(hex) ~= "string" then
		return nil
	end
	hex = hex:gsub("^#", ""):gsub("%s", "")
	if #hex == 3 then
		hex = hex:sub(1, 1):rep(2) .. hex:sub(2, 2):rep(2) .. hex:sub(3, 3):rep(2)
	end
	if #hex ~= 6 or hex:match("[^0-9a-fA-F]") then
		return nil
	end
	return Color3.fromRGB(
		tonumber(hex:sub(1, 2), 16),
		tonumber(hex:sub(3, 4), 16),
		tonumber(hex:sub(5, 6), 16)
	)
end

--- Multiplies value in HSV space. factor > 1 lightens, < 1 darkens.
function Util.Shift(color, factor)
	local h, s, v = color:ToHSV()
	return Color3.fromHSV(h, s, Util.Clamp(v * factor, 0, 1))
end

function Util.Mix(a, b, alpha)
	return a:Lerp(b, alpha)
end

--==============================================================
-- text
--==============================================================

--- Instrument-panel letterspacing. Roblox has no letter-spacing property, so
--- we interleave real spaces. Only used on short chrome labels.
function Util.Letterspace(text, separator)
	separator = separator or " "
	local chars = {}
	for _, code in utf8.codes(tostring(text)) do
		table.insert(chars, utf8.char(code))
	end
	return table.concat(chars, separator)
end

function Util.TextSize(text, textSize, font, bounds)
	local ok, size = pcall(function()
		return TextService:GetTextSize(
			tostring(text),
			textSize,
			font,
			bounds or Vector2.new(math.huge, math.huge)
		)
	end)
	if ok and size then
		return size
	end
	-- Code is ~0.6em wide; good enough for a fallback measurement.
	return Vector2.new(#tostring(text) * textSize * 0.6, textSize)
end

function Util.Truncate(text, maxChars)
	text = tostring(text)
	if utf8.len(text) and (utf8.len(text) :: number) <= maxChars then
		return text
	end
	if #text <= maxChars then
		return text
	end
	return text:sub(1, math.max(1, maxChars - 1)) .. "\u{2026}"
end

--==============================================================
-- input
--==============================================================

local MOUSE_TO_NAME = {
	[Enum.UserInputType.MouseButton1] = "MB1",
	[Enum.UserInputType.MouseButton2] = "MB2",
	[Enum.UserInputType.MouseButton3] = "MB3",
}

local NAME_TO_MOUSE = {}
for inputType, name in MOUSE_TO_NAME do
	NAME_TO_MOUSE[name] = inputType
end

local KEYCODE_TO_NAME = {
	[Enum.KeyCode.LeftShift] = "LSHIFT",
	[Enum.KeyCode.RightShift] = "RSHIFT",
	[Enum.KeyCode.LeftControl] = "LCTRL",
	[Enum.KeyCode.RightControl] = "RCTRL",
	[Enum.KeyCode.LeftAlt] = "LALT",
	[Enum.KeyCode.RightAlt] = "RALT",
	[Enum.KeyCode.CapsLock] = "CAPS",
	[Enum.KeyCode.Backspace] = "BKSP",
	[Enum.KeyCode.Return] = "ENTER",
	[Enum.KeyCode.Escape] = "ESC",
	[Enum.KeyCode.Space] = "SPACE",
	[Enum.KeyCode.Tab] = "TAB",
	[Enum.KeyCode.Delete] = "DEL",
	[Enum.KeyCode.Insert] = "INS",
	[Enum.KeyCode.PageUp] = "PGUP",
	[Enum.KeyCode.PageDown] = "PGDN",
	[Enum.KeyCode.Up] = "UP",
	[Enum.KeyCode.Down] = "DOWN",
	[Enum.KeyCode.Left] = "LEFT",
	[Enum.KeyCode.Right] = "RIGHT",
	[Enum.KeyCode.Semicolon] = ";",
	[Enum.KeyCode.Quote] = "'",
	[Enum.KeyCode.Comma] = ",",
	[Enum.KeyCode.Period] = ".",
	[Enum.KeyCode.Slash] = "/",
	[Enum.KeyCode.BackSlash] = "\\",
	[Enum.KeyCode.LeftBracket] = "[",
	[Enum.KeyCode.RightBracket] = "]",
	[Enum.KeyCode.Minus] = "-",
	[Enum.KeyCode.Equals] = "=",
	[Enum.KeyCode.Backquote] = "`",
}

local NAME_TO_KEYCODE = {}
for keyCode, name in KEYCODE_TO_NAME do
	NAME_TO_KEYCODE[name] = keyCode
end

--- Short, uppercase, fixed-width-friendly name for an InputObject.
--- Returns nil for inputs that make no sense as a bind (movement, focus, etc).
function Util.InputName(input)
	if typeof(input) ~= "Instance" then
		return nil
	end

	-- InputObject is not in the shared Instance surface; widen deliberately.
	local object = input :: any

	local mouse = MOUSE_TO_NAME[object.UserInputType]
	if mouse then
		return mouse
	end

	if object.UserInputType ~= Enum.UserInputType.Keyboard then
		return nil
	end

	local keyCode = object.KeyCode
	-- Compared by name: Enum.KeyCode.Unknown is absent from the published
	-- API dump even though it exists at runtime.
	if keyCode.Name == "Unknown" then
		return nil
	end

	local alias = KEYCODE_TO_NAME[keyCode]
	if alias then
		return alias
	end

	return keyCode.Name:upper()
end

--- Resolves a bind name to a KeyCode.
---
--- Each candidate gets its OWN pcall on purpose: indexing an Enum with a member
--- that does not exist THROWS, so evaluating `Enum.KeyCode[a] or Enum.KeyCode[b]`
--- inside one pcall makes `b` unreachable the moment `a` is not exact.
function Util.KeyCodeFromName(name)
	if type(name) ~= "string" or name == "" then
		return nil
	end

	local direct = NAME_TO_KEYCODE[name:upper()]
	if direct then
		return direct
	end

	-- FromName returns nil instead of throwing, where the client provides it.
	local ok, fromName = pcall(function()
		return (Enum.KeyCode :: any):FromName(name)
	end)
	if ok and typeof(fromName) == "EnumItem" then
		return fromName
	end

	local candidates = {
		name,
		name:sub(1, 1):upper() .. name:sub(2):lower(),
		name:upper(),
	}

	for _, candidate in candidates do
		local success, resolved = pcall(function()
			return (Enum.KeyCode :: any)[candidate]
		end)
		if success and typeof(resolved) == "EnumItem" then
			return resolved
		end
	end

	return nil
end

--- Folds a user-written bind name onto the exact spelling Util.InputName
--- produces, so "INSERT", "Insert" and "INS" all match a real Insert press.
--- Every bind comparison must go through this -- comparing raw strings is what
--- made the default menu hotkey silently dead.
function Util.CanonicalName(name)
	if type(name) ~= "string" or name == "" then
		return nil
	end

	local upper = name:upper()
	if NAME_TO_MOUSE[upper] or NAME_TO_KEYCODE[upper] then
		return upper
	end

	local keyCode = Util.KeyCodeFromName(name)
	if keyCode then
		return KEYCODE_TO_NAME[keyCode] or keyCode.Name:upper()
	end

	return upper
end

function Util.MouseTypeFromName(name)
	return NAME_TO_MOUSE[name]
end

--- True while the named bind is physically held.
function Util.IsHeld(rawName)
	local name = Util.CanonicalName(rawName)
	if not name or name == "NONE" then
		return false
	end

	local mouse = NAME_TO_MOUSE[name]
	if mouse then
		local ok, held = pcall(function()
			return UserInputService:IsMouseButtonPressed(mouse)
		end)
		return ok and held or false
	end

	local keyCode = Util.KeyCodeFromName(name)
	if not keyCode then
		return false
	end

	local ok, held = pcall(function()
		return UserInputService:IsKeyDown(keyCode)
	end)
	return ok and held or false
end

--- Does this input match the bind name? Handles mouse and keyboard alike.
function Util.InputMatches(input, rawName)
	local name = Util.CanonicalName(rawName)
	if not name then
		return false
	end

	local object = input :: any

	local mouse = NAME_TO_MOUSE[name]
	if mouse then
		return object.UserInputType == mouse
	end

	if object.UserInputType ~= Enum.UserInputType.Keyboard then
		return false
	end

	return Util.InputName(input) == name
end

--==============================================================
-- geometry
--==============================================================

function Util.MousePosition()
	return UserInputService:GetMouseLocation()
end

--- Sable's ScreenGui uses IgnoreGuiInset = false, which puts AbsolutePosition
--- in the same space GetMouseLocation reports. Do NOT add inset math here --
--- it is only needed when the ScreenGui ignores the inset.
function Util.MouseOver(guiObject, expand)
	if not guiObject or not guiObject.Visible then
		return false
	end

	expand = expand or 0

	local mouse = UserInputService:GetMouseLocation()
	local x, y = mouse.X, mouse.Y

	local pos = guiObject.AbsolutePosition
	local size = guiObject.AbsoluteSize

	return x >= pos.X - expand
		and x <= pos.X + size.X + expand
		and y >= pos.Y - expand
		and y <= pos.Y + size.Y + expand
end

--==============================================================
-- tween
--==============================================================

-- Mechanical, not bouncy. Instruments do not ease-in-out.
Util.FastInfo = TweenInfo.new(0.09, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
Util.SlowInfo = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

function Util.Tween(instance, props, info)
	local tween = TweenService:Create(instance, info or Util.FastInfo, props)
	tween:Play()
	return tween
end

--==============================================================
-- tables
--==============================================================

function Util.Find(list, value)
	for index, item in list do
		if item == value then
			return index
		end
	end
	return nil
end

function Util.Count(dict)
	local count = 0
	for _ in dict do
		count += 1
	end
	return count
end

--- typeof, not type: Roblox datatypes (Color3, UDim2, ...) must be returned by
--- reference, never walked as plain tables.
function Util.DeepCopy(value)
	if typeof(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value do
		copy[key] = Util.DeepCopy(item)
	end
	return copy
end

function Util.SortedKeys(dict)
	local keys = {}
	for key in dict do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return keys
end

--==============================================================
-- filesystem
--==============================================================

local FS = {}
Util.FS = FS

--- Every call is pcall'd and returns a sensible default, so a menu running
--- outside an executor degrades to "configs just don't persist".
local function fsCall(name, default, ...)
	local fn = Util.Global(name)
	if type(fn) ~= "function" then
		return default
	end
	local ok, result = pcall(fn, ...)
	if not ok then
		return default
	end
	if result == nil then
		return default
	end
	return result
end

function FS.Available()
	return type(Util.Global("writefile")) == "function"
		and type(Util.Global("readfile")) == "function"
		and type(Util.Global("isfolder")) == "function"
end

function FS.IsFolder(path)
	return fsCall("isfolder", false, path) == true
end

function FS.IsFile(path)
	return fsCall("isfile", false, path) == true
end

function FS.MakeFolder(path)
	if FS.IsFolder(path) then
		return true
	end
	fsCall("makefolder", nil, path)
	return FS.IsFolder(path)
end

--- Creates every segment of `a/b/c`, not just the leaf.
function FS.EnsureFolder(path)
	local built = nil
	for segment in tostring(path):gmatch("[^/\\]+") do
		built = built and (built .. "/" .. segment) or segment
		FS.MakeFolder(built)
	end
	return built ~= nil and FS.IsFolder(path)
end

function FS.Read(path)
	if not FS.IsFile(path) then
		return nil
	end
	local contents = fsCall("readfile", nil, path)
	return type(contents) == "string" and contents or nil
end

function FS.Write(path, contents)
	local fn = Util.Global("writefile")
	if type(fn) ~= "function" then
		return false
	end
	return (pcall(fn, path, contents))
end

function FS.Delete(path)
	if not FS.IsFile(path) then
		return false
	end
	local fn = Util.Global("delfile")
	if type(fn) ~= "function" then
		return false
	end
	return (pcall(fn, path))
end

function FS.List(path)
	if not FS.IsFolder(path) then
		return {}
	end
	local entries = fsCall("listfiles", {}, path)
	return type(entries) == "table" and entries or {}
end

--- Strips directory and extension: "cfgs/main.json" -> "main"
function FS.Stem(path, extension)
	local name = tostring(path):match("[^/\\]+$") or tostring(path)
	if extension then
		name = name:gsub("%" .. extension .. "$", "")
	end
	return name
end

function FS.ReadJSON(path)
	local contents = FS.Read(path)
	if not contents then
		return nil
	end
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(contents)
	end)
	if ok and type(decoded) == "table" then
		return decoded
	end
	return nil
end

function FS.WriteJSON(path, data)
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(data)
	end)
	if not ok then
		return false
	end
	return FS.Write(path, encoded)
end

function Util.SetClipboard(text)
	local fn = Util.Global("setclipboard") or Util.Global("toclipboard")
	if type(fn) ~= "function" then
		return false
	end
	return (pcall(fn, text))
end

return Util
