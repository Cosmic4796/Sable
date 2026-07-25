--!nocheck
-- Sable :: headless Roblox API mock
--
-- Enough of the Roblox surface to CONSTRUCT and DRIVE the library outside
-- Roblox, so `luau` can execute the real code paths. It is deliberately not
-- pixel-accurate -- the point is to catch nil indexes, load-order faults,
-- re-entrancy and logic errors that a typechecker cannot see.
--
-- Quirks are reproduced on purpose where they cause real bugs, notably
-- HttpService:JSONEncode({}) returning "[]" rather than "{}".

--==============================================================
-- signals
--==============================================================

local MockSignal = {}
MockSignal.__index = MockSignal

local function newSignal()
	return setmetatable({ _handlers = {} }, MockSignal)
end

function MockSignal:Connect(fn)
	local signal = self
	local conn
	conn = {
		Connected = true,
		Disconnect = function(self2)
			local target = self2 or conn
			target.Connected = false
			for i = #signal._handlers, 1, -1 do
				if signal._handlers[i] == target then
					table.remove(signal._handlers, i)
				end
			end
		end,
		_fn = fn,
	}
	conn.disconnect = conn.Disconnect
	conn.Destroy = conn.Disconnect
	table.insert(signal._handlers, conn)
	return conn
end

MockSignal.connect = MockSignal.Connect
function MockSignal:Once(fn)
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		fn(...)
	end)
	return conn
end
function MockSignal:Wait() end
function MockSignal:Fire(...)
	for _, conn in table.clone(self._handlers) do
		if conn.Connected then
			conn._fn(...)
		end
	end
end

__newSignal = newSignal

--==============================================================
-- datatypes
--==============================================================

local Vector2MT = {}
Vector2MT.__index = Vector2MT
Vector2MT.__add = function(a, b)
	return Vector2.new(a.X + b.X, a.Y + b.Y)
end
Vector2MT.__sub = function(a, b)
	return Vector2.new(a.X - b.X, a.Y - b.Y)
end
Vector2MT.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y
end
Vector2MT.__tostring = function(v)
	return ("Vector2(%s, %s)"):format(tostring(v.X), tostring(v.Y))
end

Vector2 = {}
function Vector2.new(x, y)
	return setmetatable({ X = x or 0, Y = y or 0, __t = "Vector2" }, Vector2MT)
end
Vector2.zero = Vector2.new(0, 0)
Vector2.one = Vector2.new(1, 1)

local Color3MT = {}
Color3MT.__index = Color3MT
Color3MT.__eq = function(a, b)
	return a.R == b.R and a.G == b.G and a.B == b.B
end
Color3MT.__tostring = function(c)
	return ("Color3(%.3f, %.3f, %.3f)"):format(c.R, c.G, c.B)
end

function Color3MT:ToHSV()
	local r, g, b = self.R, self.G, self.B
	local max, min = math.max(r, g, b), math.min(r, g, b)
	local delta = max - min
	local h = 0
	if delta > 0 then
		if max == r then
			h = ((g - b) / delta) % 6
		elseif max == g then
			h = ((b - r) / delta) + 2
		else
			h = ((r - g) / delta) + 4
		end
		h /= 6
	end
	local s = max == 0 and 0 or delta / max
	return h, s, max
end

function Color3MT:Lerp(other, alpha)
	return Color3.new(
		self.R + (other.R - self.R) * alpha,
		self.G + (other.G - self.G) * alpha,
		self.B + (other.B - self.B) * alpha
	)
end

Color3 = {}
function Color3.new(r, g, b)
	return setmetatable({ R = r or 0, G = g or 0, B = b or 0, __t = "Color3" }, Color3MT)
end
function Color3.fromRGB(r, g, b)
	return Color3.new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
end
function Color3.fromHSV(h, s, v)
	local i = math.floor(h * 6)
	local f = h * 6 - i
	local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
	local m = i % 6
	if m == 0 then
		return Color3.new(v, t, p)
	elseif m == 1 then
		return Color3.new(q, v, p)
	elseif m == 2 then
		return Color3.new(p, v, t)
	elseif m == 3 then
		return Color3.new(p, q, v)
	elseif m == 4 then
		return Color3.new(t, p, v)
	end
	return Color3.new(v, p, q)
end

local UDimMT = { __index = {} }
UDim = {}
function UDim.new(scale, offset)
	return setmetatable({ Scale = scale or 0, Offset = offset or 0, __t = "UDim" }, UDimMT)
end

local UDim2MT = { __index = {} }
UDim2 = {}
function UDim2.new(xs, xo, ys, yo)
	return setmetatable({ X = UDim.new(xs, xo), Y = UDim.new(ys, yo), __t = "UDim2" }, UDim2MT)
end
function UDim2.fromOffset(x, y)
	return UDim2.new(0, x, 0, y)
end
function UDim2.fromScale(x, y)
	return UDim2.new(x, 0, y, 0)
end

TweenInfo = {}
function TweenInfo.new(time, style, direction, ...)
	return { Time = time or 1, EasingStyle = style, EasingDirection = direction, __t = "TweenInfo" }
end

Rect = {}
function Rect.new(a, b, c, d)
	return { Min = Vector2.new(a, b), Max = Vector2.new(c, d), __t = "Rect" }
end

ColorSequenceKeypoint = {}
function ColorSequenceKeypoint.new(t, c)
	return { Time = t, Value = c, __t = "ColorSequenceKeypoint" }
end
ColorSequence = {}
function ColorSequence.new(a, b)
	return { Keypoints = type(a) == "table" and a or { a, b }, __t = "ColorSequence" }
end
NumberSequenceKeypoint = {}
function NumberSequenceKeypoint.new(t, v)
	return { Time = t, Value = v, __t = "NumberSequenceKeypoint" }
end
NumberSequence = {}
function NumberSequence.new(a, b)
	return { Keypoints = type(a) == "table" and a or { a, b }, __t = "NumberSequence" }
end
NumberRange = {}
function NumberRange.new(a, b)
	return { Min = a, Max = b or a, __t = "NumberRange" }
end
Font = {}
function Font.fromEnum(e)
	return { __t = "Font", Enum = e }
end

--==============================================================
-- Enum (identity-stable, so enum items work as table keys)
--==============================================================

-- Members that really exist. A typo'd member must THROW, exactly as Roblox
-- does, instead of being fabricated -- silently inventing Enum.KeyCode.INSERT
-- is what let a permanently dead default menu hotkey pass the smoke test.
local STRICT_ENUMS = {
	KeyCode = { A = true, Ampersand = true, Asterisk = true, At = true, B = true, BackSlash = true, Backquote = true, Backspace = true, Break = true, ButtonA = true, ButtonB = true, ButtonBack = true, ButtonCenter = true, ButtonDown = true, ButtonL1 = true, ButtonL2 = true, ButtonL3 = true, ButtonLeft = true, ButtonR1 = true, ButtonR2 = true, ButtonR3 = true, ButtonRight = true, ButtonSelect = true, ButtonStart = true, ButtonUp = true, ButtonX = true, ButtonY = true, C = true, CapsLock = true, Caret = true, Clear = true, Colon = true, Comma = true, Compose = true, D = true, DPadDown = true, DPadLeft = true, DPadRight = true, DPadUp = true, Delete = true, Dollar = true, Down = true, E = true, Eight = true, End = true, Equals = true, Escape = true, Euro = true, F = true, F1 = true, F10 = true, F11 = true, F12 = true, F13 = true, F14 = true, F15 = true, F2 = true, F3 = true, F4 = true, F5 = true, F6 = true, F7 = true, F8 = true, F9 = true, Five = true, Four = true, G = true, GreaterThan = true, H = true, Hash = true, Help = true, Home = true, I = true, Insert = true, J = true, K = true, KeypadDivide = true, KeypadEight = true, KeypadEnter = true, KeypadEquals = true, KeypadFive = true, KeypadFour = true, KeypadMinus = true, KeypadMultiply = true, KeypadNine = true, KeypadOne = true, KeypadPeriod = true, KeypadPlus = true, KeypadSeven = true, KeypadSix = true, KeypadThree = true, KeypadTwo = true, KeypadZero = true, L = true, Left = true, LeftAlt = true, LeftBracket = true, LeftControl = true, LeftCurly = true, LeftMeta = true, LeftParenthesis = true, LeftShift = true, LeftSuper = true, LessThan = true, M = true, Menu = true, Minus = true, Mode = true, MouseBackButton = true, MouseDelta = true, MouseLeftButton = true, MouseMiddleButton = true, MouseNoButton = true, MousePosition = true, MouseRightButton = true, MouseWheel = true, MouseX = true, MouseY = true, N = true, Nine = true, None = true, NumLock = true, O = true, One = true, P = true, PageDown = true, PageUp = true, Pause = true, Percent = true, Period = true, Pipe = true, Plus = true, Power = true, Print = true, Q = true, Question = true, Quote = true, QuotedDouble = true, R = true, Return = true, Right = true, RightAlt = true, RightBracket = true, RightControl = true, RightCurly = true, RightMeta = true, RightParenthesis = true, RightShift = true, RightSuper = true, S = true, ScrollLock = true, Semicolon = true, Seven = true, Six = true, Slash = true, Space = true, SysReq = true, T = true, Tab = true, Three = true, Thumbstick1 = true, Thumbstick1Down = true, Thumbstick1Left = true, Thumbstick1Right = true, Thumbstick1Up = true, Thumbstick2 = true, Thumbstick2Down = true, Thumbstick2Left = true, Thumbstick2Right = true, Thumbstick2Up = true, Tilde = true, TouchDelta = true, TouchPinch = true, TouchPosition = true, TrackpadPan = true, TrackpadPinch = true, Two = true, U = true, Underscore = true, Undo = true, Unknown = true, Up = true, V = true, W = true, World0 = true, World1 = true, World10 = true, World11 = true, World12 = true, World13 = true, World14 = true, World15 = true, World16 = true, World17 = true, World18 = true, World19 = true, World2 = true, World20 = true, World21 = true, World22 = true, World23 = true, World24 = true, World25 = true, World26 = true, World27 = true, World28 = true, World29 = true, World3 = true, World30 = true, World31 = true, World32 = true, World33 = true, World34 = true, World35 = true, World36 = true, World37 = true, World38 = true, World39 = true, World4 = true, World40 = true, World41 = true, World42 = true, World43 = true, World44 = true, World45 = true, World46 = true, World47 = true, World48 = true, World49 = true, World5 = true, World50 = true, World51 = true, World52 = true, World53 = true, World54 = true, World55 = true, World56 = true, World57 = true, World58 = true, World59 = true, World6 = true, World60 = true, World61 = true, World62 = true, World63 = true, World64 = true, World65 = true, World66 = true, World67 = true, World68 = true, World69 = true, World7 = true, World70 = true, World71 = true, World72 = true, World73 = true, World74 = true, World75 = true, World76 = true, World77 = true, World78 = true, World79 = true, World8 = true, World80 = true, World81 = true, World82 = true, World83 = true, World84 = true, World85 = true, World86 = true, World87 = true, World88 = true, World89 = true, World9 = true, World90 = true, World91 = true, World92 = true, World93 = true, World94 = true, World95 = true, X = true, Y = true, Z = true, Zero = true },
	UserInputType = { Accelerometer = true, Focus = true, Gamepad1 = true, Gamepad2 = true, Gamepad3 = true, Gamepad4 = true, Gamepad5 = true, Gamepad6 = true, Gamepad7 = true, Gamepad8 = true, Gyro = true, InputMethod = true, Keyboard = true, MouseButton1 = true, MouseButton2 = true, MouseButton3 = true, MouseMovement = true, MouseWheel = true, None = true, TextInput = true, Touch = true, Unknown = true },
}

local enumCache = {}
Enum = setmetatable({}, {
	__index = function(_, enumName)
		local existing = enumCache[enumName]
		if existing then
			return existing
		end

		local strict = STRICT_ENUMS[enumName]
		local items = {}

		local enumObject
		enumObject = setmetatable({
			-- Returns nil for an unknown name rather than throwing, like Roblox.
			FromName = function(_, itemName)
				if strict and not strict[itemName] then
					return nil
				end
				return rawget(enumObject, itemName) or enumObject[itemName]
			end,
		}, {
			__index = function(_, itemName)
				if strict and not strict[itemName] then
					error(("%s is not a valid member of Enum.%s"):format(tostring(itemName), enumName), 2)
				end
				local item = items[itemName]
				if not item then
					item = {
						Name = itemName,
						Value = 0,
						EnumType = enumName,
						__t = "EnumItem",
					}
					items[itemName] = item
				end
				return item
			end,
		})

		enumCache[enumName] = enumObject
		return enumObject
	end,
})

--==============================================================
-- Instance
--==============================================================

local EVENTS = {
	"MouseEnter", "MouseLeave", "MouseMoved", "MouseButton1Click", "MouseButton1Down",
	"MouseButton1Up", "MouseButton2Click", "MouseButton2Down", "InputBegan", "InputEnded",
	"InputChanged", "Activated", "FocusLost", "Focused", "ChildAdded", "ChildRemoved",
	"AncestryChanged", "Destroying", "Changed", "Touched", "SelectionGained",
}

-- Roblox property defaults. These matter: code legitimately reads a property it
-- never wrote (ZIndex defaults to 1, so `frame.ZIndex < 6` is valid Roblox), and
-- returning nil here produces mock-only failures that look like real bugs.
local function constant(value)
	return function()
		return value
	end
end

local DEFAULTS = {
	AbsoluteSize = constant(Vector2.new(300, 20)),
	AbsolutePosition = constant(Vector2.new(0, 0)),
	AbsoluteContentSize = constant(Vector2.new(0, 0)),
	CanvasPosition = constant(Vector2.new(0, 0)),
	Visible = constant(true),
	Text = constant(""),
	PlaceholderText = constant(""),
	Name = constant("Instance"),
	ClassName = constant("Instance"),
	ZIndex = constant(1),
	LayoutOrder = constant(0),
	BorderSizePixel = constant(1),
	BackgroundTransparency = constant(0),
	TextTransparency = constant(0),
	ImageTransparency = constant(0),
	GroupTransparency = constant(0),
	Transparency = constant(0),
	Thickness = constant(1),
	Rotation = constant(0),
	TextSize = constant(14),
	ScrollBarThickness = constant(12),
	ClipsDescendants = constant(false),
	Active = constant(false),
	Interactable = constant(true),
	AutoButtonColor = constant(true),
	TextWrapped = constant(false),
	Size = function()
		return UDim2.new(0, 0, 0, 0)
	end,
	Position = function()
		return UDim2.new(0, 0, 0, 0)
	end,
	AnchorPoint = constant(Vector2.new(0, 0)),
	Padding = function()
		return UDim.new(0, 0)
	end,
}

local InstanceMT = {}

local function newInstance(className)
	local self = {}
	local props = {
		ClassName = className,
		Name = className,
		Parent = nil,
	}
	local children = {}
	local attributes = {}
	local events = {}
	local propSignals = {}

	local api = {}

	function api:GetChildren()
		return table.clone(children)
	end

	function api:GetDescendants()
		local out = {}
		for _, child in children do
			table.insert(out, child)
			for _, sub in child:GetDescendants() do
				table.insert(out, sub)
			end
		end
		return out
	end

	function api:FindFirstChild(name)
		for _, child in children do
			if child.Name == name then
				return child
			end
		end
		return nil
	end

	function api:FindFirstChildOfClass(class)
		for _, child in children do
			if child.ClassName == class then
				return child
			end
		end
		return nil
	end

	function api:WaitForChild(name)
		return api:FindFirstChild(name)
	end

	function api:IsA(class)
		return props.ClassName == class
	end

	function api:IsDescendantOf(other)
		local parent = props.Parent
		while parent do
			if parent == other then
				return true
			end
			parent = parent.Parent
		end
		return false
	end

	function api:SetAttribute(key, value)
		attributes[key] = value
	end

	function api:GetAttribute(key)
		return attributes[key]
	end

	function api:GetPropertyChangedSignal(prop)
		local signal = propSignals[prop]
		if not signal then
			signal = newSignal()
			propSignals[prop] = signal
		end
		return signal
	end

	function api:Destroy()
		local parent = props.Parent
		if parent then
			parent.__removeChild(self)
		end
		props.Parent = nil
		props.__destroyed = true
		for _, child in table.clone(children) do
			child:Destroy()
		end
	end

	function api:ClearAllChildren()
		for _, child in table.clone(children) do
			child:Destroy()
		end
	end

	function api:Clone()
		return newInstance(props.ClassName)
	end

	-- TextBox surface. Headless, nothing is ever focused.
	function api:IsFocused()
		return props.__focused == true
	end
	function api:CaptureFocus()
		props.__focused = true
	end
	function api:ReleaseFocus()
		props.__focused = false
	end

	-- internal
	local internals = {
		__addChild = function(child)
			table.insert(children, child)
		end,
		__removeChild = function(child)
			for i = #children, 1, -1 do
				if children[i] == child then
					table.remove(children, i)
				end
			end
		end,
		__children = children,
	}

	-- Declared before it is assigned ON PURPOSE: the metamethods below close over
	-- `proxy`, and in `local proxy = setmetatable(...)` the local is not in scope
	-- until after the statement, so the closures would capture a nil GLOBAL. That
	-- silently handed __addChild(nil) to every parent, leaving GetChildren() /
	-- FindFirstChild() / GetDescendants() permanently empty -- a mock that
	-- answers "no children" to everything cannot catch a parenting mistake.
	local proxy
	proxy = setmetatable({}, {
		__index = function(_, key)
			if api[key] then
				return api[key]
			end
			if internals[key] then
				return internals[key]
			end
			if props[key] ~= nil then
				return props[key]
			end
			for _, name in EVENTS do
				if name == key then
					local signal = events[key]
					if not signal then
						signal = newSignal()
						events[key] = signal
					end
					return signal
				end
			end
			local default = DEFAULTS[key]
			if default then
				return default()
			end
			return nil
		end,
		__newindex = function(_, key, value)
			-- Roblox throws on an invalid property name. Reproducing that is
			-- the whole point: `ScrollBarImage = ""` shipped and crashed in a
			-- real executor because this mock used to accept any write, and
			-- Util.Create assigns by dynamic key so the typechecker is blind
			-- to it. MOCK_API is generated by tools/gen_mock_api.py; classes
			-- absent from it stay permissive.
			local allowed = MOCK_API and MOCK_API[props.ClassName]
			if allowed and not allowed[key] and key:sub(1, 2) ~= "__" then
				error(
					('%s is not a valid member of %s "%s"'):format(
						tostring(key),
						tostring(props.ClassName),
						tostring(props.Name)
					),
					2
				)
			end

			if key == "Parent" then
				local old = props.Parent
				if old then
					old.__removeChild(proxy)
				end
				props.Parent = value
				if value then
					value.__addChild(proxy)
				end
			else
				props[key] = value
			end
			local signal = propSignals[key]
			if signal then
				signal:Fire()
			end
		end,
		__tostring = function()
			return ("%s(%s)"):format(props.ClassName, tostring(props.Name))
		end,
		__t = "Instance",
	})

	self = proxy
	return proxy
end

Instance = {}
function Instance.new(className, parent)
	local inst = newInstance(className)
	if parent then
		inst.Parent = parent
	end
	return inst
end

--==============================================================
-- typeof
--==============================================================

local rawType = type
function typeof(value)
	if rawType(value) ~= "table" then
		return rawType(value)
	end
	local ok, marker = pcall(function()
		return rawget(value, "__t")
	end)
	if ok and marker then
		return marker
	end
	local mt = getmetatable(value)
	if mt and mt.__t then
		return mt.__t
	end
	-- No structural guessing. Roblox's typeof({R=1,G=1,B=1}) is "table", and
	-- pretending otherwise invents failures that cannot happen for real.
	return "table"
end

--==============================================================
-- JSON (faithful to HttpService, including the empty-table quirk)
--==============================================================

local function jsonEncode(value)
	local t = rawType(value)
	if value == nil then
		return "null"
	elseif t == "boolean" then
		return tostring(value)
	elseif t == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			error("cannot serialise non-finite number")
		end
		if value == math.floor(value) and math.abs(value) < 1e15 then
			return tostring(math.floor(value))
		end
		return tostring(value)
	elseif t == "string" then
		local out = value:gsub('[%c"\\]', function(c)
			if c == '"' then
				return '\\"'
			elseif c == "\\" then
				return "\\\\"
			elseif c == "\n" then
				return "\\n"
			elseif c == "\r" then
				return "\\r"
			elseif c == "\t" then
				return "\\t"
			end
			return ("\\u%04x"):format(c:byte())
		end)
		return '"' .. out .. '"'
	elseif t == "table" then
		local count, isArray = 0, true
		for key in value do
			count += 1
			if rawType(key) ~= "number" then
				isArray = false
			end
		end
		-- HttpService encodes an EMPTY table as "[]", not "{}". Reproduced
		-- deliberately: it is exactly how an empty multi-select set gets
		-- corrupted on a config round-trip.
		if count == 0 then
			return "[]"
		end
		if isArray and count == #value then
			local parts = {}
			for _, item in value do
				table.insert(parts, jsonEncode(item))
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local parts = {}
		local keys = {}
		for key in value do
			table.insert(keys, tostring(key))
		end
		table.sort(keys)
		for _, key in keys do
			local raw = value[key]
			if raw == nil then
				for k, v in value do
					if tostring(k) == key then
						raw = v
					end
				end
			end
			table.insert(parts, jsonEncode(key) .. ":" .. jsonEncode(raw))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	error("cannot serialise " .. t)
end

local function jsonDecode(text)
	local pos = 1

	local function skip()
		while pos <= #text and text:sub(pos, pos):match("%s") do
			pos += 1
		end
	end

	local parseValue

	local function parseString()
		pos += 1
		local out = {}
		while pos <= #text do
			local c = text:sub(pos, pos)
			if c == '"' then
				pos += 1
				return table.concat(out)
			elseif c == "\\" then
				local n = text:sub(pos + 1, pos + 1)
				local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f" }
				if n == "u" then
					local hex = text:sub(pos + 2, pos + 5)
					table.insert(out, utf8.char(tonumber(hex, 16) or 63))
					pos += 6
				else
					table.insert(out, map[n] or n)
					pos += 2
				end
			else
				table.insert(out, c)
				pos += 1
			end
		end
		error("unterminated string")
	end

	function parseValue()
		skip()
		local c = text:sub(pos, pos)
		if c == "{" then
			pos += 1
			local obj = {}
			skip()
			if text:sub(pos, pos) == "}" then
				pos += 1
				return obj
			end
			while true do
				skip()
				local key = parseString()
				skip()
				pos += 1 -- ':'
				obj[key] = parseValue()
				skip()
				local d = text:sub(pos, pos)
				pos += 1
				if d == "}" then
					return obj
				end
			end
		elseif c == "[" then
			pos += 1
			local arr = {}
			skip()
			if text:sub(pos, pos) == "]" then
				pos += 1
				return arr
			end
			while true do
				table.insert(arr, parseValue())
				skip()
				local d = text:sub(pos, pos)
				pos += 1
				if d == "]" then
					return arr
				end
			end
		elseif c == '"' then
			return parseString()
		elseif text:sub(pos, pos + 3) == "true" then
			pos += 4
			return true
		elseif text:sub(pos, pos + 4) == "false" then
			pos += 5
			return false
		elseif text:sub(pos, pos + 3) == "null" then
			pos += 4
			return nil
		else
			local numText = text:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
			pos += #numText
			return tonumber(numText)
		end
	end

	return parseValue()
end

__jsonEncode = jsonEncode
__jsonDecode = jsonDecode

--==============================================================
-- services
--==============================================================

local deferred = {}
local delayed = {}

task = {
	wait = function(t)
		return t or 0
	end,
	spawn = function(fn, ...)
		fn(...)
	end,
	defer = function(fn, ...)
		table.insert(deferred, { fn = fn, args = table.pack(...) })
	end,
	delay = function(_, fn, ...)
		table.insert(delayed, { fn = fn, args = table.pack(...) })
	end,
	cancel = function() end,
}

--- Runs everything task.defer queued. Called by the smoke test between steps.
function __drainDeferred(limit)
	local rounds = 0
	while #deferred > 0 and rounds < (limit or 20) do
		local batch = deferred
		deferred = {}
		for _, entry in batch do
			entry.fn(table.unpack(entry.args, 1, entry.args.n))
		end
		rounds += 1
	end
end

function __drainDelayed()
	local batch = delayed
	delayed = {}
	for _, entry in batch do
		entry.fn(table.unpack(entry.args, 1, entry.args.n))
	end
end

local userInput = {
	InputBegan = newSignal(),
	InputEnded = newSignal(),
	InputChanged = newSignal(),
	TextBoxFocused = newSignal(),
	TextBoxFocusReleased = newSignal(),
	GetMouseLocation = function()
		return Vector2.new(400, 300)
	end,
	IsKeyDown = function()
		return false
	end,
	IsMouseButtonPressed = function()
		return false
	end,
	GetFocusedTextBox = function()
		return nil
	end,
	MouseBehavior = nil,
	MouseIconEnabled = true,
}

local runService = {
	RenderStepped = newSignal(),
	Heartbeat = newSignal(),
	Stepped = newSignal(),
	IsStudio = function()
		return false
	end,
}

__UserInputService = userInput
__RunService = runService

local coreGui = newInstance("CoreGui")
coreGui.Name = "CoreGui"

local playerGui = newInstance("PlayerGui")
playerGui.Name = "PlayerGui"
local localPlayer = newInstance("Player")
localPlayer.Name = "LocalPlayer"
playerGui.Parent = localPlayer

local services = {
	TweenService = {
		Create = function(_, instance, info, props)
			return {
				Play = function()
					-- Apply instantly so final state is observable.
					for key, value in props do
						instance[key] = value
					end
				end,
				Cancel = function() end,
				Completed = newSignal(),
			}
		end,
	},
	TextService = {
		GetTextSize = function(_, text, size, _, _)
			return Vector2.new(#tostring(text) * size * 0.6, size)
		end,
	},
	UserInputService = userInput,
	RunService = runService,
	CoreGui = coreGui,
	GuiService = {
		GetGuiInset = function()
			return Vector2.new(0, 36), Vector2.new(0, 0)
		end,
	},
	Players = {
		LocalPlayer = localPlayer,
		GetPlayers = function()
			return {}
		end,
	},
	HttpService = {
		JSONEncode = function(_, value)
			return jsonEncode(value)
		end,
		JSONDecode = function(_, text)
			return jsonDecode(text)
		end,
		GenerateGUID = function()
			return "00000000-0000-0000-0000-000000000000"
		end,
	},
	Lighting = newInstance("Lighting"),
	Workspace = newInstance("Workspace"),
	Debris = { AddItem = function() end },
	StarterGui = newInstance("StarterGui"),
	ReplicatedStorage = newInstance("ReplicatedStorage"),
}

game = setmetatable({
	GetService = function(_, name)
		local service = services[name]
		if not service then
			service = newInstance(name)
			services[name] = service
		end
		return service
	end,
	PlaceId = 0,
	GameId = 0,
	JobId = "",
}, {
	__index = function(_, key)
		return services[key]
	end,
})

workspace = services.Workspace

--==============================================================
-- executor globals (in-memory filesystem)
--==============================================================

local files = {}
local folders = { [""] = true }

local function normalise(path)
	return (tostring(path):gsub("\\", "/"):gsub("^%./", ""))
end

__files = files
__folders = folders

local env = {}
getgenv = function()
	return env
end

writefile = function(path, contents)
	files[normalise(path)] = tostring(contents)
end
readfile = function(path)
	local data = files[normalise(path)]
	if data == nil then
		error("file not found: " .. tostring(path))
	end
	return data
end
isfile = function(path)
	return files[normalise(path)] ~= nil
end
isfolder = function(path)
	return folders[normalise(path)] == true
end
makefolder = function(path)
	folders[normalise(path)] = true
end
delfile = function(path)
	files[normalise(path)] = nil
end
delfolder = function(path)
	folders[normalise(path)] = nil
end
listfiles = function(path)
	local prefix = normalise(path)
	if prefix ~= "" then
		prefix ..= "/"
	end
	local out = {}
	for name in files do
		if name:sub(1, #prefix) == prefix and not name:sub(#prefix + 1):find("/") then
			table.insert(out, name)
		end
	end
	table.sort(out)
	return out
end
identifyexecutor = function()
	return "SableMock"
end
setclipboard = function() end
gethui = function()
	return coreGui
end

-- Faithful to real executors: getgenv()'s table also exposes the executor
-- globals, so code that looks them up either way finds them.
for name, fn in {
	writefile = writefile,
	readfile = readfile,
	isfile = isfile,
	isfolder = isfolder,
	makefolder = makefolder,
	delfile = delfile,
	delfolder = delfolder,
	listfiles = listfiles,
	identifyexecutor = identifyexecutor,
	setclipboard = setclipboard,
	gethui = gethui,
} do
	env[name] = fn
end

local realWarn = warn
warn = function(...)
	realWarn("[warn]", ...)
end
