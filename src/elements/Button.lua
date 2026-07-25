--!nonstrict
-- Sable :: elements/Button
--
-- A command row. :AddButton splits the SAME row into equal columns, so
-- SAVE | LOAD | DELETE reads as one bank of keys instead of three stacked
-- rows. Only the first button is a Base element; the columns added after it
-- are lighter objects sharing that element's row, which keeps the container's
-- element list (and therefore its layout) honest about how many rows exist.

local Base = require("elements/Base")

local Button = {}

--- How long a DoubleClick button waits for its confirming second press.
local CONFIRM_WINDOW = 0.5
--- How long the accent press-flash stays lit before easing back.
local FLASH_HOLD = 0.1
--- Uppercased by FormatLabel at paint time, like every other element label.
local CONFIRM_TEXT = "...Are you sure?"

local Segment = {}
Segment.__index = Segment

--==============================================================
-- construction helpers
--==============================================================

--- Accepts either a plain string or the full option table.
local function normalize(info)
	if type(info) ~= "table" then
		return { Text = info ~= nil and tostring(info) or "Button" }
	end

	return {
		Text = info.Text ~= nil and tostring(info.Text) or "Button",
		Func = info.Func or info.Callback,
		DoubleClick = info.DoubleClick == true,
		Tooltip = info.Tooltip,
		DisabledTooltip = info.DisabledTooltip,
		Disabled = info.Disabled == true,
	}
end

--- Re-flows every column in the shared row. Columns are always equal width, so
--- adding one moves and resizes the siblings that were already there.
local function relayout(group)
	local items = group.Items
	local count = #items
	local gap = group.Gap

	for index, segment in items do
		segment.Frame.Size = UDim2.new(1 / count, -gap * (count - 1) / count, 1, 0)
		segment.Frame.Position = UDim2.new((index - 1) / count, (index - 1) * gap / count, 0, 0)
	end
end

--- Momentary accent on the caption. The press has no lasting state to show, so
--- the flash is the entire acknowledgement.
local function flash(segment)
	local Library = segment.Library
	local label = segment.Label

	label.TextColor3 = Library:GetColor("Accent")

	task.delay(FLASH_HOLD, function()
		if Library.Unloaded or not label.Parent then
			return
		end
		Library:Tween(label, {
			TextColor3 = Library:GetColor(segment.Disabled and "FontFaint" or "Font"),
		}, Library.Motion.Slow)
	end)
end

local function press(segment)
	local Library = segment.Library
	if Library.Unloaded or segment.Disabled then
		return
	end

	if segment.DoubleClick and not segment.Confirming then
		segment.Confirming = true
		-- The token invalidates a pending revert, so a confirmed press cannot
		-- be un-confirmed by the timer it started with.
		segment.ConfirmToken += 1
		local token = segment.ConfirmToken
		segment:Display()

		task.delay(CONFIRM_WINDOW, function()
			if Library.Unloaded or segment.ConfirmToken ~= token then
				return
			end
			segment.Confirming = false
			segment:Display()
		end)

		return
	end

	segment.ConfirmToken += 1
	segment.Confirming = false
	segment:Display()

	flash(segment)
	Library:SafeCallback(segment.Func)
end

--- Builds one column into the shared row and wires its behaviour. `segment` is
--- either a Base element (the first button) or a bare Segment (every :AddButton
--- after it) -- both carry the same fields from here on.
local function build(Library, group, segment, options)
	segment.Library = Library
	segment.Group = group
	segment.Row = group.Row
	segment.Opts = options
	segment.Text = options.Text
	segment.Func = options.Func
	segment.DoubleClick = options.DoubleClick
	segment.Disabled = options.Disabled == true
	segment.Confirming = false
	segment.ConfirmToken = 0

	local frame = Library:Panel({
		Name = "Button",
		Size = UDim2.fromScale(1, 1),
		Parent = group.Row,
	}, "Panel", "Outline")

	local label = Library:Label({
		Name = "Text",
		Size = UDim2.fromScale(1, 1),
		Text = Library:FormatLabel(options.Text),
		TextXAlignment = Enum.TextXAlignment.Center,
		-- Columns get narrow fast; a clipped caption beats an overflowing one.
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = frame,
	}, "Font")

	local hit = Library:HitButton(frame)

	segment.Frame = frame
	segment.Label = label
	segment.Hit = hit

	Library:BindHover(hit, frame, "Panel", "PanelRaised")

	Library:GiveSignal(hit.MouseButton1Click:Connect(function()
		press(segment)
	end))

	table.insert(group.Items, segment)
	relayout(group)

	return segment
end

--==============================================================
-- shared column behaviour
--==============================================================

function Segment:Display()
	local text = self.Confirming and CONFIRM_TEXT or self.Text
	self.Label.Text = self.Library:FormatLabel(text)
	return self
end

function Segment:SetText(text)
	self.Text = text ~= nil and tostring(text) or ""
	self:Display()
	return self
end

function Segment:SetDisabled(disabled)
	disabled = disabled == true
	self.Disabled = disabled

	self.Hit:SetAttribute("SableDisabled", disabled)
	self.Hit.Active = not disabled
	self.Hit.Interactable = not disabled

	self.Library:AddToRegistry(self.Label, {
		TextColor3 = disabled and "FontFaint" or "Font",
	})

	return self
end

function Segment:SetTooltip(text, disabledText)
	self.Tooltip = text
	self.DisabledTooltip = disabledText
	if self.UpdateTooltip then
		self.UpdateTooltip(text, disabledText)
	end
	return self
end

--- Splits this button's row into one more equal column.
function Segment:AddButton(info)
	local Library = self.Library
	local options = normalize(info)

	local segment = build(Library, self.Group, setmetatable({}, Segment), options)

	if options.Tooltip or options.DisabledTooltip then
		segment.UpdateTooltip = Library:GiveTooltip(segment.Hit, options.Tooltip, options.DisabledTooltip)
	end

	if segment.Disabled then
		segment:SetDisabled(true)
	end

	return segment
end

--- Removes this column and re-flows the rest. Destroying the *first* button
--- goes through Base instead and takes the whole row -- every column with it.
function Segment:Destroy()
	local items = self.Group.Items
	local index = table.find(items, self)
	if index then
		table.remove(items, index)
	end

	self.Library:RemoveFromRegistry(self.Frame)
	self.Library:RemoveFromRegistry(self.Label)

	pcall(function()
		self.Frame:Destroy()
	end)

	if #items > 0 then
		relayout(self.Group)
	end
end

--==============================================================
-- constructor
--==============================================================

function Button.New(Library, container, info)
	local options = normalize(info)

	local element = Base.Create(Library, container, "Button", nil, options)

	local row = Library:Row(container, Library.Sizes.RowHeight)
	row.Name = "ButtonRow"

	element.Row = row
	element.ExpandedSize = row.Size
	element.Value = false

	local group = {
		Row = row,
		Items = {},
		Gap = Library.Sizes.RowGap * 2,
	}
	element.Group = group

	-- The first button shares the columns' behaviour but keeps Base's state
	-- handling (SetDisabled/SetVisible/Destroy operate on the row it owns).
	element.Display = Segment.Display
	element.SetText = Segment.SetText
	element.AddButton = Segment.AddButton

	--- A button carries no state; present only for the element contract, and
	--- deliberately inert so a config load can never fire a command.
	function element:SetValue(_value, _silent)
		return self
	end

	build(Library, group, element, options)

	return Base.Finish(element, nil)
end

return Button
