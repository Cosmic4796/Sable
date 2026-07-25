--!nonstrict
-- Sable :: elements/Label
--
-- Static caption row. It carries the addon slot (element.Right) so a bare
-- caption can host an inline ColorPicker/KeyPicker exactly like a Toggle can,
-- which is how Linoria-shaped scripts attach a bind to a piece of prose.

local Base = require("elements/Base")

local Label = {}

--- Space kept between the caption and whatever sits in the addon slot.
local ADDON_GAP = 4

function Label.New(Library, container, text, doesWrap)
	local wraps = doesWrap == true

	local element = Base.Create(Library, container, "Label", nil, {
		Text = text ~= nil and tostring(text) or "",
	})

	-- A wrapping label cannot know its height until the text has been laid out
	-- against the real column width, so the row measures itself instead.
	local row = Library:Row(container, wraps and 0 or Library.Sizes.RowHeight)
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
		TextSize = Library.Sizes.Text,
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
		Padding = UDim.new(0, ADDON_GAP),
		Parent = element.Right,
	})

	-- Attached pickers grow the slot; give the text back only what is left so a
	-- long caption never runs underneath a swatch or a bind.
	local function reserve()
		local used = element.Right.AbsoluteSize.X
		if used > 0 then
			used += ADDON_GAP
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
