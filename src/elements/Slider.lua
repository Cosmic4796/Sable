--!nonstrict
-- Sable :: elements/Slider
--
-- The segmented instrument slider. The track is a fixed number of equal-width
-- cells that light up as the value rises -- nothing ever resizes, which is what
-- makes it read as equipment rather than as a loading bar. The right-hand
-- readout carries the exact value, because 16 cells cannot.
--
-- The row is elements/Numeric and the bar inside it is elements/Track, both
-- shared with ProgressBar. Everything left in this file -- the hit target, the
-- drag, the readout that brightens while it is held -- is what makes this one a
-- control and that one a readout.

local Util = require("Util")
local Base = require("elements/Base")
local Numeric = require("elements/Numeric")

local Slider = {}

function Slider.New(Library, container, index, options)
	options = options or {}

	local element = Base.Create(Library, container, "Slider", index, options)

	local Sizes = Library.Sizes
	-- Compact is the slider's alone: a readout with no drag has nothing to gain
	-- from losing its label.
	local numeric = Numeric.New(Library, element, options, { Compact = true })
	local trough = numeric.Trough

	-- Taller and wider than the trough: a Track-tall grab target is a nuisance,
	-- so the hit area is grown out to the full row height plus a gap of overhang
	-- on either side.
	local hit = Library:HitButton(trough, {
		Name = "Hit",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, Sizes.RowGap, 1, math.max(0, Sizes.RowHeight - Sizes.Track)),
	})
	element.Hit = hit

	--==============================================================
	-- dragging
	--==============================================================

	local dragging = false

	local function applyFromMouse()
		local width = trough.AbsoluteSize.X
		if width <= 0 then
			return
		end

		-- Measured against the trough's AbsolutePosition, so the cursor has to be
		-- in that space: a raw reading drags the value by the gui inset.
		local alpha = Util.Clamp((Util.MouseInGuiSpace().X - trough.AbsolutePosition.X) / width, 0, 1)
		local value = numeric.ValueFromAlpha(alpha)

		if value ~= element.Value then
			element:SetValue(value)
		end
	end

	local function isDragInput(input)
		return input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
	end

	Library:GiveSignal(hit.InputBegan:Connect(function(input)
		if Library.Unloaded or element.Disabled or not isDragInput(input) then
			return
		end

		dragging = true
		numeric.SetActive(true, true)
		applyFromMouse()
	end))

	-- Movement and release are tracked on the library-wide signals, not on the
	-- button, so a drag survives the cursor leaving the row.
	Library:GiveSignal(Library.InputChanged:Connect(function(input)
		if not dragging then
			return
		end
		if Library.Unloaded then
			dragging = false
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end

		applyFromMouse()
	end))

	Library:GiveSignal(Library.InputEnded:Connect(function(input)
		if not dragging or not isDragInput(input) then
			return
		end

		dragging = false
		numeric.SetActive(false, true)
	end))

	return Base.Finish(element, Library.Options)
end

return Slider
