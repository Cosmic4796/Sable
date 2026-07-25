--!nonstrict
-- Sable :: elements/Input
--
-- Single-line text field. Label left, sunken field right; the field's hairline
-- goes Accent while focused so the box you are typing into reads at a glance.

local Util = require("Util")
local Base = require("elements/Base")

local Input = {}

-- Share of the row the field occupies when there is a label to sit beside.
local FIELD_SCALE = 0.5
local LABEL_GAP = 6

--- Accepts a leading '-' and at most one '.', so half-typed numbers ("-", ".",
--- "-1.") stay editable while anything non-numeric is rejected outright.
local function isNumericText(text)
	local body = text
	if body:sub(1, 1) == "-" then
		body = body:sub(2)
	end
	return body:match("^%d*%.?%d*$") ~= nil
end

--- Character-wise truncation. Byte truncation would be enough for ASCII but
--- can split a multi-byte codepoint and hand Roblox invalid UTF-8.
local function limit(text, maxLength)
	if not maxLength then
		return text
	end

	local length = utf8.len(text)
	if not length then
		return text:sub(1, maxLength)
	end
	if length <= maxLength then
		return text
	end

	local offset = utf8.offset(text, maxLength + 1)
	return text:sub(1, (offset or (maxLength + 1)) - 1)
end

function Input.New(Library, container, index, options)
	options = options or {}

	local element = Base.Create(Library, container, "Input", index, options)

	local numeric = options.Numeric == true
	local finished = options.Finished == true
	local maxLength = nil
	if type(options.MaxLength) == "number" then
		maxLength = math.max(0, math.floor(options.MaxLength))
	end

	--- Everything that reaches element.Value passes through here, so a script
	--- calling :SetValue can never install text the user could not have typed.
	local function coerce(value)
		local text = value == nil and "" or tostring(value)
		if numeric and not isNumericText(text) then
			text = text:match("^%-?%d*%.?%d*") or ""
		end
		return limit(text, maxLength)
	end

	local initial = coerce(options.Default)

	local row = Library:Row(container)
	element.Row = row
	element.ExpandedSize = row.Size

	local hasLabel = element.Text ~= ""

	if hasLabel then
		element.Label = Library:Label({
			Name = "Label",
			Size = UDim2.new(1 - FIELD_SCALE, -LABEL_GAP, 1, 0),
			Text = Library:FormatLabel(element.Text),
			TextSize = Library.Sizes.Text,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = row,
		}, element.Risky and "Risk" or "Font")
	end

	local field = Library:Panel({
		Name = "Field",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = hasLabel and UDim2.new(FIELD_SCALE, 0, 1, -2) or UDim2.new(1, 0, 1, -2),
		ClipsDescendants = true,
		Parent = row,
	}, "PanelSunken", false)

	local focused = false

	local stroke = Util.Stroke(field, Library:GetColor("Outline"), Library.Sizes.Outline)
	-- Registered as a resolver rather than a flat key: a live theme switch while
	-- the field is focused must repaint to the new Accent, not to Outline.
	Library:AddToRegistry(stroke, {
		Color = function(scheme)
			return focused and scheme.Accent or scheme.Outline
		end,
	})

	local box = Library:Create("TextBox", {
		Name = "Box",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Font = Library.Fonts.Value,
		TextSize = Library.Sizes.TextSmall,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		ClearTextOnFocus = options.ClearTextOnFocus ~= false,
		Text = initial,
		PlaceholderText = tostring(options.Placeholder or ""),
		Theme = { TextColor3 = "Font", PlaceholderColor3 = "FontFaint" },
		Parent = field,
	})

	Util.Padding(box, 0, 4, 0, 4)

	element.Value = initial
	element.Field = field
	element.Box = box
	element.Hit = box

	local lastValid = initial
	-- Guard for programmatic writes. Property-changed signals can be delivered
	-- deferred, so a boolean flipped around the write would already be back to
	-- false by the time the handler runs -- remembering the exact text we wrote
	-- is the guard that actually holds.
	local pending = nil

	local function assign(text)
		if box.Text == text then
			return
		end
		pending = text
		box.Text = text
	end

	local function paintOutline()
		if Library.Unloaded then
			return
		end
		Library:Tween(stroke, {
			Color = Library:GetColor(focused and "Accent" or "Outline"),
		}, Library.Motion.Fast)
	end

	Library:GiveSignal(box:GetPropertyChangedSignal("Text"):Connect(function()
		local text = box.Text

		if pending ~= nil then
			local expected = pending
			pending = nil
			if text == expected then
				return
			end
		end

		if numeric and not isNumericText(text) then
			assign(lastValid)
			return
		end

		local capped = limit(text, maxLength)
		if capped ~= text then
			assign(capped)
			text = capped
		end

		lastValid = text

		-- Also covers any stale event left over from a programmatic write: if
		-- the text already matches the stored value there is nothing to report.
		if text == element.Value then
			return
		end

		element.Value = text

		if not finished then
			element:Fire()
		end
	end))

	Library:GiveSignal(box.Focused:Connect(function()
		focused = true
		paintOutline()
	end))

	-- A Finished input commits on Enter *or* on losing focus, and both land
	-- here, so the enterPressed flag is not needed to tell them apart.
	Library:GiveSignal(box.FocusLost:Connect(function()
		focused = false
		paintOutline()

		if finished and not element.Disabled then
			element:Fire()
		end
	end))

	element.OnDisabledChanged = function(disabled)
		box.TextEditable = not disabled
		if disabled and focused then
			box:ReleaseFocus()
		end

		-- Replace rather than stack: later registry entries are applied before
		-- earlier ones, so an orphaned entry would win the next theme update.
		Library:RemoveFromRegistry(box)
		Library:AddToRegistry(box, {
			TextColor3 = disabled and "FontFaint" or "Font",
			PlaceholderColor3 = "FontFaint",
		})
	end

	function element:Display()
		assign(self.Value)
	end

	function element:SetValue(value, silent)
		local text = coerce(value)

		lastValid = text
		self.Value = text
		self:Display()

		if not silent then
			self:Fire()
		end

		return self
	end

	return Base.Finish(element, Library.Options)
end

return Input
