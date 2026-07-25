--!nonstrict
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
	local hudDefaults = {
		Watermark = { X = HUD_MARGIN, Y = HUD_MARGIN },
		KeybindList = { X = HUD_MARGIN, Y = HUD_MARGIN + WATERMARK_HEIGHT + HUD_GAP },
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

	--- Keeps a panel wholly inside HudHolder, allowing for its own size.
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
	local frameMs = 0

	local function refreshWatermark()
		if Library.Unloaded then
			return
		end

		setSegments({
			leadingSegment,
			("%d FPS"):format(fps),
			("%d MS"):format(frameMs),
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
		frameMs = math.floor(average * 1000 + 0.5)

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
		local y = NOTIFY_MARGIN

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

		local y = NOTIFY_MARGIN
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
