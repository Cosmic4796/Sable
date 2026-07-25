--!nonstrict
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
