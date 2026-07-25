--!nonstrict
-- Sable :: elements/Dropdown
--
-- Label on the left, a hairline-outlined value button on the right. The list
-- itself lives in the shared popup layer: Library:OpenPopup owns positioning,
-- outside-click dismissal and the "only one popup at a time" rule, so this
-- module never touches PopupHolder directly beyond parenting its frame.
--
-- Row instances are pooled rather than rebuilt, because :SetValues is commonly
-- called on a timer (player lists) and every rebuild would otherwise leak a
-- hover connection pair per row for the lifetime of the menu.

local Util = require("Util")
local Base = require("elements/Base")

local Dropdown = {}

local PLACEHOLDER = "NONE"

-- Plain text, never an image asset -- the library is text and rectangles only.
local CARET_CLOSED = "\u{25BC}"
local CARET_OPEN = "\u{25B2}"

--- Swaps the scheme key an instance is themed with, so live theme switching
--- keeps working after a state change. Only safe on instances that register
--- exactly ONE property, since RemoveFromRegistry drops every entry they own.
local function repaint(Library, instance, property, key)
	local attribute = "SableKey" .. property
	if instance:GetAttribute(attribute) == key then
		return
	end

	instance:SetAttribute(attribute, key)
	Library:RemoveFromRegistry(instance)
	Library:AddToRegistry(instance, { [property] = key })
end

local function toStringList(values)
	local list = {}
	if type(values) == "table" then
		for index = 1, #values do
			local value = values[index]
			if value ~= nil then
				table.insert(list, tostring(value))
			end
		end
	end
	return list
end

function Dropdown.New(Library, container, index, options)
	options = options or {}

	local element = Base.Create(Library, container, "Dropdown", index, options)

	local Sizes = Library.Sizes
	-- Half a group pad is the library's inner gap unit; Window.lua splits
	-- ColumnGap and GroupPad the same way.
	local padX = math.ceil(Sizes.GroupPad / 2)
	-- The filter field is a row of the popup, exactly like the items below it.
	local searchHeight = Sizes.RowHeight
	-- One glyph of the readout face is all the caret needs; it is drawn as text.
	local caretWidth = Sizes.TextSmall

	element.Values = toStringList(options.Values)
	element.Multi = options.Multi == true
	element.AllowNull = options.AllowNull == true
	element.Searchable = options.Searchable == true
	element.MaxVisible = math.max(
		1,
		math.floor(tonumber(options.MaxVisibleDropdownItems) or Sizes.PopupMaxItems)
	)

	element.Rows = {}
	element.Opened = false
	element.Value = element.Multi and {} or nil

	--==============================================================
	-- row
	--==============================================================

	local row = Library:Row(container)
	element.Row = row
	element.ExpandedSize = row.Size

	-- Label and value button split the row down the middle, with a half pad of
	-- air between them.
	element.Label = Library:Label({
		Name = "Label",
		Size = UDim2.new(0.5, -padX, 1, 0),
		Text = Library:FormatLabel(element.Text),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	}, element.Risky and "Risk" or "Font")

	local button, stroke = Library:Panel({
		Name = "Value",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.new(0.5, 0, 1, -Sizes.RowGap),
		ClipsDescendants = true,
		Parent = row,
	}, "Panel", "Outline")

	element.Button = button
	element.Stroke = stroke

	element.Caret = Library:Label({
		Name = "Caret",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -Sizes.RowGap, 0.5, 0),
		Size = UDim2.new(0, caretWidth, 1, 0),
		TextSize = Sizes.TextSmall,
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = CARET_CLOSED,
		Parent = button,
	}, "FontDim")

	-- Everything the caret occupies plus a half pad of clearance on both sides,
	-- so a long value truncates instead of running under the arrow.
	element.ValueLabel = Library:Label({
		Name = "Text",
		Position = UDim2.fromOffset(padX, 0),
		Size = UDim2.new(1, -(padX * 2 + caretWidth + Sizes.RowGap), 1, 0),
		TextSize = Sizes.TextSmall,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = PLACEHOLDER,
		Parent = button,
	}, "FontDim")

	element.Hit = Library:HitButton(button)
	Library:BindHover(element.Hit, button, "Panel", "PanelRaised")

	--==============================================================
	-- popup
	--==============================================================

	local popup = Library:Panel({
		Name = "DropdownPopup",
		Visible = false,
		ClipsDescendants = true,
		Size = UDim2.fromOffset(Sizes.PopupMinWidth, Sizes.RowHeight),
		Parent = Library.PopupHolder,
	}, "Panel", "Outline")

	element.Popup = popup
	Library:CornerTicks(popup, "Accent")

	local listOffset = 0
	if element.Searchable then
		local search = Library:Panel({
			Name = "Search",
			Size = UDim2.new(1, 0, 0, searchHeight),
			ClipsDescendants = true,
			Parent = popup,
		}, "PanelSunken", false)

		Library:Create("Frame", {
			Name = "Rule",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 0, 1, 0),
			Size = UDim2.new(1, 0, 0, Sizes.Outline),
			BorderSizePixel = 0,
			Theme = { BackgroundColor3 = "OutlineDim" },
			Parent = search,
		})

		element.Search = Library:Create("TextBox", {
			Name = "Field",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(padX, 0),
			Size = UDim2.new(1, -padX * 2, 1, 0),
			Font = Library.Fonts.Label,
			TextSize = Sizes.TextSmall,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Center,
			Text = "",
			PlaceholderText = Library:FormatLabel("Filter"),
			ClearTextOnFocus = false,
			ClipsDescendants = true,
			Theme = { TextColor3 = "Font", PlaceholderColor3 = "FontDim" },
			Parent = search,
		})

		listOffset = searchHeight
	end

	element.List = Library:Create("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, listOffset),
		Size = UDim2.new(1, 0, 1, -listOffset),
		CanvasSize = UDim2.new(0, 0, 0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = Sizes.ScrollBar,
		-- Empty image: the stock scrollbar texture has rounded caps.
		ScrollBarImage = "",
		ScrollBarImageTransparency = 0,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		Theme = { ScrollBarImageColor3 = "Outline" },
		Parent = popup,
	})

	Util.ListLayout(element.List, 0)

	local function makeRow(position)
		local frame = Library:Create("TextButton", {
			Name = "Item",
			AutoButtonColor = false,
			BorderSizePixel = 0,
			Text = "",
			Size = UDim2.new(1, 0, 0, Sizes.RowHeight),
			LayoutOrder = position,
			Visible = false,
			ClipsDescendants = true,
			Theme = { BackgroundColor3 = "Panel" },
			Parent = element.List,
		})

		local bar = Library:Create("Frame", {
			Name = "Mark",
			BorderSizePixel = 0,
			Visible = false,
			Size = UDim2.new(0, Sizes.Indicator, 1, 0),
			Theme = { BackgroundColor3 = "Accent" },
			Parent = frame,
		})

		-- Text clears the selection bar, then keeps a half pad on both sides.
		local label = Library:Label({
			Name = "Text",
			Position = UDim2.fromOffset(Sizes.Indicator + padX, 0),
			Size = UDim2.new(1, -(Sizes.Indicator + padX * 2), 1, 0),
			TextSize = Sizes.TextSmall,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = frame,
		}, "FontDim")

		local item = {
			Frame = frame,
			Bar = bar,
			Label = label,
			Value = nil,
			Enabled = false,
		}

		Library:BindHover(frame, frame, "Panel", "PanelRaised")

		Library:GiveSignal(frame.MouseButton1Click:Connect(function()
			if not item.Enabled or item.Value == nil then
				return
			end
			element:Choose(item.Value)
		end))

		return item
	end

	--==============================================================
	-- value handling
	--==============================================================

	--- Accepts a string, a set, a list, a number index or nil and returns the
	--- canonical shape for this dropdown's mode.
	function element:Normalise(value)
		local values = self.Values

		if self.Multi then
			local set = {}

			if type(value) == "table" then
				for key, item in value do
					if type(key) == "string" and item then
						if table.find(values, key) then
							set[key] = true
						end
					elseif type(item) == "string" and table.find(values, item) then
						set[item] = true
					end
				end
			elseif type(value) == "number" then
				local name = values[value]
				if name then
					set[name] = true
				end
			elseif type(value) == "string" and table.find(values, value) then
				set[value] = true
			end

			-- No re-seeding here. AllowNull governs SINGLE-select nullability;
			-- an empty multi-selection is a legitimate state. Re-seeding made
			-- the last item impossible to uncheck -- clicking it off put it
			-- straight back -- and silently corrupted an empty saved config.
			return set
		end

		local resolved = nil

		if type(value) == "number" then
			resolved = values[value]
		elseif type(value) == "string" then
			if table.find(values, value) then
				resolved = value
			end
		elseif type(value) == "table" then
			-- A config saved while this index was Multi, or a plain list.
			for key, item in value do
				if type(key) == "string" and item and table.find(values, key) then
					resolved = key
					break
				end
				if type(item) == "string" and table.find(values, item) then
					resolved = item
					break
				end
			end
		end

		if resolved == nil and not self.AllowNull then
			resolved = values[1]
		end

		return resolved
	end

	--- How many characters fit inside the value button at its current width.
	function element:Capacity()
		local width = self.ValueLabel.AbsoluteSize.X
		if width <= 0 then
			-- Character counts, not pixels: a conservative budget for the frame
			-- before the first layout pass has measured the button.
			return 18
		end

		local advance = Util.TextSize("0", self.Library.Sizes.TextSmall, self.Library.Fonts.Value).X
		if advance <= 0 then
			advance = self.Library.Sizes.TextSmall * 0.6
		end

		return math.max(3, math.floor(width / advance))
	end

	function element:Display()
		local text = PLACEHOLDER
		local selected = false

		if self.Multi then
			local names = {}
			for position = 1, #self.Values do
				local name = self.Values[position]
				if self.Value[name] then
					table.insert(names, name)
				end
			end
			if #names > 0 then
				text = table.concat(names, ", ")
				selected = true
			end
		elseif self.Value ~= nil then
			text = self.Value
			selected = true
		end

		self.ValueLabel.Text = Util.Truncate(text, self:Capacity())
		repaint(self.Library, self.ValueLabel, "TextColor3", selected and "Font" or "FontDim")

		for position = 1, #self.Rows do
			local item = self.Rows[position]
			if item.Enabled and item.Value ~= nil then
				local on
				if self.Multi then
					on = self.Value[item.Value] == true
				else
					on = self.Value == item.Value
				end

				item.Bar.Visible = on
				repaint(self.Library, item.Label, "TextColor3", on and "Accent" or "FontDim")
			end
		end

		return self
	end

	function element:SetValue(value, silent)
		self.Value = self:Normalise(value)
		self:Display()

		if not silent then
			self:Fire()
		end

		return self
	end

	--- Applies a row click. Multi toggles and stays open; single selects (or
	--- clears, when AllowNull) and closes.
	function element:Choose(name)
		if self.Multi then
			local set = {}
			for key in self.Value do
				set[key] = true
			end

			if set[name] then
				set[name] = nil
			else
				set[name] = true
			end

			self:SetValue(set)
			return self
		end

		if self.Value == name and self.AllowNull then
			self:SetValue(nil)
		else
			self:SetValue(name)
		end

		self:Close()
		return self
	end

	--==============================================================
	-- list
	--==============================================================

	function element:Filter(query)
		query = tostring(query or ""):lower()

		for position = 1, #self.Rows do
			local item = self.Rows[position]
			local visible = item.Enabled

			if visible and query ~= "" and item.Value ~= nil then
				visible = string.find(item.Value:lower(), query, 1, true) ~= nil
			end

			item.Frame.Visible = visible
		end

		return self
	end

	function element:Rebuild()
		local values = self.Values

		for position = 1, #values do
			local item = self.Rows[position]
			if not item then
				item = makeRow(position)
				self.Rows[position] = item
			end

			item.Value = values[position]
			item.Enabled = true
			item.Label.Text = values[position]
		end

		for position = #values + 1, #self.Rows do
			local item = self.Rows[position]
			item.Value = nil
			item.Enabled = false
			item.Bar.Visible = false
		end

		self:Filter(self.Search and self.Search.Text or "")
		return self
	end

	function element:SetValues(list)
		self.Values = toStringList(list)
		self:Rebuild()

		-- Normalise drops anything that no longer exists, and re-seeds the
		-- first entry when this dropdown may not be empty.
		self.Value = self:Normalise(self.Value)
		self:Display()

		return self
	end

	--==============================================================
	-- open / close
	--==============================================================

	function element:SetOpened(opened)
		self.Opened = opened == true

		repaint(self.Library, self.Stroke, "Color", self.Opened and "Accent" or "Outline")
		repaint(self.Library, self.Caret, "TextColor3", self.Opened and "Accent" or "FontDim")
		self.Caret.Text = self.Opened and CARET_OPEN or CARET_CLOSED

		return self
	end

	function element:Close()
		local active = self.Library.ActivePopup
		if active and active.Frame == self.Popup then
			self.Library:ClosePopup(active)
		end
		return self
	end

	function element:Open()
		local Library = self.Library
		if Library.Unloaded or self.Disabled then
			return self
		end

		local active = Library.ActivePopup
		if active and active.Frame == self.Popup then
			Library:ClosePopup(active)
			return self
		end

		if self.Search then
			self.Search.Text = ""
		end
		self:Filter("")
		self.List.CanvasPosition = Vector2.zero

		local shown = math.max(1, math.min(#self.Values, self.MaxVisible))
		local height = shown * Sizes.RowHeight + (self.Search and searchHeight or 0)

		Library:OpenPopup(self.Popup, self.Button, {
			Height = height,
			Width = math.max(self.Button.AbsoluteSize.X, Sizes.PopupMinWidth),
			Gap = Sizes.RowGap,
			OnClose = function()
				self:SetOpened(false)
			end,
		})

		self:SetOpened(true)
		return self
	end

	--==============================================================
	-- wiring
	--==============================================================

	Library:GiveSignal(element.Hit.MouseButton1Click:Connect(function()
		element:Open()
	end))

	if element.Search then
		Library:GiveSignal(element.Search:GetPropertyChangedSignal("Text"):Connect(function()
			element:Filter(element.Search.Text)
		end))
	end

	-- The button width is layout-driven, so the truncation budget is only known
	-- once it has been measured -- and again whenever the window is resized.
	Library:GiveSignal(element.ValueLabel:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		if Library.Unloaded then
			return
		end
		element:Display()
	end))

	element.OnDisabledChanged = function(disabled)
		if disabled then
			element:Close()
		end
	end

	local baseDestroy = Base.Methods.Destroy
	function element:Destroy()
		self:Close()
		pcall(function()
			self.Popup:Destroy()
		end)
		return baseDestroy(self)
	end

	element:Rebuild()
	element:SetValue(options.Default, true)

	return Base.Finish(element, Library.Options)
end

return Dropdown
