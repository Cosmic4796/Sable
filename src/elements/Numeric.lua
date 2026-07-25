--!nonstrict
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
