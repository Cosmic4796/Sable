--!nonstrict
-- Sable :: elements/Slider
--
-- The segmented instrument slider. The track is a fixed number of equal-width
-- cells that light up as the value rises -- nothing ever resizes, which is what
-- separates a piece of equipment from a progress bar. The right-hand readout
-- carries the exact value, because 16 cells cannot.

local Util = require("Util")
local Base = require("elements/Base")

local Slider = {}

-- Share of the row a label may claim before it starts squeezing the track. A
-- ratio, not a pixel: the row width is layout-driven and changes when the window
-- is resized, so a fixed cap would be wrong at every size but one.
local LABEL_SHARE = 0.45

local SEGMENT_MAX = 64
local ROUNDING_MAX = 6

function Slider.New(Library, container, index, options)
	options = options or {}

	local element = Base.Create(Library, container, "Slider", index, options)

	local Sizes = Library.Sizes
	-- label <-> track <-> readout. Half a group pad is the library's inner gap
	-- unit; Window.lua splits ColumnGap and GroupPad the same way.
	local gap = math.ceil(Sizes.GroupPad / 2)
	-- One hairline of gutter between cells, so the segmentation reads as cuts in
	-- a bar rather than as separate blocks.
	local cellGap = Sizes.Outline

	element.Min = tonumber(options.Min) or 0
	element.Max = tonumber(options.Max) or 100
	element.Rounding = math.floor(Util.Clamp(tonumber(options.Rounding) or 0, 0, ROUNDING_MAX))
	element.Suffix = tostring(options.Suffix or "")
	element.Compact = options.Compact == true
	element.Segments =
		math.floor(Util.Clamp(tonumber(options.Segments) or Sizes.Segments, 1, SEGMENT_MAX))
	element.Value = element.Min

	--==============================================================
	-- visuals
	--==============================================================

	local row = Library:Row(container)
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
	local dragging = false

	local function readoutKey()
		if element.Disabled then
			return "FontFaint"
		end
		return dragging and "Font" or "FontDim"
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

	local trough = Library:Panel({
		Name = "Track",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 0, 0.5, 0),
		Size = UDim2.new(1, 0, 0, Sizes.Track),
		Parent = row,
	}, "PanelSunken", "Outline")

	-- The cells live one level down so the trough's inset does not also shrink
	-- the hit button, which needs to cover the whole trough (and then some).
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

	local segments = table.create(element.Segments)
	local cellWidth = 1 / element.Segments

	for cellIndex = 1, element.Segments do
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
	-- value math
	--==============================================================

	--- A Max below Min collapses to a single-value slider rather than dividing
	--- by a negative span.
	local function bounds()
		local low = element.Min
		local high = element.Max
		if high < low then
			high = low
		end
		return low, high
	end

	--- Util.FormatNumber's integer path evaluates math.floor(v - 0.5) for
	--- negatives, which renders -5 as "-6". The decimal path (string.format) is
	--- correct, so only the integer case is handled locally.
	local function formatValue(value)
		if element.Rounding <= 0 then
			return tostring(math.floor(value + 0.5))
		end
		return Util.FormatNumber(value, element.Rounding)
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

		-- Crossing into a cell lights it: any value above Min shows at least one.
		local filled = 0
		if alpha > 0 then
			filled = math.max(1, math.ceil(alpha * self.Segments - 1e-4))
		end

		local fillKey = self.Disabled and "AccentDim" or "Accent"

		for cellIndex, record in segments do
			local key = cellIndex <= filled and fillKey or "PanelSunken"
			if record.Key ~= key then
				record.Key = key
				record.Frame.BackgroundColor3 = Library:GetColor(key)
			end
		end

		readout.Text = formatValue(self.Value) .. self.Suffix

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
	-- dragging
	--==============================================================

	local function applyFromMouse()
		local width = trough.AbsoluteSize.X
		if width <= 0 then
			return
		end

		-- Measured against the trough's AbsolutePosition, so the cursor has to be
		-- in that space: a raw reading drags the value by the gui inset.
		local alpha = Util.Clamp((Util.MouseInGuiSpace().X - trough.AbsolutePosition.X) / width, 0, 1)
		local low, high = bounds()
		local value = normalize(low + alpha * (high - low))

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
		paintReadout(true)
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
		paintReadout(true)
	end))

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
	element:SetValue(options.Default, true)

	return Base.Finish(element, Library.Options)
end

return Slider
