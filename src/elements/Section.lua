--!nonstrict
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
