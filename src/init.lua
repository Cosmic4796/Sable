--!nonstrict
-- Sable :: root
--
-- Owns the ScreenGui, the shared input signals, the popup layer, unload
-- bookkeeping, and every drawing primitive the rest of the library builds on.
-- Nothing below this file may require() it -- containers and elements receive
-- `Library` as an argument instead, which keeps the dependency graph acyclic.

local Util = require("Util")
local Signal = require("Signal")
local Theme = require("Theme")

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

-- Declared here rather than only inside Theme.Install so the shape of Library
-- is visible at a glance, and so static analysis of the bundle stays clean.
local Library = {
	Scheme = {} :: any,
	Sizes = {} :: any,
	Fonts = {} :: any,
	Motion = {} :: any,
}

Library.Name = "Sable"
Library.Version = "1.1.0"
Library.Util = Util
Library.Signal = Signal

-- Element stores, keyed by the index string passed to AddToggle/AddSlider/...
Library.Toggles = {}
Library.Options = {}

Library.Windows = {}
Library.Registry = {}
Library.Signals = {}
Library.UnloadCallbacks = {}

Library.Toggled = false
Library.Unloaded = false

--- Element label casing. Users write "Team check", Sable renders "TEAM CHECK".
Library.UppercaseLabels = true

-- Canonical spelling, matching what Util.InputName reports for a real key
-- press. Util.CanonicalName folds "INSERT"/"Insert" onto this too, but storing
-- the canonical form keeps the keybind pill and a re-capture consistent.
Library.MenuKeybind = "INS"
--- Set by KeyPicker while it waits for a bind so the menu hotkey (and any
--- other bind) does not fire on the very keystroke being captured.
Library.CapturingInput = false

Library.NotifySide = "Right"

Theme.Install(Library)
Library.MenuFadeTime = Library.Motion.Fade

Library.MenuToggled = Signal.new("MenuToggled")
Library.InputBegan = Signal.new("InputBegan")
Library.InputEnded = Signal.new("InputEnded")
Library.InputChanged = Signal.new("InputChanged")
Library.RenderStepped = Signal.new("RenderStepped")

--==============================================================
-- lifecycle
--==============================================================

--- Hands a connection to the library so Unload() can tear it down. Every
--- connection Sable makes must go through here.
function Library:GiveSignal(connection)
	table.insert(self.Signals, connection)
	return connection
end

function Library:OnUnload(callback)
	table.insert(self.UnloadCallbacks, callback)
	return callback
end

--- Runs a user callback without letting an error in it break the menu.
function Library:SafeCallback(fn, ...)
	if type(fn) ~= "function" then
		return
	end

	local packed = table.pack(...)
	local ok, err = pcall(function()
		return fn(table.unpack(packed, 1, packed.n))
	end)

	if not ok then
		warn(("[Sable] callback error: %s"):format(tostring(err)))
		if self.Notify and not self.Unloaded then
			self:Notify({
				Title = "Callback error",
				Description = tostring(err),
				Time = 7,
				Risk = true,
			})
		end
	end
end

function Library:Unload()
	if self.Unloaded then
		return
	end
	self.Unloaded = true

	self:ClosePopup()

	for _, callback in self.UnloadCallbacks do
		pcall(callback)
	end

	for _, connection in self.Signals do
		pcall(function()
			connection:Disconnect()
		end)
	end
	table.clear(self.Signals)

	if self.ScreenGui then
		pcall(function()
			self.ScreenGui:Destroy()
		end)
	end

	table.clear(self.Toggles)
	table.clear(self.Options)
	table.clear(self.Registry)
	table.clear(self.Windows)

	if getgenv then
		local env = getgenv()
		if env.Sable == self then
			env.Sable = nil
		end
	end
end

--==============================================================
-- screen gui
--==============================================================

local function randomName(length)
	local alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
	local out = table.create(length)
	for _ = 1, length do
		local index = math.random(1, #alphabet)
		table.insert(out, alphabet:sub(index, index))
	end
	return table.concat(out)
end

local screenGui = Util.Create("ScreenGui", {
	Name = randomName(12),
	DisplayOrder = 9999,
	-- True so the gui spans the WHOLE screen, top bar included, and the menu
	-- and the HUD can be parked anywhere on it.
	--
	-- It does NOT put the cursor and AbsolutePosition into one space, and never
	-- did: AbsolutePosition is measured from under the top bar whatever this
	-- says, while UserInputService:GetMouseLocation() is measured from the true
	-- top-left. Every hit test converts through Util.MouseInGuiSpace() in both
	-- modes; raw Util.MousePosition() is for drag deltas only. What this
	-- property does move is a holder's local (0, 0), which is why chrome that
	-- wants to clear the top bar offsets itself by Util.GuiInsetOffset().
	IgnoreGuiInset = true,
	ResetOnSpawn = false,
	AutoLocalize = false,
	ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})

Util.ProtectGui(screenGui)
screenGui.Parent = Util.GetGuiParent()
Library.ScreenGui = screenGui

-- One source of truth for where a holder's local origin sits, read back off the
-- instance rather than assumed: flip the property above and default HUD
-- placement follows it instead of quietly disagreeing with it.
Util.GuiInsetIgnored = screenGui.IgnoreGuiInset == true

--- Full-bleed transparent layer. ZIndex on the holder decides what stacks
--- above what, because ZIndexBehavior is Sibling.
local function makeHolder(name, zIndex)
	return Util.Create("Frame", {
		Name = name,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = zIndex,
		Parent = screenGui,
	})
end

Library.WindowHolder = makeHolder("Windows", 1)
Library.HudHolder = makeHolder("Hud", 20)
Library.PopupHolder = makeHolder("Popups", 100)
Library.NotificationHolder = makeHolder("Notifications", 200)
Library.TooltipHolder = makeHolder("Tooltips", 300)

--==============================================================
-- input plumbing
--==============================================================

Library:GiveSignal(UserInputService.InputBegan:Connect(function(input, gameProcessed)
	Library.InputBegan:Fire(input, gameProcessed)
end))

Library:GiveSignal(UserInputService.InputEnded:Connect(function(input, gameProcessed)
	Library.InputEnded:Fire(input, gameProcessed)
end))

Library:GiveSignal(UserInputService.InputChanged:Connect(function(input, gameProcessed)
	Library.InputChanged:Fire(input, gameProcessed)
end))

Library:GiveSignal(RunService.RenderStepped:Connect(function(delta)
	Library.RenderStepped:Fire(delta)
end))

--==============================================================
-- text
--==============================================================

--- Applies the library-wide label casing.
function Library:FormatLabel(text)
	text = tostring(text or "")
	if self.UppercaseLabels then
		return text:upper()
	end
	return text
end

--- Chrome text: cased + letterspaced. Window title, tab names, group headers
--- only -- never element labels, which would get unreadably wide.
function Library:Chrome(text)
	return Util.Letterspace(self:FormatLabel(text))
end

--==============================================================
-- drawing primitives
--==============================================================

--- Instance.new with two extra keys:
---   Theme = { PropertyName = "SchemeKey" }  auto-registers for live theming
---   Hud   = true                            marks it as always-visible chrome
function Library:Create(className, props)
	props = props or {}

	local themeMap = props.Theme
	local isHud = props.Hud
	props.Theme = nil
	props.Hud = nil

	local instance = Util.Create(className, props)

	if themeMap then
		self:AddToRegistry(instance, themeMap, isHud)
	end

	return instance
end

--- A filled, hairline-outlined rectangle. Returns frame, stroke.
--- Pass `false` for strokeKey to skip the outline entirely.
function Library:Panel(props, fillKey, strokeKey)
	props = props or {}
	props.BorderSizePixel = 0
	props.Theme = { BackgroundColor3 = fillKey or "Panel" }

	local frame = self:Create("Frame", props)

	if strokeKey == false then
		return frame, nil
	end

	local key = strokeKey or "Outline"
	local stroke = Util.Stroke(frame, self:GetColor(key), self.Sizes.Outline)
	self:AddToRegistry(stroke, { Color = key })

	return frame, stroke
end

function Library:Label(props, colorKey)
	props = props or {}
	props.BackgroundTransparency = props.BackgroundTransparency or 1
	props.BorderSizePixel = 0
	props.Font = props.Font or self.Fonts.Label
	props.TextSize = props.TextSize or self.Sizes.Text
	props.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	props.TextYAlignment = props.TextYAlignment or Enum.TextYAlignment.Center
	props.Theme = { TextColor3 = colorKey or "Font" }
	return self:Create("TextLabel", props)
end

--- Standard full-width element row, parented into a container's list layout.
function Library:Row(container, height)
	return self:Create("Frame", {
		Name = "Row",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, height or self.Sizes.RowHeight),
		LayoutOrder = #container.Elements + 1,
		Parent = container.Container,
	})
end

--- Invisible TextButton used purely for hit testing. Frames do not receive
--- input, so anything clickable needs one of these on top.
function Library:HitButton(parent, props)
	props = props or {}
	props.Name = props.Name or "Hit"
	props.Text = ""
	props.BackgroundTransparency = 1
	props.BorderSizePixel = 0
	props.AutoButtonColor = false
	props.Size = props.Size or UDim2.fromScale(1, 1)
	props.ZIndex = props.ZIndex or 5
	props.Parent = parent
	return self:Create("TextButton", props)
end

--- L-shaped corner marks. The signature detail of the tactical look -- used on
--- the window frame and popups, deliberately NOT on every groupbox.
function Library:CornerTicks(parent, colorKey, length, thickness)
	length = length or self.Sizes.Tick
	thickness = thickness or self.Sizes.TickThickness
	colorKey = colorKey or "Accent"

	local corners = {
		Vector2.new(0, 0),
		Vector2.new(1, 0),
		Vector2.new(0, 1),
		Vector2.new(1, 1),
	}

	local ticks = {}
	for index, corner in corners do
		local anchor = corner
		local position = UDim2.fromScale(corner.X, corner.Y)

		-- Both arms share the corner's anchor, so they grow inward for free.
		table.insert(
			ticks,
			self:Create("Frame", {
				Name = ("Tick%dH"):format(index),
				AnchorPoint = anchor,
				Position = position,
				Size = UDim2.fromOffset(length, thickness),
				BorderSizePixel = 0,
				ZIndex = 10,
				Theme = { BackgroundColor3 = colorKey },
				Parent = parent,
			})
		)

		table.insert(
			ticks,
			self:Create("Frame", {
				Name = ("Tick%dV"):format(index),
				AnchorPoint = anchor,
				Position = position,
				Size = UDim2.fromOffset(thickness, length),
				BorderSizePixel = 0,
				ZIndex = 10,
				Theme = { BackgroundColor3 = colorKey },
				Parent = parent,
			})
		)
	end

	return ticks
end

function Library:Tween(instance, props, info)
	return Util.Tween(instance, props, info or self.Motion.Fast)
end

--- Consistent hover feel for every interactive surface.
function Library:BindHover(button, target, normalKey, hoverKey)
	local function apply(key)
		if self.Unloaded then
			return
		end
		Util.Tween(target, { BackgroundColor3 = self:GetColor(key) }, self.Motion.Fast)
	end

	self:GiveSignal(button.MouseEnter:Connect(function()
		if button:GetAttribute("SableDisabled") then
			return
		end
		apply(hoverKey)
	end))

	self:GiveSignal(button.MouseLeave:Connect(function()
		apply(normalKey)
	end))
end

--==============================================================
-- dragging
--==============================================================

function Library:MakeDraggable(handle, target)
	local dragging = false
	local startMouse = Vector2.zero
	local startPos = Vector2.zero

	self:GiveSignal(handle.InputBegan:Connect(function(input)
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		dragging = true
		-- Raw cursor deliberately: only the DELTA below is ever used, and a
		-- constant gui inset cancels in a subtraction.
		startMouse = Util.MousePosition()
		-- Position is an offset inside the parent, so the grab point has to be
		-- parent-relative too. The holder's own AbsolutePosition is NOT zero
		-- while the gui ignores the inset -- it sits one inset ABOVE the origin
		-- AbsolutePosition is measured from, so its Y is negative -- and this
		-- subtraction is the whole reason a grab does not jump the window.
		local holder = target.Parent
		startPos = target.AbsolutePosition - (holder and holder.AbsolutePosition or Vector2.zero)
		self:ClosePopup()
	end))

	self:GiveSignal(self.InputChanged:Connect(function(input)
		if not dragging then
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end

		-- Pure delta: unaffected by the gui inset, so both readings stay raw.
		local delta = Util.MousePosition() - startMouse
		local viewport = self.ScreenGui.AbsoluteSize
		local size = target.AbsoluteSize

		-- Keep at least a sliver on screen so a window can never be lost.
		-- The gui ignores the inset, so y = 0 is now the true top of the screen
		-- and a window may sit over the top bar -- that is the point of it. The
		-- slivers still guarantee the title bar can be grabbed again.
		local x = Util.Clamp(startPos.X + delta.X, -size.X + 48, viewport.X - 48)
		local y = Util.Clamp(startPos.Y + delta.Y, 0, math.max(0, viewport.Y - 24))

		target.Position = UDim2.fromOffset(math.floor(x), math.floor(y))
	end))

	self:GiveSignal(self.InputEnded:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = false
		end
	end))
end

--==============================================================
-- popups (dropdown lists, colour pickers, bind capture)
--==============================================================

Library.ActivePopup = nil

function Library:ClosePopup(popup)
	local active = self.ActivePopup
	if not active then
		return
	end
	if popup and popup ~= active then
		return
	end

	self.ActivePopup = nil

	if active.Connection then
		active.Connection:Disconnect()
	end

	pcall(function()
		active.Frame.Visible = false
	end)

	if active.OnClose then
		self:SafeCallback(active.OnClose)
	end
end

--- Shows `frame` in the popup layer, positioned under `anchor` (flipping above
--- it when there is no room below). Only one popup is ever open.
---
--- options = { Height = number (required), Width = number?, Gap = number?,
---             OnClose = function? }
function Library:OpenPopup(frame, anchor, options)
	options = options or {}
	self:ClosePopup()

	local holder = self.PopupHolder
	frame.Parent = holder

	local gap = options.Gap or 2
	local width = options.Width or anchor.AbsoluteSize.X
	local height = options.Height or frame.AbsoluteSize.Y
	local viewport = holder.AbsoluteSize

	-- No cursor involved: one AbsolutePosition minus another is already the
	-- offset inside the holder, in whichever space both of them are measured.
	-- The gui inset cancels here, so there is nothing to convert.
	local origin = anchor.AbsolutePosition - holder.AbsolutePosition
	local x = origin.X
	local y = origin.Y + anchor.AbsoluteSize.Y + gap

	if y + height > viewport.Y - 4 then
		local above = origin.Y - height - gap
		if above >= 4 then
			y = above
		end
	end

	-- The holder spans the whole screen now, top bar included, so a popup from a
	-- window parked up there stays with its anchor instead of being shoved down.
	x = Util.Clamp(x, 4, math.max(4, viewport.X - width - 4))
	y = Util.Clamp(y, 4, math.max(4, viewport.Y - height - 4))

	frame.Position = UDim2.fromOffset(math.floor(x), math.floor(y))
	frame.Size = UDim2.fromOffset(math.floor(width), math.floor(height))
	frame.Visible = true

	local popup = {
		Frame = frame,
		Anchor = anchor,
		OnClose = options.OnClose,
	}
	self.ActivePopup = popup

	-- Deferred so the click that opened this popup cannot immediately close it.
	task.defer(function()
		if self.ActivePopup ~= popup then
			return
		end
		popup.Connection = self.InputBegan:Connect(function(input)
			if
				input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch
			then
				return
			end
			if Util.MouseOver(frame) or Util.MouseOver(anchor) then
				return
			end
			self:ClosePopup(popup)
		end)
	end)

	return popup
end

--==============================================================
-- tooltips
--==============================================================

local tooltipFrame = Library:Panel({
	Name = "Tooltip",
	Visible = false,
	AutomaticSize = Enum.AutomaticSize.XY,
	Size = UDim2.fromOffset(0, 0),
	ZIndex = 300,
	Parent = Library.TooltipHolder,
}, "PanelRaised", "Outline")

Util.Padding(tooltipFrame, 4, 6, 4, 6)

local tooltipLabel = Library:Label({
	Name = "Text",
	AutomaticSize = Enum.AutomaticSize.XY,
	Size = UDim2.fromOffset(0, 0),
	TextSize = Library.Sizes.TextSmall,
	ZIndex = 301,
	Parent = tooltipFrame,
}, "Font")

Library.TooltipFrame = tooltipFrame

--- Shows `text` while the cursor is over `guiObject`. When the object carries
--- the SableDisabled attribute, `disabledText` is shown instead (if given).
function Library:GiveTooltip(guiObject, text, disabledText)
	if not text and not disabledText then
		return
	end

	local state = { Text = text, DisabledText = disabledText }
	guiObject:SetAttribute("SableHasTooltip", true)

	local hovering = false
	local moveConnection = nil

	local function hide()
		hovering = false
		if moveConnection then
			moveConnection:Disconnect()
			moveConnection = nil
		end
		tooltipFrame.Visible = false
	end

	self:GiveSignal(guiObject.MouseEnter:Connect(function()
		local disabled = guiObject:GetAttribute("SableDisabled") == true
		local shown = disabled and (state.DisabledText or state.Text) or state.Text
		if not shown or shown == "" then
			return
		end

		hovering = true
		tooltipLabel.Text = shown
		tooltipFrame.Visible = true

		moveConnection = self.RenderStepped:Connect(function()
			if not hovering or self.Unloaded then
				return
			end
			if not guiObject.Parent or not Util.MouseOver(guiObject) then
				hide()
				return
			end

			-- An absolute placement, not a delta: take the cursor in
			-- AbsolutePosition space, then make it relative to the holder,
			-- because Position is an offset inside it.
			local holder = self.TooltipHolder
			local mouse = Util.MouseInGuiSpace() - holder.AbsolutePosition
			local size = tooltipFrame.AbsoluteSize
			local viewport = holder.AbsoluteSize

			local x = Util.Clamp(mouse.X + 14, 0, math.max(0, viewport.X - size.X - 2))
			local y = Util.Clamp(mouse.Y + 16, 0, math.max(0, viewport.Y - size.Y - 2))
			tooltipFrame.Position = UDim2.fromOffset(x, y)
		end)
	end))

	self:GiveSignal(guiObject.MouseLeave:Connect(hide))
	self:OnUnload(hide)

	return function(newText, newDisabledText)
		state.Text = newText
		state.DisabledText = newDisabledText
	end
end

--==============================================================
-- visibility
--==============================================================

function Library:SetOpen(open)
	if self.Unloaded then
		return
	end

	self.Toggled = open and true or false
	self:ClosePopup()

	for _, window in self.Windows do
		window:SetVisible(self.Toggled)
	end

	self.MenuToggled:Fire(self.Toggled)
end

function Library:Toggle()
	self:SetOpen(not self.Toggled)
end

function Library:SetMenuKeybind(name)
	if type(name) == "string" and name ~= "" then
		self.MenuKeybind = name
	end
end

Library:GiveSignal(Library.InputBegan:Connect(function(input, gameProcessed)
	if Library.Unloaded or Library.CapturingInput then
		return
	end
	if gameProcessed then
		return
	end
	if UserInputService:GetFocusedTextBox() then
		return
	end
	if Util.InputMatches(input, Library.MenuKeybind) then
		Library:Toggle()
	end
end))

--==============================================================
-- assembly
--==============================================================

require("Window").Install(Library)
require("Overlays").Install(Library)

Library.ThemeManager = require("addons/ThemeManager")
Library.SaveManager = require("addons/SaveManager")
Library.ThemeManager:SetLibrary(Library)
Library.SaveManager:SetLibrary(Library)

if getgenv then
	local env = getgenv()
	env.Sable = Library
	env.Toggles = Library.Toggles
	env.Options = Library.Options
end

return Library
