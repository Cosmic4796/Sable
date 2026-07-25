--!nonstrict
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
