--!nonstrict
-- Sable :: Overlays
--
-- The chrome that lives outside the window: watermark, keybind list and the
-- notification stack. Watermark and keybind list share one auto-sizing column
-- in HudHolder, so hiding the watermark reflows the binds up for free. All of
-- it keeps rendering while the menu itself is closed.

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
	-- hud column
	--==============================================================

	local hudColumn = Library:Create("Frame", {
		Name = "Column",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(HUD_MARGIN, HUD_MARGIN),
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		Parent = Library.HudHolder,
	})

	Util.ListLayout(hudColumn, HUD_GAP)

	--==============================================================
	-- watermark
	--==============================================================

	local watermark = Library:Panel({
		Name = "Watermark",
		Size = UDim2.fromOffset(0, WATERMARK_HEIGHT),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = 1,
		Hud = true,
		Parent = hudColumn,
	}, "Panel", "Outline")

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

	local keybindPanel = Library:Panel({
		Name = "Keybinds",
		Size = UDim2.fromOffset(0, 0),
		AutomaticSize = Enum.AutomaticSize.XY,
		Visible = false,
		LayoutOrder = 2,
		Hud = true,
		Parent = hudColumn,
	}, "Panel", "Outline")

	Util.Padding(keybindPanel, BIND_PAD_Y, BIND_PAD_X, BIND_PAD_Y, BIND_PAD_X)
	Util.ListLayout(keybindPanel, BIND_ROW_GAP)

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
