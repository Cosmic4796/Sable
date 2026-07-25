--!nonstrict
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
