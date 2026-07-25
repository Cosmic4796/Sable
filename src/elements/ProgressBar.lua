--!nonstrict
-- Sable :: elements/ProgressBar
--
-- A read-only readout wearing the slider's clothes: same segmented track, same
-- right-aligned monospace value. Farm progress, a cooldown, a health bar --
-- anything the SCRIPT knows and the user only watches.
--
-- What makes it a readout rather than a control is everything it does not have:
-- no hit button, no drag, no hover, and a value column that never brightens,
-- because nothing the user does can move it. Sharing the track with Slider is
-- deliberate (see elements/Track): one segmented bar, two meanings.
--
-- It is registered in Library.Options so a script can drive it by index, but it
-- carries no persistent state -- SaveManager's serialize() has no case for this
-- type and returns nil, so it never reaches a config file.

local Util = require("Util")
local Base = require("elements/Base")
local Track = require("elements/Track")

local ProgressBar = {}

-- Share of the row the label may claim before it starts squeezing the track,
-- matching Slider: the same row shape has to hold the same proportions.
local LABEL_SHARE = 0.45

local ROUNDING_MAX = 6

function ProgressBar.New(Library, container, index, options)
	options = options or {}

	local element = Base.Create(Library, container, "ProgressBar", index, options)

	local Sizes = Library.Sizes
	-- label <-> track <-> readout. Half a group pad is the library's inner gap
	-- unit; Window.lua splits ColumnGap and GroupPad the same way.
	local gap = math.ceil(Sizes.GroupPad / 2)

	element.Min = tonumber(options.Min) or 0
	element.Max = tonumber(options.Max) or 100
	element.Rounding = math.floor(Util.Clamp(tonumber(options.Rounding) or 0, 0, ROUNDING_MAX))
	-- Percent by default: a bar with no suffix reads as a bare number, and the
	-- overwhelmingly common progress readout is a percentage.
	element.Suffix = options.Suffix ~= nil and tostring(options.Suffix) or "%"
	element.Segments = Track.Count(options.Segments, Sizes)
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
		Parent = row,
	}, element.Risky and "Risk" or "Font")
	element.Label = label

	--- FontDim at rest, always. A slider's readout brightens while it is being
	--- dragged; there is no drag here, so brightening would promise an
	--- interaction that does not exist.
	local function readoutKey()
		return element.Disabled and "FontFaint" or "FontDim"
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

	local bar = Track.New(Library, row, element.Segments)
	local trough = bar.Trough
	element.Bar = bar

	--==============================================================
	-- value math
	--==============================================================

	--- A Max below Min collapses to a single-value bar rather than dividing by a
	--- negative span.
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

		local labelWidth = measure(label.Text, Sizes.Text, Library.Fonts.Label) + Sizes.Outline

		-- Capped against the LIVE row, not a fixed pixel budget, so the same cap
		-- holds after the window is resized. Before the first layout pass the row
		-- has no width yet and the measured label stands.
		local available = row.AbsoluteSize.X
		if available > 0 then
			labelWidth = math.min(labelWidth, math.floor(available * LABEL_SHARE))
		end

		label.Size = UDim2.new(0, labelWidth, 1, 0)

		local left = labelWidth > 0 and labelWidth + gap or 0
		trough.Position = UDim2.new(0, left, 0.5, 0)
		trough.Size = UDim2.new(1, -(left + gap + readoutWidth), 0, Sizes.Track)
	end

	--==============================================================
	-- api
	--==============================================================

	function element:Display()
		local low, high = bounds()
		local alpha = high > low and Util.Alpha(self.Value, low, high) or 0

		bar:Paint(alpha, self.Disabled and "AccentDim" or "Accent")

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
		label.Text = self.Library:FormatLabel(self.Text)
		relayout()
		return self
	end

	element.OnDisabledChanged = function()
		readout.TextColor3 = Library:GetColor(readoutKey())
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
	element:SetValue(options.Default ~= nil and options.Default or 0, true)

	return Base.Finish(element, Library.Options)
end

return ProgressBar
