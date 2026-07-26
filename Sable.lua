--!nonstrict
-- Sable v1.2.0 - generated bundle. Do not edit; edit src/ and rebuild.
-- 25 modules, built by tools/build.py

local __modules = {}
local __cache = {}

local function require(name)
	local cached = __cache[name]
	if cached ~= nil then
		return cached
	end

	local factory = __modules[name]
	if not factory then
		error("[Sable] missing module: " .. tostring(name), 2)
	end

	local result = factory()
	if result == nil then
		result = true
	end

	__cache[name] = result
	return result
end

__modules["Overlays"] = function()

-- Sable :: Overlays
--
-- The chrome that lives outside the window: watermark, keybind list and the
-- notification stack. The watermark and the keybind list are independently
-- positioned children of HudHolder -- each is draggable while the menu is open
-- and remembers where it was put, which a shared list layout could never allow.
-- Hiding one therefore no longer reflows the other; they stay where the user
-- parked them. All of it keeps rendering while the menu itself is closed.

local Util = require("Util")

local Overlays = {}

--==============================================================
-- metrics
--==============================================================

local WATERMARK_REFRESH = 0.25 -- ~4 recomputes/sec
local NOTIFY_DEFAULT_TIME = 5

-- ASCII pipe on purpose: the Code font has no box-drawing glyphs, and a missing
-- glyph renders as tofu on some platforms.
local SEPARATOR = "|"

-- A character budget, not a pixel one: the bind list is monospace and auto-width,
-- so it is the glyph count that has to be bounded.
local BIND_TEXT_MAX = 32

-- Unbounded height for a wrapped measurement. TextService needs a finite box;
-- this is "taller than any notification could ever be", not a layout metric.
local MEASURE_HEIGHT = 4096

function Overlays.Install(Library)
	local Sizes = Library.Sizes
	local Fonts = Library.Fonts
	local SlowTime = Library.Motion.Slow.Time

	-- Half a group pad is the library's inner gap unit; Window.lua splits
	-- ColumnGap and GroupPad the same way.
	local halfPad = math.ceil(Sizes.GroupPad / 2)
	local halfGap = math.ceil(Sizes.GroupGap / 2)

	-- The HUD sits a group pad in from the screen edge, exactly as a groupbox
	-- sits a group pad in from the window edge.
	local HUD_MARGIN = Sizes.GroupPad
	local HUD_GAP = halfGap

	-- One line of chrome: the same height a row of the menu gets.
	local WATERMARK_HEIGHT = Sizes.RowHeight
	local WATERMARK_PAD_X = halfPad
	local WATERMARK_SPACING = Sizes.RowGap

	-- A bind row is one line of readout text plus a row gap of leading. It is
	-- deliberately not RowHeight: the HUD list is a readout, not a control strip.
	local BIND_ROW_HEIGHT = Sizes.TextSmall + Sizes.RowGap
	local BIND_PAD_X = halfPad
	local BIND_PAD_Y = Sizes.RowGap
	local BIND_SPACING = halfPad
	-- The row height already carries the leading, so rows only need parting.
	local BIND_ROW_GAP = Sizes.Outline

	-- A notification is one groupbox column wide, so the HUD keeps the same
	-- rhythm as the menu: the window body minus its pad on both sides, halved
	-- across the column gap.
	local NOTIFY_WIDTH = math.floor((Sizes.WindowWidth - Sizes.GroupPad * 2 - Sizes.ColumnGap) / 2)
	-- The left edge bar is an accent marker, the same weight as the tab underline.
	local NOTIFY_BAR = Sizes.Indicator
	local NOTIFY_PAD_X = Sizes.GroupPad
	local NOTIFY_PAD_Y = halfPad
	local NOTIFY_GAP = halfGap
	local NOTIFY_MARGIN = Sizes.GroupPad
	-- One line of title text plus a row gap of leading; same rule as a bind row.
	local NOTIFY_TITLE_HEIGHT = Sizes.Text + Sizes.RowGap
	local NOTIFY_MIN_HEIGHT = Sizes.RowHeight

	--- Destroying an instance leaves its colour registry entries behind, and
	--- overlays churn instances constantly -- prune before the instance dies.
	local function dispose(instance)
		if not instance then
			return
		end

		local ok, descendants = pcall(function()
			return instance:GetDescendants()
		end)
		if ok and descendants then
			for _, child in descendants do
				Library:RemoveFromRegistry(child)
			end
		end

		Library:RemoveFromRegistry(instance)
		pcall(function()
			instance:Destroy()
		end)
	end

	--- Re-points a themed property at a different scheme key. Removing first
	--- keeps the registry from growing every time a bind flickers on and off.
	local function recolor(instance, property, key)
		Library:RemoveFromRegistry(instance)
		Library:AddToRegistry(instance, { [property] = key }, true)
	end

	--==============================================================
	-- hud panels (independent placement, dragging, persistence)
	--==============================================================

	-- Deliberately not Library:MakeDraggable. That one is built for a window: it
	-- closes any open popup on grab, drags whenever its handle is clicked, and
	-- clamps by leaving a 48px sliver on screen. A HUD panel has no business
	-- closing a dropdown, must never be draggable with the menu closed, and has
	-- to stay WHOLLY on screen -- half a watermark is not a watermark.
	local HUD_FILE = "hud.json"

	-- Where each panel starts, in HudHolder pixels. The keybind list sits one
	-- HUD gap under a watermark of the standard height, which is exactly where
	-- the old shared list layout put it, so a first run looks unchanged.
	--
	-- Measured from the top-bar-free area, not from the top of the holder: the
	-- gui ignores the inset, so the holder now extends up BEHIND the top bar and
	-- a bare margin would drop the watermark straight onto Roblox's own menu
	-- button. Parking it up there stays perfectly legal -- it is a drag away --
	-- it is just not where the HUD starts life.
	local safe = Util.GuiInsetOffset()
	local hudDefaults = {
		Watermark = { X = HUD_MARGIN + safe.X, Y = HUD_MARGIN + safe.Y },
		KeybindList = {
			X = HUD_MARGIN + safe.X,
			Y = HUD_MARGIN + safe.Y + WATERMARK_HEIGHT + HUD_GAP,
		},
	}

	-- Live positions as plain numbers, which is also the saved form: HttpService
	-- cannot encode a UDim2, and offsets are what the clamp works in anyway.
	--
	-- X/Y is where the panel actually sits -- already clamped, and what gets
	-- saved. WantX/WantY is where it was PUT. Every re-clamp works from the
	-- wanted position, never from the last clamped one: clamping the result of
	-- the previous clamp is a running minimum, so a panel parked against an edge
	-- would be shoved inward every time it grew and never come back when it
	-- shrank. The watermark changes width with every FPS digit and the keybind
	-- list with every bind, so that drift is not hypothetical.
	local hudLayout = {}
	for panelKey, default in hudDefaults do
		hudLayout[panelKey] = { X = default.X, Y = default.Y, WantX = default.X, WantY = default.Y }
	end

	local hudPanels = {}

	local dragPanel = nil
	local dragOrigin = Vector2.zero
	local dragStartX, dragStartY = 0, 0

	--- NaN fails the self-comparison and 1e999 decodes to infinity; a clamp
	--- catches neither, and both reach UDim2.fromOffset intact on the load that
	--- runs before the holder has ever been measured.
	local function finite(value)
		return type(value) == "number" and value == value and value > -math.huge and value < math.huge
	end

	--- Keeps a panel wholly inside HudHolder, allowing for its own size. The
	--- ScreenGui ignores the top bar inset, so HudHolder covers the whole screen
	--- and 0 is the true top edge: a panel may be parked over the top bar, and
	--- still cannot leave the screen in any direction.
	local function clampToViewport(frame, x, y)
		local viewport = Library.HudHolder.AbsoluteSize
		-- Before the first frame the holder has no measured size; clamping
		-- against it would collapse every panel onto the origin.
		if viewport.X <= 0 or viewport.Y <= 0 then
			return x, y
		end

		local size = frame.AbsoluteSize
		return Util.Clamp(x, 0, math.max(0, viewport.X - size.X)),
			Util.Clamp(y, 0, math.max(0, viewport.Y - size.Y))
	end

	--- The handle is a SIBLING of the panel, not a child: both panels drive a
	--- UIListLayout over their own contents and a layout owns every child it can
	--- see, so a button inside one would be dragged into the flow. It tracks the
	--- panel's rectangle instead.
	local function syncHandle(panel)
		local size = panel.Frame.AbsoluteSize

		panel.Handle.Position = panel.Frame.Position
		panel.Handle.Size = UDim2.fromOffset(size.X, size.Y)
		-- A hidden panel must not leave a live hit box behind, and a closed menu
		-- must not swallow input at all.
		panel.Handle.Visible = Library.Toggled == true and panel.Frame.Visible == true
	end

	local function applyHudPosition(panel)
		local entry = hudLayout[panel.Key]
		local x, y = clampToViewport(panel.Frame, entry.WantX, entry.WantY)

		entry.X, entry.Y = math.floor(x), math.floor(y)
		panel.Frame.Position = UDim2.fromOffset(entry.X, entry.Y)
		syncHandle(panel)
	end

	--- Ends the gesture and pins the wanted position to where the panel actually
	--- landed, so a throw at a corner does not leave an overshoot behind for the
	--- next re-clamp to act on. Returns the panel's entry, or nil if no drag was
	--- running.
	local function endDrag()
		local panel = dragPanel
		dragPanel = nil
		if not panel then
			return nil
		end

		local entry = hudLayout[panel.Key]
		entry.WantX, entry.WantY = entry.X, entry.Y
		return entry
	end

	--- Makes `frame` an independently placed, draggable HUD panel. `stroke` is
	--- the panel's outline, which goes Accent while the menu is open and the
	--- cursor is over it -- the whole affordance that it can be moved.
	local function registerHudPanel(key, frame, stroke)
		local panel = {
			Key = key,
			Frame = frame,
			Stroke = stroke,
			-- Frames do not reliably receive clicks; the drag target is a button.
			Handle = Library:HitButton(Library.HudHolder, {
				Name = key .. "Drag",
				Size = UDim2.fromOffset(0, 0),
				Visible = false,
			}),
		}

		table.insert(hudPanels, panel)
		applyHudPosition(panel)

		local function paintOutline(colorKey)
			if stroke then
				Library:Retheme(stroke, { Color = colorKey })
			end
		end

		Library:GiveSignal(panel.Handle.MouseEnter:Connect(function()
			if Library.Unloaded or not Library.Toggled then
				return
			end
			paintOutline("Accent")
		end))

		Library:GiveSignal(panel.Handle.MouseLeave:Connect(function()
			if Library.Unloaded then
				return
			end
			paintOutline("Outline")
		end))

		Library:GiveSignal(panel.Handle.InputBegan:Connect(function(input)
			if Library.Unloaded or not Library.Toggled then
				return
			end
			if
				input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch
			then
				return
			end

			dragPanel = panel
			-- Raw cursor on purpose: the gesture is tracked as a delta from
			-- here, and a constant gui inset cancels in that subtraction. The
			-- panel's own position never comes from a cursor reading.
			dragOrigin = Util.MousePosition()
			dragStartX, dragStartY = hudLayout[key].X, hudLayout[key].Y
		end))

		-- Both panels auto-size, so their rectangle changes under them: a grown
		-- keybind list parked at an edge has to be pulled back into view, and the
		-- handle has to keep covering it.
		Library:GiveSignal(frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			if Library.Unloaded then
				return
			end
			applyHudPosition(panel)
		end))

		Library:GiveSignal(frame:GetPropertyChangedSignal("Visible"):Connect(function()
			if Library.Unloaded then
				return
			end
			syncHandle(panel)

			-- The handle disappears with the panel, so MouseLeave never lands on
			-- it: a panel hidden under the cursor would come back amber, and the
			-- accent means "on", never "here is some chrome".
			if not frame.Visible then
				paintOutline("Outline")
			end
		end))

		return panel
	end

	Library:GiveSignal(Library.InputChanged:Connect(function(input)
		if Library.Unloaded or not dragPanel then
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end

		-- Pure delta again: both readings are raw, so the inset cancels.
		local delta = Util.MousePosition() - dragOrigin
		local entry = hudLayout[dragPanel.Key]
		entry.WantX = dragStartX + delta.X
		entry.WantY = dragStartY + delta.Y
		applyHudPosition(dragPanel)
	end))

	Library:GiveSignal(Library.InputEnded:Connect(function(input)
		if not dragPanel then
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end

		local entry = endDrag()
		-- On the END of the gesture, and only when the panel actually moved: a
		-- click that never became a drag has nothing to persist, and writing a
		-- file per mouse-move would hammer the executor's filesystem.
		if not Library.Unloaded and entry and (entry.X ~= dragStartX or entry.Y ~= dragStartY) then
			Library:SaveHudLayout()
		end
	end))

	Library:GiveSignal(Library.MenuToggled:Connect(function(open)
		for _, panel in hudPanels do
			-- Re-measure on open: a panel that has never been drawn reports a
			-- zero size, and the handle would be an empty hit box.
			syncHandle(panel)
			if not open then
				-- MouseLeave never arrives if the menu closes under the cursor.
				if panel.Stroke then
					Library:Retheme(panel.Stroke, { Color = "Outline" })
				end
			end
		end

		if not open then
			endDrag()
		end
	end))

	--- A resolution change moves the edges every panel is clamped against.
	Library:GiveSignal(Library.HudHolder:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if Library.Unloaded then
			return
		end
		for _, panel in hudPanels do
			applyHudPosition(panel)
		end
	end))

	Library.HudFolder = Library.Name

	function Library:SetHudFolder(path)
		if type(path) == "string" and path ~= "" then
			self.HudFolder = path
		end
		return self
	end

	local function hudLayoutPath()
		return ("%s/%s"):format(tostring(Library.HudFolder or Library.Name), HUD_FILE)
	end

	--- { Watermark = { X =, Y = }, KeybindList = { X =, Y = } } -- a copy, and
	--- plain numbers, so a caller can neither corrupt the live table nor be
	--- handed a datatype JSON refuses to encode.
	function Library:GetHudLayout()
		local out = {}
		for key, entry in hudLayout do
			out[key] = { X = entry.X, Y = entry.Y }
		end
		return out
	end

	function Library:SaveHudLayout()
		if self.Unloaded or not Util.FS.Available() then
			return false
		end
		if not Util.FS.EnsureFolder(self.HudFolder) then
			return false
		end
		return Util.FS.WriteJSON(hudLayoutPath(), self:GetHudLayout()) == true
	end

	--- A missing or corrupt file degrades to "keep the defaults": a HUD that
	--- refuses to appear is worse than one in the wrong place. Positions are
	--- clamped on the way in, so a layout saved at another resolution -- or
	--- hand-edited -- can never hide a panel off screen.
	function Library:LoadHudLayout()
		if self.Unloaded then
			return false
		end

		local data = Util.FS.ReadJSON(hudLayoutPath())
		if type(data) ~= "table" then
			return false
		end

		local applied = false
		for _, panel in hudPanels do
			local saved = data[panel.Key]
			if type(saved) == "table" then
				local x, y = tonumber(saved.X), tonumber(saved.Y)
				if finite(x) and finite(y) then
					hudLayout[panel.Key].WantX = x
					hudLayout[panel.Key].WantY = y
					applyHudPosition(panel)
					applied = true
				end
			end
		end

		return applied
	end

	function Library:ResetHudLayout()
		if self.Unloaded then
			return self
		end

		for _, panel in hudPanels do
			local default = hudDefaults[panel.Key]
			hudLayout[panel.Key].WantX = default.X
			hudLayout[panel.Key].WantY = default.Y
			applyHudPosition(panel)
		end

		self:SaveHudLayout()
		return self
	end

	--==============================================================
	-- watermark
	--==============================================================

	local watermark, watermarkStroke = Library:Panel({
		Name = "Watermark",
		Position = UDim2.fromOffset(hudDefaults.Watermark.X, hudDefaults.Watermark.Y),
		Size = UDim2.fromOffset(0, WATERMARK_HEIGHT),
		AutomaticSize = Enum.AutomaticSize.X,
		Hud = true,
		Parent = Library.HudHolder,
	}, "Panel", "Outline")

	registerHudPanel("Watermark", watermark, watermarkStroke)

	Util.Padding(watermark, 0, WATERMARK_PAD_X, 0, WATERMARK_PAD_X)

	Util.Create("UIListLayout", {
		Name = "List",
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, WATERMARK_SPACING),
		Parent = watermark,
	})

	local segmentLabels = {}
	local separatorLabels = {}

	local function watermarkLabel(name, order, colorKey)
		return Library:Label({
			Name = name,
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.new(0, 0, 1, 0),
			Font = Fonts.Value,
			TextSize = Sizes.TextSmall,
			-- Segments are separate instances precisely so the separator colour
			-- can live in the registry; markup would hardcode it.
			RichText = false,
			LayoutOrder = order,
			Hud = true,
			Parent = watermark,
		}, colorKey)
	end

	--- Rebuilds the label pool only when the segment count changes; the common
	--- case (four segments, new numbers) is four text assignments.
	local function setSegments(values)
		for index = #segmentLabels + 1, #values do
			if index > 1 then
				local separator = watermarkLabel("Separator", index * 2 - 1, "Accent")
				separator.Text = SEPARATOR
				separatorLabels[index - 1] = separator
			end
			segmentLabels[index] = watermarkLabel("Segment", index * 2, "Font")
		end

		for index = #segmentLabels, #values + 1, -1 do
			dispose(segmentLabels[index])
			segmentLabels[index] = nil

			local separator = separatorLabels[index - 1]
			if separator then
				dispose(separator)
				separatorLabels[index - 1] = nil
			end
		end

		for index, value in values do
			segmentLabels[index].Text = tostring(value)
		end
	end

	local leadingSegment = Library:FormatLabel(Library.Name)
	local fps = 0
	local ping = 0

	--- Network ping, in milliseconds.
	---
	--- This segment used to show FRAME TIME, which is 1000/FPS -- arithmetically
	--- redundant with the FPS reading sitting right next to it, and read by
	--- everyone as ping, because "MS" beside a framerate in a game overlay means
	--- ping. So show the thing people were already reading it as.
	---
	--- Wrapped: Stats is present in a real client but not in the test mock, and
	--- the item name has changed across engine versions, so a miss falls back to
	--- the last good number rather than blanking the segment.
	local function readPing()
		local ok, value = pcall(function()
			local stats = game:GetService("Stats")
			local item = stats.Network.ServerStatsItem["Data Ping"]
			return item:GetValue()
		end)
		if ok and type(value) == "number" and value > 0 then
			return math.floor(value + 0.5)
		end
		return ping
	end

	local function refreshWatermark()
		if Library.Unloaded then
			return
		end

		setSegments({
			leadingSegment,
			("%d FPS"):format(fps),
			("%d MS"):format(ping),
			tostring(os.date("%H:%M:%S")),
		})
	end

	local frameCount = 0
	local frameTime = 0

	Library:GiveSignal(Library.RenderStepped:Connect(function(delta)
		if Library.Unloaded then
			return
		end

		frameCount += 1
		frameTime += delta
		if frameTime < WATERMARK_REFRESH then
			return
		end

		-- Averaged over the whole window rather than sampled from one frame, so
		-- a single hitch does not make the readout jump.
		local average = frameTime / frameCount
		fps = average > 0 and math.floor(1 / average + 0.5) or 0
		ping = readPing()

		frameCount = 0
		frameTime = 0

		refreshWatermark()
	end))

	Library.Watermark = watermark
	Library.WatermarkText = leadingSegment
	Library.WatermarkVisible = true

	function Library:SetWatermark(text)
		text = tostring(text or "")
		leadingSegment = self:FormatLabel(text ~= "" and text or self.Name)
		self.WatermarkText = leadingSegment
		refreshWatermark()
		return self
	end

	function Library:SetWatermarkVisibility(visible)
		visible = visible ~= false
		self.WatermarkVisible = visible
		watermark.Visible = visible
		return self
	end

	refreshWatermark()

	--==============================================================
	-- keybind list
	--==============================================================

	local keybindPanel, keybindStroke = Library:Panel({
		Name = "Keybinds",
		Position = UDim2.fromOffset(hudDefaults.KeybindList.X, hudDefaults.KeybindList.Y),
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		Visible = false,
		Hud = true,
		Parent = Library.HudHolder,
	}, "Panel", "Outline")

	Util.Padding(keybindPanel, BIND_PAD_Y, BIND_PAD_X, BIND_PAD_Y, BIND_PAD_X)
	Util.ListLayout(keybindPanel, BIND_ROW_GAP)

	registerHudPanel("KeybindList", keybindPanel, keybindStroke)

	local bindRows = {}
	local bindCount = 0
	local bindOrder = 0

	Library.KeybindsVisible = true

	local function refreshKeybindPanel()
		keybindPanel.Visible = Library.KeybindsVisible and bindCount > 0
	end

	local function paintBindRow(row)
		row.TextLabel.Text = Library:FormatLabel(Util.Truncate(row.TextValue, BIND_TEXT_MAX))
		row.KeyLabel.Text = ("[%s]"):format(Library:FormatLabel(row.KeyValue))

		-- KeyPickers repaint on every state change, so only touch the registry
		-- when the colour actually differs.
		local key = row.Active and "Accent" or "FontDim"
		if row.ColorKey ~= key then
			row.ColorKey = key
			recolor(row.KeyLabel, "TextColor3", key)
		end
	end

	local function createBindRow(id)
		bindOrder += 1

		local frame = Library:Create("Frame", {
			Name = "Bind",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(0, 0, 0, BIND_ROW_HEIGHT),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = bindOrder,
			Parent = keybindPanel,
		})

		Util.Create("UIListLayout", {
			Name = "List",
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, BIND_SPACING),
			Parent = frame,
		})

		local function label(name, order, colorKey)
			return Library:Label({
				Name = name,
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.new(0, 0, 1, 0),
				Font = Fonts.Value,
				TextSize = Sizes.TextSmall,
				LayoutOrder = order,
				Hud = true,
				Parent = frame,
			}, colorKey)
		end

		return {
			Frame = frame,
			TextLabel = label("Text", 1, "Font"),
			KeyLabel = label("Key", 2, "FontDim"),
			TextValue = tostring(id),
			KeyValue = "NONE",
			Mode = "Toggle",
			Active = false,
			ColorKey = "FontDim",
		}
	end

	local KeybindList = {}
	Library.KeybindList = KeybindList

	--- Creates the row on first call for `id`, patches it afterwards. Only the
	--- fields present in `data` are touched, so `:Set(id, { Active = true })` is
	--- a legitimate per-frame update.
	function KeybindList:Set(id, data)
		if Library.Unloaded or id == nil then
			return nil
		end

		data = data or {}

		local row = bindRows[id]
		if not row then
			row = createBindRow(id)
			bindRows[id] = row
			bindCount += 1
		end

		if data.Text ~= nil then
			row.TextValue = tostring(data.Text)
		end
		if data.Key ~= nil then
			row.KeyValue = tostring(data.Key)
		end
		if data.Mode ~= nil then
			row.Mode = tostring(data.Mode)
		end
		if data.Active ~= nil then
			row.Active = data.Active == true
		end

		paintBindRow(row)
		refreshKeybindPanel()

		return row
	end

	function KeybindList:Remove(id)
		local row = bindRows[id]
		if not row then
			return
		end

		bindRows[id] = nil
		bindCount -= 1

		dispose(row.Frame)
		refreshKeybindPanel()
	end

	function KeybindList:Clear()
		for id in bindRows do
			self:Remove(id)
		end
	end

	Library.KeybindPanel = keybindPanel

	function Library:SetKeybindVisibility(visible)
		self.KeybindsVisible = visible ~= false
		refreshKeybindPanel()
		return self
	end

	--==============================================================
	-- notifications
	--==============================================================

	local notifications = {}

	--- Top of the notification stack, in NotificationHolder pixels. The gui
	--- ignores the top bar inset, so the holder's own origin is the true top of
	--- the screen and a bare margin would slide the first notification in behind
	--- Roblox's top bar. A notification is never dragged, unlike a HUD panel, so
	--- clearing the bar is not a default it can move away from -- it is the only
	--- place it may sit.
	local function stackTop()
		return NOTIFY_MARGIN + Util.GuiInsetOffset().Y
	end

	--- Off-screen position is a full width past the edge, so the slide reads as
	--- the panel entering from outside the viewport rather than fading in.
	local function slotPosition(note, shown)
		if note.Side == "Left" then
			local offset = shown and NOTIFY_MARGIN or -(NOTIFY_WIDTH + NOTIFY_MARGIN)
			return UDim2.new(0, offset, 0, note.Y)
		end

		local offset = shown and -NOTIFY_MARGIN or (NOTIFY_WIDTH + NOTIFY_MARGIN)
		return UDim2.new(1, offset, 0, note.Y)
	end

	--- Re-stacks every live notification from the top. Called after any removal
	--- so the survivors close the gap instead of leaving a hole.
	local function reflow()
		local y = stackTop()

		for _, note in notifications do
			if note.Y ~= y then
				note.Y = y
				Library:Tween(note.Frame, { Position = slotPosition(note, note.Shown) }, Library.Motion.Slow)
			end
			y += note.Height + NOTIFY_GAP
		end
	end

	local function close(note)
		if note.Closing then
			return
		end
		note.Closing = true
		note.Shown = false

		if Library.Unloaded then
			dispose(note.Frame)
			return
		end

		Library:Tween(note.Frame, { Position = slotPosition(note, false) }, Library.Motion.Slow)

		-- Stays in the stack until it is fully off screen; removing it early
		-- would slide the rest up through it.
		task.delay(SlowTime + 0.05, function()
			local index = table.find(notifications, note)
			if index then
				table.remove(notifications, index)
			end

			dispose(note.Frame)

			if not Library.Unloaded then
				reflow()
			end
		end)
	end

	--- Notify("text", 4) or Notify({ Title =, Description =, Time =, Risk =,
	--- Good = }). Returns the notification handle, which carries :Close().
	function Library:Notify(content, duration)
		if self.Unloaded then
			return nil
		end

		local options = type(content) == "table" and content or { Description = content }

		local titleText = options.Title ~= nil and self:FormatLabel(options.Title) or nil
		local bodySource = options.Description
		if bodySource == nil then
			bodySource = options.Text
		end
		local bodyText = bodySource ~= nil and tostring(bodySource) or nil

		if (titleText == nil or titleText == "") and (bodyText == nil or bodyText == "") then
			return nil
		end

		local edgeKey = "Accent"
		if options.Risk then
			edgeKey = "Risk"
		elseif options.Good then
			edgeKey = "Good"
		end

		local hold = tonumber(duration) or tonumber(options.Time) or NOTIFY_DEFAULT_TIME
		hold = math.max(hold, 0.5)

		-- Height is measured up front rather than left to AutomaticSize: the
		-- stack needs every panel's height before the first frame is drawn.
		local inner = NOTIFY_WIDTH - NOTIFY_BAR - NOTIFY_PAD_X * 2
		local bodyHeight = 0
		if bodyText then
			local measured =
				Util.TextSize(bodyText, Sizes.TextSmall, Fonts.Label, Vector2.new(inner, MEASURE_HEIGHT))
			bodyHeight = math.max(math.ceil(measured.Y), Sizes.TextSmall + Sizes.RowGap)
		end

		local titleHeight = titleText and NOTIFY_TITLE_HEIGHT or 0
		local innerGap = (titleText and bodyText) and Sizes.RowGap or 0
		local height =
			math.max(NOTIFY_PAD_Y * 2 + titleHeight + innerGap + bodyHeight, NOTIFY_MIN_HEIGHT)

		local y = stackTop()
		for _, existing in notifications do
			y += existing.Height + NOTIFY_GAP
		end

		local note = {
			Side = self.NotifySide == "Left" and "Left" or "Right",
			Height = height,
			Y = y,
			Shown = false,
			Closing = false,
		}

		local frame = self:Panel({
			Name = "Notification",
			AnchorPoint = note.Side == "Left" and Vector2.new(0, 0) or Vector2.new(1, 0),
			Position = slotPosition(note, false),
			Size = UDim2.fromOffset(NOTIFY_WIDTH, height),
			ZIndex = 200,
			Parent = self.NotificationHolder,
		}, "Panel", "Outline")

		note.Frame = frame

		self:Create("Frame", {
			Name = "Edge",
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(0, 0),
			Size = UDim2.new(0, NOTIFY_BAR, 1, 0),
			ZIndex = 201,
			Theme = { BackgroundColor3 = edgeKey },
			Parent = frame,
		})

		local body = self:Create("Frame", {
			Name = "Body",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(NOTIFY_BAR + NOTIFY_PAD_X, NOTIFY_PAD_Y),
			Size = UDim2.new(1, -(NOTIFY_BAR + NOTIFY_PAD_X * 2), 1, -NOTIFY_PAD_Y * 2),
			ZIndex = 201,
			Parent = frame,
		})

		Util.ListLayout(body, innerGap)

		if titleText then
			self:Label({
				Name = "Title",
				Size = UDim2.new(1, 0, 0, NOTIFY_TITLE_HEIGHT),
				Text = titleText,
				Font = Fonts.Label,
				TextSize = Sizes.Text,
				TextTruncate = Enum.TextTruncate.AtEnd,
				LayoutOrder = 1,
				ZIndex = 202,
				Parent = body,
			}, "Font")
		end

		if bodyText then
			self:Label({
				Name = "Description",
				Size = UDim2.new(1, 0, 0, bodyHeight),
				Text = bodyText,
				Font = Fonts.Label,
				TextSize = Sizes.TextSmall,
				TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top,
				LayoutOrder = 2,
				ZIndex = 202,
				Parent = body,
			}, "FontDim")
		end

		function note:Close()
			close(self)
		end

		table.insert(notifications, note)

		note.Shown = true
		self:Tween(frame, { Position = slotPosition(note, true) }, self.Motion.Slow)

		task.delay(hold, function()
			close(note)
		end)

		return note
	end

	Library:OnUnload(function()
		dragPanel = nil
		table.clear(hudPanels)

		for index = #notifications, 1, -1 do
			dispose(notifications[index].Frame)
			notifications[index] = nil
		end

		for id in bindRows do
			bindRows[id] = nil
		end
		bindCount = 0

		table.clear(segmentLabels)
		table.clear(separatorLabels)
	end)
end

return Overlays
end

__modules["Signal"] = function()

-- Sable :: Signal
-- Minimal, allocation-light signal. Handlers are pcall'd so one bad callback
-- can never take the menu down mid-frame.

local Signal = {}
Signal.__index = Signal

local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false

	local handlers = self._signal._handlers
	for i = #handlers, 1, -1 do
		if handlers[i] == self then
			table.remove(handlers, i)
			break
		end
	end

	self._fn = nil
	self._signal = nil
end

Connection.disconnect = Connection.Disconnect
Connection.Destroy = Connection.Disconnect

function Signal.new(name)
	return setmetatable({
		_handlers = {},
		_name = name or "Signal",
	}, Signal)
end

function Signal:Connect(fn)
	assert(type(fn) == "function", "[Sable] Signal:Connect expects a function")

	local connection = setmetatable({
		Connected = true,
		_fn = fn,
		_signal = self,
	}, Connection)

	table.insert(self._handlers, connection)
	return connection
end

Signal.connect = Signal.Connect

function Signal:Once(fn)
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		fn(...)
	end)
	return connection
end

function Signal:Fire(...)
	-- Snapshot so a handler disconnecting (or connecting) mid-fire is safe.
	local snapshot = table.clone(self._handlers)
	for i = 1, #snapshot do
		local connection = snapshot[i]
		if connection.Connected then
			local ok, err = pcall(connection._fn, ...)
			if not ok then
				warn(("[Sable] %s handler error: %s"):format(self._name, tostring(err)))
			end
		end
	end
end

function Signal:DisconnectAll()
	local snapshot = table.clone(self._handlers)
	for i = 1, #snapshot do
		snapshot[i]:Disconnect()
	end
	table.clear(self._handlers)
end

Signal.Destroy = Signal.DisconnectAll

return Signal
end

__modules["Theme"] = function()

-- Sable :: Theme
-- The design system: palette, metrics, fonts, and the live colour registry.
--
-- LOOK: "tactical / instrument". Warm dark grey, one amber accent, hard 1px
-- hairlines, zero corner radius, uppercase letterspaced chrome, monospace
-- numerals. Deliberately NOT: rounded cards, gradients as decoration, glow,
-- blur, emoji, pastel accents.

local Util = require("Util")

local Theme = {}

--==============================================================
-- palette
--==============================================================

-- Warm greys: every neutral carries a little orange so the amber accent reads
-- as part of the same family instead of a sticker on top of a blue-grey UI.
Theme.Default = {
	Background = Color3.fromRGB(18, 17, 15),
	Panel = Color3.fromRGB(26, 25, 22),
	PanelRaised = Color3.fromRGB(34, 32, 29),
	PanelSunken = Color3.fromRGB(13, 12, 11),

	Outline = Color3.fromRGB(52, 49, 44),
	OutlineDim = Color3.fromRGB(36, 34, 30),

	Accent = Color3.fromRGB(233, 161, 59),
	AccentDim = Color3.fromRGB(126, 88, 34),

	Font = Color3.fromRGB(218, 213, 204),
	FontDim = Color3.fromRGB(124, 117, 107),
	FontFaint = Color3.fromRGB(84, 79, 72),

	Risk = Color3.fromRGB(226, 78, 63),
	Good = Color3.fromRGB(126, 176, 106),

	Black = Color3.fromRGB(0, 0, 0),
}

-- Linoria-flavoured names, so ported scripts and old configs keep working.
Theme.Aliases = {
	MainColor = "Panel",
	BackgroundColor = "Background",
	AccentColor = "Accent",
	OutlineColor = "Outline",
	FontColor = "Font",
	RiskColor = "Risk",
}

--==============================================================
-- metrics
--==============================================================

-- Dense, but not cramped. Instrument panels pack information; they still need
-- enough air that a row reads as a row. EVERY size in the library must come
-- from this table -- a hardcoded pixel is a bug, because it will not move when
-- these numbers do.
Theme.Sizes = {
	WindowWidth = 620,
	WindowHeight = 660,
	WindowMinWidth = 460,
	WindowMinHeight = 360,

	TitleBar = 34,
	TabStrip = 30,

	RowHeight = 26,
	RowGap = 4,

	GroupPad = 12,
	GroupGap = 12,
	ColumnGap = 12,
	GroupHeader = 20,

	Outline = 1,
	Tick = 8, -- corner tick arm length
	TickThickness = 1,

	Text = 13, -- element labels
	TextSmall = 12, -- readouts, captions, footer
	TextTitle = 14, -- window title, group headers

	Control = 15, -- checkbox / swatch square edge
	Track = 9, -- slider bar height
	Segments = 16, -- slider segment count
	Indicator = 2, -- active-tab underline thickness

	-- The ColorPicker's saturation/value canvas. It is the one content surface
	-- in the library that is not a row, a control or a column, so there is
	-- nothing honest to derive it from -- it belongs here rather than as a magic
	-- number inside the element.
	PickerSquare = 144,

	PopupWidth = 0, -- 0 = match anchor width
	-- Floor for popups that otherwise match their anchor's width, so a narrow
	-- control cannot open a sliver of a list. Roughly one groupbox column.
	PopupMinWidth = 140,
	PopupMaxItems = 9,

	ScrollBar = 3,
	-- The stock scrollbar is the last piece of default Roblox chrome left in the
	-- design, so it is invisible at rest and never comes back further than this:
	-- enough to read a position from, not enough to become furniture. The bar
	-- keeps its thickness while hidden -- a zero-width bar has no drag target.
	ScrollBarFaint = 0.5,
}

-- Monospace throughout. Mixing a proportional UI font in is the single fastest
-- way to make this read as a generic dashboard.
Theme.Fonts = {
	Label = Enum.Font.Code,
	Value = Enum.Font.Code,
	Title = Enum.Font.Code,
}

Theme.Motion = {
	Fast = TweenInfo.new(0.09, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	Slow = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	Fade = 0.14,
	-- Seconds a scrollbar stays up after the last scroll, once the cursor is no
	-- longer over the column. Long enough to finish the gesture, short enough
	-- that a still menu has no scrollbars in it at all.
	ScrollBarIdle = 0.6,
}

--==============================================================
-- install
--==============================================================

function Theme.Install(Library)
	Library.Scheme = table.clone(Theme.Default)
	Library.Sizes = table.clone(Theme.Sizes)
	Library.Fonts = table.clone(Theme.Fonts)
	Library.Motion = table.clone(Theme.Motion)
	Library.Registry = {}
	-- [Instance] = entry, so re-registration is O(1) and can merge in place.
	Library.RegistryIndex = {}

	--- Resolves a scheme key (or alias) to a live colour.
	function Library:GetColor(key)
		if typeof(key) == "Color3" then
			return key
		end
		if type(key) ~= "string" then
			return nil
		end
		local resolved = Theme.Aliases[key] or key
		return self.Scheme[resolved]
	end

	--- properties maps an instance property name to either a scheme key
	--- ("Accent") or a function(scheme) -> value for derived colours.
	---
	---   Library:AddToRegistry(frame, { BackgroundColor3 = "Panel" })
	---
	--- `isHud` marks chrome that stays visible while the menu is closed
	--- (watermark, keybind list) so themes can treat it separately.
	--- Re-registering the SAME instance MERGES into its existing entry rather
	--- than appending a second one. Two entries for one instance would fight
	--- over the same property and the winner would depend on registry iteration
	--- order -- which silently beat state-dependent colours (a toggle's label
	--- reverting to a static colour after any theme switch) and leaked an entry
	--- on every state flip.
	function Library:AddToRegistry(instance, properties, isHud)
		local existing = self.RegistryIndex[instance]
		if existing and not existing.Dead then
			for property, source in properties do
				existing.Properties[property] = source
			end
			if isHud then
				existing.Hud = true
			end
			self:ApplyRegistryEntry(existing)
			return existing
		end

		local entry = {
			Instance = instance,
			Properties = properties,
			Hud = isHud or false,
		}
		table.insert(self.Registry, entry)
		self.RegistryIndex[instance] = entry
		self:ApplyRegistryEntry(entry)
		return entry
	end

	--- The source currently mapped to a property, so a caller can restore an
	--- element's own (possibly function-based) colour rule after temporarily
	--- overriding it.
	function Library:GetRegistrySource(instance, property)
		local entry = self.RegistryIndex[instance]
		if entry and not entry.Dead then
			return entry.Properties[property]
		end
		return nil
	end

	--- Same behaviour as AddToRegistry; the separate name states the intent
	--- that you are changing an existing mapping (on/off, enabled/disabled).
	function Library:Retheme(instance, properties)
		return self:AddToRegistry(instance, properties)
	end

	--- Also drops entries for DESCENDANTS of `instance`. Writing to a destroyed
	--- Instance does not throw in Roblox, so the dead-entry pruning in
	--- UpdateColorsUsingRegistry never reclaims a destroyed element's children
	--- on its own.
	function Library:RemoveFromRegistry(instance)
		for index = #self.Registry, 1, -1 do
			local entry = self.Registry[index]
			local target = entry.Instance

			local matches = target == instance
			if not matches then
				local ok, isDescendant = pcall(function()
					return target:IsDescendantOf(instance)
				end)
				matches = ok and isDescendant
			end

			if matches then
				self.RegistryIndex[target] = nil
				table.remove(self.Registry, index)
			end
		end
	end

	function Library:ApplyRegistryEntry(entry)
		local instance = entry.Instance
		if entry.Dead then
			return false
		end

		for property, source in entry.Properties do
			local value
			if type(source) == "function" then
				local ok, result = pcall(source, self.Scheme)
				value = ok and result or nil
			else
				value = self:GetColor(source)
			end

			if value ~= nil then
				local ok = pcall(function()
					instance[property] = value
				end)
				if not ok then
					-- Instance was destroyed, or the property does not exist.
					entry.Dead = true
					return false
				end
			end
		end

		return true
	end

	--- Re-applies every registered colour. Cheap enough to call on any change;
	--- dead entries are pruned as they are found.
	function Library:UpdateColorsUsingRegistry()
		for index = #self.Registry, 1, -1 do
			local entry = self.Registry[index]
			if not self:ApplyRegistryEntry(entry) then
				self.RegistryIndex[entry.Instance] = nil
				table.remove(self.Registry, index)
			end
		end
	end

	--- SetScheme("Accent", color) or SetScheme({ Accent = color, ... })
	function Library:SetScheme(keyOrTable, color)
		if type(keyOrTable) == "table" then
			for key, value in keyOrTable do
				local resolved = Theme.Aliases[key] or key
				if self.Scheme[resolved] ~= nil and typeof(value) == "Color3" then
					self.Scheme[resolved] = value
				end
			end
		else
			local resolved = Theme.Aliases[keyOrTable] or keyOrTable
			if self.Scheme[resolved] == nil then
				return false
			end
			self.Scheme[resolved] = color
		end

		-- Accent drives a derived shade; keep it consistent unless explicitly set.
		if
			(type(keyOrTable) == "table" and keyOrTable.Accent and not keyOrTable.AccentDim)
			or (keyOrTable == "Accent" or keyOrTable == "AccentColor")
		then
			self.Scheme.AccentDim = Util.Shift(self.Scheme.Accent, 0.55)
		end

		self:UpdateColorsUsingRegistry()
		return true
	end

	function Library:ResetScheme()
		self.Scheme = table.clone(Theme.Default)
		self:UpdateColorsUsingRegistry()
	end

	Library.ThemeDefaults = Theme.Default
	Library.ThemeAliases = Theme.Aliases
end

return Theme
end

__modules["Util"] = function()

-- Sable :: Util
-- Dependency-free helpers. Nothing in here may require() another Sable module.

local TweenService = game:GetService("TweenService")
local TextService = game:GetService("TextService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local CoreGui = game:GetService("CoreGui")
local RunService = game:GetService("RunService")

local Util = {}

Util.Services = {
	Tween = TweenService,
	Text = TextService,
	Input = UserInputService,
	Gui = GuiService,
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

--- Mirrors ScreenGui.IgnoreGuiInset for the gui Sable actually created; init
--- assigns it from the ScreenGui itself the moment that exists. It decides
--- where PLACED chrome has to start to clear the top bar. It deliberately does
--- NOT enter the cursor conversion, which is the same in both modes -- see
--- MouseInGuiSpace. Nothing but init may write it.
Util.GuiInsetIgnored = false

--- Where the top-bar-free area begins, measured in the offset space a holder's
--- children are POSITIONED in -- not a cursor conversion.
---
--- A holder is a full-bleed child of the ScreenGui, so its local origin is the
--- gui's own top-left: the true top of the screen when the gui ignores the
--- inset, the point just under the top bar when it does not. Chrome that must
--- clear the top bar starts here; chrome that may be parked over it ignores it.
function Util.GuiInsetOffset()
	if not Util.GuiInsetIgnored then
		return Vector2.zero
	end
	-- GetGuiInset returns (topLeft, bottomRight); only the top-left offset
	-- describes the band the top bar covers.
	return (GuiService:GetGuiInset())
end

--- RAW cursor, exactly as UserInputService reports it: measured from the true
--- top-left of the screen, top bar INCLUDED, whatever the ScreenGui does.
---
--- Legitimate for DELTAS ONLY -- drag and resize offsets, where a constant
--- inset cancels in the subtraction. Comparing this against an AbsolutePosition
--- is a bug in both inset modes; use MouseInGuiSpace.
function Util.MousePosition()
	return UserInputService:GetMouseLocation()
end

--- Cursor in the SAME space as GuiObject.AbsolutePosition. Every hit test and
--- every comparison against an AbsolutePosition must use this one.
---
--- The two spaces are one inset apart in BOTH modes, so the conversion is
--- unconditional. AbsolutePosition is always measured from just under the top
--- bar and IgnoreGuiInset does not move that origin -- it only lets the gui
--- render above it, which is why a frame at the very top of the screen inside
--- an inset-ignoring gui reports a NEGATIVE AbsolutePosition.Y. The cursor is
--- measured from the true top-left, so it always reads one inset higher and
--- always has that inset taken back off.
---
--- Skip the conversion and nothing errors: every hit test just reacts one inset
--- BELOW the real cursor, so the user has to aim above the control.
function Util.MouseInGuiSpace()
	return UserInputService:GetMouseLocation() - (GuiService:GetGuiInset())
end

--- Is the cursor inside `guiObject`, optionally grown by `expand` pixels?
--- The comparison happens in AbsolutePosition space, which is why the cursor
--- goes through MouseInGuiSpace rather than being read raw.
function Util.MouseOver(guiObject, expand)
	if not guiObject or not guiObject.Visible then
		return false
	end

	expand = expand or 0

	local mouse = Util.MouseInGuiSpace()
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
end

__modules["Window"] = function()

-- Sable :: Window
--
-- Window chrome plus the container object model: window -> tab -> column ->
-- groupbox / tabbox / dependency box.
--
-- Every container type is built from ONE metatable, so elements/init installs
-- its Add* constructors a single time and groupboxes, tabbox tabs and
-- dependency boxes all gain them together. Containers never measure their own
-- children: they read UIListLayout.AbsoluteContentSize and resize from that,
-- which is why an element only has to create its row.

local Util = require("Util")
local Elements = require("elements/init")

local Window = {}

-- Indexes AddSettingsTab registers. "MenuKeybind" keeps its plain Linoria name
-- so ported scripts reading Options.MenuKeybind still find it; the other two are
-- prefixed, because a hub is far more likely to own "Watermark" than
-- "SableWatermark" and a collision would silently replace its element.
local MENU_KEYBIND_INDEX = "MenuKeybind"
local WATERMARK_INDEX = "SableWatermark"
local KEYBIND_LIST_INDEX = "SableKeybindList"

function Window.Install(Library)
	local Sizes = Library.Sizes

	-- How far a groupbox header reaches inside the box whose hairline it cuts.
	local HeaderDrop = math.ceil(Sizes.GroupHeader / 2)
	-- Groupbox content starts clear of that header, then a half pad of air.
	local GroupTop = HeaderDrop + math.floor(Sizes.GroupPad / 2)
	-- A column must reserve room above its first groupbox for the header that
	-- overhangs it, or the ScrollingFrame clips the header in half.
	local ColumnTop = HeaderDrop + Sizes.RowGap
	local ChromeHeight = Sizes.TitleBar + Sizes.TabStrip
	local HalfGap = math.ceil(Sizes.ColumnGap / 2)
	local TabboxStrip = Sizes.RowHeight
	local TitlePad = Sizes.GroupPad + Sizes.Tick -- clears the corner ticks

	-- Square scrollbar caps. The stock end textures are rounded, which is the
	-- one place Roblox would sneak a radius into the menu.
	local FLAT_SCROLL = "rbxasset://textures/ui/Scroll/scroll-middle.png"

	--- Swaps an instance's themed colours without stacking registry entries.
	--- Always pass the FULL map: the old entry is dropped wholesale.
	local function retheme(instance, properties)
		Library:RemoveFromRegistry(instance)
		Library:AddToRegistry(instance, properties)
	end

	local function hairline(parent, y, colorKey, zIndex)
		return Library:Create("Frame", {
			Name = "Rule",
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(0, y),
			Size = UDim2.new(1, 0, 0, Sizes.Outline),
			ZIndex = zIndex or 1,
			Theme = { BackgroundColor3 = colorKey },
			Parent = parent,
		})
	end

	--==============================================================
	-- containers
	--==============================================================

	-- Forward declarations: the container methods below close over these.
	local newDependencyBox

	local Container = {}
	Container.__index = Container

	--- Recompute this container's height, then let whatever owns it do the
	--- same. Idempotent, so calling it when nothing changed costs one layout
	--- read and stops.
	function Container:Resize()
		if self.Recompute then
			self:Recompute()
		end

		local owner = self.Owner
		if owner and owner.Resize then
			owner:Resize()
		end

		return self
	end

	function Container:AddDependencyBox()
		return newDependencyBox(self)
	end

	Elements.Install(Library, Container)

	local function newContainer(frame, owner)
		return setmetatable({
			Library = Library,
			Container = frame,
			Elements = {},
			Owner = owner,
		}, Container)
	end

	--==============================================================
	-- dependency box
	--==============================================================

	function newDependencyBox(parent)
		local frame = Library:Create("Frame", {
			Name = "DependencyBox",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ClipsDescendants = true,
			Size = UDim2.new(1, 0, 0, 0),
			Visible = false,
			Parent = parent.Container,
		})

		local layout = Util.ListLayout(frame, Sizes.RowGap)

		local box = newContainer(frame, parent)
		box.Type = "DependencyBox"
		box.Frame = frame
		box.Layout = layout
		box.Dependencies = {}
		box.Shown = false

		-- The box occupies a slot in its parent's list, so it must occupy one in
		-- Elements too -- otherwise the next element reuses its LayoutOrder.
		-- Base.Create appends before Library:Row reads the count, so a slot's
		-- LayoutOrder is its index + 1; match that exactly or the box ties with
		-- the element above it.
		table.insert(parent.Elements, box)
		frame.LayoutOrder = #parent.Elements + 1

		function box:Recompute()
			frame.Visible = self.Shown
			frame.Size = UDim2.new(1, 0, 0, self.Shown and math.ceil(layout.AbsoluteContentSize.Y) or 0)
		end

		function box:Evaluate()
			local shown = true

			for _, pair in self.Dependencies do
				local element = pair[1]
				if not element or element.Value ~= pair[2] then
					shown = false
					break
				end
			end

			self.Shown = shown
			self:Resize()

			return shown
		end

		--- list is { { element, expectedValue }, ... }; the box is visible only
		--- while every pair matches.
		function box:SetupDependencies(list)
			self.Dependencies = list or {}

			for _, pair in self.Dependencies do
				local element = pair[1]
				if element and element.OnChanged then
					element:OnChanged(function()
						box:Evaluate()
					end)
				end
			end

			self:Evaluate()
			return self
		end

		Library:GiveSignal(layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
			box:Resize()
		end))

		return box
	end

	--==============================================================
	-- groupbox
	--==============================================================

	local function newGroupbox(tab, side, name)
		local column = side == "Right" and tab.Right or tab.Left
		tab.Order[side] += 1

		local frame = Library:Panel({
			Name = "Groupbox",
			Size = UDim2.new(1, 0, 0, Sizes.GroupHeader + Sizes.GroupPad),
			LayoutOrder = tab.Order[side],
			Parent = column,
		}, "Panel", "Outline")

		-- Signature detail: the title interrupts the top hairline rather than
		-- sitting inside the box. An opaque Background fill over a higher ZIndex
		-- makes the cut; the padding sets how wide the gap in the line is.
		local header = Library:Create("TextLabel", {
			Name = "Header",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromOffset(Sizes.GroupPad, 0),
			-- Height is the width of the CUT in the hairline, not the text box.
			-- Roblox draws TextLabel text outside its frame, so the caption is
			-- unaffected. At Sizes.GroupHeader (18) the opaque fill spanned
			-- +/-9px and reached across the GroupGap to punch a hole through
			-- the bottom hairline of the groupbox above.
			Size = UDim2.new(0, 0, 0, Sizes.GroupPad - 2),
			AutomaticSize = Enum.AutomaticSize.X,
			BorderSizePixel = 0,
			Font = Library.Fonts.Title,
			Text = Library:Chrome(name or ""),
			TextSize = Sizes.TextSmall,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Center,
			ZIndex = 4,
			Theme = { BackgroundColor3 = "Background", TextColor3 = "FontDim" },
			Parent = frame,
		})
		Util.Padding(header, 0, 4, 0, 4)

		local content = Library:Create("Frame", {
			Name = "Content",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			Parent = frame,
		})
		Util.Padding(content, GroupTop, Sizes.GroupPad, Sizes.GroupPad, Sizes.GroupPad)

		local layout = Util.ListLayout(content, Sizes.RowGap)

		local box = newContainer(content, nil)
		box.Type = "Groupbox"
		box.Frame = frame
		box.Header = header
		box.Layout = layout

		function box:Recompute()
			local height = layout.AbsoluteContentSize.Y + GroupTop + Sizes.GroupPad
			frame.Size = UDim2.new(1, 0, 0, math.ceil(height))
		end

		function box:SetTitle(text)
			header.Text = Library:Chrome(text or "")
			return self
		end

		Library:GiveSignal(layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
			box:Resize()
		end))

		table.insert(tab.Boxes, box)
		box:Recompute()

		return box
	end

	--==============================================================
	-- tabbox
	--==============================================================

	local function newTabbox(tab, side)
		local column = side == "Right" and tab.Right or tab.Left
		tab.Order[side] += 1

		local shell = Library:Panel({
			Name = "Tabbox",
			Size = UDim2.new(1, 0, 0, TabboxStrip + Sizes.GroupPad * 2),
			LayoutOrder = tab.Order[side],
			Parent = column,
		}, "Panel", "Outline")

		local strip = Library:Create("Frame", {
			Name = "Strip",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, TabboxStrip),
			ZIndex = 2,
			Parent = shell,
		})

		hairline(shell, TabboxStrip - Sizes.Outline, "OutlineDim", 1)

		local indicator = Library:Create("Frame", {
			Name = "Indicator",
			AnchorPoint = Vector2.new(0, 1),
			BorderSizePixel = 0,
			Position = UDim2.new(0, 0, 1, 0),
			Size = UDim2.new(0, 0, 0, Sizes.Indicator),
			Visible = false,
			ZIndex = 3,
			Theme = { BackgroundColor3 = "Accent" },
			Parent = strip,
		})

		local tabbox = {
			Library = Library,
			Frame = shell,
			Tabs = {},
			Active = nil,
		}

		local function resizeShell()
			local active = tabbox.Active
			local inner = active and active.Layout.AbsoluteContentSize.Y or 0
			shell.Size = UDim2.new(1, 0, 0, math.ceil(TabboxStrip + inner + Sizes.GroupPad * 2))
		end

		local function placeIndicator(animate)
			local count = #tabbox.Tabs
			local index = tabbox.Active and table.find(tabbox.Tabs, tabbox.Active) or nil

			if not index or count == 0 then
				indicator.Visible = false
				return
			end

			indicator.Visible = true

			local position = UDim2.new((index - 1) / count, 0, 1, 0)
			local size = UDim2.new(1 / count, 0, 0, Sizes.Indicator)

			if animate then
				Library:Tween(indicator, { Position = position, Size = size }, Library.Motion.Fast)
			else
				indicator.Position = position
				indicator.Size = size
			end
		end

		local function layoutButtons()
			local count = #tabbox.Tabs
			if count == 0 then
				return
			end

			for index, entry in tabbox.Tabs do
				entry.Button.Position = UDim2.new((index - 1) / count, 0, 0, 0)
				entry.Button.Size = UDim2.new(1 / count, 0, 1, 0)
			end

			placeIndicator(false)
		end

		function tabbox:SetTab(target)
			if not target then
				return self
			end

			for _, entry in self.Tabs do
				local on = entry == target
				entry.Container.Visible = on
				retheme(entry.Label, { TextColor3 = on and "Font" or "FontDim" })
			end

			-- Slide the underline only if it was already somewhere; the first
			-- placement should not animate in from zero width.
			local placed = indicator.Visible

			self.Active = target
			placeIndicator(placed)
			target:Resize()

			return self
		end

		function tabbox:AddTab(name)
			local content = Library:Create("Frame", {
				Name = "Tab",
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Position = UDim2.fromOffset(0, TabboxStrip),
				Size = UDim2.new(1, 0, 1, -TabboxStrip),
				Visible = false,
				Parent = shell,
			})
			Util.Padding(content, Sizes.GroupPad, Sizes.GroupPad, Sizes.GroupPad, Sizes.GroupPad)

			local layout = Util.ListLayout(content, Sizes.RowGap)

			-- The label is a separate instance so switching tabs can retheme the
			-- text without wiping the button's hover colour out of the registry.
			local button = Library:Create("TextButton", {
				Name = "Button",
				AutoButtonColor = false,
				BorderSizePixel = 0,
				Position = UDim2.fromScale(0, 0),
				Size = UDim2.new(1, 0, 1, 0),
				Text = "",
				Theme = { BackgroundColor3 = "Panel" },
				Parent = strip,
			})

			local label = Library:Label({
				Name = "Label",
				Font = Library.Fonts.Title,
				Size = UDim2.fromScale(1, 1),
				Text = Library:Chrome(name or ""),
				TextSize = Sizes.TextSmall,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextXAlignment = Enum.TextXAlignment.Center,
				Parent = button,
			}, "FontDim")

			Library:BindHover(button, button, "Panel", "PanelRaised")

			local entry = newContainer(content, nil)
			entry.Type = "TabboxTab"
			entry.Name = name
			entry.Button = button
			entry.Label = label
			entry.Layout = layout
			entry.Tabbox = tabbox

			function entry:Recompute()
				resizeShell()
			end

			table.insert(tabbox.Tabs, entry)
			table.insert(tab.Boxes, entry)

			Library:GiveSignal(layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
				entry:Resize()
			end))

			Library:GiveSignal(button.MouseButton1Click:Connect(function()
				tabbox:SetTab(entry)
			end))

			layoutButtons()

			if #tabbox.Tabs == 1 then
				tabbox:SetTab(entry)
			end

			return entry
		end

		resizeShell()

		return tabbox
	end

	--==============================================================
	-- tab
	--==============================================================

	local function newColumn(page, side)
		local isLeft = side == "Left"

		local column = Library:Create("ScrollingFrame", {
			Name = side,
			-- Active so touch drag-scrolling works; the mouse wheel does not
			-- care either way.
			Active = true,
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			BottomImage = FLAT_SCROLL,
			CanvasSize = UDim2.fromOffset(0, 0),
			ElasticBehavior = Enum.ElasticBehavior.Never,
			Position = isLeft and UDim2.fromScale(0, 0) or UDim2.new(0.5, HalfGap, 0, 0),
			ScrollBarThickness = Sizes.ScrollBar,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			Size = UDim2.new(0.5, -HalfGap, 1, 0),
			TopImage = FLAT_SCROLL,
			VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
			Parent = page,
		})

		-- Owns the bar's colour and transparency from here on.
		Library:QuietScrollbar(column)

		-- Side padding is a hairline wide so a groupbox's UIStroke, which draws
		-- outside the frame, is not eaten by the ScrollingFrame's clipping.
		Util.Padding(column, ColumnTop, Sizes.Outline, Sizes.GroupGap, Sizes.Outline)
		Util.ListLayout(column, Sizes.GroupGap)

		return column
	end

	local Tab = {}
	Tab.__index = Tab

	function Tab:AddLeftGroupbox(name)
		return newGroupbox(self, "Left", name)
	end

	function Tab:AddRightGroupbox(name)
		return newGroupbox(self, "Right", name)
	end

	function Tab:AddLeftTabbox()
		return newTabbox(self, "Left")
	end

	function Tab:AddRightTabbox()
		return newTabbox(self, "Right")
	end

	function Tab:Show()
		self.Window:SetTab(self)
		return self
	end

	function Tab:Resize()
		for _, box in self.Boxes do
			box:Resize()
		end
		return self
	end

	--==============================================================
	-- window
	--==============================================================

	local WindowMeta = {}
	WindowMeta.__index = WindowMeta

	function WindowMeta:SetTitle(text)
		self.Title = tostring(text or "")
		self.TitleLabel.Text = Library:Chrome(self.Title)
		return self
	end

	function WindowMeta:SetFooter(text)
		self.Footer = tostring(text or "")
		self.FooterLabel.Text = Library:FormatLabel(self.Footer)
		return self
	end

	function WindowMeta:PlaceIndicator(animate)
		local count = #self.Tabs
		local index = self.ActiveTab and table.find(self.Tabs, self.ActiveTab) or nil

		if not index or count == 0 then
			self.Indicator.Visible = false
			return self
		end

		self.Indicator.Visible = true

		-- Read the active button's real geometry rather than recomputing an
		-- equal share. Tabs are sized to their own text now, so any independent
		-- arithmetic here would drift out from under them -- and the underline
		-- landing beside the tab it marks is worse than no underline at all.
		local button = self.ActiveTab.Button
		local position = UDim2.new(0, button.Position.X.Offset, 1, 0)
		local size = UDim2.new(0, button.Size.X.Offset, 0, Sizes.Indicator)

		if animate then
			Library:Tween(self.Indicator, { Position = position, Size = size }, Library.Motion.Fast)
		else
			self.Indicator.Position = position
			self.Indicator.Size = size
		end

		return self
	end

	--- Breathing room either side of a tab label, so adjacent tabs do not run
	--- into each other once they are sized to their own text.
	local TAB_PAD = 18
	--- Nothing narrower than this, however cramped the strip: a 12px tab is not
	--- a target, it is a smear.
	local TAB_MIN = 34

	function WindowMeta:LayoutTabs()
		local count = #self.Tabs
		if count == 0 then
			return self
		end

		-- Tabs are sized to their OWN TEXT, not to an equal share of the strip.
		--
		-- Equal shares are what made a long name unreadable next to a short one:
		-- with 11 tabs everything got 1/11 of the width, so "RAGE SETTINGS" was
		-- truncated to "RAGE SETTIN." while "TROLL" sat in a half-empty cell --
		-- and shrinking the window truncated every one of them to "LEGI...".
		-- Proportional widths mean a long label gives up the same FRACTION as a
		-- short one, so they stay legible together at any window size.
		local available = self.TabStrip.AbsoluteSize.X

		-- LETTERSPACING IS DROPPED BEFORE TEXT IS. Chrome() interleaves spaces,
		-- which roughly DOUBLES every label -- lovely with four tabs, fatal with
		-- eleven, where it is the difference between "RAGE SETTINGS" fitting and
		-- being cut to "RAGE SE.". Spacing is styling; the word is information,
		-- so measure both and spend the room on the word.
		local function measureAll(spaced)
			local widths, total = {}, 0
			for index, tab in self.Tabs do
				local text = spaced and Library:Chrome(tab.Name) or Library:FormatLabel(tab.Name)
				widths[index] = Util.TextSize(text, Sizes.TextSmall, Library.Fonts.Title).X + TAB_PAD
				total += widths[index]
			end
			return widths, total
		end

		local widths, total = measureAll(true)
		local spaced = true

		-- Unspaced whenever the spaced form does not fit -- including when
		-- neither fits, because the tighter text truncates less badly.
		if available > 0 and total > available then
			widths, total = measureAll(false)
			spaced = false
		end

		for _, tab in self.Tabs do
			tab.Label.Text = spaced and Library:Chrome(tab.Name) or Library:FormatLabel(tab.Name)
		end

		-- Before the first layout pass the strip has no width yet; natural widths
		-- stand until a resize brings us back through here.
		local scale = (available > 0 and total > 0) and (available / total) or 1

		local x = 0
		for index, tab in self.Tabs do
			local width = math.max(TAB_MIN, math.floor(widths[index] * scale))

			-- The last tab absorbs the rounding so the row ends flush with the
			-- strip instead of leaving a one-pixel gap that reads as a seam.
			if index == count and available > 0 then
				width = math.max(TAB_MIN, math.floor(available - x))
			end

			tab.Button.Position = UDim2.fromOffset(math.floor(x), 0)
			tab.Button.Size = UDim2.new(0, width, 1, 0)
			x += width
		end

		self:PlaceIndicator(false)
		return self
	end

	--- Accepts a tab object or a tab name.
	function WindowMeta:SetTab(target)
		local resolved = target

		if type(target) == "string" then
			resolved = nil
			for _, candidate in self.Tabs do
				if candidate.Name == target then
					resolved = candidate
					break
				end
			end
		end

		if type(resolved) ~= "table" or resolved.Window ~= self then
			return self
		end

		Library:ClosePopup()

		-- Only slide the underline when it already had a home.
		local placed = self.Indicator.Visible
		self.ActiveTab = resolved

		for _, candidate in self.Tabs do
			local on = candidate == resolved
			candidate.Page.Visible = on
			retheme(candidate.Label, { TextColor3 = on and "Font" or "FontDim" })
		end

		self:PlaceIndicator(placed)
		resolved:Resize()

		return self
	end

	function WindowMeta:AddTab(name)
		local page = Library:Create("Frame", {
			Name = "Page",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			Visible = false,
			Parent = self.Body,
		})

		local button = Library:Create("TextButton", {
			Name = "Tab",
			AutoButtonColor = false,
			BorderSizePixel = 0,
			Position = UDim2.fromScale(0, 0),
			Size = UDim2.new(1, 0, 1, 0),
			Text = "",
			Theme = { BackgroundColor3 = "Background" },
			Parent = self.TabStrip,
		})

		-- Text lives on its own label: SetTab rethemes the label, which would
		-- otherwise drop the button's hover colour out of the registry with it.
		local label = Library:Label({
			Name = "Label",
			Font = Library.Fonts.Title,
			Size = UDim2.fromScale(1, 1),
			Text = Library:Chrome(name or ""),
			TextSize = Sizes.TextSmall,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Center,
			Parent = button,
		}, "FontDim")

		Library:BindHover(button, button, "Background", "Panel")

		local tab = setmetatable({
			Library = Library,
			Window = self,
			Name = name or "",
			Page = page,
			Button = button,
			Label = label,
			Boxes = {},
			Order = { Left = 0, Right = 0 },
		}, Tab)

		tab.Left = newColumn(page, "Left")
		tab.Right = newColumn(page, "Right")

		table.insert(self.Tabs, tab)

		Library:GiveSignal(button.MouseButton1Click:Connect(function()
			self:SetTab(tab)
		end))

		self:LayoutTabs()

		if #self.Tabs == 1 then
			self:SetTab(tab)
		end

		return tab
	end

	--- Both addons ship with a folder already set, so this only fills in a
	--- manager whose folder a host script cleared. SetFolder is called rather
	--- than assigning `.Folder` because it also creates the directory on disk.
	local function defaultFolder(manager)
		if type(manager) ~= "table" or type(manager.SetFolder) ~= "function" then
			return
		end
		if type(manager.Folder) == "string" and manager.Folder ~= "" then
			return
		end
		manager:SetFolder(Library.Name)
	end

	--- The whole settings tab in one call: menu preferences, the theme editor
	--- and the config section. Every index it registers is added to the
	--- SaveManager ignore list, so a config file carries game settings only and
	--- never another machine's menu keybind.
	---
	--- Both addons are optional here. A build with either one stripped out still
	--- gets the Menu groupbox and a usable tab.
	function WindowMeta:AddSettingsTab(name)
		local tab = self:AddTab(type(name) == "string" and name ~= "" and name or "Settings")

		local menu = tab:AddLeftGroupbox("Menu")

		menu:AddKeyPicker(MENU_KEYBIND_INDEX, {
			Default = Library.MenuKeybind,
			Mode = "Toggle",
			Text = "Menu",
			-- The bind that opens the menu has no business in the keybind list:
			-- it is the one bind the user cannot forget.
			NoUI = true,
			Tooltip = "Opens and closes the menu",
			ChangedCallback = function(value)
				Library:SetMenuKeybind(value)
			end,
		})

		menu:AddToggle(WATERMARK_INDEX, {
			Text = "Watermark",
			Default = true,
			Callback = function(value)
				Library:SetWatermarkVisibility(value)
			end,
		})

		menu:AddToggle(KEYBIND_LIST_INDEX, {
			Text = "Keybind list",
			Default = true,
			Callback = function(value)
				Library:SetKeybindVisibility(value)
			end,
		})

		-- The recovery path for a panel dragged somewhere awkward -- or onto a
		-- screen edge that the next session's resolution no longer has.
		menu:AddButton({
			Text = "Reset HUD positions",
			Tooltip = "Move the watermark and keybind list back to the top left",
			Func = function()
				if type(Library.ResetHudLayout) ~= "function" then
					return
				end

				Library:ResetHudLayout()
				Library:Notify({
					Title = "HUD",
					Description = "Watermark and keybind list moved back to the top left",
					Time = 4,
					Good = true,
				})
			end,
		})

		menu:AddDivider()

		menu:AddButton({
			Text = "Unload",
			DoubleClick = true,
			Tooltip = "Double click to remove the menu",
			Func = function()
				Library:Unload()
			end,
		})

		local themeManager = Library.ThemeManager
		local saveManager = Library.SaveManager

		defaultFolder(themeManager)
		defaultFolder(saveManager)

		-- After the folders settle, so a host script that pointed the HUD
		-- somewhere of its own is read from there. Overlays is optional in a
		-- stripped build, hence the guard.
		if type(Library.LoadHudLayout) == "function" then
			Library:LoadHudLayout()
		end

		if type(saveManager) == "table" then
			-- Menu preferences belong to the person, not to the config. Both
			-- calls ADD to the ignore set, so whatever the host script already
			-- ignored survives.
			saveManager:IgnoreThemeSettings()
			saveManager:SetIgnoreIndexes({ MENU_KEYBIND_INDEX, WATERMARK_INDEX, KEYBIND_LIST_INDEX })

			saveManager:BuildConfigSection(tab)
		end

		if type(themeManager) == "table" then
			themeManager:ApplyToTab(tab)
		end

		return tab
	end

	--- Library:SetOpen drives this; it is required on every window.
	function WindowMeta:SetVisible(visible)
		visible = visible == true
		self.Shown = visible

		local fade = math.max(tonumber(Library.MenuFadeTime) or 0, 0)
		local info = TweenInfo.new(fade, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		local goal = visible and 0 or 1

		if visible then
			self.Frame.Visible = true
		end

		Library:Tween(self.Frame, { BackgroundTransparency = goal }, info)
		Library:Tween(self.Stroke, { Transparency = goal }, info)
		Library:Tween(self.Canvas, { GroupTransparency = goal }, info)

		self.FadeToken += 1
		local token = self.FadeToken

		if not visible then
			-- Only hide once this particular fade finishes: a re-open mid-fade
			-- bumps the token and this delayed call becomes a no-op.
			task.delay(fade, function()
				if Library.Unloaded then
					return
				end
				if self.FadeToken == token and not self.Shown then
					self.Frame.Visible = false
				end
			end)
		end

		return self
	end

	--==============================================================
	-- constructor
	--==============================================================

	function Library:CreateWindow(config)
		config = config or {}

		if type(config.MenuFadeTime) == "number" then
			Library.MenuFadeTime = config.MenuFadeTime
		end

		local sizeUDim = typeof(config.Size) == "UDim2" and config.Size
			or UDim2.fromOffset(Sizes.WindowWidth, Sizes.WindowHeight)

		local root, stroke = Library:Panel({
			Name = "Window",
			Active = true,
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			Position = typeof(config.Position) == "UDim2" and config.Position or UDim2.fromOffset(48, 48),
			Size = sizeUDim,
			Visible = false,
			Parent = Library.WindowHolder,
		}, "Background", "Outline")
		stroke.Transparency = 1

		-- Everything except the frame fill and its hairline lives in the canvas,
		-- so the menu fades as one object instead of a hundred transparencies.
		local canvas = Library:Create("CanvasGroup", {
			Name = "Canvas",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			GroupTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Parent = root,
		})

		Library:CornerTicks(canvas, "Accent")

		local titleBar = Library:Create("Frame", {
			Name = "TitleBar",
			Active = true,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, Sizes.TitleBar),
			ZIndex = 2,
			Parent = canvas,
		})

		local titleLabel = Library:Label({
			Name = "Title",
			Font = Library.Fonts.Title,
			Position = UDim2.fromOffset(TitlePad, 0),
			Size = UDim2.new(0.62, -TitlePad, 1, 0),
			Text = Library:Chrome(config.Title or Library.Name),
			TextSize = Sizes.TextTitle,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = titleBar,
		}, "Font")

		local footerLabel = Library:Label({
			Name = "Footer",
			Position = UDim2.new(0.62, 0, 0, 0),
			Size = UDim2.new(0.38, -TitlePad, 1, 0),
			Text = Library:FormatLabel(config.Footer or ("v" .. tostring(Library.Version))),
			TextSize = Sizes.TextSmall,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = titleBar,
		}, "FontDim")

		-- Rules are parented to the canvas, not to the bars, so no padding on a
		-- bar can ever shorten them.
		hairline(canvas, Sizes.TitleBar - Sizes.Outline, "Outline", 1)
		hairline(canvas, ChromeHeight - Sizes.Outline, "OutlineDim", 1)

		local tabStrip = Library:Create("Frame", {
			Name = "TabStrip",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(0, Sizes.TitleBar),
			Size = UDim2.new(1, 0, 0, Sizes.TabStrip),
			ZIndex = 2,
			Parent = canvas,
		})

		local indicator = Library:Create("Frame", {
			Name = "Indicator",
			AnchorPoint = Vector2.new(0, 1),
			BorderSizePixel = 0,
			Position = UDim2.new(0, 0, 1, 0),
			Size = UDim2.new(0, 0, 0, Sizes.Indicator),
			Visible = false,
			ZIndex = 3,
			Theme = { BackgroundColor3 = "Accent" },
			Parent = tabStrip,
		})

		local body = Library:Create("Frame", {
			Name = "Body",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(0, ChromeHeight),
			Size = UDim2.new(1, 0, 1, -ChromeHeight),
			Parent = canvas,
		})
		Util.Padding(body, Sizes.RowGap, Sizes.GroupPad, Sizes.GroupPad, Sizes.GroupPad)

		local window = setmetatable({
			Library = Library,
			Frame = root,
			Stroke = stroke,
			Canvas = canvas,
			TitleBar = titleBar,
			TitleLabel = titleLabel,
			FooterLabel = footerLabel,
			TabStrip = tabStrip,
			Indicator = indicator,
			Body = body,
			Tabs = {},
			ActiveTab = nil,
			Title = tostring(config.Title or Library.Name),
			Footer = tostring(config.Footer or ("v" .. tostring(Library.Version))),
			Shown = false,
			FadeToken = 0,
		}, WindowMeta)

		-- Tab widths are OFFSETS now (sized to their own text), so unlike the old
		-- equal-share scale they do not follow the window on their own. Without
		-- this the strip keeps whatever width it was first laid out at: resize
		-- the window wider and the tabs stay bunched in the left of an empty
		-- strip; resize it narrower and they overflow past the edge.
		Library:GiveSignal(tabStrip:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			window:LayoutTabs()
		end))

		Library:MakeDraggable(titleBar, root)

		if config.Center and not (typeof(config.Position) == "UDim2") then
			-- AbsoluteSize is still zero this frame, so centre from the intended
			-- size and retry once the layout has run if the viewport is not up yet.
			local function centre()
				local viewport = Library.ScreenGui.AbsoluteSize
				if viewport.X <= 0 or viewport.Y <= 0 then
					return false
				end

				local width = sizeUDim.X.Scale * viewport.X + sizeUDim.X.Offset
				local height = sizeUDim.Y.Scale * viewport.Y + sizeUDim.Y.Offset

				root.Position = UDim2.fromOffset(
					math.floor((viewport.X - width) / 2),
					math.floor((viewport.Y - height) / 2)
				)
				return true
			end

			if not centre() then
				-- The ScreenGui has not been measured yet; try again each frame
				-- until it has, then stop.
				local connection
				connection = Library:GiveSignal(Library.RenderStepped:Connect(function()
					if Library.Unloaded or centre() then
						connection:Disconnect()
					end
				end))
			end
		end

		if config.Resizable ~= false then
			local grip = Library:Create("Frame", {
				Name = "Grip",
				AnchorPoint = Vector2.new(1, 1),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Position = UDim2.new(1, -3, 1, -3),
				Size = UDim2.fromOffset(16, 16),
				ZIndex = 11,
				Parent = canvas,
			})

			for index, length in { 9, 5 } do
				Library:Create("Frame", {
					Name = ("Mark%d"):format(index),
					AnchorPoint = Vector2.new(1, 1),
					BorderSizePixel = 0,
					Position = UDim2.new(1, 0, 1, -(index - 1) * 3),
					Size = UDim2.fromOffset(length, Sizes.Outline),
					ZIndex = 11,
					Theme = { BackgroundColor3 = "Outline" },
					Parent = grip,
				})
			end

			local hit = Library:HitButton(grip, { ZIndex = 12 })

			local resizing = false
			local startMouse = Vector2.zero
			local startSize = Vector2.zero

			Library:GiveSignal(hit.InputBegan:Connect(function(input)
				if
					input.UserInputType ~= Enum.UserInputType.MouseButton1
					and input.UserInputType ~= Enum.UserInputType.Touch
				then
					return
				end
				resizing = true
				-- Raw cursor: the grip works purely off the delta below, where
				-- a constant gui inset cancels. Nothing here is compared to an
				-- AbsolutePosition, so there is nothing to convert.
				startMouse = Util.MousePosition()
				startSize = root.AbsoluteSize
				Library:ClosePopup()
			end))

			Library:GiveSignal(Library.InputChanged:Connect(function(input)
				if not resizing then
					return
				end
				if
					input.UserInputType ~= Enum.UserInputType.MouseMovement
					and input.UserInputType ~= Enum.UserInputType.Touch
				then
					return
				end

				local delta = Util.MousePosition() - startMouse
				local viewport = Library.ScreenGui.AbsoluteSize

				local width = Util.Clamp(
					startSize.X + delta.X,
					Sizes.WindowMinWidth,
					math.max(Sizes.WindowMinWidth, viewport.X)
				)
				local height = Util.Clamp(
					startSize.Y + delta.Y,
					Sizes.WindowMinHeight,
					math.max(Sizes.WindowMinHeight, viewport.Y)
				)

				root.Size = UDim2.fromOffset(math.floor(width), math.floor(height))
			end))

			Library:GiveSignal(Library.InputEnded:Connect(function(input)
				if
					input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch
				then
					resizing = false
				end
			end))
		end

		table.insert(Library.Windows, window)

		if config.AutoShow then
			Library:SetOpen(true)
		end

		return window
	end
end

return Window
end

__modules["addons/SaveManager"] = function()

-- Sable :: addons/SaveManager
--
-- Serialises Library.Toggles + Library.Options by index to
-- <folder>/settings/<name>.json, and rebuilds them by calling :SetValue so the
-- script's own callbacks run exactly as if the user had clicked.
--
-- Also turns a config into one line of paste-safe text ("SABLE1:...") so it can
-- be handed to someone else, and back again. Export copies to the clipboard;
-- import reads a TextBox, because setclipboard is near-universal among
-- executors and a working getclipboard is not.
--
-- Reached as Library.SaveManager -- the spine calls :SetLibrary for you; the
-- method survives being called again so ported scripts keep working. Every
-- filesystem call goes through Util.FS, which no-ops outside an executor, so
-- the buttons still respond there -- they just report that nothing was written.

local Util = require("Util")

local NAME_INDEX = "SaveManager_ConfigName"
local LIST_INDEX = "SaveManager_ConfigList"
local SHARE_INDEX = "SaveManager_ConfigShare"

--- Fallback for :IgnoreThemeSettings when the ThemeManager is not reachable.
--- Mirrors ThemeManager.Indexes; keep the two in step.
local THEME_INDEXES = {
	"ThemeManager_ThemeList",
	"ThemeManager_CustomName",
	"ThemeManager_CustomList",
	"ThemeManager_AccentColor",
	"ThemeManager_BackgroundColor",
	"ThemeManager_PanelColor",
	"ThemeManager_OutlineColor",
	"ThemeManager_FontColor",
}

local SaveManager = {}

SaveManager.Library = nil :: any
SaveManager.Folder = "Sable"
SaveManager.AutoloadName = nil :: any
SaveManager.Indexes = { NAME_INDEX, LIST_INDEX, SHARE_INDEX }

--- index -> true. Its own three controls are always skipped: a config that
--- restored the config picker -- or pasted a whole other config into the import
--- box -- would fight with the user.
SaveManager.Ignore = {
	[NAME_INDEX] = true,
	[LIST_INDEX] = true,
	[SHARE_INDEX] = true,
}

--- Elements built by :BuildConfigSection.
SaveManager.Objects = {}

--==============================================================
-- serialisation
--==============================================================

--- Element -> plain JSON-safe entry, or nil for types configs do not carry.
local function serialize(index, element)
	local kind = element.Type

	if kind == "Toggle" then
		return { type = "Toggle", idx = index, value = element.Value == true }
	elseif kind == "Slider" then
		local number = tonumber(element.Value)
		if not number then
			return nil
		end
		return { type = "Slider", idx = index, value = number }
	elseif kind == "Input" then
		return { type = "Input", idx = index, value = tostring(element.Value or "") }
	elseif kind == "Dropdown" then
		local value = element.Value

		if type(value) == "table" then
			local set = {}
			for name, on in value do
				if on then
					set[tostring(name)] = true
				end
			end
			return { type = "Dropdown", idx = index, multi = true, value = set }
		end

		-- AllowNull dropdowns need the empty selection to survive a round trip,
		-- and JSON has no way to store a nil field.
		if value == nil then
			return { type = "Dropdown", idx = index, multi = false, null = true, value = "" }
		end

		return { type = "Dropdown", idx = index, multi = false, value = tostring(value) }
	elseif kind == "ColorPicker" then
		if typeof(element.Value) ~= "Color3" then
			return nil
		end
		return {
			type = "ColorPicker",
			idx = index,
			value = {
				hex = Util.ToHex(element.Value),
				transparency = tonumber(element.Transparency),
			},
		}
	elseif kind == "KeyPicker" then
		return {
			type = "KeyPicker",
			idx = index,
			value = {
				key = tostring(element.Value or "None"),
				mode = tostring(element.Mode or "Toggle"),
			},
		}
	end

	return nil
end

--- Entry -> element, through :SetValue so callbacks fire. Returns false when
--- the payload is malformed; the caller skips it silently.
local function deserialize(element, entry)
	local kind = element.Type
	local value = entry.value

	if kind == "Toggle" then
		if type(value) ~= "boolean" then
			return false
		end
		element:SetValue(value)
	elseif kind == "Slider" then
		local number = tonumber(value)
		if not number then
			return false
		end
		element:SetValue(number)
	elseif kind == "Input" then
		if type(value) ~= "string" then
			return false
		end
		element:SetValue(value)
	elseif kind == "Dropdown" then
		if type(value) == "table" then
			local set = {}
			for name, on in value do
				if on then
					set[tostring(name)] = true
				end
			end
			element:SetValue(set)
		elseif entry.null == true then
			element:SetValue(nil)
		elseif type(value) == "string" then
			element:SetValue(value)
		else
			return false
		end
	elseif kind == "ColorPicker" then
		if type(value) ~= "table" then
			return false
		end

		local color = Util.FromHex(value.hex or value[1])
		if not color then
			return false
		end

		-- Transparency rides along with the colour, so stage it before the
		-- repaint that :SetValue triggers.
		local transparency = tonumber(value.transparency or value[2])
		if transparency and element.Transparency ~= nil then
			if type(element.SetTransparency) == "function" then
				element:SetTransparency(transparency)
			else
				element.Transparency = transparency
			end
		end

		element:SetValue(color)
	elseif kind == "KeyPicker" then
		if type(value) ~= "table" then
			return false
		end

		local key = value.key or value[1]
		if type(key) ~= "string" then
			return false
		end

		local mode = value.mode or value[2]
		element:SetValue({ key, type(mode) == "string" and mode or element.Mode })
	else
		return false
	end

	return true
end

--==============================================================
-- share encoding
--==============================================================

-- A shared config is ONE line: "SABLE1:" followed by base64 of a small payload.
-- The version lives in the prefix so a build that cannot read a string can say
-- so instead of guessing, and the payload's first byte says how the JSON inside
-- was packed -- MODE_RAW for plain text, MODE_LZW for the compressor below.
-- That byte is what lets compression be skipped for a payload it does not help,
-- or fail safe, without a second prefix to explain.
local SHARE_PREFIX = "SABLE"
local SHARE_VERSION = 1
local SHARE_PATTERN = "^" .. SHARE_PREFIX .. "(%d+):(.*)$"

local MODE_RAW = "R"
local MODE_LZW = "Z"

--- LZW codes are a fixed 12 bits, two to every three bytes, and the dictionary
--- FREEZES at this size rather than resetting. A reset has to be synchronised
--- with a decoder that is always exactly one entry behind the encoder; a frozen
--- dictionary needs no synchronisation at all, and configs never come close.
local LZW_MAX_CODES = 4096

local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local B64_VALUE = {}
for index = 1, #B64_ALPHABET do
	B64_VALUE[B64_ALPHABET:sub(index, index)] = index - 1
end
-- Decode-only tolerance: chat clients and forums love rewriting a pasted "+/"
-- into the url-safe "-_". We never emit those, but we accept them.
B64_VALUE["-"] = 62
B64_VALUE["_"] = 63

local function b64Char(value)
	return B64_ALPHABET:sub(value + 1, value + 1)
end

local function base64Encode(data)
	local out = {}
	local length = #data
	local index = 1

	while index + 2 <= length do
		local a, b, c = data:byte(index, index + 2)
		local packed = a * 65536 + b * 256 + c
		out[#out + 1] = b64Char(math.floor(packed / 262144))
			.. b64Char(math.floor(packed / 4096) % 64)
			.. b64Char(math.floor(packed / 64) % 64)
			.. b64Char(packed % 64)
		index += 3
	end

	local remaining = length - index + 1
	if remaining == 1 then
		local a = data:byte(index)
		out[#out + 1] = b64Char(math.floor(a / 4)) .. b64Char((a % 4) * 16) .. "=="
	elseif remaining == 2 then
		local a, b = data:byte(index, index + 1)
		local packed = a * 256 + b
		out[#out + 1] = b64Char(math.floor(packed / 1024))
			.. b64Char(math.floor(packed / 16) % 64)
			.. b64Char((packed % 16) * 4)
			.. "="
	end

	return table.concat(out)
end

--- Returns nil for anything that is not base64 rather than erroring: this runs
--- on text a user pasted, so "damaged" is an ordinary outcome, not a fault.
local function base64Decode(text)
	if type(text) ~= "string" then
		return nil
	end

	-- Whitespace anywhere is fine: a long string wrapped by a chat client is
	-- still the same string once the newlines come out.
	local clean = (text:gsub("%s", ""))
	clean = (clean:gsub("=+$", ""))
	if clean:find("=", 1, true) then
		return nil
	end

	-- Four base64 digits carry three bytes; a lone leftover digit carries none,
	-- so that length can only mean the string was cut short.
	if #clean % 4 == 1 then
		return nil
	end

	local out = {}
	local accumulator, bits = 0, 0

	for index = 1, #clean do
		local value = B64_VALUE[clean:sub(index, index)]
		if value == nil then
			return nil
		end

		accumulator = accumulator * 64 + value
		bits += 6

		if bits >= 8 then
			bits -= 8
			local scale = 2 ^ bits
			local byte = math.floor(accumulator / scale)
			accumulator -= byte * scale
			out[#out + 1] = string.char(byte)
		end
	end

	return table.concat(out)
end

--- Textbook LZW over the byte string. Single bytes are their own codes, so the
--- dictionary only ever holds sequences of two or more.
local function lzwCompress(data)
	local dictionary = {}
	local nextCode = 256
	local codes = {}
	local word = nil

	local function codeOf(text)
		if #text == 1 then
			return text:byte()
		end
		return dictionary[text]
	end

	for index = 1, #data do
		local char = data:sub(index, index)

		if word == nil then
			word = char
		else
			local candidate = word .. char
			if dictionary[candidate] then
				word = candidate
			else
				codes[#codes + 1] = codeOf(word)
				if nextCode < LZW_MAX_CODES then
					dictionary[candidate] = nextCode
					nextCode += 1
				end
				word = char
			end
		end
	end

	if word ~= nil then
		codes[#codes + 1] = codeOf(word)
	end

	return codes
end

--- The decoder's dictionary is always one entry behind the encoder's, which is
--- why a code can legitimately name the entry that is about to be added -- the
--- KwKwK case below. Any code beyond that is corruption, and returns nil.
local function lzwDecompress(codes)
	local entries = {}
	local nextCode = 256
	local out = {}
	local previous = nil

	for _, code in codes do
		local entry
		if code < 256 then
			entry = string.char(code)
		elseif entries[code] then
			entry = entries[code]
		elseif code == nextCode and previous ~= nil then
			entry = previous .. previous:sub(1, 1)
		else
			return nil
		end

		out[#out + 1] = entry

		if previous ~= nil and nextCode < LZW_MAX_CODES then
			entries[nextCode] = previous .. entry:sub(1, 1)
			nextCode += 1
		end

		previous = entry
	end

	return table.concat(out)
end

--- Two 12-bit codes per three bytes. An odd final code takes two bytes and
--- leaves a zero nibble, which is why the count is stored separately.
local function packCodes(codes)
	local out = {}
	local index = 1
	local count = #codes

	while index <= count do
		local first = codes[index]
		local second = codes[index + 1]

		if second then
			out[#out + 1] = string.char(
				math.floor(first / 16),
				(first % 16) * 16 + math.floor(second / 256),
				second % 256
			)
			index += 2
		else
			out[#out + 1] = string.char(math.floor(first / 16), (first % 16) * 16)
			index += 1
		end
	end

	return table.concat(out)
end

local function unpackCodes(data, count)
	local codes = {}
	local index = 1

	while #codes < count do
		local first, second, third = data:byte(index, index + 2)
		if first == nil or second == nil then
			return nil
		end

		codes[#codes + 1] = first * 16 + math.floor(second / 16)

		if #codes < count then
			if third == nil then
				return nil
			end
			codes[#codes + 1] = (second % 16) * 256 + third
		end

		index += 3
	end

	return codes
end

local function writeUInt32(value)
	return string.char(
		math.floor(value / 16777216) % 256,
		math.floor(value / 65536) % 256,
		math.floor(value / 256) % 256,
		value % 256
	)
end

local function readUInt32(data, index)
	local a, b, c, d = data:byte(index, index + 3)
	if a == nil or b == nil or c == nil or d == nil then
		return nil
	end
	return a * 16777216 + b * 65536 + c * 256 + d
end

--- Payload -> JSON text, or nil plus a reason a human can act on.
local function unpackPayload(payload)
	local mode = payload:sub(1, 1)

	if mode == MODE_RAW then
		return payload:sub(2)
	elseif mode ~= MODE_LZW then
		return nil, "Config string uses a format this build does not know"
	end

	local count = readUInt32(payload, 2)
	if not count then
		return nil, "Config string is damaged (payload is cut short)"
	end

	local codes = unpackCodes(payload:sub(6), count)
	if not codes then
		return nil, "Config string is damaged (payload is cut short)"
	end

	local text = lzwDecompress(codes)
	if not text then
		return nil, "Config string is damaged (could not be unpacked)"
	end

	return text
end

--- JSON text -> the payload the base64 carries.
---
--- The compressed form is DECODED and compared before it is used. Compression
--- is an optimisation; correctness is not. If the two ever disagree -- or if
--- compressing did not actually save anything -- the plain payload ships, and
--- the mode byte tells the far end which it got.
local function packPayload(json)
	local codes = lzwCompress(json)
	local compressed = MODE_LZW .. writeUInt32(#codes) .. packCodes(codes)

	if #compressed < #json + 1 and unpackPayload(compressed) == json then
		return compressed
	end

	return MODE_RAW .. json
end

--==============================================================
-- plumbing
--==============================================================

local function notify(Library, description, kind)
	if not Library or not Library.Notify then
		return
	end
	Library:Notify({
		Title = "Config",
		Description = description,
		Time = 4,
		Good = kind == "good",
		Risk = kind == "risk",
	})
end

function SaveManager:SetLibrary(Library)
	if type(Library) ~= "table" then
		return self
	end
	self.Library = Library
	return self
end

function SaveManager:SetFolder(path)
	if type(path) == "string" and path ~= "" then
		self.Folder = path
	end
	self:BuildFolders()
	return self
end

function SaveManager:SettingsFolder()
	return self.Folder .. "/settings"
end

function SaveManager:ConfigPath(name)
	return ("%s/%s.json"):format(self:SettingsFolder(), name)
end

function SaveManager:AutoloadPath()
	return self:SettingsFolder() .. "/autoload.txt"
end

function SaveManager:BuildFolders()
	if not Util.FS.Available() then
		return false
	end
	return Util.FS.EnsureFolder(self:SettingsFolder())
end

--- Accepts either an array of indexes or a set; both forms show up in scripts
--- ported from other libraries.
function SaveManager:SetIgnoreIndexes(list)
	if type(list) ~= "table" then
		return self
	end

	for key, value in list do
		if type(key) == "number" then
			if value ~= nil then
				self.Ignore[value] = true
			end
		else
			self.Ignore[key] = value == true
		end
	end

	return self
end

function SaveManager:IgnoreThemeSettings()
	local manager = self.Library and self.Library.ThemeManager
	local indexes = (type(manager) == "table" and type(manager.Indexes) == "table") and manager.Indexes
		or THEME_INDEXES

	for _, index in indexes do
		self.Ignore[index] = true
	end

	return self
end

--- Config names become file names, so anything that could walk out of the
--- settings folder is stripped rather than rejected. Leading dots go too:
--- "../../evil" has to land on "evil", not on a hidden file.
function SaveManager:Sanitize(name)
	if type(name) ~= "string" then
		return nil
	end

	name = name:gsub("[^%w%-%. _]", "")
	name = name:gsub("^[%.%s]+", ""):gsub("[%.%s]+$", "")

	if name == "" or name == "autoload" then
		return nil
	end

	return name
end

--==============================================================
-- config data
--==============================================================

function SaveManager:Collect()
	local Library = self.Library
	local objects = {}

	local function scan(store)
		if type(store) ~= "table" then
			return
		end

		-- Sorted so a config file diffs cleanly between saves.
		for _, index in Util.SortedKeys(store) do
			local element = store[index]
			if type(element) == "table" and not self.Ignore[index] then
				local ok, entry = pcall(serialize, index, element)
				if ok and entry then
					table.insert(objects, entry)
				end
			end
		end
	end

	scan(Library and Library.Toggles)
	scan(Library and Library.Options)

	return objects
end

--- Returns how many entries were applied. Anything unknown, ignored, or of the
--- wrong shape is skipped without erroring.
function SaveManager:Apply(objects)
	local Library = self.Library
	if not Library or type(objects) ~= "table" then
		return 0
	end

	local applied = 0

	-- Selecting a theme clears custom colours and applies the whole preset, so
	-- it has to land BEFORE the per-key colour entries. Collect() emits indexes
	-- alphabetically, which put ThemeManager_ThemeList last and silently threw
	-- away every custom colour the config had just restored.
	local themeListIndex = Library.ThemeManager and Library.ThemeManager.ListIndex
	local ordered, rest = {}, {}
	for _, entry in objects do
		if themeListIndex and type(entry) == "table" and entry.idx == themeListIndex then
			table.insert(ordered, entry)
		else
			table.insert(rest, entry)
		end
	end
	table.move(rest, 1, #rest, #ordered + 1, ordered)

	for _, entry in ordered do
		if type(entry) == "table" and entry.idx ~= nil and not self.Ignore[entry.idx] then
			local element = Library.Toggles[entry.idx] or Library.Options[entry.idx]
			if type(element) == "table" and element.Type == entry.type then
				local ok, result = pcall(deserialize, element, entry)
				if ok and result then
					applied += 1
				end
			end
		end
	end

	return applied
end

function SaveManager:ConfigList()
	local list = {}

	for _, path in Util.FS.List(self:SettingsFolder()) do
		if type(path) == "string" and path:sub(-5) == ".json" then
			local stem = Util.FS.Stem(path, ".json")
			if stem ~= "" then
				table.insert(list, stem)
			end
		end
	end

	table.sort(list)
	return list
end

--==============================================================
-- operations
--==============================================================

function SaveManager:Save(name)
	local Library = self.Library

	local clean = self:Sanitize(name)
	if not clean then
		notify(Library, "Enter a valid config name", "risk")
		return false
	end

	if not Util.FS.Available() then
		notify(Library, "Filesystem unavailable", "risk")
		return false
	end

	self:BuildFolders()

	local written = Util.FS.WriteJSON(self:ConfigPath(clean), {
		name = clean,
		version = 1,
		objects = self:Collect(),
	})

	if not written then
		notify(Library, ("Could not write %s"):format(clean), "risk")
		return false
	end

	notify(Library, ("Saved %s"):format(clean), "good")
	self:RefreshConfigList()

	return true
end

function SaveManager:Load(name)
	local Library = self.Library

	local clean = self:Sanitize(name)
	if not clean then
		notify(Library, "Select a config first", "risk")
		return false
	end

	if not Util.FS.Available() then
		notify(Library, "Filesystem unavailable", "risk")
		return false
	end

	local data = Util.FS.ReadJSON(self:ConfigPath(clean))
	if type(data) ~= "table" or type(data.objects) ~= "table" then
		notify(Library, ("%s could not be read"):format(clean), "risk")
		return false
	end

	local applied = self:Apply(data.objects)
	notify(Library, ("Loaded %s (%d values)"):format(clean, applied), "good")

	return true
end

function SaveManager:Delete(name)
	local Library = self.Library

	local clean = self:Sanitize(name)
	if not clean then
		notify(Library, "Select a config first", "risk")
		return false
	end

	if not Util.FS.Available() then
		notify(Library, "Filesystem unavailable", "risk")
		return false
	end

	local path = self:ConfigPath(clean)
	if not Util.FS.IsFile(path) then
		notify(Library, ("%s does not exist"):format(clean), "risk")
		return false
	end

	if not Util.FS.Delete(path) then
		notify(Library, ("Could not delete %s"):format(clean), "risk")
		return false
	end

	if self.AutoloadName == clean then
		self:ClearAutoload()
	end

	notify(Library, ("Deleted %s"):format(clean), "good")
	self:RefreshConfigList()

	return true
end

function SaveManager:SetAutoload(name)
	local Library = self.Library

	local clean = self:Sanitize(name)
	if not clean then
		notify(Library, "Select a config first", "risk")
		return false
	end

	if not Util.FS.Available() then
		notify(Library, "Filesystem unavailable", "risk")
		return false
	end

	if not Util.FS.IsFile(self:ConfigPath(clean)) then
		notify(Library, ("%s does not exist"):format(clean), "risk")
		return false
	end

	self:BuildFolders()

	if not Util.FS.Write(self:AutoloadPath(), clean) then
		notify(Library, "Could not write autoload", "risk")
		return false
	end

	self.AutoloadName = clean
	self:UpdateAutoloadLabel()
	notify(Library, ("%s will autoload"):format(clean), "good")

	return true
end

function SaveManager:ClearAutoload()
	Util.FS.Delete(self:AutoloadPath())
	self.AutoloadName = nil
	self:UpdateAutoloadLabel()
	return true
end

--- Reads (and caches) the autoload name without loading it.
function SaveManager:ReadAutoload()
	local contents = Util.FS.Read(self:AutoloadPath())
	self.AutoloadName = self:Sanitize(contents)
	return self.AutoloadName
end

function SaveManager:LoadAutoloadConfig()
	local name = self:ReadAutoload()
	if not name then
		return false
	end

	self:UpdateAutoloadLabel()
	return self:Load(name)
end

--==============================================================
-- sharing
--==============================================================

--- Config -> one line of paste-safe text, or nil plus a reason.
---
--- A name encodes that saved config exactly as it sits on disk; no name encodes
--- what is on screen right now, so a config can be shared without saving it
--- first.
function SaveManager:ExportConfig(name)
	local objects, label

	if name == nil then
		objects, label = self:Collect(), nil
	else
		local clean = self:Sanitize(name)
		if not clean then
			return nil, "Select a config first"
		end

		if not Util.FS.Available() then
			return nil, "Filesystem unavailable"
		end

		local data = Util.FS.ReadJSON(self:ConfigPath(clean))
		if type(data) ~= "table" or type(data.objects) ~= "table" then
			return nil, ("%s could not be read"):format(clean)
		end

		objects, label = data.objects, clean
	end

	if #objects == 0 then
		return nil, "This config holds no values to share"
	end

	local ok, json = pcall(function()
		return Util.Services.Http:JSONEncode({
			name = label,
			version = 1,
			objects = objects,
		})
	end)

	if not ok or type(json) ~= "string" then
		return nil, "Could not encode this config"
	end

	return ("%s%d:%s"):format(SHARE_PREFIX, SHARE_VERSION, base64Encode(packPayload(json)))
end

--- Text -> config table, or nil plus a reason. Pure: no elements are touched,
--- nothing is written, nothing is notified. Every failure is a return value,
--- because this is the one entry point fed arbitrary text by a human.
function SaveManager:DecodeConfig(text)
	if type(text) ~= "string" then
		return nil, "Paste a config string first"
	end

	local trimmed = (text:gsub("^%s+", ""))
	trimmed = (trimmed:gsub("%s+$", ""))
	if trimmed == "" then
		return nil, "Paste a config string first"
	end

	local version, body = trimmed:match(SHARE_PATTERN)
	if not version then
		return nil, ("Not a Sable config string (it must start with %s%d:)"):format(SHARE_PREFIX, SHARE_VERSION)
	end

	if tonumber(version) ~= SHARE_VERSION then
		return nil, ("Config string is version %s; this build reads version %d"):format(version, SHARE_VERSION)
	end

	local payload = base64Decode(body)
	if not payload then
		return nil, "Config string is damaged (unreadable characters)"
	end

	-- An empty body decodes cleanly to nothing at all, which is a different
	-- fault from a damaged one: the string was cut off at the prefix.
	if payload == "" then
		return nil, "Config string carries nothing after the prefix"
	end

	local json, reason = unpackPayload(payload)
	if not json then
		return nil, reason or "Config string is damaged"
	end

	local ok, decoded = pcall(function()
		return Util.Services.Http:JSONDecode(json)
	end)

	if not ok then
		return nil, "Config string is damaged (contents are not readable)"
	end

	if type(decoded) ~= "table" then
		return nil, ("Config string decoded to a %s, not a config"):format(type(decoded))
	end

	if type(decoded.objects) ~= "table" then
		return nil, "That string decoded, but it is not a config"
	end

	return decoded
end

--- Applies a shared string to the live elements, and -- when a name is given --
--- saves it so it survives the session.
---
--- The FILE is the payload verbatim, not a re-collect of what landed: entries
--- for elements this hub does not have are then still there for the hub that
--- does, and the saved config is byte-for-byte the one that was shared.
function SaveManager:ImportConfig(text, name)
	local Library = self.Library

	local data, reason = self:DecodeConfig(text)
	if not data then
		notify(Library, reason, "risk")
		return false, reason
	end

	local applied = self:Apply(data.objects)

	if type(name) ~= "string" or name == "" then
		notify(Library, ("Imported %d value(s)"):format(applied), "good")
		return true
	end

	-- Saving is the optional half. The values are already in, so a failure past
	-- this point reports what did and did not happen rather than claiming the
	-- whole import failed.
	local clean = self:Sanitize(name)
	if not clean then
		notify(Library, ("Imported %d value(s); the config name is not usable"):format(applied), "risk")
		return true
	end

	if not Util.FS.Available() then
		notify(Library, ("Imported %d value(s); filesystem unavailable, not saved"):format(applied), "risk")
		return true
	end

	self:BuildFolders()

	local written = Util.FS.WriteJSON(self:ConfigPath(clean), {
		name = clean,
		version = 1,
		objects = data.objects,
	})

	if not written then
		notify(Library, ("Imported %d value(s); could not save %s"):format(applied, clean), "risk")
		return true
	end

	self:RefreshConfigList()
	notify(Library, ("Imported %d value(s), saved as %s"):format(applied, clean), "good")

	return true
end

--- Export + clipboard. Returns the string as well, because a host with no
--- working setclipboard still produced one -- the caller can print it, and the
--- user is told the clipboard was the part that failed, not the export.
function SaveManager:CopyConfig(name)
	local Library = self.Library

	local text, reason = self:ExportConfig(name)
	if not text then
		notify(Library, reason or "Could not export this config", "risk")
		return false, nil, reason
	end

	if not Util.SetClipboard(text) then
		notify(Library, "Clipboard unavailable, nothing was copied", "risk")
		return false, text
	end

	local what = name ~= nil and (self:Sanitize(name) or tostring(name)) or "the current values"
	notify(Library, ("Copied %s to the clipboard (%d chars)"):format(what, #text), "good")

	return true, text
end

--==============================================================
-- ui
--==============================================================

function SaveManager:UpdateAutoloadLabel()
	local label = self.Objects.AutoloadLabel
	if label and label.SetText then
		label:SetText(("Autoload: %s"):format(self.AutoloadName or "none"))
	end
	return self
end

function SaveManager:RefreshConfigList()
	local list = self:ConfigList()

	local dropdown = self.Objects.List
	if dropdown and dropdown.SetValues then
		dropdown:SetValues(list)
	end

	return list
end

--- Whatever the list is pointing at, or nil when nothing is selected.
function SaveManager:Selected()
	local dropdown = self.Objects.List
	local value = dropdown and dropdown.Value
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

function SaveManager:BuildConfigSection(tab)
	local Library = self.Library

	if not Library then
		warn("[Sable] SaveManager:BuildConfigSection called before :SetLibrary")
		return tab
	end

	local groupbox = tab
	if type(tab) == "table" and tab.AddRightGroupbox then
		groupbox = tab:AddRightGroupbox("Configuration")
	end
	if type(groupbox) ~= "table" or not groupbox.AddInput then
		warn("[Sable] SaveManager:BuildConfigSection needs a tab or groupbox")
		return groupbox
	end

	self:BuildFolders()
	self:ReadAutoload()

	local nameInput = groupbox:AddInput(NAME_INDEX, {
		Text = "Config name",
		Placeholder = "name",
		MaxLength = 40,
		Tooltip = "Used by CREATE",
	})
	self.Objects.Name = nameInput

	self.Objects.List = groupbox:AddDropdown(LIST_INDEX, {
		Text = "Config list",
		Values = self:ConfigList(),
		Default = 1,
		AllowNull = true,
		Tooltip = "Configs found on disk",
	})

	--- The typed name wins for CREATE; every other action works on the list
	--- selection and falls back to the typed name.
	local function target()
		return self:Selected() or (nameInput and nameInput.Value)
	end

	local create = groupbox:AddButton({
		Text = "Create",
		Tooltip = "Write the current values to the typed name",
		Func = function()
			self:Save(nameInput and nameInput.Value)
		end,
	})

	if create and create.AddButton then
		create:AddButton({
			Text = "Overwrite",
			Tooltip = "Write the current values over the selected config",
			Func = function()
				self:Save(target())
			end,
		})
	end

	local load = groupbox:AddButton({
		Text = "Load",
		Tooltip = "Apply the selected config",
		Func = function()
			self:Load(target())
		end,
	})

	if load and load.AddButton then
		load:AddButton({
			Text = "Delete",
			DoubleClick = true,
			Tooltip = "Double click to delete the selected config",
			Func = function()
				self:Delete(target())
			end,
		})
	end

	groupbox:AddButton({
		Text = "Refresh list",
		Tooltip = "Re-read the settings folder",
		Func = function()
			local list = self:RefreshConfigList()
			notify(Library, ("%d config(s) on disk"):format(#list))
		end,
	})

	groupbox:AddButton({
		Text = "Set as autoload",
		Tooltip = "Load the selected config on the next run",
		Func = function()
			self:SetAutoload(target())
		end,
	})

	self.Objects.AutoloadLabel = groupbox:AddLabel("Autoload: none")
	self:UpdateAutoloadLabel()

	-- Sharing. Export writes to the clipboard, import reads a field: setclipboard
	-- is near-universal among executors and a working getclipboard is not, so the
	-- paste has to be done by the user, in a box.
	if groupbox.AddSection then
		groupbox:AddSection("Share")
	else
		groupbox:AddDivider()
	end

	groupbox:AddButton({
		Text = "Copy config",
		Tooltip = "Copy the selected config, or the current values, as one shareable line",
		Func = function()
			self:CopyConfig(self:Selected())
		end,
	})

	local shareInput = groupbox:AddInput(SHARE_INDEX, {
		Text = "Shared string",
		Placeholder = ("%s%d:"):format(SHARE_PREFIX, SHARE_VERSION),
		-- A paste field the box empties the moment it is clicked would lose the
		-- pasted string on the way to reading it back.
		ClearTextOnFocus = false,
		Tooltip = "Paste a config string someone sent you",
	})
	self.Objects.Share = shareInput

	groupbox:AddButton({
		Text = "Import",
		Tooltip = "Apply the pasted string, saving it under the typed config name when there is one",
		Func = function()
			self:ImportConfig(shareInput and shareInput.Value, nameInput and nameInput.Value)
		end,
	})

	return groupbox
end

return SaveManager
end

__modules["addons/ThemeManager"] = function()

-- Sable :: addons/ThemeManager
--
-- Colour presets, a live per-key editor, and named themes the user saves
-- themselves -- all persisted as hex under <folder>/themes. Reached as
-- Library.ThemeManager -- the spine calls :SetLibrary for you; the method
-- survives being called again so Linoria-style scripts that call it themselves
-- keep working.
--
-- Two kinds of file live in that folder: `default.json`, the pointer at
-- whatever should load on startup, and one `<name>.json` per saved theme
-- holding the whole scheme. "default" is therefore a reserved theme name.
--
-- Every preset keeps the warm, dark, low-chroma neutrals of the stock scheme.
-- A theme moves the accent and nudges the greys; it never turns Sable into a
-- bright or pastel menu.

local Util = require("Util")

local ThemeManager = {}

--- The keys the editor exposes. Everything else in a scheme is derived from
--- the preset (AccentDim follows Accent inside Library:SetScheme).
local KEYS = { "Accent", "Background", "Panel", "Outline", "Font" }

--- Presentation order for the dropdown; unknown extras are appended sorted.
local ORDER = { "Sable", "Ember", "Signal", "Ice", "Void", "Mono" }

--- Stem of the pointer file :SetDefault writes, and therefore the one name a
--- saved theme may not take.
local DEFAULT_STEM = "default"

ThemeManager.Library = nil :: any
ThemeManager.Folder = "Sable"
ThemeManager.Theme = "Sable"
ThemeManager.CustomKeys = KEYS

--- Name of the saved theme currently on screen, or nil while a built-in preset
--- is live. Kept apart from .Theme because a saved theme is a whole scheme read
--- off disk rather than one of the presets.
ThemeManager.CustomTheme = nil :: any

--- key -> hex string, only for colours the user overrode on top of the preset.
ThemeManager.Custom = {}
--- Elements built by :ApplyToGroupbox, so a later theme change can resync them.
ThemeManager.Objects = {}

--- True only while :ApplyToGroupbox constructs its controls, so the elements'
--- initial callbacks cannot stomp a theme that was already loaded from disk.
ThemeManager.Building = false

ThemeManager.ListIndex = "ThemeManager_ThemeList"
ThemeManager.PickerIndexes = {
	Accent = "ThemeManager_AccentColor",
	Background = "ThemeManager_BackgroundColor",
	Panel = "ThemeManager_PanelColor",
	Outline = "ThemeManager_OutlineColor",
	Font = "ThemeManager_FontColor",
}

ThemeManager.CustomNameIndex = "ThemeManager_CustomName"
ThemeManager.CustomListIndex = "ThemeManager_CustomList"

-- Flat list so SaveManager:IgnoreThemeSettings has one thing to read. Every
-- control this addon owns belongs here: a config that restored the theme
-- editor's own name box would fight with the user.
ThemeManager.Indexes = {
	ThemeManager.ListIndex,
	ThemeManager.CustomNameIndex,
	ThemeManager.CustomListIndex,
}
for _, key in KEYS do
	table.insert(ThemeManager.Indexes, ThemeManager.PickerIndexes[key])
end

--==============================================================
-- presets
--==============================================================

ThemeManager.BuiltInThemes = {
	-- Mirrored from Theme.Default in :SetLibrary; kept here in full so the
	-- table is complete even if the addon is used before the spine runs.
	Sable = {
		Background = Color3.fromRGB(18, 17, 15),
		Panel = Color3.fromRGB(26, 25, 22),
		PanelRaised = Color3.fromRGB(34, 32, 29),
		PanelSunken = Color3.fromRGB(13, 12, 11),
		Outline = Color3.fromRGB(52, 49, 44),
		OutlineDim = Color3.fromRGB(36, 34, 30),
		Accent = Color3.fromRGB(233, 161, 59),
		AccentDim = Color3.fromRGB(126, 88, 34),
		Font = Color3.fromRGB(218, 213, 204),
		FontDim = Color3.fromRGB(124, 117, 107),
		FontFaint = Color3.fromRGB(84, 79, 72),
		Risk = Color3.fromRGB(226, 78, 63),
		Good = Color3.fromRGB(126, 176, 106),
		Black = Color3.fromRGB(0, 0, 0),
	},

	-- Brick red. Deliberately deeper than Risk so a risky label still reads as
	-- a warning and not as an active control.
	Ember = {
		Background = Color3.fromRGB(20, 16, 15),
		Panel = Color3.fromRGB(29, 23, 22),
		PanelRaised = Color3.fromRGB(37, 30, 28),
		PanelSunken = Color3.fromRGB(14, 11, 11),
		Outline = Color3.fromRGB(57, 45, 43),
		OutlineDim = Color3.fromRGB(40, 32, 30),
		-- Brightened: a deep red carries little luminance, so the original sat at
		-- 2.8:1 against the panel and read as muddy rather than lit.
		Accent = Color3.fromRGB(228, 86, 58),
		AccentDim = Color3.fromRGB(122, 46, 31),
		Font = Color3.fromRGB(219, 209, 205),
		FontDim = Color3.fromRGB(126, 114, 110),
		FontFaint = Color3.fromRGB(86, 76, 73),
		Risk = Color3.fromRGB(232, 96, 82),
		Good = Color3.fromRGB(126, 176, 106),
		Black = Color3.fromRGB(0, 0, 0),
	},

	Signal = {
		Background = Color3.fromRGB(16, 18, 15),
		Panel = Color3.fromRGB(23, 26, 22),
		PanelRaised = Color3.fromRGB(30, 34, 29),
		PanelSunken = Color3.fromRGB(12, 13, 11),
		Outline = Color3.fromRGB(46, 53, 44),
		OutlineDim = Color3.fromRGB(32, 37, 30),
		Accent = Color3.fromRGB(96, 196, 84),
		AccentDim = Color3.fromRGB(48, 101, 42),
		Font = Color3.fromRGB(211, 216, 205),
		FontDim = Color3.fromRGB(117, 122, 109),
		FontFaint = Color3.fromRGB(79, 84, 73),
		Risk = Color3.fromRGB(226, 78, 63),
		Good = Color3.fromRGB(148, 190, 120),
		Black = Color3.fromRGB(0, 0, 0),
	},

	Ice = {
		Background = Color3.fromRGB(15, 18, 19),
		Panel = Color3.fromRGB(21, 26, 27),
		PanelRaised = Color3.fromRGB(28, 34, 35),
		PanelSunken = Color3.fromRGB(11, 13, 14),
		Outline = Color3.fromRGB(44, 52, 54),
		OutlineDim = Color3.fromRGB(30, 36, 38),
		Accent = Color3.fromRGB(78, 178, 196),
		AccentDim = Color3.fromRGB(38, 92, 102),
		Font = Color3.fromRGB(206, 214, 217),
		FontDim = Color3.fromRGB(110, 119, 123),
		FontFaint = Color3.fromRGB(74, 81, 84),
		Risk = Color3.fromRGB(226, 78, 63),
		Good = Color3.fromRGB(126, 176, 106),
		Black = Color3.fromRGB(0, 0, 0),
	},

	-- The violet has to carry real saturation or it reads as another grey against
	-- the neutrals. The earlier value sat at 0.35 and looked like nothing had
	-- happened when you picked it.
	Void = {
		Background = Color3.fromRGB(16, 14, 21),
		Panel = Color3.fromRGB(24, 21, 31),
		PanelRaised = Color3.fromRGB(32, 28, 41),
		PanelSunken = Color3.fromRGB(11, 10, 15),
		Outline = Color3.fromRGB(51, 45, 65),
		OutlineDim = Color3.fromRGB(35, 31, 45),
		Accent = Color3.fromRGB(163, 112, 240),
		AccentDim = Color3.fromRGB(88, 60, 130),
		Font = Color3.fromRGB(215, 210, 224),
		FontDim = Color3.fromRGB(122, 116, 134),
		FontFaint = Color3.fromRGB(83, 78, 93),
		Risk = Color3.fromRGB(226, 78, 63),
		Good = Color3.fromRGB(126, 176, 106),
		Black = Color3.fromRGB(0, 0, 0),
	},

	-- No hue at all: "on" is simply brighter than the text around it. Text is
	-- pulled down a step so the accent still separates from a plain label.
	-- With no hue to spend, "on" has to be signalled by BRIGHTNESS, so the accent
	-- is pushed to near-white and Font pulled down to leave it room. The
	-- neutrals also drop their warm tint -- previously they were byte-identical
	-- to Sable, so picking Mono changed almost nothing on screen.
	Mono = {
		Background = Color3.fromRGB(17, 17, 18),
		Panel = Color3.fromRGB(25, 25, 27),
		PanelRaised = Color3.fromRGB(33, 33, 36),
		PanelSunken = Color3.fromRGB(12, 12, 13),
		Outline = Color3.fromRGB(50, 50, 53),
		OutlineDim = Color3.fromRGB(34, 34, 37),
		Accent = Color3.fromRGB(246, 246, 249),
		AccentDim = Color3.fromRGB(126, 126, 130),
		Font = Color3.fromRGB(186, 186, 191),
		FontDim = Color3.fromRGB(112, 112, 117),
		FontFaint = Color3.fromRGB(78, 78, 82),
		Risk = Color3.fromRGB(226, 78, 63),
		Good = Color3.fromRGB(126, 176, 106),
		Black = Color3.fromRGB(0, 0, 0),
	},
}

--==============================================================
-- plumbing
--==============================================================

local function notify(Library, description, kind)
	if not Library or not Library.Notify then
		return
	end
	Library:Notify({
		Title = "Theme",
		Description = description,
		Time = 4,
		Good = kind == "good",
		Risk = kind == "risk",
	})
end

function ThemeManager:SetLibrary(Library)
	if type(Library) ~= "table" then
		return self
	end

	self.Library = Library

	-- Theme.lua owns the stock palette, so mirror it rather than letting the
	-- copy above drift away from it.
	if type(Library.ThemeDefaults) == "table" then
		self.BuiltInThemes.Sable = Util.DeepCopy(Library.ThemeDefaults)
	end

	return self
end

function ThemeManager:SetFolder(path)
	if type(path) == "string" and path ~= "" then
		self.Folder = path
	end
	self:BuildFolders()
	return self
end

function ThemeManager:ThemesFolder()
	return self.Folder .. "/themes"
end

function ThemeManager:DefaultPath()
	return ("%s/%s.json"):format(self:ThemesFolder(), DEFAULT_STEM)
end

function ThemeManager:ThemePath(name)
	return ("%s/%s.json"):format(self:ThemesFolder(), name)
end

--- Theme names become file names, so anything that could walk out of the themes
--- folder is stripped rather than rejected -- the same rule SaveManager applies
--- to config names. Leading dots go too, so "../../evil" lands on "evil".
function ThemeManager:Sanitize(name)
	if type(name) ~= "string" then
		return nil
	end

	name = name:gsub("[^%w%-%. _]", "")
	name = name:gsub("^[%.%s]+", ""):gsub("[%.%s]+$", "")

	if name == "" or name:lower() == DEFAULT_STEM then
		return nil
	end

	return name
end

function ThemeManager:BuildFolders()
	if not Util.FS.Available() then
		return false
	end
	return Util.FS.EnsureFolder(self:ThemesFolder())
end

function ThemeManager:ThemeNames()
	local names = {}

	for _, name in ORDER do
		if self.BuiltInThemes[name] then
			table.insert(names, name)
		end
	end

	for _, name in Util.SortedKeys(self.BuiltInThemes) do
		if not table.find(names, name) then
			table.insert(names, name)
		end
	end

	return names
end

--==============================================================
-- applying
--==============================================================

--- Pushes the live scheme back into the editor controls without re-firing
--- their callbacks.
function ThemeManager:Sync()
	local Library = self.Library
	if not Library then
		return self
	end

	local list = self.Objects.List
	if list and list.SetValue and list.Value ~= self.Theme then
		list:SetValue(self.Theme, true)
	end

	for _, key in KEYS do
		local picker = self.Objects[key]
		local color = Library.Scheme[key]
		if picker and picker.SetValue and color and picker.Value ~= color then
			picker:SetValue(color, true)
		end
	end

	return self
end

function ThemeManager:ApplyTheme(name)
	local Library = self.Library
	local theme = type(name) == "string" and self.BuiltInThemes[name] or nil

	if not Library or not theme then
		return false
	end

	self.Theme = name
	-- A preset is a whole scheme, so per-key overrides -- and any saved theme
	-- that was on screen -- are done with.
	self.CustomTheme = nil
	table.clear(self.Custom)

	Library:SetScheme(theme)
	self:Sync()

	return true
end

--- One key of the live scheme, remembered as an override so :SetDefault can
--- write it back out.
function ThemeManager:SetColor(key, color)
	local Library = self.Library
	if not Library or typeof(color) ~= "Color3" then
		return false
	end
	if Library.Scheme[key] == nil then
		return false
	end

	self.Custom[key] = Util.ToHex(color)
	Library:SetScheme(key, color)

	return true
end

--- Back to stock: the Sable preset, no overrides, no stored default.
function ThemeManager:Reset()
	self:ApplyTheme("Sable")
	Util.FS.Delete(self:DefaultPath())
	return true
end

--- Remembers what should load on startup: a preset name (plus whatever per-key
--- overrides sit on top of it) or the name of a saved theme. Defaults to
--- whichever of those is currently on screen.
function ThemeManager:SetDefault(name)
	name = type(name) == "string" and name or (self.CustomTheme or self.Theme)

	local builtIn = self.BuiltInThemes[name] ~= nil
	local saved = nil

	if not builtIn then
		saved = self:Sanitize(name)
		if not saved or not Util.FS.IsFile(self:ThemePath(saved)) then
			return false
		end
	end

	-- The file has to describe what the user is actually looking at, so make the
	-- live scheme agree with the name being written before writing it.
	if builtIn then
		if name ~= self.Theme or self.CustomTheme ~= nil then
			self:ApplyTheme(name)
		end
	elseif saved ~= self.CustomTheme and not self:ApplyCustomTheme(saved) then
		return false
	end

	if not Util.FS.Available() then
		return false
	end

	self:BuildFolders()

	local ok = Util.FS.WriteJSON(self:DefaultPath(), {
		Theme = builtIn and name or saved,
		Kind = builtIn and "builtin" or "custom",
		Custom = Util.DeepCopy(self.Custom),
	})

	return ok and true or false
end

function ThemeManager:LoadDefault()
	local data = Util.FS.ReadJSON(self:DefaultPath())

	local name = data and data.Theme

	-- A name that is not a preset is a saved theme, stored in its own file next
	-- to this one. If it has since been deleted, fall through to the presets.
	if type(name) == "string" and not self.BuiltInThemes[name] then
		local saved = self:Sanitize(name)
		if saved and self:ApplyCustomTheme(saved) then
			return saved
		end
	end

	if type(name) ~= "string" or not self.BuiltInThemes[name] then
		name = "Sable"
	end

	self:ApplyTheme(name)

	if data and type(data.Custom) == "table" then
		for key, hex in data.Custom do
			local color = Util.FromHex(hex)
			if color then
				self:SetColor(key, color)
			end
		end
	end

	self:Sync()

	return self.Theme
end

--==============================================================
-- saved themes
--==============================================================

--- The live scheme as key -> hex. HttpService cannot encode a Color3 -- it is
--- userdata -- so a theme file is strings the whole way down.
function ThemeManager:SchemeHex()
	local Library = self.Library
	local out = {}

	if not Library then
		return out
	end

	for key, color in Library.Scheme do
		if type(key) == "string" and typeof(color) == "Color3" then
			out[key] = Util.ToHex(color)
		end
	end

	return out
end

--- Theme file -> scheme table, plus how many keys survived. Unknown keys and
--- unparseable hex are dropped rather than errored on, so a hand-edited or
--- older file still contributes whatever it got right. A flat key -> hex map is
--- accepted too, because that is the shape someone writing one by hand reaches
--- for.
function ThemeManager:DecodeScheme(data)
	local Library = self.Library
	local scheme, count = {}, 0

	if not Library or type(data) ~= "table" then
		return scheme, count
	end

	local colors = type(data.colors) == "table" and data.colors or data

	for key, hex in colors do
		-- GetColor resolves the Linoria aliases too, so AccentColor lands on
		-- Accent instead of being thrown away.
		if type(key) == "string" and Library:GetColor(key) ~= nil then
			local color = Util.FromHex(hex)
			if color then
				scheme[key] = color
				count += 1
			end
		end
	end

	return scheme, count
end

function ThemeManager:CustomThemeList()
	local list = {}

	for _, path in Util.FS.List(self:ThemesFolder()) do
		if type(path) == "string" and path:sub(-5) == ".json" then
			local stem = Util.FS.Stem(path, ".json")
			-- default.json is the startup pointer, not a theme.
			if stem ~= "" and stem:lower() ~= DEFAULT_STEM then
				table.insert(list, stem)
			end
		end
	end

	table.sort(list)
	return list
end

function ThemeManager:RefreshCustomThemeList()
	local list = self:CustomThemeList()

	local dropdown = self.Objects.CustomList
	if dropdown and dropdown.SetValues then
		dropdown:SetValues(list)
	end

	return list
end

--- Whatever the saved-theme dropdown is pointing at, or nil.
function ThemeManager:SelectedCustom()
	local dropdown = self.Objects.CustomList
	local value = dropdown and dropdown.Value

	if type(value) == "string" and value ~= "" then
		return value
	end

	return nil
end

--- Moves that dropdown onto `name` silently, so a programmatic load cannot
--- recurse back into :LoadCustomTheme through the dropdown's own callback.
function ThemeManager:SelectCustom(name)
	local dropdown = self.Objects.CustomList

	if dropdown and dropdown.SetValue and dropdown.Value ~= name then
		dropdown:SetValue(name, true)
	end

	return self
end

--- The load path :LoadCustomTheme and :LoadDefault share. Returns false plus a
--- reason instead of notifying, so the caller decides whether that reason is
--- worth a notification -- restoring the startup theme quietly is not.
function ThemeManager:ApplyCustomTheme(clean)
	local Library = self.Library

	if not Library or type(clean) ~= "string" then
		return false, "Theme manager is not attached"
	end

	local data = Util.FS.ReadJSON(self:ThemePath(clean))
	if type(data) ~= "table" then
		return false, ("%s could not be read"):format(clean)
	end

	local scheme, count = self:DecodeScheme(data)
	if count == 0 then
		return false, ("%s holds no colours"):format(clean)
	end

	-- A saved theme is a whole scheme, so per-key overrides are done with.
	self.CustomTheme = clean
	table.clear(self.Custom)

	Library:SetScheme(scheme)
	self:SelectCustom(clean)
	self:Sync()

	return true
end

--- Writes the CURRENT scheme -- presets, per-key edits and all -- under `name`.
function ThemeManager:SaveCustomTheme(name)
	local Library = self.Library

	local clean = self:Sanitize(name)
	if not clean then
		notify(Library, "Enter a valid theme name", "risk")
		return false
	end

	if not Library then
		return false
	end

	if not Util.FS.Available() then
		notify(Library, "Filesystem unavailable", "risk")
		return false
	end

	self:BuildFolders()

	local written = Util.FS.WriteJSON(self:ThemePath(clean), {
		name = clean,
		version = 1,
		colors = self:SchemeHex(),
	})

	if not written then
		notify(Library, ("Could not write %s"):format(clean), "risk")
		return false
	end

	-- What is on screen is now exactly this file.
	self.CustomTheme = clean
	self:RefreshCustomThemeList()
	self:SelectCustom(clean)

	notify(Library, ("Saved theme %s"):format(clean), "good")

	return true
end

function ThemeManager:LoadCustomTheme(name)
	local Library = self.Library

	local clean = self:Sanitize(name)
	if not clean then
		notify(Library, "Select a theme first", "risk")
		return false
	end

	if not Util.FS.Available() then
		notify(Library, "Filesystem unavailable", "risk")
		return false
	end

	local ok, reason = self:ApplyCustomTheme(clean)
	if not ok then
		notify(Library, reason or ("%s could not be read"):format(clean), "risk")
		return false
	end

	notify(Library, ("Loaded theme %s"):format(clean), "good")

	return true
end

function ThemeManager:DeleteCustomTheme(name)
	local Library = self.Library

	local clean = self:Sanitize(name)
	if not clean then
		notify(Library, "Select a theme first", "risk")
		return false
	end

	if not Util.FS.Available() then
		notify(Library, "Filesystem unavailable", "risk")
		return false
	end

	local path = self:ThemePath(clean)
	if not Util.FS.IsFile(path) then
		notify(Library, ("%s does not exist"):format(clean), "risk")
		return false
	end

	if not Util.FS.Delete(path) then
		notify(Library, ("Could not delete %s"):format(clean), "risk")
		return false
	end

	-- The colours stay on screen; there is simply no file behind them any more,
	-- so :SetDefault must stop offering to write this name.
	if self.CustomTheme == clean then
		self.CustomTheme = nil
	end

	self:RefreshCustomThemeList()
	notify(Library, ("Deleted %s"):format(clean), "good")

	return true
end

--==============================================================
-- ui
--==============================================================

function ThemeManager:ApplyToGroupbox(groupbox)
	local Library = self.Library

	if not Library then
		warn("[Sable] ThemeManager:ApplyToGroupbox called before :SetLibrary")
		return groupbox
	end
	if type(groupbox) ~= "table" or not groupbox.AddDropdown then
		warn("[Sable] ThemeManager:ApplyToGroupbox needs a groupbox")
		return groupbox
	end

	local names = self:ThemeNames()

	self.Building = true

	self.Objects.List = groupbox:AddDropdown(self.ListIndex, {
		Text = "Theme",
		Values = names,
		Default = table.find(names, self.Theme) or 1,
		Tooltip = "Built-in colour schemes",
		Callback = function(value)
			if self.Building then
				return
			end
			self:ApplyTheme(value)
		end,
	})

	for _, key in KEYS do
		self.Objects[key] = groupbox:AddColorPicker(self.PickerIndexes[key], {
			Text = key,
			Title = key,
			Default = Library.Scheme[key],
			Tooltip = ("Overrides the %s colour of the selected theme"):format(key:lower()),
			Callback = function(color)
				if self.Building then
					return
				end
				self:SetColor(key, color)
			end,
		})
	end

	local setDefault = groupbox:AddButton({
		Text = "Set as default",
		Tooltip = "Apply this theme automatically on load",
		-- No argument: :SetDefault picks whatever is actually on screen, which
		-- may be a saved theme rather than one of the presets.
		Func = function()
			if self:SetDefault() then
				notify(Library, ("%s saved as default"):format(self.CustomTheme or self.Theme), "good")
			else
				notify(Library, "Filesystem unavailable", "risk")
			end
		end,
	})

	if setDefault and setDefault.AddButton then
		setDefault:AddButton({
			Text = "Reset",
			Tooltip = "Back to the stock Sable scheme",
			Func = function()
				self:Reset()
				notify(Library, "Reset to Sable", "good")
			end,
		})
	end

	self.Building = false

	-- The controls were built from whatever the scheme already was; make sure
	-- they agree with it now that callbacks are live again.
	self:Sync()

	return groupbox
end

--- Name box, saved-theme list and the file commands. Split out of
--- :ApplyToGroupbox so a script laying the tab out by hand can place the two
--- halves of the editor wherever it likes.
function ThemeManager:BuildCustomThemeSection(groupbox)
	local Library = self.Library

	if not Library then
		warn("[Sable] ThemeManager:BuildCustomThemeSection called before :SetLibrary")
		return groupbox
	end
	if type(groupbox) ~= "table" or not groupbox.AddInput then
		warn("[Sable] ThemeManager:BuildCustomThemeSection needs a groupbox")
		return groupbox
	end

	self:BuildFolders()

	self.Building = true

	local nameInput = groupbox:AddInput(self.CustomNameIndex, {
		Text = "Theme name",
		Placeholder = "name",
		MaxLength = 40,
		Tooltip = "Used by CREATE",
	})
	self.Objects.CustomName = nameInput

	self.Objects.CustomList = groupbox:AddDropdown(self.CustomListIndex, {
		Text = "Saved themes",
		Values = self:CustomThemeList(),
		-- Starts on whatever :LoadDefault already restored, and on NONE
		-- otherwise: pre-selecting a file nobody applied would read as if that
		-- theme were the live one.
		Default = self.CustomTheme,
		AllowNull = true,
		Tooltip = "Themes on disk; picking one loads it",
		Callback = function(value)
			-- AllowNull hands back nil when the selection is cleared, which is
			-- not a request to load anything.
			if self.Building or type(value) ~= "string" or value == "" then
				return
			end
			self:LoadCustomTheme(value)
		end,
	})

	self.Building = false

	--- CREATE writes the typed name; everything else works on the list
	--- selection and falls back to the typed name, matching the config section.
	local function target()
		return self:SelectedCustom() or (nameInput and nameInput.Value)
	end

	local create = groupbox:AddButton({
		Text = "Create",
		Tooltip = "Save the colours on screen under the typed name",
		Func = function()
			self:SaveCustomTheme(nameInput and nameInput.Value)
		end,
	})

	if create and create.AddButton then
		create:AddButton({
			Text = "Overwrite",
			Tooltip = "Save the colours on screen over the selected theme",
			Func = function()
				self:SaveCustomTheme(target())
			end,
		})
	end

	local load = groupbox:AddButton({
		Text = "Load",
		Tooltip = "Apply the selected theme",
		Func = function()
			self:LoadCustomTheme(target())
		end,
	})

	if load and load.AddButton then
		load:AddButton({
			Text = "Delete",
			DoubleClick = true,
			Tooltip = "Double click to delete the selected theme",
			Func = function()
				self:DeleteCustomTheme(target())
			end,
		})
	end

	groupbox:AddButton({
		Text = "Refresh",
		Tooltip = "Re-read the themes folder",
		Func = function()
			local list = self:RefreshCustomThemeList()
			notify(Library, ("%d theme(s) on disk"):format(#list))
		end,
	})

	return groupbox
end

function ThemeManager:ApplyToTab(tab)
	if type(tab) == "table" and tab.AddLeftGroupbox then
		local groupbox = self:ApplyToGroupbox(tab:AddLeftGroupbox("Theme"))
		self:BuildCustomThemeSection(tab:AddLeftGroupbox("Custom themes"))
		return groupbox
	end

	-- Handed a bare groupbox: there is nowhere to put a second box, so the
	-- saved-theme controls continue inside the one we were given.
	local groupbox = self:ApplyToGroupbox(tab)
	if type(groupbox) == "table" and groupbox.AddInput then
		self:BuildCustomThemeSection(groupbox)
	end

	return groupbox
end

return ThemeManager
end

__modules["elements/Base"] = function()

-- Sable :: elements/Base
--
-- Shared behaviour for every control. Element modules call Base.Create to get
-- an object with change notification, visibility, disabled state and tooltip
-- handling already wired, then attach their own visuals and :SetValue.
--
-- CONTRACT for element authors -- after Base.Create you MUST set:
--   element.Row    the row Frame you created with Library:Row(container, h)
--   element.Value  the current value
-- and you SHOULD set:
--   element.Label  the TextLabel showing element.Text, if the control has one
--   element.Hit    the TextButton used for hit testing, if the control has one
-- and you MUST implement on the element (not on Base):
--   element:SetValue(value, silent)  apply + repaint + Fire unless silent
--   element:Display()                repaint visuals from element.Value

local Base = {}

local Methods = {}
Methods.__index = Methods
Base.Methods = Methods

--- kind is the element type name ("Toggle", "Slider", ...). `index` is the key
--- it will be registered under in Library.Toggles / Library.Options.
function Base.Create(Library, container, kind, index, options)
	options = options or {}

	local element = setmetatable({}, Methods)

	element.Library = Library
	element.Parent = container
	element.Type = kind
	element.Index = index
	element.Opts = options
	element.Callbacks = {}

	element.Text = options.Text or (type(index) == "string" and index) or ""
	element.Tooltip = options.Tooltip
	element.DisabledTooltip = options.DisabledTooltip
	element.Disabled = options.Disabled == true
	element.Visible = options.Visible ~= false
	element.Risky = options.Risky == true

	table.insert(container.Elements, element)

	return element
end

--- Call once at the end of an element's constructor: registers it in the right
--- store and applies tooltip / disabled / visible state.
---
--- It deliberately does NOT fire the callback: constructing a menu would
--- otherwise run every callback in the script during layout. Callers that want
--- the initial value delivered should use `:OnChanged(fn, true)`.
function Base.Finish(element, store)
	local Library = element.Library

	if element.Index ~= nil and store then
		store[element.Index] = element
		element.Store = store
	end

	if element.Tooltip or element.DisabledTooltip then
		local target = element.Hit or element.Row
		if target then
			element.UpdateTooltip = Library:GiveTooltip(target, element.Tooltip, element.DisabledTooltip)
		end
	end

	if element.Disabled then
		element:SetDisabled(true)
	end

	if not element.Visible then
		element:SetVisible(false)
	end

	return element
end

--==============================================================
-- change notification
--==============================================================

--- Subscribe to value changes. Pass callNow = true to also run immediately
--- with the current value.
function Methods:OnChanged(callback, callNow)
	table.insert(self.Callbacks, callback)
	if callNow then
		self.Library:SafeCallback(callback, self.Value, self)
	end
	return self
end

--- Runs the option Callback first, then every OnChanged subscriber.
function Methods:Fire()
	local Library = self.Library

	if self.Opts.Callback then
		Library:SafeCallback(self.Opts.Callback, self.Value, self)
	end

	for _, callback in self.Callbacks do
		Library:SafeCallback(callback, self.Value, self)
	end
end

--==============================================================
-- state
--==============================================================

function Methods:SetVisible(visible)
	visible = visible ~= false
	self.Visible = visible

	-- UIListLayout already skips invisible children, so toggling Visible is
	-- enough -- the groupbox's AbsoluteContentSize follows on its own. Do not
	-- also zero the row's size; that loses the size with nothing restoring it.
	if self.Row then
		self.Row.Visible = visible
	end

	if self.Parent and self.Parent.Resize then
		self.Parent:Resize()
	end

	return self
end

function Methods:SetDisabled(disabled)
	disabled = disabled == true
	self.Disabled = disabled

	if self.Row then
		self.Row:SetAttribute("SableDisabled", disabled)
	end
	if self.Hit then
		self.Hit:SetAttribute("SableDisabled", disabled)
		self.Hit.Active = not disabled
		self.Hit.Interactable = not disabled
	end

	-- Retheme, not AddToRegistry: adding would stack a second entry for the
	-- same instance every time disabled state flipped.
	--
	-- The element's own rule is captured once and restored on re-enable.
	-- Elements like Toggle register a FUNCTION source that derives the label
	-- colour from live state; overwriting it with a flat key here left OFF
	-- toggles repainting as ON after any theme change.
	if self.Label then
		if self.LabelColourSource == nil then
			self.LabelColourSource = self.Library:GetRegistrySource(self.Label, "TextColor3")
				or (self.Risky and "Risk" or "Font")
		end

		self.Library:Retheme(self.Label, {
			TextColor3 = disabled and "FontFaint" or self.LabelColourSource,
		})
	end

	if self.OnDisabledChanged then
		self.Library:SafeCallback(self.OnDisabledChanged, disabled, self)
	end

	return self
end

function Methods:SetText(text)
	self.Text = text or ""
	if self.Label then
		self.Label.Text = self.Library:FormatLabel(self.Text)
	end
	return self
end

function Methods:SetTooltip(text, disabledText)
	self.Tooltip = text
	self.DisabledTooltip = disabledText
	if self.UpdateTooltip then
		self.UpdateTooltip(text, disabledText)
	end
	return self
end

--==============================================================
-- teardown
--==============================================================

function Methods:Destroy()
	-- Library signals are plain Lua signals, not RBXScriptConnections, so
	-- destroying instances does NOT silence handlers that closed over this
	-- element. Any handler an element registers on Library.InputBegan and
	-- friends MUST bail on this flag, or a destroyed bind keeps firing the
	-- user's callback.
	self.Destroyed = true

	-- Inline pickers live inside THIS element's row but are registered as
	-- independent elements. Destroying only ourselves would take their visuals
	-- away while leaving their store entry, input handlers and keybind-list row
	-- alive forever -- a dead bind that still fires the user's callback.
	if self.Row and self.Parent and self.Parent.Elements then
		for _, other in table.clone(self.Parent.Elements) do
			if other ~= self and other.Row and other.Row ~= self.Row then
				local ok, isDescendant = pcall(function()
					return other.Row:IsDescendantOf(self.Row)
				end)
				if ok and isDescendant then
					other:Destroy()
				end
			end
		end
	end

	if self.Store and self.Index ~= nil and self.Store[self.Index] == self then
		self.Store[self.Index] = nil
	end

	if self.Parent and self.Parent.Elements then
		local index = table.find(self.Parent.Elements, self)
		if index then
			table.remove(self.Parent.Elements, index)
		end
	end

	if self.Row then
		self.Library:RemoveFromRegistry(self.Row)
		pcall(function()
			self.Row:Destroy()
		end)
	end

	table.clear(self.Callbacks)

	if self.Parent and self.Parent.Resize then
		self.Parent:Resize()
	end
end

return Base
end

__modules["elements/Button"] = function()

-- Sable :: elements/Button
--
-- A command row. :AddButton splits the SAME row into equal columns, so
-- SAVE | LOAD | DELETE reads as one bank of keys instead of three stacked
-- rows. Only the first button is a Base element; the columns added after it
-- are lighter objects sharing that element's row, which keeps the container's
-- element list (and therefore its layout) honest about how many rows exist.

local Base = require("elements/Base")

local Button = {}

--- How long a DoubleClick button waits for its confirming second press.
local CONFIRM_WINDOW = 0.5
--- How long the accent press-flash stays lit before easing back.
local FLASH_HOLD = 0.1
--- Uppercased by FormatLabel at paint time, like every other element label.
local CONFIRM_TEXT = "...Are you sure?"

local Segment = {}
Segment.__index = Segment

--==============================================================
-- construction helpers
--==============================================================

--- Accepts either a plain string or the full option table.
local function normalize(info)
	if type(info) ~= "table" then
		return { Text = info ~= nil and tostring(info) or "Button" }
	end

	return {
		Text = info.Text ~= nil and tostring(info.Text) or "Button",
		Func = info.Func or info.Callback,
		DoubleClick = info.DoubleClick == true,
		Tooltip = info.Tooltip,
		DisabledTooltip = info.DisabledTooltip,
		Disabled = info.Disabled == true,
	}
end

--- Re-flows every column in the shared row. Columns are always equal width, so
--- adding one moves and resizes the siblings that were already there.
local function relayout(group)
	local items = group.Items
	local count = #items
	local gap = group.Gap

	for index, segment in items do
		segment.Frame.Size = UDim2.new(1 / count, -gap * (count - 1) / count, 1, 0)
		segment.Frame.Position = UDim2.new((index - 1) / count, (index - 1) * gap / count, 0, 0)
	end
end

--- Momentary accent on the caption. The press has no lasting state to show, so
--- the flash is the entire acknowledgement.
local function flash(segment)
	local Library = segment.Library
	local label = segment.Label

	label.TextColor3 = Library:GetColor("Accent")

	task.delay(FLASH_HOLD, function()
		if Library.Unloaded or not label.Parent then
			return
		end
		Library:Tween(label, {
			TextColor3 = Library:GetColor(segment.Disabled and "FontFaint" or "Font"),
		}, Library.Motion.Slow)
	end)
end

local function press(segment)
	local Library = segment.Library
	if Library.Unloaded or segment.Disabled then
		return
	end

	if segment.DoubleClick and not segment.Confirming then
		segment.Confirming = true
		-- The token invalidates a pending revert, so a confirmed press cannot
		-- be un-confirmed by the timer it started with.
		segment.ConfirmToken += 1
		local token = segment.ConfirmToken
		segment:Display()

		task.delay(CONFIRM_WINDOW, function()
			if Library.Unloaded or segment.ConfirmToken ~= token then
				return
			end
			segment.Confirming = false
			segment:Display()
		end)

		return
	end

	segment.ConfirmToken += 1
	segment.Confirming = false
	segment:Display()

	flash(segment)
	Library:SafeCallback(segment.Func)
end

--- Builds one column into the shared row and wires its behaviour. `segment` is
--- either a Base element (the first button) or a bare Segment (every :AddButton
--- after it) -- both carry the same fields from here on.
local function build(Library, group, segment, options)
	segment.Library = Library
	segment.Group = group
	segment.Row = group.Row
	segment.Opts = options
	segment.Text = options.Text
	segment.Func = options.Func
	segment.DoubleClick = options.DoubleClick
	segment.Disabled = options.Disabled == true
	segment.Confirming = false
	segment.ConfirmToken = 0

	local frame = Library:Panel({
		Name = "Button",
		Size = UDim2.fromScale(1, 1),
		Parent = group.Row,
	}, "Panel", "Outline")

	local label = Library:Label({
		Name = "Text",
		Size = UDim2.fromScale(1, 1),
		Text = Library:FormatLabel(options.Text),
		TextXAlignment = Enum.TextXAlignment.Center,
		-- Columns get narrow fast; a clipped caption beats an overflowing one.
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = frame,
	}, "Font")

	local hit = Library:HitButton(frame)

	segment.Frame = frame
	segment.Label = label
	segment.Hit = hit

	Library:BindHover(hit, frame, "Panel", "PanelRaised")

	Library:GiveSignal(hit.MouseButton1Click:Connect(function()
		press(segment)
	end))

	table.insert(group.Items, segment)
	relayout(group)

	return segment
end

--==============================================================
-- shared column behaviour
--==============================================================

function Segment:Display()
	local text = self.Confirming and CONFIRM_TEXT or self.Text
	self.Label.Text = self.Library:FormatLabel(text)
	return self
end

function Segment:SetText(text)
	self.Text = text ~= nil and tostring(text) or ""
	self:Display()
	return self
end

function Segment:SetDisabled(disabled)
	disabled = disabled == true
	self.Disabled = disabled

	self.Hit:SetAttribute("SableDisabled", disabled)
	self.Hit.Active = not disabled
	self.Hit.Interactable = not disabled

	self.Library:AddToRegistry(self.Label, {
		TextColor3 = disabled and "FontFaint" or "Font",
	})

	return self
end

function Segment:SetTooltip(text, disabledText)
	self.Tooltip = text
	self.DisabledTooltip = disabledText
	if self.UpdateTooltip then
		self.UpdateTooltip(text, disabledText)
	end
	return self
end

--- Splits this button's row into one more equal column.
function Segment:AddButton(info)
	local Library = self.Library
	local options = normalize(info)

	local segment = build(Library, self.Group, setmetatable({}, Segment), options)

	if options.Tooltip or options.DisabledTooltip then
		segment.UpdateTooltip = Library:GiveTooltip(segment.Hit, options.Tooltip, options.DisabledTooltip)
	end

	if segment.Disabled then
		segment:SetDisabled(true)
	end

	return segment
end

--- Removes this column and re-flows the rest. Destroying the *first* button
--- goes through Base instead and takes the whole row -- every column with it.
function Segment:Destroy()
	local items = self.Group.Items
	local index = table.find(items, self)
	if index then
		table.remove(items, index)
	end

	self.Library:RemoveFromRegistry(self.Frame)
	self.Library:RemoveFromRegistry(self.Label)

	pcall(function()
		self.Frame:Destroy()
	end)

	if #items > 0 then
		relayout(self.Group)
	end
end

--==============================================================
-- constructor
--==============================================================

function Button.New(Library, container, info)
	local options = normalize(info)

	local element = Base.Create(Library, container, "Button", nil, options)

	local row = Library:Row(container, Library.Sizes.RowHeight)
	row.Name = "ButtonRow"

	element.Row = row
	element.ExpandedSize = row.Size
	element.Value = false

	local group = {
		Row = row,
		Items = {},
		Gap = Library.Sizes.RowGap * 2,
	}
	element.Group = group

	-- The first button shares the columns' behaviour but keeps Base's state
	-- handling (SetDisabled/SetVisible/Destroy operate on the row it owns).
	element.Display = Segment.Display
	element.SetText = Segment.SetText
	element.AddButton = Segment.AddButton

	--- A button carries no state; present only for the element contract, and
	--- deliberately inert so a config load can never fire a command.
	function element:SetValue(_value, _silent)
		return self
	end

	build(Library, group, element, options)

	return Base.Finish(element, nil)
end

return Button
end

__modules["elements/ColorPicker"] = function()

-- Sable :: elements/ColorPicker
--
-- A swatch that opens an HSV popup: saturation/value square, vertical hue bar,
-- an optional alpha bar, and a hex field. Hue/sat/val are stored separately
-- from the resulting Color3 -- deriving the colour from HSV on every change is
-- what lets you drag value down to black and back without the hue collapsing
-- to red on the way.
--
-- Two entry points share one builder: New() gives the swatch its own row,
-- Attach() puts it in a host element's Right slot at LayoutOrder 10 + n, which
-- lands it to the left of the host's own control.

local Util = require("Util")
local Base = require("elements/Base")

local ColorPicker = {}

--==============================================================
-- geometry
--==============================================================

-- The SV crosshair is sized against the surface it sits ON, not against the
-- design grid: it has to stay small enough that the colour underneath it is
-- still readable however large the canvas gets. A layout metric here would make
-- the marker swallow the thing it is pointing at.
local CURSOR_SIZE = 7

-- Pure white and pure black are not theming here, they are the arithmetic of
-- the HSV square: saturation fades toward white, value fades toward black. A
-- themed "white" would make the picker report a colour it is not showing. Same
-- exemption the swatch fill gets -- these ARE the value, not a surface.
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)

-- Six equal steps around the hue wheel. A property of the colour space, not a
-- layout choice, so it does not scale with anything.
local hueStops = table.create(7)
for step = 0, 6 do
	local alpha = step / 6
	table.insert(hueStops, ColorSequenceKeypoint.new(alpha, Color3.fromHSV(alpha, 1, 1)))
end
local HUE_SEQUENCE = ColorSequence.new(hueStops)

-- Opaque at offset 0, gone at offset 1. Rotation decides which edge that is.
local FADE_OUT = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(1, 1),
})

local FADE_IN = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(1, 0),
})

--- Every popup dimension, derived from the design system. Built per element
--- rather than once at module scope because the copy button is measured from
--- live text metrics, which need the Library's fonts.
local function geometry(Library)
	local sizes = Library.Sizes

	-- Half a group pad is the library's internal gap unit; Window.lua splits
	-- ColumnGap and GroupPad the same way.
	local gap = math.ceil(sizes.GroupPad / 2)
	local copyText = Library:FormatLabel("Copy")

	local geo = {
		Pad = sizes.GroupPad,
		Gap = gap,
		-- Hue and alpha bars are one control square thick, so they carry the
		-- same visual weight as the swatch that opened the popup.
		Bar = sizes.Control,
		Square = sizes.PickerSquare,
		-- The popup's caption band is a group header by another name.
		TitleHeight = sizes.GroupHeader,
		-- The hex field and its copy button are a row of the popup.
		FieldHeight = sizes.RowHeight,
		CopyText = copyText,
		CopyWidth = math.ceil(Util.TextSize(copyText, sizes.TextSmall, Library.Fonts.Label).X)
			+ sizes.GroupPad * 2,
	}

	geo.Content = geo.Square + geo.Gap + geo.Bar
	geo.Width = geo.Content + geo.Pad * 2

	return geo
end

--==============================================================
-- helpers
--==============================================================

--- Next free slot in a host's addon band. Counted off the live children rather
--- than a shared counter so ColorPicker and KeyPicker interleave correctly no
--- matter which order the script author attaches them in.
local function nextAddonOrder(right)
	local used = 0
	for _, child in right:GetChildren() do
		-- The host's own control sits at 100; addons occupy 10..99.
		if child:IsA("GuiObject") and child.LayoutOrder >= 10 and child.LayoutOrder < 100 then
			used += 1
		end
	end
	return 10 + used
end

--- Accepts everything a caller or a saved config might hand us: a Color3, a
--- hex string, or the { hex, transparency } pair SaveManager serialises.
local function decode(value)
	if typeof(value) == "Color3" then
		return value, nil
	end

	if type(value) == "string" then
		return Util.FromHex(value), nil
	end

	if type(value) == "table" then
		local raw = value.Hex or value.hex or value.Color or value[1]
		local color = typeof(raw) == "Color3" and raw or Util.FromHex(raw)

		local transparency = value.Transparency or value.transparency or value[2]
		return color, type(transparency) == "number" and transparency or nil
	end

	return nil, nil
end

--==============================================================
-- builder
--==============================================================

--- `host` is nil for a standalone row, or the element whose Right slot the
--- swatch should live in. Everything past the swatch is identical either way.
local function build(Library, container, host, index, options)
	options = options or {}

	local element = Base.Create(Library, container, "ColorPicker", index, options)

	local sizes = Library.Sizes
	local control = sizes.Control
	local geo = geometry(Library)

	local default = typeof(options.Default) == "Color3" and options.Default or Library:GetColor("Accent")
	local hue, saturation, value = default:ToHSV()

	element.Hue = hue
	element.Sat = saturation
	element.Val = value
	element.Value = Color3.fromHSV(hue, saturation, value)
	element.Transparency = type(options.Transparency) == "number" and Util.Clamp(options.Transparency, 0, 1)
		or nil
	element.Title = options.Title or (type(index) == "string" and index) or element.Text

	local hasAlpha = element.Transparency ~= nil

	--==========================================================
	-- swatch
	--==========================================================

	local row
	if host then
		-- Hosts put a row-wide hit button at the default ZIndex 5; lifting the
		-- addon slot above it is what lets a click reach the swatch instead of
		-- toggling the host underneath.
		if host.Right.ZIndex < 6 then
			host.Right.ZIndex = 6
		end

		-- The holder is exactly swatch-sized so the host's list layout reserves
		-- the right amount of room, and so SetVisible can collapse just us.
		row = Library:Create("Frame", {
			Name = "ColorPicker",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(control, control),
			LayoutOrder = nextAddonOrder(host.Right),
			ZIndex = 6,
			Parent = host.Right,
		})
	else
		row = Library:Row(container)

		element.Label = Library:Label({
			Name = "Label",
			Text = Library:FormatLabel(element.Text),
			Size = UDim2.new(1, -(control + geo.Gap), 1, 0),
			Parent = row,
		}, element.Risky and "Risk" or "Font")
	end

	element.Row = row
	element.ExpandedSize = row.Size

	-- The one legitimate raw Color3 in an element: this is the value itself,
	-- not a themed surface, so it must NOT go into the colour registry.
	local swatch = Library:Create("Frame", {
		Name = "Swatch",
		BorderSizePixel = 0,
		BackgroundColor3 = element.Value,
		BackgroundTransparency = element.Transparency or 0,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(control, control),
		Parent = row,
	})
	Library:AddToRegistry(Util.Stroke(swatch, Library:GetColor("Outline"), sizes.Outline), { Color = "Outline" })

	local hit = Library:HitButton(swatch, { Name = "SwatchHit" })

	element.Swatch = swatch
	element.Hit = hit

	--==========================================================
	-- popup
	--==========================================================

	local popupFrame, popupHandle
	local svBase, svCursor, hueBar, hueMarker
	local alphaBase, alphaFill, alphaMarker, hexBox
	local dragging = nil

	local function popupHeight()
		local height = geo.Pad + geo.TitleHeight + geo.Gap + geo.Square + geo.Gap + geo.FieldHeight + geo.Pad
		if hasAlpha then
			height += geo.Bar + geo.Gap
		end
		return height
	end

	--- Fraction of the way across (or down) a frame the cursor currently is.
	--- The cursor is taken in AbsolutePosition space -- the SV square, the hue
	--- bar and the alpha bar are all measured off their own rectangles, so a raw
	--- reading would shift every picked colour by the gui inset.
	local function ratio(frame, horizontal)
		local origin = frame.AbsolutePosition
		local size = frame.AbsoluteSize
		local mouse = Util.MouseInGuiSpace()

		if horizontal then
			if size.X <= 0 then
				return 0
			end
			return Util.Clamp((mouse.X - origin.X) / size.X, 0, 1)
		end

		if size.Y <= 0 then
			return 0
		end
		return Util.Clamp((mouse.Y - origin.Y) / size.Y, 0, 1)
	end

	local function commit(silent)
		element.Value = Color3.fromHSV(element.Hue, element.Sat, element.Val)
		element:Display()
		if not silent then
			element:Fire()
		end
	end

	local function updateDrag()
		if dragging == "SV" then
			element.Sat = ratio(svBase, true)
			element.Val = 1 - ratio(svBase, false)
		elseif dragging == "Hue" then
			element.Hue = ratio(hueBar, false)
		elseif dragging == "Alpha" then
			element.Transparency = ratio(alphaBase, true)
		else
			return
		end

		commit(false)
	end

	--- Press anywhere in a track starts a drag AND jumps to that point, which
	--- is what makes the control feel direct rather than handle-based.
	local function bindTrack(button, mode)
		Library:GiveSignal(button.InputBegan:Connect(function(input)
			if
				input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch
			then
				return
			end
			dragging = mode
			updateDrag()
		end))
	end

	local function buildPopup()
		if popupFrame then
			return popupFrame
		end

		local frame = Library:Panel({
			Name = "ColorPopup",
			Visible = false,
			Size = UDim2.fromOffset(geo.Width, popupHeight()),
			Parent = Library.PopupHolder,
		}, "Panel", "Outline")
		popupFrame = frame

		Library:CornerTicks(frame, "Accent")

		Library:Label({
			Name = "Title",
			Text = Library:Chrome(element.Title),
			TextSize = sizes.TextSmall,
			Position = UDim2.fromOffset(geo.Pad, geo.Pad),
			Size = UDim2.new(1, -geo.Pad * 2, 0, geo.TitleHeight),
			Parent = frame,
		}, "FontDim")

		local cursorY = geo.Pad + geo.TitleHeight + geo.Gap

		--------------------------------------------------------
		-- saturation / value square
		--------------------------------------------------------

		svBase = Library:Create("Frame", {
			Name = "SV",
			BorderSizePixel = 0,
			BackgroundColor3 = Color3.fromHSV(element.Hue, 1, 1),
			Position = UDim2.fromOffset(geo.Pad, cursorY),
			-- Square by construction: saturation runs one axis, value the other,
			-- so equal edges keep both at the same sensitivity per pixel.
			Size = UDim2.fromOffset(geo.Square, geo.Square),
			Parent = frame,
		})
		Library:AddToRegistry(
			Util.Stroke(svBase, Library:GetColor("Outline"), sizes.Outline),
			{ Color = "Outline" }
		)

		local satFade = Library:Create("Frame", {
			Name = "Saturation",
			BorderSizePixel = 0,
			BackgroundColor3 = WHITE,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 2,
			Parent = svBase,
		})
		Util.Create("UIGradient", {
			Name = "Fade",
			Transparency = FADE_OUT,
			Parent = satFade,
		})

		local valFade = Library:Create("Frame", {
			Name = "Value",
			BorderSizePixel = 0,
			BackgroundColor3 = BLACK,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 3,
			Parent = svBase,
		})
		Util.Create("UIGradient", {
			Name = "Fade",
			Rotation = 90,
			Transparency = FADE_IN,
			Parent = valFade,
		})

		-- Two nested hairline rings: the dark one reads on pale colours, the
		-- light one on dark colours, so the marker never disappears.
		svCursor = Library:Create("Frame", {
			Name = "Cursor",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(CURSOR_SIZE, CURSOR_SIZE),
			ZIndex = 4,
			Parent = svBase,
		})
		Library:AddToRegistry(
			Util.Stroke(svCursor, Library:GetColor("Black"), sizes.Outline),
			{ Color = "Black" }
		)

		-- Inset by exactly one hairline on each side: the two rings have to be
		-- adjacent, or the pair stops reading as a single marker.
		local cursorInner = Library:Create("Frame", {
			Name = "Inner",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, -sizes.Outline * 2, 1, -sizes.Outline * 2),
			ZIndex = 4,
			Parent = svCursor,
		})
		Library:AddToRegistry(
			Util.Stroke(cursorInner, Library:GetColor("Font"), sizes.Outline),
			{ Color = "Font" }
		)

		bindTrack(Library:HitButton(svBase, { Name = "SVHit" }), "SV")

		--------------------------------------------------------
		-- hue bar
		--------------------------------------------------------

		hueBar = Library:Create("Frame", {
			Name = "Hue",
			BorderSizePixel = 0,
			-- A UIGradient multiplies the fill, so the base has to be white for
			-- the spectrum keypoints to come through unshifted.
			BackgroundColor3 = WHITE,
			Position = UDim2.fromOffset(geo.Pad + geo.Square + geo.Gap, cursorY),
			Size = UDim2.fromOffset(geo.Bar, geo.Square),
			Parent = frame,
		})
		Util.Create("UIGradient", {
			Name = "Spectrum",
			Rotation = 90,
			Color = HUE_SEQUENCE,
			Parent = hueBar,
		})
		Library:AddToRegistry(
			Util.Stroke(hueBar, Library:GetColor("Outline"), sizes.Outline),
			{ Color = "Outline" }
		)

		-- Overhangs its bar by a hairline on each side so the marker reads as a
		-- cut across the track rather than a block sitting inside it.
		hueMarker = Library:Create("Frame", {
			Name = "Marker",
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0),
			Size = UDim2.new(1, sizes.Outline * 2, 0, sizes.Indicator),
			ZIndex = 2,
			Theme = { BackgroundColor3 = "Font" },
			Parent = hueBar,
		})
		Library:AddToRegistry(
			Util.Stroke(hueMarker, Library:GetColor("Black"), sizes.Outline),
			{ Color = "Black" }
		)

		bindTrack(Library:HitButton(hueBar, { Name = "HueHit" }), "Hue")

		cursorY += geo.Square + geo.Gap

		--------------------------------------------------------
		-- alpha bar
		--------------------------------------------------------

		if hasAlpha then
			alphaBase = Library:Panel({
				Name = "Alpha",
				Position = UDim2.fromOffset(geo.Pad, cursorY),
				Size = UDim2.fromOffset(geo.Content, geo.Bar),
				Parent = frame,
			}, "PanelSunken", "Outline")

			alphaFill = Library:Create("Frame", {
				Name = "Fill",
				BorderSizePixel = 0,
				BackgroundColor3 = element.Value,
				Size = UDim2.fromScale(1, 1),
				ZIndex = 2,
				Parent = alphaBase,
			})
			Util.Create("UIGradient", {
				Name = "Fade",
				Transparency = FADE_OUT,
				Parent = alphaFill,
			})

			-- Same construction as the hue marker, rotated: a cut across the bar.
			alphaMarker = Library:Create("Frame", {
				Name = "Marker",
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0, 0.5),
				Size = UDim2.new(0, sizes.Indicator, 1, sizes.Outline * 2),
				ZIndex = 3,
				Theme = { BackgroundColor3 = "Font" },
				Parent = alphaBase,
			})
			Library:AddToRegistry(
				Util.Stroke(alphaMarker, Library:GetColor("Black"), sizes.Outline),
				{ Color = "Black" }
			)

			bindTrack(Library:HitButton(alphaBase, { Name = "AlphaHit" }), "Alpha")

			cursorY += geo.Bar + geo.Gap
		end

		--------------------------------------------------------
		-- hex field + copy
		--------------------------------------------------------

		local fieldWidth = geo.Content - geo.CopyWidth - geo.Gap

		local field = Library:Panel({
			Name = "Hex",
			Position = UDim2.fromOffset(geo.Pad, cursorY),
			Size = UDim2.fromOffset(fieldWidth, geo.FieldHeight),
			Parent = frame,
		}, "PanelSunken", "Outline")

		hexBox = Library:Create("TextBox", {
			Name = "Field",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ClearTextOnFocus = false,
			Font = Library.Fonts.Value,
			TextSize = sizes.TextSmall,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Center,
			Text = Util.ToHex(element.Value),
			PlaceholderText = "RRGGBB",
			Size = UDim2.fromScale(1, 1),
			ZIndex = 2,
			Theme = { TextColor3 = "Font", PlaceholderColor3 = "FontFaint" },
			Parent = field,
		})

		Library:GiveSignal(hexBox.FocusLost:Connect(function()
			local parsed = Util.FromHex(hexBox.Text)
			if parsed then
				element:SetValue(parsed)
			else
				-- Invalid input never mutates the value; repaint puts the last
				-- good hex back in the box.
				element:Display()
			end
		end))

		local copy = Library:Panel({
			Name = "Copy",
			Position = UDim2.fromOffset(geo.Pad + fieldWidth + geo.Gap, cursorY),
			Size = UDim2.fromOffset(geo.CopyWidth, geo.FieldHeight),
			Parent = frame,
		}, "Panel", "Outline")

		Library:Label({
			Name = "Text",
			Text = geo.CopyText,
			TextSize = sizes.TextSmall,
			TextXAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 2,
			Parent = copy,
		}, "FontDim")

		local copyHit = Library:HitButton(copy, { Name = "CopyHit" })
		Library:BindHover(copyHit, copy, "Panel", "PanelRaised")

		Library:GiveSignal(copyHit.MouseButton1Click:Connect(function()
			Util.SetClipboard(Util.ToHex(element.Value))
		end))

		return frame
	end

	--==========================================================
	-- api
	--==========================================================

	function element:Display()
		swatch.BackgroundColor3 = self.Value
		swatch.BackgroundTransparency = self.Transparency or 0

		if not popupFrame then
			return self
		end

		svBase.BackgroundColor3 = Color3.fromHSV(self.Hue, 1, 1)
		svCursor.Position = UDim2.fromScale(self.Sat, 1 - self.Val)
		hueMarker.Position = UDim2.fromScale(0.5, self.Hue)

		if alphaFill then
			alphaFill.BackgroundColor3 = self.Value
			alphaMarker.Position = UDim2.fromScale(self.Transparency or 0, 0.5)
		end

		-- Never fight the user mid-edit.
		if not hexBox:IsFocused() then
			hexBox.Text = Util.ToHex(self.Value)
		end

		return self
	end

	function element:SetValue(newValue, silent)
		local color, transparency = decode(newValue)

		if color then
			local newHue, newSat, newVal = color:ToHSV()
			-- Greys and blacks report hue 0; keeping the stored hue means a
			-- round trip through black does not silently turn the picker red.
			if newSat > 0 and newVal > 0 then
				self.Hue = newHue
			end
			self.Sat = newSat
			self.Val = newVal
		end

		if transparency ~= nil and self.Transparency ~= nil then
			self.Transparency = Util.Clamp(transparency, 0, 1)
		end

		commit(silent)
		return self
	end

	--- Linoria compatibility: same thing, always audible.
	function element:SetValueRGB(color, transparency)
		if transparency ~= nil and self.Transparency ~= nil then
			self.Transparency = Util.Clamp(tonumber(transparency) or 0, 0, 1)
		end
		return self:SetValue(color, false)
	end

	function element:SetTransparency(newTransparency, silent)
		if self.Transparency == nil then
			return self
		end
		self.Transparency = Util.Clamp(tonumber(newTransparency) or 0, 0, 1)
		commit(silent)
		return self
	end

	function element:Open()
		if self.Disabled then
			return self
		end

		local frame = buildPopup()
		self:Display()

		popupHandle = Library:OpenPopup(frame, swatch, {
			Width = geo.Width,
			Height = popupHeight(),
			Gap = sizes.RowGap,
			OnClose = function()
				dragging = nil
			end,
		})

		return self
	end

	function element:Close()
		if popupHandle then
			Library:ClosePopup(popupHandle)
		end
		return self
	end

	function element:Destroy()
		self:Close()

		if popupFrame then
			pcall(function()
				popupFrame:Destroy()
			end)
			popupFrame = nil
		end

		return Base.Methods.Destroy(self)
	end

	--==========================================================
	-- wiring
	--==========================================================

	Library:GiveSignal(hit.MouseButton1Click:Connect(function()
		if element.Disabled then
			return
		end

		local active = Library.ActivePopup
		if active and popupFrame and active.Frame == popupFrame then
			element:Close()
			return
		end

		element:Open()
	end))

	-- Tracked on the shared signals rather than the track itself so the drag
	-- survives the cursor leaving the popup entirely.
	Library:GiveSignal(Library.InputChanged:Connect(function(input)
		if Library.Unloaded or not dragging then
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		updateDrag()
	end))

	Library:GiveSignal(Library.InputEnded:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = nil
		end
	end))

	element:Display()

	return Base.Finish(element, Library.Options)
end

--==============================================================
-- constructors
--==============================================================

function ColorPicker.New(Library, container, index, options)
	return build(Library, container, nil, index, options)
end

--- Inline picker: registered in Library.Options exactly like a standalone one,
--- but parented into the host's addon slot and owned by the host's container
--- so Destroy/Resize bookkeeping still lands in the right place.
function ColorPicker.Attach(Library, host, index, options)
	assert(host.Right, "[Sable] host element has no Right slot for a ColorPicker")
	assert(host.Parent, "[Sable] host element has no container")

	local element = build(Library, host.Parent, host, index, options)
	element.Host = host

	return element
end

return ColorPicker
end

__modules["elements/Divider"] = function()

-- Sable :: elements/Divider
--
-- A hairline rule between groups of controls. Deliberately dimmer than a
-- groupbox outline (OutlineDim) so it separates without framing anything.

local Base = require("elements/Base")

local Divider = {}

function Divider.New(Library, container)
	local element = Base.Create(Library, container, "Divider", nil, {})

	-- One pixel of rule with a row gap of air on either side.
	local row = Library:Row(container, Library.Sizes.RowGap * 2 + Library.Sizes.Outline)
	row.Name = "DividerRow"

	element.Row = row
	element.ExpandedSize = row.Size
	element.Value = false

	element.Line = Library:Create("Frame", {
		Name = "Line",
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(1, 0, 0, Library.Sizes.Outline),
		Theme = { BackgroundColor3 = "OutlineDim" },
		Parent = row,
	})

	-- A divider is pure chrome: no value, nothing to repaint. Both members
	-- exist only because the element contract requires them.
	function element:Display()
		return self
	end

	function element:SetValue(_value, _silent)
		return self
	end

	return Base.Finish(element, nil)
end

return Divider
end

__modules["elements/Dropdown"] = function()

-- Sable :: elements/Dropdown
--
-- Label on the left, a hairline-outlined value button on the right. The list
-- itself lives in the shared popup layer: Library:OpenPopup owns positioning,
-- outside-click dismissal and the "only one popup at a time" rule, so this
-- module never touches PopupHolder directly beyond parenting its frame.
--
-- Row instances are pooled rather than rebuilt, because :SetValues is commonly
-- called on a timer (player lists) and every rebuild would otherwise leak a
-- hover connection pair per row for the lifetime of the menu.

local Util = require("Util")
local Base = require("elements/Base")

local Dropdown = {}

local PLACEHOLDER = "NONE"

-- Plain text, never an image asset -- the library is text and rectangles only.
local CARET_CLOSED = "\u{25BC}"
local CARET_OPEN = "\u{25B2}"

--- Swaps the scheme key an instance is themed with, so live theme switching
--- keeps working after a state change. Only safe on instances that register
--- exactly ONE property, since RemoveFromRegistry drops every entry they own.
local function repaint(Library, instance, property, key)
	local attribute = "SableKey" .. property
	if instance:GetAttribute(attribute) == key then
		return
	end

	instance:SetAttribute(attribute, key)
	Library:RemoveFromRegistry(instance)
	Library:AddToRegistry(instance, { [property] = key })
end

local function toStringList(values)
	local list = {}
	if type(values) == "table" then
		for index = 1, #values do
			local value = values[index]
			if value ~= nil then
				table.insert(list, tostring(value))
			end
		end
	end
	return list
end

function Dropdown.New(Library, container, index, options)
	options = options or {}

	local element = Base.Create(Library, container, "Dropdown", index, options)

	local Sizes = Library.Sizes
	-- Half a group pad is the library's inner gap unit; Window.lua splits
	-- ColumnGap and GroupPad the same way.
	local padX = math.ceil(Sizes.GroupPad / 2)
	-- The filter field is a row of the popup, exactly like the items below it.
	local searchHeight = Sizes.RowHeight
	-- One glyph of the readout face is all the caret needs; it is drawn as text.
	local caretWidth = Sizes.TextSmall

	element.Values = toStringList(options.Values)
	element.Multi = options.Multi == true
	element.AllowNull = options.AllowNull == true
	element.Searchable = options.Searchable == true
	element.MaxVisible = math.max(
		1,
		math.floor(tonumber(options.MaxVisibleDropdownItems) or Sizes.PopupMaxItems)
	)

	element.Rows = {}
	element.Opened = false
	element.Value = element.Multi and {} or nil

	--==============================================================
	-- row
	--==============================================================

	local row = Library:Row(container)
	element.Row = row
	element.ExpandedSize = row.Size

	-- Label and value button split the row down the middle, with a half pad of
	-- air between them.
	element.Label = Library:Label({
		Name = "Label",
		Size = UDim2.new(0.5, -padX, 1, 0),
		Text = Library:FormatLabel(element.Text),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	}, element.Risky and "Risk" or "Font")

	local button, stroke = Library:Panel({
		Name = "Value",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.new(0.5, 0, 1, -Sizes.RowGap),
		ClipsDescendants = true,
		Parent = row,
	}, "Panel", "Outline")

	element.Button = button
	element.Stroke = stroke

	element.Caret = Library:Label({
		Name = "Caret",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -Sizes.RowGap, 0.5, 0),
		Size = UDim2.new(0, caretWidth, 1, 0),
		TextSize = Sizes.TextSmall,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = CARET_CLOSED,
		Parent = button,
	}, "FontDim")

	-- Everything the caret occupies plus a half pad of clearance on both sides,
	-- so a long value truncates instead of running under the arrow.
	element.ValueLabel = Library:Label({
		Name = "Text",
		Position = UDim2.fromOffset(padX, 0),
		Size = UDim2.new(1, -(padX * 2 + caretWidth + Sizes.RowGap), 1, 0),
		TextSize = Sizes.TextSmall,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = PLACEHOLDER,
		Parent = button,
	}, "FontDim")

	element.Hit = Library:HitButton(button)
	Library:BindHover(element.Hit, button, "Panel", "PanelRaised")

	--==============================================================
	-- popup
	--==============================================================

	local popup = Library:Panel({
		Name = "DropdownPopup",
		Visible = false,
		ClipsDescendants = true,
		Size = UDim2.fromOffset(Sizes.PopupMinWidth, Sizes.RowHeight),
		Parent = Library.PopupHolder,
	}, "Panel", "Outline")

	element.Popup = popup
	Library:CornerTicks(popup, "Accent")

	local listOffset = 0
	if element.Searchable then
		local search = Library:Panel({
			Name = "Search",
			Size = UDim2.new(1, 0, 0, searchHeight),
			ClipsDescendants = true,
			Parent = popup,
		}, "PanelSunken", false)

		Library:Create("Frame", {
			Name = "Rule",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 0, 1, 0),
			Size = UDim2.new(1, 0, 0, Sizes.Outline),
			BorderSizePixel = 0,
			Theme = { BackgroundColor3 = "OutlineDim" },
			Parent = search,
		})

		element.Search = Library:Create("TextBox", {
			Name = "Field",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(padX, 0),
			Size = UDim2.new(1, -padX * 2, 1, 0),
			Font = Library.Fonts.Label,
			TextSize = Sizes.TextSmall,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Center,
			Text = "",
			PlaceholderText = Library:FormatLabel("Filter"),
			ClearTextOnFocus = false,
			ClipsDescendants = true,
			Theme = { TextColor3 = "Font", PlaceholderColor3 = "FontDim" },
			Parent = search,
		})

		listOffset = searchHeight
	end

	element.List = Library:Create("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, listOffset),
		Size = UDim2.new(1, 0, 1, -listOffset),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = Sizes.ScrollBar,
		-- The stock scrollbar has rounded caps. Pinning both end images to the
		-- middle slice squares it off. (There is no "ScrollBarImage" property --
		-- the caps are TopImage/BottomImage.)
		TopImage = "rbxasset://textures/ui/Scroll/scroll-middle.png",
		BottomImage = "rbxasset://textures/ui/Scroll/scroll-middle.png",
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		Parent = popup,
	})

	-- Owns the bar's colour and transparency from here on.
	Library:QuietScrollbar(element.List)

	Util.ListLayout(element.List, 0)

	local function makeRow(position)
		local frame = Library:Create("TextButton", {
			Name = "Item",
			AutoButtonColor = false,
			BorderSizePixel = 0,
			Text = "",
			Size = UDim2.new(1, 0, 0, Sizes.RowHeight),
			LayoutOrder = position,
			Visible = false,
			ClipsDescendants = true,
			Theme = { BackgroundColor3 = "Panel" },
			Parent = element.List,
		})

		local bar = Library:Create("Frame", {
			Name = "Mark",
			BorderSizePixel = 0,
			Visible = false,
			Size = UDim2.new(0, Sizes.Indicator, 1, 0),
			Theme = { BackgroundColor3 = "Accent" },
			Parent = frame,
		})

		-- Text clears the selection bar, then keeps a half pad on both sides.
		local label = Library:Label({
			Name = "Text",
			Position = UDim2.fromOffset(Sizes.Indicator + padX, 0),
			Size = UDim2.new(1, -(Sizes.Indicator + padX * 2), 1, 0),
			TextSize = Sizes.TextSmall,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = frame,
		}, "FontDim")

		local item = {
			Frame = frame,
			Bar = bar,
			Label = label,
			Value = nil,
			Enabled = false,
		}

		Library:BindHover(frame, frame, "Panel", "PanelRaised")

		Library:GiveSignal(frame.MouseButton1Click:Connect(function()
			if not item.Enabled or item.Value == nil then
				return
			end
			element:Choose(item.Value)
		end))

		return item
	end

	--==============================================================
	-- value handling
	--==============================================================

	--- Accepts a string, a set, a list, a number index or nil and returns the
	--- canonical shape for this dropdown's mode.
	function element:Normalise(value)
		local values = self.Values

		if self.Multi then
			local set = {}

			if type(value) == "table" then
				for key, item in value do
					if type(key) == "string" and item then
						if table.find(values, key) then
							set[key] = true
						end
					elseif type(item) == "string" and table.find(values, item) then
						set[item] = true
					end
				end
			elseif type(value) == "number" then
				local name = values[value]
				if name then
					set[name] = true
				end
			elseif type(value) == "string" and table.find(values, value) then
				set[value] = true
			end

			-- No re-seeding here. AllowNull governs SINGLE-select nullability;
			-- an empty multi-selection is a legitimate state. Re-seeding made
			-- the last item impossible to uncheck -- clicking it off put it
			-- straight back -- and silently corrupted an empty saved config.
			return set
		end

		local resolved = nil

		if type(value) == "number" then
			resolved = values[value]
		elseif type(value) == "string" then
			if table.find(values, value) then
				resolved = value
			end
		elseif type(value) == "table" then
			-- A config saved while this index was Multi, or a plain list.
			for key, item in value do
				if type(key) == "string" and item and table.find(values, key) then
					resolved = key
					break
				end
				if type(item) == "string" and table.find(values, item) then
					resolved = item
					break
				end
			end
		end

		if resolved == nil and not self.AllowNull then
			resolved = values[1]
		end

		return resolved
	end

	--- How many characters fit inside the value button at its current width.
	function element:Capacity()
		local width = self.ValueLabel.AbsoluteSize.X
		if width <= 0 then
			-- Character counts, not pixels: a conservative budget for the frame
			-- before the first layout pass has measured the button.
			return 18
		end

		local advance = Util.TextSize("0", self.Library.Sizes.TextSmall, self.Library.Fonts.Value).X
		if advance <= 0 then
			advance = self.Library.Sizes.TextSmall * 0.6
		end

		return math.max(3, math.floor(width / advance))
	end

	function element:Display()
		local text = PLACEHOLDER
		local selected = false

		if self.Multi then
			local names = {}
			for position = 1, #self.Values do
				local name = self.Values[position]
				if self.Value[name] then
					table.insert(names, name)
				end
			end
			if #names > 0 then
				text = table.concat(names, ", ")
				selected = true
			end
		elseif self.Value ~= nil then
			text = self.Value
			selected = true
		end

		self.ValueLabel.Text = Util.Truncate(text, self:Capacity())
		repaint(self.Library, self.ValueLabel, "TextColor3", selected and "Font" or "FontDim")

		for position = 1, #self.Rows do
			local item = self.Rows[position]
			if item.Enabled and item.Value ~= nil then
				local on
				if self.Multi then
					on = self.Value[item.Value] == true
				else
					on = self.Value == item.Value
				end

				item.Bar.Visible = on
				repaint(self.Library, item.Label, "TextColor3", on and "Accent" or "FontDim")
			end
		end

		return self
	end

	function element:SetValue(value, silent)
		self.Value = self:Normalise(value)
		self:Display()

		if not silent then
			self:Fire()
		end

		return self
	end

	--- Applies a row click. Multi toggles and stays open; single selects (or
	--- clears, when AllowNull) and closes.
	function element:Choose(name)
		if self.Multi then
			local set = {}
			for key in self.Value do
				set[key] = true
			end

			if set[name] then
				set[name] = nil
			else
				set[name] = true
			end

			self:SetValue(set)
			return self
		end

		if self.Value == name and self.AllowNull then
			self:SetValue(nil)
		else
			self:SetValue(name)
		end

		self:Close()
		return self
	end

	--==============================================================
	-- list
	--==============================================================

	function element:Filter(query)
		query = tostring(query or ""):lower()

		for position = 1, #self.Rows do
			local item = self.Rows[position]
			local visible = item.Enabled

			if visible and query ~= "" and item.Value ~= nil then
				visible = string.find(item.Value:lower(), query, 1, true) ~= nil
			end

			item.Frame.Visible = visible
		end

		return self
	end

	function element:Rebuild()
		local values = self.Values

		for position = 1, #values do
			local item = self.Rows[position]
			if not item then
				item = makeRow(position)
				self.Rows[position] = item
			end

			item.Value = values[position]
			item.Enabled = true
			item.Label.Text = values[position]
		end

		for position = #values + 1, #self.Rows do
			local item = self.Rows[position]
			item.Value = nil
			item.Enabled = false
			item.Bar.Visible = false
		end

		self:Filter(self.Search and self.Search.Text or "")
		return self
	end

	function element:SetValues(list)
		self.Values = toStringList(list)
		self:Rebuild()

		-- Normalise drops anything that no longer exists, and re-seeds the
		-- first entry when this dropdown may not be empty.
		self.Value = self:Normalise(self.Value)
		self:Display()

		return self
	end

	--==============================================================
	-- open / close
	--==============================================================

	function element:SetOpened(opened)
		self.Opened = opened == true

		repaint(self.Library, self.Stroke, "Color", self.Opened and "Accent" or "Outline")
		repaint(self.Library, self.Caret, "TextColor3", self.Opened and "Accent" or "FontDim")
		self.Caret.Text = self.Opened and CARET_OPEN or CARET_CLOSED

		return self
	end

	function element:Close()
		local active = self.Library.ActivePopup
		if active and active.Frame == self.Popup then
			self.Library:ClosePopup(active)
		end
		return self
	end

	function element:Open()
		local Library = self.Library
		if Library.Unloaded or self.Disabled then
			return self
		end

		local active = Library.ActivePopup
		if active and active.Frame == self.Popup then
			Library:ClosePopup(active)
			return self
		end

		if self.Search then
			self.Search.Text = ""
		end
		self:Filter("")
		self.List.CanvasPosition = Vector2.zero

		local shown = math.max(1, math.min(#self.Values, self.MaxVisible))
		local height = shown * Sizes.RowHeight + (self.Search and searchHeight or 0)

		Library:OpenPopup(self.Popup, self.Button, {
			Height = height,
			Width = math.max(self.Button.AbsoluteSize.X, Sizes.PopupMinWidth),
			Gap = Sizes.RowGap,
			OnClose = function()
				self:SetOpened(false)
			end,
		})

		self:SetOpened(true)
		return self
	end

	--==============================================================
	-- wiring
	--==============================================================

	Library:GiveSignal(element.Hit.MouseButton1Click:Connect(function()
		element:Open()
	end))

	if element.Search then
		Library:GiveSignal(element.Search:GetPropertyChangedSignal("Text"):Connect(function()
			element:Filter(element.Search.Text)
		end))
	end

	-- The button width is layout-driven, so the truncation budget is only known
	-- once it has been measured -- and again whenever the window is resized.
	Library:GiveSignal(element.ValueLabel:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if Library.Unloaded then
			return
		end
		element:Display()
	end))

	element.OnDisabledChanged = function(disabled)
		if disabled then
			element:Close()
		end
	end

	local baseDestroy = Base.Methods.Destroy
	function element:Destroy()
		self:Close()
		pcall(function()
			self.Popup:Destroy()
		end)
		return baseDestroy(self)
	end

	element:Rebuild()
	element:SetValue(options.Default, true)

	return Base.Finish(element, Library.Options)
end

return Dropdown
end

__modules["elements/Image"] = function()

-- Sable :: elements/Image
--
-- The one element that shows something Sable did not draw: a hub banner, a
-- diagram, a captured frame. It is framed exactly like a slider trough -- sunken
-- fill, one hairline outline, one hairline of inset -- so an arbitrary bitmap
-- lands inside the instrument rather than on top of it.
--
-- ScaleType defaults to Fit, which letterboxes rather than crops: an asset of
-- unknown proportions is far more often information than decoration, and half a
-- diagram is worse than a smaller one.
--
-- Registered in Library.Options so a hub can swap the asset live. Like
-- ProgressBar it carries no persistent state: SaveManager's serialize() has no
-- case for this type and returns nil, so it never reaches a config file.

local Util = require("Util")
local Base = require("elements/Base")

local Image = {}

-- Four rows tall by default: enough for an image to be an image, still short
-- enough that one does not push every control below the fold.
local DEFAULT_ROWS = 4

-- How far a disabled image fades toward its background, as a share of the
-- transparency it has left. Text goes FontFaint when disabled; a bitmap has no
-- text colour to dim, and tinting it would be a colour Sable does not own.
local DISABLED_FADE = 0.6

function Image.New(Library, container, index, options)
	options = options or {}

	local element = Base.Create(Library, container, "Image", index, options)

	local Sizes = Library.Sizes

	local height = math.floor(tonumber(options.Height) or Sizes.RowHeight * DEFAULT_ROWS)
	-- A panel shorter than a row is a hairline sandwich, not a picture.
	height = math.max(height, Sizes.RowHeight)

	-- An EnumItem or nothing. A string would have to be resolved by indexing
	-- Enum.ScaleType, which THROWS on a typo rather than returning nil.
	local scaleType = typeof(options.ScaleType) == "EnumItem" and options.ScaleType
		or Enum.ScaleType.Fit

	element.Value = options.Image ~= nil and tostring(options.Image) or ""
	element.Transparency = Util.Clamp(tonumber(options.Transparency) or 0, 0, 1)

	local row = Library:Row(container, height)
	row.Name = "ImageRow"

	element.Row = row
	element.ExpandedSize = row.Size

	local panel = Library:Panel({
		Name = "Panel",
		ClipsDescendants = true,
		Size = UDim2.fromScale(1, 1),
		Parent = row,
	}, "PanelSunken", "Outline")
	element.Panel = panel

	-- One hairline of inset, so the bitmap never sits on the outline it is
	-- framed by. The same inset the segmented track gives its cells.
	Util.Padding(panel, Sizes.Outline)

	local image = Library:Create("ImageLabel", {
		Name = "Image",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Image = element.Value,
		ImageTransparency = element.Transparency,
		ScaleType = scaleType,
		Size = UDim2.fromScale(1, 1),
		Parent = panel,
	})
	element.ImageLabel = image

	--- What is actually on screen: the caller's transparency, faded further while
	--- the element is disabled. Display goes through this rather than writing
	--- element.Transparency straight out, or a repaint mid-disable would quietly
	--- un-fade the image.
	local function shownTransparency()
		local rest = element.Transparency
		if element.Disabled then
			return rest + (1 - rest) * DISABLED_FADE
		end
		return rest
	end

	function element:Display()
		image.Image = self.Value
		image.ImageTransparency = shownTransparency()
		return self
	end

	--- The asset id IS the value, so this and :SetValue are the same operation
	--- under two names -- :SetImage reads better at a call site, :SetValue keeps
	--- the element contract.
	function element:SetImage(asset, silent)
		return self:SetValue(asset, silent)
	end

	function element:SetValue(value, silent)
		self.Value = value ~= nil and tostring(value) or ""
		self:Display()

		if not silent then
			self:Fire()
		end

		return self
	end

	function element:SetTransparency(value)
		self.Transparency = Util.Clamp(tonumber(value) or 0, 0, 1)
		return self:Display()
	end

	element.OnDisabledChanged = function()
		image.ImageTransparency = shownTransparency()
	end

	element:Display()

	return Base.Finish(element, Library.Options)
end

return Image
end

__modules["elements/Input"] = function()

-- Sable :: elements/Input
--
-- Single-line text field. Label left, sunken field right; the field's hairline
-- goes Accent while focused so the box you are typing into reads at a glance.

local Util = require("Util")
local Base = require("elements/Base")

local Input = {}

-- Share of the row the field occupies when there is a label to sit beside. A
-- ratio, not a pixel: the row splits down the middle at any column width.
local FIELD_SCALE = 0.5

--- Accepts a leading '-' and at most one '.', so half-typed numbers ("-", ".",
--- "-1.") stay editable while anything non-numeric is rejected outright.
local function isNumericText(text)
	local body = text
	if body:sub(1, 1) == "-" then
		body = body:sub(2)
	end
	return body:match("^%d*%.?%d*$") ~= nil
end

--- Character-wise truncation. Byte truncation would be enough for ASCII but
--- can split a multi-byte codepoint and hand Roblox invalid UTF-8.
local function limit(text, maxLength)
	if not maxLength then
		return text
	end

	local length = utf8.len(text)
	if not length then
		return text:sub(1, maxLength)
	end
	if length <= maxLength then
		return text
	end

	local offset = utf8.offset(text, maxLength + 1)
	return text:sub(1, (offset or (maxLength + 1)) - 1)
end

function Input.New(Library, container, index, options)
	options = options or {}

	local element = Base.Create(Library, container, "Input", index, options)

	local Sizes = Library.Sizes
	-- Half a group pad of air between the label and the field; Window.lua splits
	-- ColumnGap and GroupPad the same way.
	local labelGap = math.ceil(Sizes.GroupPad / 2)

	local numeric = options.Numeric == true
	local finished = options.Finished == true
	local maxLength = nil
	if type(options.MaxLength) == "number" then
		maxLength = math.max(0, math.floor(options.MaxLength))
	end

	--- Everything that reaches element.Value passes through here, so a script
	--- calling :SetValue can never install text the user could not have typed.
	local function coerce(value)
		local text = value == nil and "" or tostring(value)
		if numeric and not isNumericText(text) then
			text = text:match("^%-?%d*%.?%d*") or ""
		end
		return limit(text, maxLength)
	end

	local initial = coerce(options.Default)

	local row = Library:Row(container)
	element.Row = row
	element.ExpandedSize = row.Size

	local hasLabel = element.Text ~= ""

	if hasLabel then
		element.Label = Library:Label({
			Name = "Label",
			Size = UDim2.new(1 - FIELD_SCALE, -labelGap, 1, 0),
			Text = Library:FormatLabel(element.Text),
			TextSize = Sizes.Text,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = row,
		}, element.Risky and "Risk" or "Font")
	end

	local field = Library:Panel({
		Name = "Field",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		-- A row gap short of the full row, so the field's hairline is not welded
		-- to the rows above and below it.
		Size = hasLabel and UDim2.new(FIELD_SCALE, 0, 1, -Sizes.RowGap)
			or UDim2.new(1, 0, 1, -Sizes.RowGap),
		ClipsDescendants = true,
		Parent = row,
	}, "PanelSunken", false)

	local focused = false

	local stroke = Util.Stroke(field, Library:GetColor("Outline"), Sizes.Outline)
	-- Registered as a resolver rather than a flat key: a live theme switch while
	-- the field is focused must repaint to the new Accent, not to Outline.
	Library:AddToRegistry(stroke, {
		Color = function(scheme)
			return focused and scheme.Accent or scheme.Outline
		end,
	})

	local box = Library:Create("TextBox", {
		Name = "Box",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Font = Library.Fonts.Value,
		TextSize = Sizes.TextSmall,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		ClearTextOnFocus = options.ClearTextOnFocus ~= false,
		Text = initial,
		PlaceholderText = tostring(options.Placeholder or ""),
		Theme = { TextColor3 = "Font", PlaceholderColor3 = "FontFaint" },
		Parent = field,
	})

	Util.Padding(box, 0, Sizes.RowGap, 0, Sizes.RowGap)

	element.Value = initial
	element.Field = field
	element.Box = box
	element.Hit = box

	local lastValid = initial
	-- Guard for programmatic writes. Property-changed signals can be delivered
	-- deferred, so a boolean flipped around the write would already be back to
	-- false by the time the handler runs -- remembering the exact text we wrote
	-- is the guard that actually holds.
	local pending = nil

	local function assign(text)
		if box.Text == text then
			return
		end
		pending = text
		box.Text = text
	end

	local function paintOutline()
		if Library.Unloaded then
			return
		end
		Library:Tween(stroke, {
			Color = Library:GetColor(focused and "Accent" or "Outline"),
		}, Library.Motion.Fast)
	end

	Library:GiveSignal(box:GetPropertyChangedSignal("Text"):Connect(function()
		local text = box.Text

		if pending ~= nil then
			local expected = pending
			pending = nil
			if text == expected then
				return
			end
		end

		if numeric and not isNumericText(text) then
			assign(lastValid)
			return
		end

		local capped = limit(text, maxLength)
		if capped ~= text then
			assign(capped)
			text = capped
		end

		lastValid = text

		-- Also covers any stale event left over from a programmatic write: if
		-- the text already matches the stored value there is nothing to report.
		if text == element.Value then
			return
		end

		element.Value = text

		if not finished then
			element:Fire()
		end
	end))

	Library:GiveSignal(box.Focused:Connect(function()
		focused = true
		paintOutline()
	end))

	-- A Finished input commits on Enter *or* on losing focus, and both land
	-- here, so the enterPressed flag is not needed to tell them apart.
	Library:GiveSignal(box.FocusLost:Connect(function()
		focused = false
		paintOutline()

		if finished and not element.Disabled then
			element:Fire()
		end
	end))

	element.OnDisabledChanged = function(disabled)
		box.TextEditable = not disabled
		if disabled and focused then
			box:ReleaseFocus()
		end

		-- Replace rather than stack: later registry entries are applied before
		-- earlier ones, so an orphaned entry would win the next theme update.
		Library:RemoveFromRegistry(box)
		Library:AddToRegistry(box, {
			TextColor3 = disabled and "FontFaint" or "Font",
			PlaceholderColor3 = "FontFaint",
		})
	end

	function element:Display()
		assign(self.Value)
	end

	function element:SetValue(value, silent)
		local text = coerce(value)

		lastValid = text
		self.Value = text
		self:Display()

		if not silent then
			self:Fire()
		end

		return self
	end

	return Base.Finish(element, Library.Options)
end

return Input
end

__modules["elements/KeyPicker"] = function()

-- Sable :: elements/KeyPicker
--
-- A bind capture pill, in two shapes: a standalone row, and an inline addon
-- that rides in a Toggle's / Label's Right slot. State is driven off the
-- library input signals rather than a polling loop, so a Hold bind releases on
-- exactly the frame the key does.

local Util = require("Util")
local Base = require("elements/Base")

local UserInputService = game:GetService("UserInputService")

local KeyPicker = {}

local MODES = { "Toggle", "Hold", "Always" }
local MODE_SET = { Toggle = true, Hold = true, Always = true }

-- Only one pill may be capturing at a time, library-wide: a second click has to
-- cancel the first, or two pickers would swallow the same keystroke.
local ActiveCapture = nil

-- Feeds the stable per-picker id used by the keybind overlay.
local PickerCount = 0

-- A mouse bind resolves on the button *press* that also produces the pill's
-- Click event, so without a short debounce the pill re-enters capture instantly.
local CLICK_DEBOUNCE = 0.2

--==============================================================
-- helpers
--==============================================================

--- Bind names are stored the way Util.InputName produces them (uppercase), so
--- a hand-written Default of "e" still matches a real E press.
local function normalizeKey(key)
	if type(key) ~= "string" or key == "" then
		return "None"
	end

	local upper = key:upper()
	if upper == "NONE" then
		return "None"
	end

	return upper
end

local function normalizeMode(mode)
	if type(mode) ~= "string" or mode == "" then
		return nil
	end

	local canonical = mode:sub(1, 1):upper() .. mode:sub(2):lower()
	if MODE_SET[canonical] then
		return canonical
	end

	return nil
end

--- Swaps a themed colour without leaving a stale registry entry behind. The
--- registry re-applies oldest-entry-last, so simply adding a second entry for
--- the same property would lose to the original on the next theme change.
local function recolor(Library, instance, property, key)
	Library:RemoveFromRegistry(instance)
	Library:AddToRegistry(instance, { [property] = key })
end

--- Inline addons occupy LayoutOrder 10..99 in an element's Right slot, left of
--- the element's own control at 100. Counting what is already there keeps the
--- order stable no matter which addon type was attached first.
local function nextAddonOrder(right)
	local used = 0

	for _, child in right:GetChildren() do
		local gui = child :: any
		if child:IsA("GuiObject") and gui.LayoutOrder >= 10 and gui.LayoutOrder < 100 then
			used += 1
		end
	end

	return 10 + used
end

--- Half a group pad: the library's inner gap unit. Window.lua splits ColumnGap
--- and GroupPad the same way.
local function halfPad(Library)
	return math.ceil(Library.Sizes.GroupPad / 2)
end

--- The pill itself: hairline panel, monospace bind name, auto width.
local function buildPill(Library, parent, standalone, layoutOrder)
	local Sizes = Library.Sizes
	local padX = halfPad(Library)

	local pill, stroke = Library:Panel({
		Name = "Bind",
		AnchorPoint = standalone and Vector2.new(1, 0.5) or Vector2.new(0, 0),
		Position = standalone and UDim2.new(1, 0, 0.5, 0) or UDim2.new(0, 0, 0, 0),
		-- One control square tall plus a row gap of air, so the bind text is not
		-- jammed against the hairline. Still short enough that the pill, its
		-- stroke and a swatch all clear a RowHeight addon slot.
		Size = UDim2.new(0, 0, 0, Sizes.Control + Sizes.RowGap),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = layoutOrder or 1,
		Parent = parent,
	}, "Panel", "Outline")

	Util.Padding(pill, 0, padX, 0, padX)

	local value = Library:Label({
		Name = "Value",
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = Library.Fonts.Value,
		TextSize = Sizes.TextSmall,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "NONE",
		Parent = pill,
	}, "FontDim")

	local hit = Library:HitButton(pill, { Name = "Hit" })

	return pill, stroke, value, hit
end

--==============================================================
-- behaviour
--==============================================================

--- Everything both constructors share. `host` is the element this picker is
--- attached to, or nil for a standalone row.
local function install(Library, element, options, host, pill, stroke, value, hit)
	PickerCount += 1

	local overlayId = ("Sable.KeyPicker.%d.%s"):format(PickerCount, tostring(element.Index))
	local clickCallbacks = {}
	local lastCaptureEnd = 0

	-- SyncToggleState is only meaningful on a host that owns a boolean.
	local sync = host ~= nil and options.SyncToggleState == true and host.Type == "Toggle"
	local syncing = false

	local popupFrame = nil
	local popupHandle = nil
	local popupRows = nil
	local refreshPopup = nil

	element.Value = normalizeKey(options.Default)
	element.Mode = normalizeMode(options.Mode) or "Toggle"
	element.State = false
	element.Capturing = false
	element.NoUI = options.NoUI == true

	--==========================================================
	-- paint
	--==========================================================

	--- The overlay is installed by Overlays, which may not have run when this
	--- module was required -- so it is resolved on every call, never cached.
	local function overlay()
		if element.NoUI then
			return
		end

		local list = Library.KeybindList
		if not list then
			return
		end

		-- An UNBOUND picker does not belong on the HUD. It used to register
		-- anyway, so a hub that declares ten keybinds and binds none showed ten
		-- rows of "KEYBIND [NONE]" -- a list of things that cannot happen,
		-- occupying the corner of the screen from the moment the script loaded.
		--
		-- Remove rather than skip: a picker that is CLEARED back to None has to
		-- leave the list, not sit there stale at its old key.
		if element.Value == nil or element.Value == "None" then
			list:Remove(overlayId)
			return
		end

		list:Set(overlayId, {
			Text = element.Text,
			Key = element.Value,
			Mode = element.Mode,
			Active = element:GetState(),
		})
	end

	function element:GetState()
		if self.Mode == "Always" then
			return true
		end
		if self.Mode == "Hold" then
			return Util.IsHeld(self.Value)
		end
		return self.State == true
	end

	function element:Display()
		local capturing = self.Capturing

		value.Text = capturing and "..." or Library:FormatLabel(self.Value)

		local textKey
		if self.Disabled then
			textKey = "FontFaint"
		elseif capturing then
			textKey = "Accent"
		elseif self:GetState() then
			textKey = "Font"
		else
			textKey = "FontDim"
		end

		recolor(Library, value, "TextColor3", textKey)
		recolor(Library, stroke, "Color", capturing and "Accent" or (self.Disabled and "OutlineDim" or "Outline"))

		if refreshPopup then
			refreshPopup()
		end
	end

	-- Base repaints the row label on its own; the pill needs the same nudge.
	element.OnDisabledChanged = function()
		element:Display()
	end

	--==========================================================
	-- state
	--==========================================================

	local function fireState()
		Library:SafeCallback(options.Callback, element.State, element)

		for _, callback in clickCallbacks do
			Library:SafeCallback(callback, element.State, element)
		end
	end

	local function setState(state, silent)
		state = state == true
		if element.State == state then
			return
		end

		element.State = state
		element:Display()
		overlay()

		if sync and not syncing then
			syncing = true
			host:SetValue(state)
			syncing = false
		end

		if not silent then
			fireState()
		end
	end

	--- Hold and Always are derived states -- recompute them whenever the bind
	--- or the mode moves. Toggle keeps whatever the user last set.
	local function reconcileState(silent)
		if element.Mode == "Always" then
			setState(true, silent)
		elseif element.Mode == "Hold" then
			setState(Util.IsHeld(element.Value), silent)
		end
	end

	--==========================================================
	-- capture
	--==========================================================

	local function endCapture()
		if not element.Capturing then
			return
		end

		element.Capturing = false
		lastCaptureEnd = os.clock()

		if ActiveCapture == element then
			ActiveCapture = nil
			-- Deferred: handlers further down the same InputBegan dispatch must
			-- still see the flag, or the keystroke just bound here would also
			-- fire whatever else listens for it.
			task.defer(function()
				if not ActiveCapture then
					Library.CapturingInput = false
				end
			end)
		end

		element:Display()
	end

	element.CancelCapture = endCapture

	local function beginCapture()
		if element.Disabled or element.Capturing then
			return
		end
		if os.clock() - lastCaptureEnd < CLICK_DEBOUNCE then
			return
		end

		if ActiveCapture then
			ActiveCapture.CancelCapture()
		end

		Library:ClosePopup()

		element.Capturing = true
		ActiveCapture = element
		Library.CapturingInput = true

		element:Display()
	end

	--==========================================================
	-- mode popup
	--==========================================================

	local Sizes = Library.Sizes
	local padX = halfPad(Library)

	local rowHeight = Sizes.RowHeight
	-- The rows sit inside a one-hairline inset, which the popup has to carry.
	local popupHeight = rowHeight * #MODES + Sizes.Outline * 2
	local popupWidth = 0

	for _, mode in MODES do
		local measured = Util.TextSize(Library:FormatLabel(mode), Sizes.TextSmall, Library.Fonts.Value)
		popupWidth = math.max(popupWidth, measured.X)
	end
	-- Widest mode name, plus each row's own padding and the same hairline inset.
	popupWidth = math.ceil(popupWidth) + padX * 2 + Sizes.Outline * 2

	local function buildPopup()
		if popupFrame then
			return
		end

		local frame = Library:Panel({
			Name = "BindModes",
			Visible = false,
			Size = UDim2.fromOffset(popupWidth, popupHeight),
			Parent = Library.PopupHolder,
		}, "Panel", "Outline")

		-- The ticks must NOT share a parent with the list layout: UIListLayout
		-- positions every GuiObject child with no opt-out, so eight tick frames
		-- would be laid out as rows and shove the real ones out of the popup.
		Library:CornerTicks(frame, "Accent")

		local content = Library:Create("Frame", {
			Name = "Content",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			Parent = frame,
		})

		Util.Padding(content, Sizes.Outline, Sizes.Outline, Sizes.Outline, Sizes.Outline)
		Util.ListLayout(content, 0)

		popupRows = {}

		for order, mode in MODES do
			local rowFrame = Library:Panel({
				Name = mode,
				Size = UDim2.new(1, 0, 0, rowHeight),
				LayoutOrder = order,
				Parent = content,
			}, "Panel", false)

			local rowLabel = Library:Label({
				Name = "Text",
				Size = UDim2.fromScale(1, 1),
				Font = Library.Fonts.Value,
				TextSize = Sizes.TextSmall,
				Text = Library:FormatLabel(mode),
				Parent = rowFrame,
			}, "FontDim")

			Util.Padding(rowLabel, 0, padX, 0, padX)

			local rowHit = Library:HitButton(rowFrame, { Name = "Hit" })
			Library:BindHover(rowHit, rowFrame, "Panel", "PanelRaised")

			Library:GiveSignal(rowHit.MouseButton1Click:Connect(function()
				Library:ClosePopup(popupHandle)
				popupHandle = nil
				element:SetValue({ Key = element.Value, Mode = mode })
			end))

			popupRows[mode] = rowLabel
		end

		popupFrame = frame
	end

	refreshPopup = function()
		if not popupRows then
			return
		end

		for mode, rowLabel in popupRows do
			recolor(Library, rowLabel, "TextColor3", mode == element.Mode and "Accent" or "FontDim")
		end
	end

	local function openModePopup()
		buildPopup()
		refreshPopup()

		popupHandle = Library:OpenPopup(popupFrame, pill, {
			Width = popupWidth,
			Height = popupHeight,
			OnClose = function()
				popupHandle = nil
			end,
		})
	end

	--==========================================================
	-- public value api
	--==========================================================

	--- Accepts "E", { "E", "Hold" } or { Key = "E", Mode = "Hold" }.
	function element:SetValue(newValue, silent)
		local key, mode = self.Value, self.Mode

		if type(newValue) == "table" then
			key = newValue.Key or newValue.key or newValue[1] or key
			mode = newValue.Mode or newValue.mode or newValue[2] or mode
		elseif newValue ~= nil then
			key = newValue
		end

		self.Value = normalizeKey(key)
		self.Mode = normalizeMode(mode) or self.Mode

		reconcileState(silent)
		self:Display()
		overlay()

		if not silent then
			self:Fire()
		end

		return self
	end

	--- KeyPicker splits its callbacks: Callback carries the on/off state, while
	--- Fire (bind or mode changed) drives ChangedCallback and OnChanged.
	function element:Fire()
		Library:SafeCallback(options.ChangedCallback, self.Value, self)

		for _, callback in self.Callbacks do
			Library:SafeCallback(callback, self.Value, self)
		end
	end

	function element:OnClick(callback)
		if type(callback) == "function" then
			table.insert(clickCallbacks, callback)
		end
		return self
	end

	-- The overlay row carries the element's text, so renaming has to repost it.
	local baseSetText = Base.Methods.SetText

	function element:SetText(text)
		baseSetText(self, text)
		overlay()
		return self
	end

	--==========================================================
	-- input
	--==========================================================

	Library:GiveSignal(hit.MouseButton1Click:Connect(function()
		beginCapture()
	end))

	Library:GiveSignal(hit.MouseButton2Click:Connect(function()
		if element.Disabled then
			return
		end
		if element.Capturing then
			endCapture()
			return
		end
		if os.clock() - lastCaptureEnd < CLICK_DEBOUNCE then
			return
		end
		openModePopup()
	end))

	Library:GiveSignal(Library.InputBegan:Connect(function(input)
		-- Destroyed is set by Base:Destroy. Without it this closure keeps the
		-- element alive and a deleted bind still runs the user's callback.
		if Library.Unloaded or element.Destroyed then
			return
		end

		if element.Capturing then
			local name = Util.InputName(input)
			if not name then
				return
			end

			endCapture()
			element:SetValue(name == "ESC" and "None" or name)
			return
		end

		if Library.CapturingInput or element.Disabled then
			return
		end
		if UserInputService:GetFocusedTextBox() then
			return
		end
		if element.Value == "None" or not Util.InputMatches(input, element.Value) then
			return
		end

		if element.Mode == "Toggle" then
			setState(not element.State)
		elseif element.Mode == "Hold" then
			setState(true)
		end
	end))

	Library:GiveSignal(Library.InputEnded:Connect(function(input)
		if Library.Unloaded or element.Destroyed or element.Mode ~= "Hold" then
			return
		end
		if element.Value == "None" or not Util.InputMatches(input, element.Value) then
			return
		end

		-- Releases are honoured even mid-capture or with a textbox focused: a
		-- Hold bind stuck on is far worse than one that drops early.
		setState(false)
	end))

	--==========================================================
	-- teardown
	--==========================================================

	local baseDestroy = Base.Methods.Destroy

	function element:Destroy()
		endCapture()

		if popupHandle then
			Library:ClosePopup(popupHandle)
			popupHandle = nil
		end

		if popupFrame then
			Library:RemoveFromRegistry(popupFrame)
			pcall(function()
				popupFrame:Destroy()
			end)
			popupFrame = nil
			popupRows = nil
		end

		local list = Library.KeybindList
		if list and not self.NoUI then
			list:Remove(overlayId)
		end

		table.clear(clickCallbacks)
		baseDestroy(self)
	end

	Library:OnUnload(function()
		-- Immediate, not deferred: nothing is left running to clear the flag.
		if element.Capturing then
			element.Capturing = false
			if ActiveCapture == element then
				ActiveCapture = nil
			end
			Library.CapturingInput = false
		end
	end)

	--==========================================================
	-- initial state
	--==========================================================

	if sync then
		element.State = host.Value == true

		host:OnChanged(function(hostValue)
			if syncing then
				return
			end
			syncing = true
			setState(hostValue == true)
			syncing = false
		end)
	end

	reconcileState(true)
	element:Display()
	overlay()
end

--==============================================================
-- constructors
--==============================================================

function KeyPicker.New(Library, container, index, options)
	options = options or {}

	local element = Base.Create(Library, container, "KeyPicker", index, options)

	local row = Library:Row(container)
	element.Row = row
	element.ExpandedSize = row.Size

	local label = Library:Label({
		Name = "Label",
		Size = UDim2.new(1, 0, 1, 0),
		Text = Library:FormatLabel(element.Text),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	}, element.Risky and "Risk" or "Font")
	element.Label = label

	local pill, stroke, value, hit = buildPill(Library, row, true, nil)
	element.Hit = hit

	-- The pill's width is only known once AutomaticSize has run, so the label
	-- reserves its space reactively instead of guessing.
	local labelGap = halfPad(Library)

	Library:GiveSignal(pill:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		label.Size = UDim2.new(1, -(pill.AbsoluteSize.X + labelGap), 1, 0)
	end))

	install(Library, element, options, nil, pill, stroke, value, hit)

	return Base.Finish(element, Library.Options)
end

function KeyPicker.Attach(Library, host, index, options)
	options = options or {}

	-- Registered against the host's container so the groupbox still owns it,
	-- but the pill (not the host row) is the element's own frame.
	local element = Base.Create(Library, host.Parent, "KeyPicker", index, options)

	local pill, stroke, value, hit = buildPill(Library, host.Right, false, nextAddonOrder(host.Right))
	element.Row = pill
	element.ExpandedSize = pill.Size
	element.Hit = hit
	element.Host = host

	install(Library, element, options, host, pill, stroke, value, hit)

	host.KeyPicker = element

	return Base.Finish(element, Library.Options)
end

return KeyPicker
end

__modules["elements/Label"] = function()

-- Sable :: elements/Label
--
-- Static caption row. It carries the addon slot (element.Right) so a bare
-- caption can host an inline ColorPicker/KeyPicker exactly like a Toggle can,
-- which is how Linoria-shaped scripts attach a bind to a piece of prose.

local Base = require("elements/Base")

local Label = {}

function Label.New(Library, container, text, doesWrap)
	local wraps = doesWrap == true

	local element = Base.Create(Library, container, "Label", nil, {
		Text = text ~= nil and tostring(text) or "",
	})

	local Sizes = Library.Sizes
	--- Space kept between the caption and whatever sits in the addon slot; the
	--- same gap the slot's own list layout uses between two addons.
	local addonGap = Sizes.RowGap

	-- A wrapping label cannot know its height until the text has been laid out
	-- against the real column width, so the row measures itself instead. The
	-- declared height stays RowHeight either way: AutomaticSize treats it as a
	-- floor, which is what keeps a one-line wrapped caption from collapsing
	-- shorter than the addon pill docked beside it.
	local row = Library:Row(container, Sizes.RowHeight)
	row.Name = "LabelRow"
	if wraps then
		row.AutomaticSize = Enum.AutomaticSize.Y
	end

	element.Row = row
	element.ExpandedSize = row.Size
	element.Value = element.Text

	local caption = Library:Label({
		Name = "Text",
		Size = wraps and UDim2.new(1, 0, 0, 0) or UDim2.fromScale(1, 1),
		AutomaticSize = wraps and Enum.AutomaticSize.Y or Enum.AutomaticSize.None,
		TextWrapped = wraps,
		TextYAlignment = wraps and Enum.TextYAlignment.Top or Enum.TextYAlignment.Center,
		TextSize = Sizes.Text,
		Text = Library:FormatLabel(element.Text),
		Parent = row,
	}, "FontDim")

	element.Label = caption

	element.Right = Library:Create("Frame", {
		Name = "Right",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = row,
	})

	Library:Create("UIListLayout", {
		Name = "List",
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, addonGap),
		Parent = element.Right,
	})

	-- Attached pickers grow the slot; give the text back only what is left so a
	-- long caption never runs underneath a swatch or a bind.
	local function reserve()
		local used = element.Right.AbsoluteSize.X
		if used > 0 then
			used += addonGap
		end
		caption.Size = UDim2.new(1, -used, wraps and 0 or 1, 0)
	end

	Library:GiveSignal(element.Right:GetPropertyChangedSignal("AbsoluteSize"):Connect(reserve))

	function element:Display()
		self.Value = self.Text
		self.Label.Text = self.Library:FormatLabel(self.Text)
	end

	--- Base:SetText is the normal entry point; this exists so a Label answers
	--- the same :SetValue(value, silent) contract every other element does.
	function element:SetValue(value, silent)
		self:SetText(value ~= nil and tostring(value) or "")
		self:Display()

		if not silent then
			self:Fire()
		end

		return self
	end

	if wraps then
		-- AutomaticSize would immediately undo the zero height SetVisible uses
		-- to collapse a row, so it has to be off for as long as the row is.
		function element:SetVisible(visible)
			visible = visible ~= false
			row.AutomaticSize = visible and Enum.AutomaticSize.Y or Enum.AutomaticSize.None
			return Base.Methods.SetVisible(self, visible)
		end
	end

	return Base.Finish(element, nil)
end

return Label
end

__modules["elements/Numeric"] = function()

-- Sable :: elements/Numeric
--
-- The label / segmented track / readout row, shared by Slider and ProgressBar.
--
-- elements/Track already guarantees one segmented bar. This guarantees one of
-- everything wrapped around it: the bounds arithmetic, the rounding, the readout
-- sized for the widest value it can ever show, and the three-column layout that
-- keeps the track between the other two. Two copies of that drift apart the
-- moment either one is fixed, so there is one -- and the owners differ only in
-- what they layer over it. Slider adds a hit target, a drag, and a readout that
-- brightens while it is held; ProgressBar adds nothing, which is exactly what
-- makes it a readout.
--
-- This is a helper, not an element: it has no store entry and never calls
-- Base.Finish. The owner does that, after it has attached its own interaction.

local Util = require("Util")
local Track = require("elements/Track")

local Numeric = {}

-- Share of the row a label may claim before it starts squeezing the track. A
-- ratio, not a pixel: the row width is layout-driven and changes when the window
-- is resized, so a fixed cap would be wrong at every size but one.
local LABEL_SHARE = 0.45

local ROUNDING_MAX = 6

--- Builds the row inside `element.Parent` and installs the numeric API --
--- `:Display`, `:SetValue`, `:SetMin`, `:SetMax`, `:SetText` and the disabled
--- repaint -- onto `element`.
---
--- `config` is the short list of things the two owners disagree about:
---   Suffix   suffix used when the caller passes none   (ProgressBar: "%")
---   Default  value used when the caller passes none    (ProgressBar: 0)
---   Compact  honour options.Compact and drop the label (Slider only)
---
--- Returns the pieces an owner needs to layer interaction over the row: the
--- trough to hang a hit target on, `ValueFromAlpha` to turn a position along it
--- into a legal value, and `SetActive` to lift the readout while a drag is live.
function Numeric.New(Library, element, options, config)
	options = options or {}
	config = config or {}

	local Sizes = Library.Sizes
	-- label <-> track <-> readout. Half a group pad is the library's inner gap
	-- unit; Window.lua splits ColumnGap and GroupPad the same way.
	local gap = math.ceil(Sizes.GroupPad / 2)

	element.Min = tonumber(options.Min) or 0
	element.Max = tonumber(options.Max) or 100
	element.Rounding = math.floor(Util.Clamp(tonumber(options.Rounding) or 0, 0, ROUNDING_MAX))
	-- A bare number reads as a bare number, so an owner may name a better default
	-- than nothing -- the overwhelmingly common progress readout is a percentage.
	element.Suffix = tostring(options.Suffix or config.Suffix or "")
	-- Whether a whole number is allowed to print as one. OFF for a ProgressBar,
	-- whose padded decimals hold a column of readouts aligned; ON for a Slider,
	-- which is a control you set rather than a column you scan, and where
	-- "10.0%" / "0.0%" is just noise around the number you actually wanted.
	-- An owner can still force either way per element.
	if options.TrimZeros ~= nil then
		element.TrimZeros = options.TrimZeros == true
	else
		element.TrimZeros = config.TrimZeros == true
	end
	-- Left unset for an owner that does not offer it, rather than set to false: a
	-- ProgressBar carrying a Compact field would advertise an option that does
	-- nothing. Everything below reads it for truth, so absent and off are one.
	if config.Compact then
		element.Compact = options.Compact == true
	end
	element.Segments = Track.Count(options.Segments, Sizes)
	element.Value = element.Min

	--==============================================================
	-- visuals
	--==============================================================

	local row = Library:Row(element.Parent)
	element.Row = row
	element.ExpandedSize = row.Size

	local label = Library:Label({
		Name = "Label",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(0, 0, 1, 0),
		Text = Library:FormatLabel(element.Text),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Visible = not element.Compact,
		Parent = row,
	}, element.Risky and "Risk" or "Font")
	element.Label = label

	-- Declared ahead of the readout: its registry entry closes over this so a
	-- theme switch mid-drag still resolves to the active colour.
	local active = false

	--- FontDim at rest. It lifts to Font only while an owner says an interaction
	--- is live, so a ProgressBar -- which never says so -- can never promise a
	--- drag that does not exist.
	local function readoutKey()
		if element.Disabled then
			return "FontFaint"
		end
		return active and "Font" or "FontDim"
	end

	local readout = Library:Create("TextLabel", {
		Name = "Readout",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.new(0, 0, 1, 0),
		Font = Library.Fonts.Value,
		TextSize = Sizes.TextSmall,
		TextXAlignment = Enum.TextXAlignment.Right,
		TextYAlignment = Enum.TextYAlignment.Center,
		Text = "",
		Theme = {
			TextColor3 = function()
				return Library:GetColor(readoutKey())
			end,
		},
		Parent = row,
	})

	-- The segmented bar itself; see elements/Track.
	local bar = Track.New(Library, row, element.Segments)
	local trough = bar.Trough
	element.Bar = bar

	--==============================================================
	-- value math
	--==============================================================

	--- A Max below Min collapses to a single value rather than dividing by a
	--- negative span.
	local function bounds()
		local low = element.Min
		local high = element.Max
		if high < low then
			high = low
		end
		return low, high
	end

	--- Half UP, rather than the half-away-from-zero Util.FormatNumber's integer
	--- path uses -- the only thing the two disagree about. A value arriving from
	--- normalize is already rounded and reads the same either way; the raw bounds
	--- relayout measures are not, so this stays local rather than quietly moving
	--- the readout column by a character. The decimal path is string.format in
	--- both, so only the integer case is handled here.
	local function formatValue(value)
		if element.Rounding <= 0 then
			return tostring(math.floor(value + 0.5))
		end
		return Util.FormatNumber(value, element.Rounding)
	end

	--- What the user actually reads. `%.2f` on a slider that happens to be
	--- sitting on a whole number prints "10.00%" / "0.0%", which is noise: the
	--- decimals exist so the value CAN be fractional, not so it always looks
	--- fractional. Trim a trailing zero run, and the now-orphaned point with it.
	---
	--- Deliberately NOT used by relayout. The readout column is sized from the
	--- widest value the slider can ever show, and trimming only ever shortens,
	--- so measuring the UNtrimmed bounds keeps that column still while the
	--- displayed text gets shorter. Measuring the trimmed form instead would let
	--- a fractional mid-drag value overflow a column sized from two whole-number
	--- endpoints -- exactly the twitch the sizing exists to prevent.
	local function displayValue(value)
		local text = formatValue(value)
		if element.TrimZeros and element.Rounding > 0 and string.find(text, ".", 1, true) then
			text = string.gsub(text, "0+$", "")
			text = string.gsub(text, "%.$", "")
		end
		return text
	end

	local function normalize(value)
		local low, high = bounds()
		local number = tonumber(value)
		if not number then
			number = low
		end
		-- Clamp last: a bound that is off the rounding grid still has to be
		-- reachable exactly.
		return Util.Clamp(Util.Round(number, element.Rounding), low, high)
	end

	local function measure(text, textSize, font)
		return math.ceil(Util.TextSize(text, textSize, font).X)
	end

	--- Maps a 0..1 position along the track onto a legal value. The one place a
	--- pointer becomes a number, so an interactive owner never restates the
	--- bounds or the rounding.
	local function valueFromAlpha(alpha)
		local low, high = bounds()
		return normalize(low + alpha * (high - low))
	end

	--==============================================================
	-- layout
	--==============================================================

	--- The readout is sized for the widest value it can ever show, so the track
	--- does not twitch as digits come and go.
	local function relayout()
		local low, high = bounds()
		local readoutWidth = math.max(
			measure(formatValue(low) .. element.Suffix, Sizes.TextSmall, Library.Fonts.Value),
			measure(formatValue(high) .. element.Suffix, Sizes.TextSmall, Library.Fonts.Value)
		) + Sizes.Outline * 2

		readout.Size = UDim2.new(0, readoutWidth, 1, 0)

		local labelWidth = 0
		if not element.Compact then
			labelWidth = measure(label.Text, Sizes.Text, Library.Fonts.Label) + Sizes.Outline

			-- Capped against the LIVE row, not a fixed pixel budget, so the same
			-- cap holds after the window is resized. Before the first layout pass
			-- the row has no width yet and the measured label stands.
			local available = row.AbsoluteSize.X
			if available > 0 then
				labelWidth = math.min(labelWidth, math.floor(available * LABEL_SHARE))
			end
		end

		label.Visible = not element.Compact
		label.Size = UDim2.new(0, labelWidth, 1, 0)

		local left = labelWidth > 0 and labelWidth + gap or 0
		trough.Position = UDim2.new(0, left, 0.5, 0)
		trough.Size = UDim2.new(1, -(left + gap + readoutWidth), 0, Sizes.Track)
	end

	local function paintReadout(animate)
		local color = Library:GetColor(readoutKey())
		if animate then
			Library:Tween(readout, { TextColor3 = color }, Library.Motion.Fast)
		else
			readout.TextColor3 = color
		end
	end

	--==============================================================
	-- api
	--==============================================================

	function element:Display()
		local low, high = bounds()
		local alpha = high > low and Util.Alpha(self.Value, low, high) or 0

		bar:Paint(alpha, self.Disabled and "AccentDim" or "Accent")

		readout.Text = displayValue(self.Value) .. self.Suffix

		return self
	end

	function element:SetValue(value, silent)
		self.Value = normalize(value)
		self:Display()

		if not silent then
			self:Fire()
		end

		return self
	end

	--- Shared tail of SetMin/SetMax: the readout may need a different width and
	--- the current value may no longer be in range.
	local function rebound()
		relayout()

		local clamped = normalize(element.Value)
		if clamped ~= element.Value then
			element:SetValue(clamped)
		else
			element:Display()
		end
	end

	function element:SetMin(value)
		self.Min = tonumber(value) or self.Min
		rebound()
		return self
	end

	function element:SetMax(value)
		self.Max = tonumber(value) or self.Max
		rebound()
		return self
	end

	-- Overrides Base so the label column is re-measured when the text changes.
	function element:SetText(text)
		self.Text = text or ""
		label.Text = Library:FormatLabel(self.Text)
		relayout()
		return self
	end

	element.OnDisabledChanged = function()
		paintReadout(false)
		element:Display()
	end

	--==============================================================
	-- init
	--==============================================================

	-- The label cap is a share of the row, and the row is layout-driven, so the
	-- columns have to be re-measured whenever the window changes width.
	Library:GiveSignal(row:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if Library.Unloaded then
			return
		end
		relayout()
	end))

	relayout()
	-- No Default falls back to the owner's own: a Slider starts at its Min, which
	-- is what normalize makes of nil, a ProgressBar at zero.
	element:SetValue(options.Default ~= nil and options.Default or config.Default, true)

	return {
		Row = row,
		Label = label,
		Readout = readout,
		Bar = bar,
		Trough = trough,
		Relayout = relayout,
		ValueFromAlpha = valueFromAlpha,

		--- Lifts the readout to the active colour. An interactive owner holds this
		--- true for the length of a drag; a readout never touches it.
		SetActive = function(state, animate)
			active = state == true
			paintReadout(animate)
		end,
	}
end

return Numeric
end

__modules["elements/Paragraph"] = function()

-- Sable :: elements/Paragraph
--
-- A block of explanatory copy: instructions, a changelog, a warning. Title line
-- in the element label voice, body underneath in FontDim at readout size.
--
-- The body keeps the caller's own casing. Every other piece of text in Sable is
-- cased by FormatLabel or Chrome, but those are LABELS -- a sentence shouted in
-- capitals is unreadable, and prose is the one thing here that is a sentence.

local Util = require("Util")
local Base = require("elements/Base")

local Paragraph = {}

-- Unbounded height for a wrapped measurement. TextService needs a finite box;
-- this is "taller than any paragraph could ever be", not a layout metric.
local MEASURE_HEIGHT = 4096

function Paragraph.New(Library, container, title, body)
	local element = Base.Create(Library, container, "Paragraph", nil, {
		Text = title ~= nil and tostring(title) or "",
	})

	local Sizes = Library.Sizes
	-- RowGap doubles as leading, so a line of text plus its gap is one line of
	-- copy -- the same unit the readouts are spaced on.
	local titleHeight = Sizes.Text + Sizes.RowGap
	local lineHeight = Sizes.TextSmall + Sizes.RowGap

	element.Body = body ~= nil and tostring(body) or ""

	local row = Library:Row(container, titleHeight)
	row.Name = "ParagraphRow"
	-- The declared height above is a FLOOR once this is on; relayout keeps that
	-- floor at the measured height so the groupbox is the right size on the very
	-- first layout pass instead of sampling a one-line row and jumping.
	row.AutomaticSize = Enum.AutomaticSize.Y

	element.Row = row
	element.ExpandedSize = row.Size
	element.Value = element.Body

	Library:Create("UIListLayout", {
		Name = "List",
		FillDirection = Enum.FillDirection.Vertical,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 0),
		Parent = row,
	})

	local titleLabel = Library:Label({
		Name = "Title",
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, titleHeight),
		Text = Library:FormatLabel(element.Text),
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextYAlignment = Enum.TextYAlignment.Center,
		Parent = row,
	}, "Font")
	element.Label = titleLabel

	local bodyLabel = Library:Label({
		Name = "Body",
		LayoutOrder = 2,
		-- Full row width, no declared height: the wrap decides how tall this is,
		-- and AutomaticSize is the only thing that knows the real font metrics.
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextSize = Sizes.TextSmall,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Text = element.Body,
		Parent = row,
	}, "FontDim")
	element.BodyLabel = bodyLabel

	-- Width the floor was last measured against. The row's AbsoluteSize changes
	-- when the row grows as well as when the column does, and remeasuring on our
	-- own height change would be a loop; only a width change is news.
	local measuredWidth = -1

	local function relayout()
		local width = math.floor(row.AbsoluteSize.X)
		measuredWidth = width

		local height = titleHeight

		if element.Body ~= "" then
			-- Bounded on purpose: the wrap is what decides the height, so the
			-- available width has to go in. An unbounded reading is one long line.
			local measured = width > 0
					and Util.TextSize(
						element.Body,
						Sizes.TextSmall,
						Library.Fonts.Label,
						Vector2.new(width, MEASURE_HEIGHT)
					)
				or Util.TextSize(element.Body, Sizes.TextSmall, Library.Fonts.Label)

			height += math.max(lineHeight, math.ceil(measured.Y) + Sizes.RowGap)
		end

		row.Size = UDim2.new(1, 0, 0, height)
		element.ExpandedSize = row.Size
	end

	function element:Display()
		titleLabel.Text = self.Library:FormatLabel(self.Text)
		bodyLabel.Text = self.Body
		self.Value = self.Body
		relayout()
		return self
	end

	-- Widens Base's one-argument SetText: a paragraph's two lines are almost
	-- always rewritten together, and passing only a title must not silently
	-- strand the old body under a new heading.
	function element:SetText(newTitle, newBody)
		self.Text = newTitle ~= nil and tostring(newTitle) or ""
		if newBody ~= nil then
			self.Body = tostring(newBody)
		end
		return self:Display()
	end

	function element:SetBody(newBody)
		self.Body = newBody ~= nil and tostring(newBody) or ""
		return self:Display()
	end

	--- The body is the paragraph's value: the title is a heading, the copy is
	--- the content, and a script updating one line is updating that one.
	function element:SetValue(value, silent)
		self:SetBody(value)

		if not silent then
			self:Fire()
		end

		return self
	end

	-- The column is layout-driven, so the wrap -- and with it the row's floor --
	-- changes whenever the window is resized.
	Library:GiveSignal(row:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if Library.Unloaded or math.floor(row.AbsoluteSize.X) == measuredWidth then
			return
		end
		relayout()
	end))

	relayout()

	return Base.Finish(element, nil)
end

return Paragraph
end

__modules["elements/ProgressBar"] = function()

-- Sable :: elements/ProgressBar
--
-- A read-only readout wearing the slider's clothes: same segmented track, same
-- right-aligned monospace value. Farm progress, a cooldown, a health bar --
-- anything the SCRIPT knows and the user only watches.
--
-- What makes it a readout rather than a control is everything it does not have:
-- no hit button, no drag, no hover, and a value column that never brightens,
-- because nothing the user does can move it. The row itself is elements/Numeric
-- and the bar inside it is elements/Track, both shared with Slider -- one set of
-- arithmetic, two meanings. This file is the absence of the interaction.
--
-- It is registered in Library.Options so a script can drive it by index, but it
-- carries no persistent state -- SaveManager's serialize() has no case for this
-- type and returns nil, so it never reaches a config file.

local Base = require("elements/Base")
local Numeric = require("elements/Numeric")

local ProgressBar = {}

function ProgressBar.New(Library, container, index, options)
	options = options or {}

	local element = Base.Create(Library, container, "ProgressBar", index, options)

	-- Percent by default, because the overwhelmingly common progress readout is
	-- one; and zero by default, because progress starts at nothing rather than at
	-- whatever the low bound happens to be.
	Numeric.New(Library, element, options, { Suffix = "%", Default = 0 })

	return Base.Finish(element, Library.Options)
end

return ProgressBar
end

__modules["elements/Section"] = function()

-- Sable :: elements/Section
--
-- A named break inside a long groupbox: chrome-cased caption on the left, a
-- hairline running out to the right edge on the caption's centre line. It is
-- the same interruption the groupbox header makes in the box outline, turned
-- inward -- which is why the caption is Library:Chrome and not a label.
--
-- Deliberately taller than a control row. A section that is row-height reads as
-- one more setting; the extra air is what makes it read as a divider with a
-- name on it.

local Util = require("Util")
local Base = require("elements/Base")

local Section = {}

function Section.New(Library, container, text)
	local element = Base.Create(Library, container, "Section", nil, {
		Text = text ~= nil and tostring(text) or "",
	})

	local Sizes = Library.Sizes
	-- Half a group pad is the library's inner gap unit; it separates the caption
	-- from the rule the same way it separates a slider label from its track.
	local gap = math.ceil(Sizes.GroupPad / 2)

	local row = Library:Row(container, Sizes.RowHeight + Sizes.RowGap)
	row.Name = "SectionRow"

	element.Row = row
	element.ExpandedSize = row.Size
	element.Value = element.Text

	local caption = Library:Label({
		Name = "Caption",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(0, 0, 1, 0),
		Font = Library.Fonts.Title,
		Text = Library:Chrome(element.Text),
		TextSize = Sizes.TextSmall,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	}, "FontDim")
	element.Label = caption

	-- OutlineDim, matching Divider: a section separates, it does not frame.
	local rule = Library:Create("Frame", {
		Name = "Rule",
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(1, 0, 0, Sizes.Outline),
		Theme = { BackgroundColor3 = "OutlineDim" },
		Parent = row,
	})
	element.Rule = rule

	--- The rule starts where the caption ends, so the caption has to be measured.
	--- It is the LABEL's text that is measured, never element.Text: Library:Chrome
	--- interleaves spaces, so the rendered string is roughly twice as wide as the
	--- one the caller passed in.
	local function relayout()
		local width = 0
		if caption.Text ~= "" then
			width = math.ceil(Util.TextSize(caption.Text, Sizes.TextSmall, Library.Fonts.Title).X)
		end

		caption.Size = UDim2.new(0, width, 1, 0)

		local left = width > 0 and width + gap or 0
		rule.Position = UDim2.new(0, left, 0.5, 0)
		rule.Size = UDim2.new(1, -left, 0, Sizes.Outline)
	end

	function element:Display()
		self.Value = self.Text
		return self
	end

	-- Overrides Base: the caption is chrome rather than a label, and the rule has
	-- to be re-measured against the new text or it starts under or short of it.
	function element:SetText(newText)
		self.Text = newText ~= nil and tostring(newText) or ""
		caption.Text = self.Library:Chrome(self.Text)
		relayout()
		return self:Display()
	end

	--- A section holds no state; this exists so it answers the same
	--- :SetValue(value, silent) contract every other element does.
	function element:SetValue(value, silent)
		self:SetText(value)

		if not silent then
			self:Fire()
		end

		return self
	end

	relayout()

	return Base.Finish(element, nil)
end

return Section
end

__modules["elements/Slider"] = function()

-- Sable :: elements/Slider
--
-- The segmented instrument slider. The track is a fixed number of equal-width
-- cells that light up as the value rises -- nothing ever resizes, which is what
-- makes it read as equipment rather than as a loading bar. The right-hand
-- readout carries the exact value, because 16 cells cannot.
--
-- The row is elements/Numeric and the bar inside it is elements/Track, both
-- shared with ProgressBar. Everything left in this file -- the hit target, the
-- drag, the readout that brightens while it is held -- is what makes this one a
-- control and that one a readout.

local Util = require("Util")
local Base = require("elements/Base")
local Numeric = require("elements/Numeric")

local Slider = {}

function Slider.New(Library, container, index, options)
	options = options or {}

	local element = Base.Create(Library, container, "Slider", index, options)

	local Sizes = Library.Sizes
	-- Compact is the slider's alone: a readout with no drag has nothing to gain
	-- from losing its label.
	local numeric = Numeric.New(Library, element, options, { Compact = true, TrimZeros = true })
	local trough = numeric.Trough

	-- Taller and wider than the trough: a Track-tall grab target is a nuisance,
	-- so the hit area is grown out to the full row height plus a gap of overhang
	-- on either side.
	local hit = Library:HitButton(trough, {
		Name = "Hit",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, Sizes.RowGap, 1, math.max(0, Sizes.RowHeight - Sizes.Track)),
	})
	element.Hit = hit

	--==============================================================
	-- dragging
	--==============================================================

	local dragging = false

	local function applyFromMouse()
		local width = trough.AbsoluteSize.X
		if width <= 0 then
			return
		end

		-- Measured against the trough's AbsolutePosition, so the cursor has to be
		-- in that space: a raw reading drags the value by the gui inset.
		local alpha = Util.Clamp((Util.MouseInGuiSpace().X - trough.AbsolutePosition.X) / width, 0, 1)
		local value = numeric.ValueFromAlpha(alpha)

		if value ~= element.Value then
			element:SetValue(value)
		end
	end

	local function isDragInput(input)
		return input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
	end

	Library:GiveSignal(hit.InputBegan:Connect(function(input)
		if Library.Unloaded or element.Disabled or not isDragInput(input) then
			return
		end

		dragging = true
		numeric.SetActive(true, true)
		applyFromMouse()
	end))

	-- Movement and release are tracked on the library-wide signals, not on the
	-- button, so a drag survives the cursor leaving the row.
	Library:GiveSignal(Library.InputChanged:Connect(function(input)
		if not dragging then
			return
		end
		if Library.Unloaded then
			dragging = false
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end

		applyFromMouse()
	end))

	Library:GiveSignal(Library.InputEnded:Connect(function(input)
		if not dragging or not isDragInput(input) then
			return
		end

		dragging = false
		numeric.SetActive(false, true)
	end))

	--==============================================================
	-- type-in
	--==============================================================
	--
	-- A drag cannot express "exactly 37". On a 0-1000 track one pixel is several
	-- units, so any precise value is unreachable by pointer -- click the readout
	-- and type it instead.
	--
	-- The readout stays a TextLabel and an editable TextBox sits over it, rather
	-- than making the readout itself a TextBox. A TextBox renders its own
	-- selection and caret and is focusable by stray clicks, and this control is a
	-- readout ~100% of the time; borrowing it only while editing keeps the
	-- resting state exactly as designed.

	local readout = numeric.Readout

	local entry = Library:Create("TextBox", {
		Name = "Entry",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Font = readout.Font,
		Size = UDim2.fromScale(1, 1),
		Text = "",
		TextSize = readout.TextSize,
		TextXAlignment = readout.TextXAlignment,
		Theme = { TextColor3 = "Accent" },
		Visible = false,
		Parent = readout,
	})

	-- Sits over the readout only. Sized off the readout so it tracks relayout.
	local editHit = Library:HitButton(readout, {
		Name = "EditHit",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
	})

	local editing = false

	local function endEdit(commit)
		if not editing then
			return
		end
		editing = false

		entry.Visible = false
		readout.Visible = true
		editHit.Visible = true
		numeric.SetActive(false, true)

		-- SetValue normalises and clamps, so nonsense and out-of-range typing are
		-- already handled; only a non-number needs rejecting here.
		local typed = commit and tonumber((string.gsub(entry.Text, "[^%d%.%-]", "")))
		if typed then
			element:SetValue(typed)
		else
			element:Display()
		end
	end

	local function beginEdit()
		if editing or Library.Unloaded or element.Disabled then
			return
		end
		editing = true

		-- Seed with the RAW number and no suffix: the user is editing a value,
		-- not a label, and "10%" would have to be stripped back off again.
		entry.Text = tostring(element.Value)
		readout.Visible = false
		editHit.Visible = false
		entry.Visible = true
		numeric.SetActive(true, true)

		entry:CaptureFocus()
		entry.CursorPosition = #entry.Text + 1
		entry.SelectionStart = 1
	end

	Library:GiveSignal(editHit.InputBegan:Connect(function(input)
		if isDragInput(input) then
			beginEdit()
		end
	end))

	-- enterPressed is false when focus is lost by clicking away, which still
	-- commits: losing a typed value because you clicked elsewhere is worse than
	-- committing one you may not have finished.
	Library:GiveSignal(entry.FocusLost:Connect(function()
		endEdit(true)
	end))

	return Base.Finish(element, Library.Options)
end

return Slider
end

__modules["elements/Toggle"] = function()

-- Sable :: elements/Toggle
--
-- Label on the left, a hard-edged checkbox in the shared `Right` addon slot so
-- inline ColorPickers / KeyPickers can dock to its left. The whole row is the
-- hit target; the box itself is only a readout.

local Util = require("Util")
local Base = require("elements/Base")

local Toggle = {}

function Toggle.New(Library, container, index, options)
	options = options or {}

	local element = Base.Create(Library, container, "Toggle", index, options)
	element.Value = options.Default and true or false

	local Sizes = Library.Sizes

	local row = Library:Row(container)
	element.Row = row
	element.ExpandedSize = row.Size

	-- The mark is a fraction of the box it sits in -- a ratio, not a pixel --
	-- so the inset stays proportional at any Sizes.Control.
	local mark = math.max(3, math.floor(Sizes.Control * 0.6))
	-- Half a group pad of air between the label and the addon slot; Window.lua
	-- splits ColumnGap and GroupPad the same way.
	local labelGap = math.ceil(Sizes.GroupPad / 2)
	local hovering = false

	--==============================================================
	-- colour sources
	--==============================================================

	-- These are registered as function sources rather than plain scheme keys
	-- because the colour depends on live element state as well as the palette.
	-- One entry per instance then stays correct across both theme switches and
	-- value changes, instead of stacking a new registry entry on every repaint.

	local function labelColor(scheme)
		local base
		if element.Disabled then
			base = scheme.FontFaint
		elseif element.Value then
			base = element.Risky and scheme.Risk or scheme.Font
		else
			base = scheme.FontDim
		end

		-- Rows are flat -- there is no hover fill to lean on, so the label
		-- itself carries the affordance.
		if hovering and not element.Disabled then
			return Util.Shift(base, 1.25)
		end
		return base
	end

	local function strokeColor(scheme)
		if element.Value and not element.Disabled then
			return scheme.Accent
		end
		return scheme.Outline
	end

	local function markColor(scheme)
		return element.Disabled and scheme.AccentDim or scheme.Accent
	end

	--==============================================================
	-- visuals
	--==============================================================

	element.Label = Library:Label({
		Name = "Label",
		Size = UDim2.new(1, -(Sizes.Control + labelGap), 1, 0),
		Text = Library:FormatLabel(element.Text),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	}, labelColor)

	element.Right = Library:Create("Frame", {
		Name = "Right",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		-- Above the row-wide hit button, so an attached picker still receives
		-- its own clicks instead of the row swallowing them.
		ZIndex = 3,
		Parent = row,
	})

	Library:Create("UIListLayout", {
		Name = "List",
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, Sizes.RowGap),
		Parent = element.Right,
	})

	local box = Library:Panel({
		Name = "Box",
		Size = UDim2.fromOffset(Sizes.Control, Sizes.Control),
		LayoutOrder = 100,
		Parent = element.Right,
	}, "PanelSunken", false)

	local stroke = Util.Stroke(box, strokeColor(Library.Scheme), Sizes.Outline)
	Library:AddToRegistry(stroke, { Color = strokeColor })

	local fill = Library:Create("Frame", {
		Name = "Fill",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Theme = { BackgroundColor3 = markColor },
		Parent = box,
	})

	element.Box = box
	element.Fill = fill

	element.Hit = Library:HitButton(row, { ZIndex = 1 })

	-- The addon slot auto-sizes, so the label has to yield width every time a
	-- picker docks beside the box.
	local function syncLabelWidth()
		element.Label.Size = UDim2.new(1, -(element.Right.AbsoluteSize.X + labelGap), 1, 0)
	end

	Library:GiveSignal(element.Right:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncLabelWidth))
	syncLabelWidth()

	--==============================================================
	-- state
	--==============================================================

	local function paintLabel()
		if Library.Unloaded then
			return
		end
		Library:Tween(element.Label, { TextColor3 = labelColor(Library.Scheme) }, Library.Motion.Fast)
	end

	function element:Display()
		if Library.Unloaded then
			return self
		end

		local on = self.Value == true
		local motion = Library.Motion.Fast

		-- Size and transparency move together over 0.09s: the mark punches in
		-- rather than fading up.
		Library:Tween(fill, {
			Size = on and UDim2.fromOffset(mark, mark) or UDim2.fromOffset(0, 0),
			BackgroundTransparency = on and 0 or 1,
		}, motion)

		fill.BackgroundColor3 = markColor(Library.Scheme)
		Library:Tween(stroke, { Color = strokeColor(Library.Scheme) }, motion)
		paintLabel()

		return self
	end

	function element:SetValue(value, silent)
		self.Value = value and true or false
		self:Display()

		if not silent then
			self:Fire()
		end

		return self
	end

	element.OnDisabledChanged = function(disabled)
		-- MouseLeave never arrives once the button stops being interactable.
		if disabled then
			hovering = false
		end
		element:Display()
	end

	--==============================================================
	-- input
	--==============================================================

	Library:GiveSignal(element.Hit.MouseButton1Click:Connect(function()
		if Library.Unloaded or element.Disabled then
			return
		end
		element:SetValue(not element.Value)
	end))

	Library:GiveSignal(element.Hit.MouseEnter:Connect(function()
		if element.Disabled then
			return
		end
		hovering = true
		paintLabel()
	end))

	Library:GiveSignal(element.Hit.MouseLeave:Connect(function()
		hovering = false
		paintLabel()
	end))

	element:Display()

	return Base.Finish(element, Library.Toggles)
end

return Toggle
end

__modules["elements/Track"] = function()

-- Sable :: elements/Track
--
-- The segmented instrument bar, shared by Slider and ProgressBar. It is the
-- library's signature control surface, so there is exactly one of it: a fixed
-- number of equal-width cells that light up as a fraction rises. Cells are
-- RECOLOURED and never resized -- a bar that grows is a progress meter, a bar
-- whose cells change state is an instrument.
--
-- This is a helper, not an element: it has no row, no store entry and no value.
-- The owning element positions Track.Trough and calls :Paint each time its
-- value changes.

local Util = require("Util")

local Track = {}

-- More cells than this and each one is thinner than its own gutter, which reads
-- as a smear rather than as segmentation.
local SEGMENT_MAX = 64

--- Folds a requested segment count into the range a bar can actually draw.
function Track.Count(requested, Sizes)
	return math.floor(Util.Clamp(tonumber(requested) or Sizes.Segments, 1, SEGMENT_MAX))
end

--- Builds the trough and its cells inside `parent`. The caller owns the
--- trough's position and width; only its height is fixed here, because the
--- cells are sized in scale against it.
function Track.New(Library, parent, count)
	local Sizes = Library.Sizes
	-- One hairline of gutter between cells, so the segmentation reads as cuts in
	-- a bar rather than as separate blocks.
	local cellGap = Sizes.Outline

	local trough = Library:Panel({
		Name = "Track",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(1, 0, 0, Sizes.Track),
		Parent = parent,
	}, "PanelSunken", "Outline")

	-- The cells live one level down so the trough's inset does not also shrink
	-- anything the owner lays over the trough -- a Slider's hit button covers the
	-- whole trough and then some.
	local cells = Library:Create("Frame", {
		Name = "Cells",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = trough,
	})

	-- No right padding: the trailing cell's own gutter supplies it, so the
	-- inset reads as one hairline on both ends.
	Util.Padding(cells, Sizes.Outline, 0, Sizes.Outline, Sizes.Outline)

	Library:Create("UIListLayout", {
		Name = "List",
		FillDirection = Enum.FillDirection.Horizontal,
		HorizontalAlignment = Enum.HorizontalAlignment.Left,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, cellGap),
		Parent = cells,
	})

	local segments = table.create(count)
	local cellWidth = 1 / count

	for cellIndex = 1, count do
		-- Each cell carries its own scheme KEY, never a baked Color3, so a live
		-- theme change repaints filled and empty cells correctly.
		local record = { Key = "PanelSunken" }

		record.Frame = Library:Create("Frame", {
			Name = ("Cell%02d"):format(cellIndex),
			BorderSizePixel = 0,
			Size = UDim2.new(cellWidth, -cellGap, 1, 0),
			LayoutOrder = cellIndex,
			Theme = {
				BackgroundColor3 = function()
					return Library:GetColor(record.Key)
				end,
			},
			Parent = cells,
		})

		segments[cellIndex] = record
	end

	local bar = {
		Trough = trough,
		Cells = cells,
		Count = count,
		Segments = segments,
	}

	--- How many cells a 0..1 fraction lights. Crossing into a cell lights it, so
	--- any fraction above zero shows at least one -- a bar that reads empty at 1%
	--- is indistinguishable from a bar that is off.
	function bar:Filled(alpha)
		if alpha <= 0 then
			return 0
		end
		return math.max(1, math.min(self.Count, math.ceil(alpha * self.Count - 1e-4)))
	end

	--- Recolours the cells for `alpha`, writing only the ones that changed.
	--- Returns the filled count.
	function bar:Paint(alpha, fillKey)
		local filled = self:Filled(alpha)

		for cellIndex, record in self.Segments do
			local key = cellIndex <= filled and fillKey or "PanelSunken"
			if record.Key ~= key then
				record.Key = key
				record.Frame.BackgroundColor3 = Library:GetColor(key)
			end
		end

		return filled
	end

	return bar
end

return Track
end

__modules["elements/init"] = function()

-- Sable :: elements/init
--
-- Installs the Add* constructors onto the shared container metatable, and the
-- inline picker attachments onto the element base. This is the only place that
-- knows the full element roster.

local Base = require("elements/Base")

local Label = require("elements/Label")
local Button = require("elements/Button")
local Divider = require("elements/Divider")
local Section = require("elements/Section")
local Paragraph = require("elements/Paragraph")
local Toggle = require("elements/Toggle")
local Slider = require("elements/Slider")
local ProgressBar = require("elements/ProgressBar")
local Input = require("elements/Input")
local Dropdown = require("elements/Dropdown")
local ColorPicker = require("elements/ColorPicker")
local KeyPicker = require("elements/KeyPicker")
local Image = require("elements/Image")

local Elements = {}

Elements.Modules = {
	Label = Label,
	Button = Button,
	Divider = Divider,
	Section = Section,
	Paragraph = Paragraph,
	Toggle = Toggle,
	Slider = Slider,
	ProgressBar = ProgressBar,
	Input = Input,
	Dropdown = Dropdown,
	ColorPicker = ColorPicker,
	KeyPicker = KeyPicker,
	Image = Image,
}

--- `Container` is the shared __index table used by groupboxes, tabbox tabs and
--- dependency boxes, so installing here covers all three.
function Elements.Install(Library, Container)
	function Container:AddLabel(text, doesWrap)
		return Label.New(Library, self, text, doesWrap)
	end

	function Container:AddButton(...)
		return Button.New(Library, self, ...)
	end

	function Container:AddDivider()
		return Divider.New(Library, self)
	end

	function Container:AddSection(text)
		return Section.New(Library, self, text)
	end

	function Container:AddParagraph(title, body)
		return Paragraph.New(Library, self, title, body)
	end

	function Container:AddToggle(index, options)
		return Toggle.New(Library, self, index, options)
	end

	function Container:AddSlider(index, options)
		return Slider.New(Library, self, index, options)
	end

	function Container:AddProgressBar(index, options)
		return ProgressBar.New(Library, self, index, options)
	end

	function Container:AddInput(index, options)
		return Input.New(Library, self, index, options)
	end

	function Container:AddDropdown(index, options)
		return Dropdown.New(Library, self, index, options)
	end

	function Container:AddColorPicker(index, options)
		return ColorPicker.New(Library, self, index, options)
	end

	function Container:AddKeyPicker(index, options)
		return KeyPicker.New(Library, self, index, options)
	end

	function Container:AddImage(index, options)
		return Image.New(Library, self, index, options)
	end

	-- Inline pickers live in an element's `Right` slot, left of its own control.
	function Base.Methods:AddColorPicker(index, options)
		assert(self.Right, ("[Sable] %s does not support an inline ColorPicker"):format(self.Type))
		return ColorPicker.Attach(Library, self, index, options)
	end

	function Base.Methods:AddKeyPicker(index, options)
		assert(self.Right, ("[Sable] %s does not support an inline KeyPicker"):format(self.Type))
		return KeyPicker.Attach(Library, self, index, options)
	end
end

return Elements
end

__modules["init"] = function()

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
end

return require("init")
