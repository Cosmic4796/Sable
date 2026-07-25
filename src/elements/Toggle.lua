--!nonstrict
-- Sable :: elements/Toggle
--
-- Label on the left, a hard-edged checkbox in the shared `Right` addon slot so
-- inline ColorPickers / KeyPickers can dock to its left. The whole row is the
-- hit target; the box itself is only a readout.

local Util = require("Util")
local Base = require("elements/Base")

local Toggle = {}

function Toggle.New(Library, container, index, options)
	options = options or {}

	local element = Base.Create(Library, container, "Toggle", index, options)
	element.Value = options.Default and true or false

	local row = Library:Row(container)
	element.Row = row
	element.ExpandedSize = row.Size

	-- Inner mark is derived from the control metric so the box keeps its
	-- 3px inset if Sizes.Control is ever retuned.
	local mark = math.max(3, Library.Sizes.Control - 6)
	local hovering = false

	--==============================================================
	-- colour sources
	--==============================================================

	-- These are registered as function sources rather than plain scheme keys
	-- because the colour depends on live element state as well as the palette.
	-- One entry per instance then stays correct across both theme switches and
	-- value changes, instead of stacking a new registry entry on every repaint.

	local function labelColor(scheme)
		local base
		if element.Disabled then
			base = scheme.FontFaint
		elseif element.Value then
			base = element.Risky and scheme.Risk or scheme.Font
		else
			base = scheme.FontDim
		end

		-- Rows are flat -- there is no hover fill to lean on, so the label
		-- itself carries the affordance.
		if hovering and not element.Disabled then
			return Util.Shift(base, 1.25)
		end
		return base
	end

	local function strokeColor(scheme)
		if element.Value and not element.Disabled then
			return scheme.Accent
		end
		return scheme.Outline
	end

	local function markColor(scheme)
		return element.Disabled and scheme.AccentDim or scheme.Accent
	end

	--==============================================================
	-- visuals
	--==============================================================

	element.Label = Library:Label({
		Name = "Label",
		Size = UDim2.new(1, -(Library.Sizes.Control + 6), 1, 0),
		Text = Library:FormatLabel(element.Text),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	}, labelColor)

	element.Right = Library:Create("Frame", {
		Name = "Right",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		-- Above the row-wide hit button, so an attached picker still receives
		-- its own clicks instead of the row swallowing them.
		ZIndex = 3,
		Parent = row,
	})

	Library:Create("UIListLayout", {
		Name = "List",
		FillDirection = Enum.FillDirection.Horizontal,
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, 4),
		Parent = element.Right,
	})

	local box = Library:Panel({
		Name = "Box",
		Size = UDim2.fromOffset(Library.Sizes.Control, Library.Sizes.Control),
		LayoutOrder = 100,
		Parent = element.Right,
	}, "PanelSunken", false)

	local stroke = Util.Stroke(box, strokeColor(Library.Scheme), Library.Sizes.Outline)
	Library:AddToRegistry(stroke, { Color = strokeColor })

	local fill = Library:Create("Frame", {
		Name = "Fill",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Theme = { BackgroundColor3 = markColor },
		Parent = box,
	})

	element.Box = box
	element.Fill = fill

	element.Hit = Library:HitButton(row, { ZIndex = 1 })

	-- The addon slot auto-sizes, so the label has to yield width every time a
	-- picker docks beside the box.
	local function syncLabelWidth()
		element.Label.Size = UDim2.new(1, -(element.Right.AbsoluteSize.X + 6), 1, 0)
	end

	Library:GiveSignal(element.Right:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncLabelWidth))
	syncLabelWidth()

	--==============================================================
	-- state
	--==============================================================

	local function paintLabel()
		if Library.Unloaded then
			return
		end
		Library:Tween(element.Label, { TextColor3 = labelColor(Library.Scheme) }, Library.Motion.Fast)
	end

	function element:Display()
		if Library.Unloaded then
			return self
		end

		local on = self.Value == true
		local motion = Library.Motion.Fast

		-- Size and transparency move together over 0.09s: the mark punches in
		-- rather than fading up.
		Library:Tween(fill, {
			Size = on and UDim2.fromOffset(mark, mark) or UDim2.fromOffset(0, 0),
			BackgroundTransparency = on and 0 or 1,
		}, motion)

		fill.BackgroundColor3 = markColor(Library.Scheme)
		Library:Tween(stroke, { Color = strokeColor(Library.Scheme) }, motion)
		paintLabel()

		return self
	end

	function element:SetValue(value, silent)
		self.Value = value and true or false
		self:Display()

		if not silent then
			self:Fire()
		end

		return self
	end

	element.OnDisabledChanged = function(disabled)
		-- MouseLeave never arrives once the button stops being interactable.
		if disabled then
			hovering = false
		end
		element:Display()
	end

	--==============================================================
	-- input
	--==============================================================

	Library:GiveSignal(element.Hit.MouseButton1Click:Connect(function()
		if Library.Unloaded or element.Disabled then
			return
		end
		element:SetValue(not element.Value)
	end))

	Library:GiveSignal(element.Hit.MouseEnter:Connect(function()
		if element.Disabled then
			return
		end
		hovering = true
		paintLabel()
	end))

	Library:GiveSignal(element.Hit.MouseLeave:Connect(function()
		hovering = false
		paintLabel()
	end))

	element:Display()

	return Base.Finish(element, Library.Toggles)
end

return Toggle
