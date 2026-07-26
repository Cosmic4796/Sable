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
Library.Version = "1.2.0"
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

--- Scrollbars are hidden until a column is actually being scrolled or hovered.
--- Set this false BEFORE creating a window to keep a constant faint bar instead,
--- for anyone who wants the affordance on screen at all times.
Library.QuietScrollbars = true

-- Canonical spelling, matching what Util.InputName reports for a real key
-- press. Util.CanonicalName folds "INSERT"/"Insert" onto this too, but storing
-- the canonical form keeps the keybind pill and a re-capture consistent.
Library.MenuKeybind = "INS"
--- Set by KeyPicker while it waits for a bind so the menu hotkey (and any
--- other bind) does not fire on the very keystroke being captured.
Library.CapturingInput = false

Library.NotifySide = "Right"

--- Touch-primary means a touchscreen AND no keyboard: a device where the menu
--- keybind is not merely inconvenient but UNREACHABLE. A tablet with a mouse
--- and keyboard reports TouchEnabled too and must NOT be treated as mobile,
--- which is why both halves are tested.
---
--- Read once. Roblox can flip these mid-session (a controller connecting, an
--- emulator changing profile) and a UI that re-lays-itself-out underneath the
--- user is worse than one that picked wrong at load. `ForceTouchUI` overrides
--- for anyone on an emulator that misreports.
Library.TouchPrimary = UserInputService.TouchEnabled
	and not UserInputService.KeyboardEnabled
Library.ForceTouchUI = nil

--- True when the UI should use touch affordances. Call this rather than reading
--- TouchPrimary, so the override is honoured everywhere.
function Library:IsTouchUI()
	if self.ForceTouchUI ~= nil then
		return self.ForceTouchUI == true
	end
	return self.TouchPrimary == true
end

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

--- Takes over a ScrollingFrame's scrollbar: transparent at rest, faint while
--- the canvas is moving or the cursor is over it, gone again after
--- Motion.ScrollBarIdle. Every ScrollingFrame in the library goes through here,
--- so the feel lives in one place.
---
--- Only the bar's VISIBILITY changes -- the frame stays interactive and keeps
--- its thickness, because a zero-thickness bar is also a zero-width drag
--- target. When the content already fits, the bar never appears at all.
function Library:QuietScrollbar(frame)
	local faint = self.Sizes.ScrollBarFaint

	self:AddToRegistry(frame, { ScrollBarImageColor3 = "Outline" })

	if not self.QuietScrollbars then
		frame.ScrollBarImageTransparency = faint
		return frame
	end

	frame.ScrollBarImageTransparency = 1

	local hovering = false
	-- Bumped by everything that renews interest in the bar, so a fade-out
	-- queued by an earlier scroll cannot fire after a later one.
	local generation = 0

	-- Only an axis that can actually SCROLL counts. A Y-only column whose canvas
	-- is a few pixels wider than its window -- the vertical bar's own inset does
	-- exactly that -- has nothing to drag, and a bar that cannot move is the
	-- chrome this helper exists to remove.
	local function overflows()
		local window = frame.AbsoluteWindowSize
		local canvas = frame.AbsoluteCanvasSize
		local direction = frame.ScrollingDirection
		if direction ~= Enum.ScrollingDirection.X and canvas.Y > window.Y then
			return true
		end
		if direction ~= Enum.ScrollingDirection.Y and canvas.X > window.X then
			return true
		end
		return false
	end

	--- MouseEnter/MouseLeave are driven by cursor MOVEMENT, so a frame that goes
	--- out from under a STILL cursor -- a popup closing on the click that chose a
	--- row, the menu toggling off -- never delivers a MouseLeave. Hover is the one
	--- state that holds the bar up with NO fade queued, so a flag left standing
	--- there pins the bar on screen for the rest of the session. The cursor is the
	--- source of truth; the flag only says where it was last seen.
	local function hovered()
		if hovering and not (frame.Parent and Util.MouseOver(frame)) then
			hovering = false
		end
		return hovering
	end

	local function fade(target, info)
		if self.Unloaded then
			return
		end
		self:Tween(frame, { ScrollBarImageTransparency = target }, info)
	end

	local function hide()
		generation += 1
		fade(1, self.Motion.Slow)
	end

	local function scheduleHide()
		generation += 1
		local token = generation
		task.delay(self.Motion.ScrollBarIdle, function()
			-- Runs long after the fact: the menu may have been unloaded and the
			-- gui destroyed, and a newer scroll or a hover may own the bar now.
			if self.Unloaded or token ~= generation or hovered() then
				return
			end
			fade(1, self.Motion.Slow)
		end)
	end

	--- `hold` keeps the bar up with no pending fade -- that is the hover state.
	local function show(hold)
		if not overflows() then
			hide()
			return
		end
		generation += 1
		fade(faint, self.Motion.Fast)
		if not hold then
			scheduleHide()
		end
	end

	self:GiveSignal(frame:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		show(hovered())
	end))

	-- Groupboxes grow and shrink, so what overflows changes under the bar. A
	-- column that no longer has anything to scroll must not keep one.
	self:GiveSignal(frame:GetPropertyChangedSignal("AbsoluteCanvasSize"):Connect(function()
		if not overflows() then
			hide()
		elseif hovered() then
			show(true)
		elseif frame.ScrollBarImageTransparency < 1 then
			-- Up with nothing holding it: the cursor left without a MouseLeave.
			-- This is the beat that lets a stranded hover go.
			scheduleHide()
		end
	end))

	self:GiveSignal(frame.MouseEnter:Connect(function()
		hovering = true
		show(true)
	end))

	self:GiveSignal(frame.MouseLeave:Connect(function()
		hovering = false
		if overflows() then
			scheduleHide()
		else
			hide()
		end
	end))

	return frame
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
-- touch toggle
--==============================================================
--
-- On a touch-primary device the menu keybind is not inconvenient, it is
-- UNREACHABLE -- there is no keyboard to press INS on, so without this the
-- library loads and the user can never open it. Everything else about mobile
-- support is polish; this is the difference between usable and not.
--
-- Draggable, because a fixed button always ends up over something that
-- matters, and touch targets cannot be nudged out of the way like a cursor.

local touchToggle = nil

--- Creates the on-screen toggle. Idempotent, and a no-op off touch.
function Library:EnsureTouchToggle()
	if touchToggle or self.Unloaded or not self:IsTouchUI() then
		return touchToggle
	end

	-- Derived, not hardcoded. Theme.Sizes is the single source of truth for
	-- geometry, and on touch RowHeight is already the minimum comfortable
	-- target -- so the button is exactly one row square by construction.
	local Sizes = self.Sizes
	local size = Sizes.RowHeight
	local button, stroke = self:Panel({
		Name = "TouchToggle",
		Active = true,
		Position = UDim2.fromOffset(Sizes.GroupPad, Sizes.TitleBar * 2 + Sizes.GroupPad),
		Size = UDim2.fromOffset(size, size),
		ZIndex = 5,
		Hud = true,
		Parent = self.HudHolder,
	}, "Panel", "Accent")

	local label = self:Label({
		Name = "Label",
		Font = self.Fonts.Title,
		Size = UDim2.fromScale(1, 1),
		Text = "\u{2261}", -- three bars; no image asset, so nothing to load
		TextSize = Sizes.TextTitle + 6,
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = button,
	}, "Accent")

	local hit = self:HitButton(button, {
		Name = "Hit",
		Size = UDim2.fromScale(1, 1),
	})

	-- A drag must not also toggle. Track whether the touch moved and only treat
	-- a stationary press as a tap; otherwise repositioning the button opens the
	-- menu every time you let go of it.
	local pressPos, moved = nil, false

	self:GiveSignal(hit.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1 then
			pressPos, moved = input.Position, false
		end
	end))

	self:GiveSignal(self.InputChanged:Connect(function(input)
		if not pressPos then
			return
		end
		if input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseMovement then
			if (input.Position - pressPos).Magnitude > 8 then
				moved = true
			end
		end
	end))

	self:GiveSignal(self.InputEnded:Connect(function(input)
		if not pressPos then
			return
		end
		if input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1 then
			if not moved then
				self:Toggle()
			end
			pressPos, moved = nil, false
		end
	end))

	self:MakeDraggable(button, button)

	touchToggle = button
	self.TouchToggle = button
	return button
end

--- Hidden while the menu is open: the menu covers the screen on a phone, and a
--- floating button on top of it reads as a stray control rather than a way out.
Library:GiveSignal(Library.MenuToggled:Connect(function(open)
	if touchToggle then
		touchToggle.Visible = not open
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
