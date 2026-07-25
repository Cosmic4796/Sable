--!nonstrict
-- Sable :: elements/ColorPicker
--
-- A swatch that opens an HSV popup: saturation/value square, vertical hue bar,
-- an optional alpha bar, and a hex field. Hue/sat/val are stored separately
-- from the resulting Color3 -- deriving the colour from HSV on every change is
-- what lets you drag value down to black and back without the hue collapsing
-- to red on the way.
--
-- Two entry points share one builder: New() gives the swatch its own row,
-- Attach() puts it in a host element's Right slot at LayoutOrder 10 + n, which
-- lands it to the left of the host's own control.

local Util = require("Util")
local Base = require("elements/Base")

local ColorPicker = {}

--==============================================================
-- geometry
--==============================================================

local PAD = 8
local GAP = 6
local SV_SIZE = 132
local BAR_WIDTH = 12
local ALPHA_HEIGHT = 10
local FIELD_HEIGHT = 18
local COPY_WIDTH = 44
local TITLE_HEIGHT = 12
local CURSOR_SIZE = 7

local CONTENT_WIDTH = SV_SIZE + GAP + BAR_WIDTH
local POPUP_WIDTH = CONTENT_WIDTH + PAD * 2

-- Pure white and pure black are not theming here, they are the arithmetic of
-- the HSV square: saturation fades toward white, value fades toward black. A
-- themed "white" would make the picker report a colour it is not showing. Same
-- exemption the swatch fill gets -- these ARE the value, not a surface.
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)

local hueStops = table.create(7)
for step = 0, 6 do
	local alpha = step / 6
	table.insert(hueStops, ColorSequenceKeypoint.new(alpha, Color3.fromHSV(alpha, 1, 1)))
end
local HUE_SEQUENCE = ColorSequence.new(hueStops)

-- Opaque at offset 0, gone at offset 1. Rotation decides which edge that is.
local FADE_OUT = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(1, 1),
})

local FADE_IN = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(1, 0),
})

--==============================================================
-- helpers
--==============================================================

--- Next free slot in a host's addon band. Counted off the live children rather
--- than a shared counter so ColorPicker and KeyPicker interleave correctly no
--- matter which order the script author attaches them in.
local function nextAddonOrder(right)
	local used = 0
	for _, child in right:GetChildren() do
		-- The host's own control sits at 100; addons occupy 10..99.
		if child:IsA("GuiObject") and child.LayoutOrder >= 10 and child.LayoutOrder < 100 then
			used += 1
		end
	end
	return 10 + used
end

--- Accepts everything a caller or a saved config might hand us: a Color3, a
--- hex string, or the { hex, transparency } pair SaveManager serialises.
local function decode(value)
	if typeof(value) == "Color3" then
		return value, nil
	end

	if type(value) == "string" then
		return Util.FromHex(value), nil
	end

	if type(value) == "table" then
		local raw = value.Hex or value.hex or value.Color or value[1]
		local color = typeof(raw) == "Color3" and raw or Util.FromHex(raw)

		local transparency = value.Transparency or value.transparency or value[2]
		return color, type(transparency) == "number" and transparency or nil
	end

	return nil, nil
end

--==============================================================
-- builder
--==============================================================

--- `host` is nil for a standalone row, or the element whose Right slot the
--- swatch should live in. Everything past the swatch is identical either way.
local function build(Library, container, host, index, options)
	options = options or {}

	local element = Base.Create(Library, container, "ColorPicker", index, options)

	local sizes = Library.Sizes
	local control = sizes.Control

	local default = typeof(options.Default) == "Color3" and options.Default or Library:GetColor("Accent")
	local hue, saturation, value = default:ToHSV()

	element.Hue = hue
	element.Sat = saturation
	element.Val = value
	element.Value = Color3.fromHSV(hue, saturation, value)
	element.Transparency = type(options.Transparency) == "number" and Util.Clamp(options.Transparency, 0, 1)
		or nil
	element.Title = options.Title or (type(index) == "string" and index) or element.Text

	local hasAlpha = element.Transparency ~= nil

	--==========================================================
	-- swatch
	--==========================================================

	local row
	if host then
		-- Hosts put a row-wide hit button at the default ZIndex 5; lifting the
		-- addon slot above it is what lets a click reach the swatch instead of
		-- toggling the host underneath.
		if host.Right.ZIndex < 6 then
			host.Right.ZIndex = 6
		end

		-- The holder is exactly swatch-sized so the host's list layout reserves
		-- the right amount of room, and so SetVisible can collapse just us.
		row = Library:Create("Frame", {
			Name = "ColorPicker",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.fromOffset(control, control),
			LayoutOrder = nextAddonOrder(host.Right),
			ZIndex = 6,
			Parent = host.Right,
		})
	else
		row = Library:Row(container)

		element.Label = Library:Label({
			Name = "Label",
			Text = Library:FormatLabel(element.Text),
			Size = UDim2.new(1, -(control + GAP), 1, 0),
			Parent = row,
		}, element.Risky and "Risk" or "Font")
	end

	element.Row = row
	element.ExpandedSize = row.Size

	-- The one legitimate raw Color3 in an element: this is the value itself,
	-- not a themed surface, so it must NOT go into the colour registry.
	local swatch = Library:Create("Frame", {
		Name = "Swatch",
		BorderSizePixel = 0,
		BackgroundColor3 = element.Value,
		BackgroundTransparency = element.Transparency or 0,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, 0, 0.5, 0),
		Size = UDim2.fromOffset(control, control),
		Parent = row,
	})
	Library:AddToRegistry(Util.Stroke(swatch, Library:GetColor("Outline"), sizes.Outline), { Color = "Outline" })

	local hit = Library:HitButton(swatch, { Name = "SwatchHit" })

	element.Swatch = swatch
	element.Hit = hit

	--==========================================================
	-- popup
	--==========================================================

	local popupFrame, popupHandle
	local svBase, svCursor, hueBar, hueMarker
	local alphaBase, alphaFill, alphaMarker, hexBox
	local dragging = nil

	local function popupHeight()
		local height = PAD + TITLE_HEIGHT + GAP + SV_SIZE + GAP + FIELD_HEIGHT + PAD
		if hasAlpha then
			height += ALPHA_HEIGHT + GAP
		end
		return height
	end

	--- Fraction of the way across (or down) a frame the cursor currently is.
	local function ratio(frame, horizontal)
		local origin = frame.AbsolutePosition
		local size = frame.AbsoluteSize
		local mouse = Util.MousePosition()

		if horizontal then
			if size.X <= 0 then
				return 0
			end
			return Util.Clamp((mouse.X - origin.X) / size.X, 0, 1)
		end

		if size.Y <= 0 then
			return 0
		end
		return Util.Clamp((mouse.Y - origin.Y) / size.Y, 0, 1)
	end

	local function commit(silent)
		element.Value = Color3.fromHSV(element.Hue, element.Sat, element.Val)
		element:Display()
		if not silent then
			element:Fire()
		end
	end

	local function updateDrag()
		if dragging == "SV" then
			element.Sat = ratio(svBase, true)
			element.Val = 1 - ratio(svBase, false)
		elseif dragging == "Hue" then
			element.Hue = ratio(hueBar, false)
		elseif dragging == "Alpha" then
			element.Transparency = ratio(alphaBase, true)
		else
			return
		end

		commit(false)
	end

	--- Press anywhere in a track starts a drag AND jumps to that point, which
	--- is what makes the control feel direct rather than handle-based.
	local function bindTrack(button, mode)
		Library:GiveSignal(button.InputBegan:Connect(function(input)
			if
				input.UserInputType ~= Enum.UserInputType.MouseButton1
				and input.UserInputType ~= Enum.UserInputType.Touch
			then
				return
			end
			dragging = mode
			updateDrag()
		end))
	end

	local function buildPopup()
		if popupFrame then
			return popupFrame
		end

		local frame = Library:Panel({
			Name = "ColorPopup",
			Visible = false,
			Size = UDim2.fromOffset(POPUP_WIDTH, popupHeight()),
			Parent = Library.PopupHolder,
		}, "Panel", "Outline")
		popupFrame = frame

		Library:CornerTicks(frame, "Accent")

		Library:Label({
			Name = "Title",
			Text = Library:Chrome(element.Title),
			TextSize = sizes.TextSmall,
			Position = UDim2.fromOffset(PAD, PAD),
			Size = UDim2.new(1, -PAD * 2, 0, TITLE_HEIGHT),
			Parent = frame,
		}, "FontDim")

		local cursorY = PAD + TITLE_HEIGHT + GAP

		--------------------------------------------------------
		-- saturation / value square
		--------------------------------------------------------

		svBase = Library:Create("Frame", {
			Name = "SV",
			BorderSizePixel = 0,
			BackgroundColor3 = Color3.fromHSV(element.Hue, 1, 1),
			Position = UDim2.fromOffset(PAD, cursorY),
			Size = UDim2.fromOffset(SV_SIZE, SV_SIZE),
			Parent = frame,
		})
		Library:AddToRegistry(
			Util.Stroke(svBase, Library:GetColor("Outline"), sizes.Outline),
			{ Color = "Outline" }
		)

		local satFade = Library:Create("Frame", {
			Name = "Saturation",
			BorderSizePixel = 0,
			BackgroundColor3 = WHITE,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 2,
			Parent = svBase,
		})
		Util.Create("UIGradient", {
			Name = "Fade",
			Transparency = FADE_OUT,
			Parent = satFade,
		})

		local valFade = Library:Create("Frame", {
			Name = "Value",
			BorderSizePixel = 0,
			BackgroundColor3 = BLACK,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 3,
			Parent = svBase,
		})
		Util.Create("UIGradient", {
			Name = "Fade",
			Rotation = 90,
			Transparency = FADE_IN,
			Parent = valFade,
		})

		-- Two nested hairline rings: the dark one reads on pale colours, the
		-- light one on dark colours, so the marker never disappears.
		svCursor = Library:Create("Frame", {
			Name = "Cursor",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(CURSOR_SIZE, CURSOR_SIZE),
			ZIndex = 4,
			Parent = svBase,
		})
		Library:AddToRegistry(Util.Stroke(svCursor, Library:GetColor("Black"), 1), { Color = "Black" })

		local cursorInner = Library:Create("Frame", {
			Name = "Inner",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, -2, 1, -2),
			ZIndex = 4,
			Parent = svCursor,
		})
		Library:AddToRegistry(Util.Stroke(cursorInner, Library:GetColor("Font"), 1), { Color = "Font" })

		bindTrack(Library:HitButton(svBase, { Name = "SVHit" }), "SV")

		--------------------------------------------------------
		-- hue bar
		--------------------------------------------------------

		hueBar = Library:Create("Frame", {
			Name = "Hue",
			BorderSizePixel = 0,
			-- A UIGradient multiplies the fill, so the base has to be white for
			-- the spectrum keypoints to come through unshifted.
			BackgroundColor3 = WHITE,
			Position = UDim2.fromOffset(PAD + SV_SIZE + GAP, cursorY),
			Size = UDim2.fromOffset(BAR_WIDTH, SV_SIZE),
			Parent = frame,
		})
		Util.Create("UIGradient", {
			Name = "Spectrum",
			Rotation = 90,
			Color = HUE_SEQUENCE,
			Parent = hueBar,
		})
		Library:AddToRegistry(
			Util.Stroke(hueBar, Library:GetColor("Outline"), sizes.Outline),
			{ Color = "Outline" }
		)

		hueMarker = Library:Create("Frame", {
			Name = "Marker",
			BorderSizePixel = 0,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0),
			Size = UDim2.new(1, 2, 0, 2),
			ZIndex = 2,
			Theme = { BackgroundColor3 = "Font" },
			Parent = hueBar,
		})
		Library:AddToRegistry(Util.Stroke(hueMarker, Library:GetColor("Black"), 1), { Color = "Black" })

		bindTrack(Library:HitButton(hueBar, { Name = "HueHit" }), "Hue")

		cursorY += SV_SIZE + GAP

		--------------------------------------------------------
		-- alpha bar
		--------------------------------------------------------

		if hasAlpha then
			alphaBase = Library:Panel({
				Name = "Alpha",
				Position = UDim2.fromOffset(PAD, cursorY),
				Size = UDim2.fromOffset(CONTENT_WIDTH, ALPHA_HEIGHT),
				Parent = frame,
			}, "PanelSunken", "Outline")

			alphaFill = Library:Create("Frame", {
				Name = "Fill",
				BorderSizePixel = 0,
				BackgroundColor3 = element.Value,
				Size = UDim2.fromScale(1, 1),
				ZIndex = 2,
				Parent = alphaBase,
			})
			Util.Create("UIGradient", {
				Name = "Fade",
				Transparency = FADE_OUT,
				Parent = alphaFill,
			})

			alphaMarker = Library:Create("Frame", {
				Name = "Marker",
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0, 0.5),
				Size = UDim2.new(0, 2, 1, 2),
				ZIndex = 3,
				Theme = { BackgroundColor3 = "Font" },
				Parent = alphaBase,
			})
			Library:AddToRegistry(Util.Stroke(alphaMarker, Library:GetColor("Black"), 1), { Color = "Black" })

			bindTrack(Library:HitButton(alphaBase, { Name = "AlphaHit" }), "Alpha")

			cursorY += ALPHA_HEIGHT + GAP
		end

		--------------------------------------------------------
		-- hex field + copy
		--------------------------------------------------------

		local fieldWidth = CONTENT_WIDTH - COPY_WIDTH - GAP

		local field = Library:Panel({
			Name = "Hex",
			Position = UDim2.fromOffset(PAD, cursorY),
			Size = UDim2.fromOffset(fieldWidth, FIELD_HEIGHT),
			Parent = frame,
		}, "PanelSunken", "Outline")

		hexBox = Library:Create("TextBox", {
			Name = "Field",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ClearTextOnFocus = false,
			Font = Library.Fonts.Value,
			TextSize = sizes.TextSmall,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Center,
			Text = Util.ToHex(element.Value),
			PlaceholderText = "RRGGBB",
			Size = UDim2.fromScale(1, 1),
			ZIndex = 2,
			Theme = { TextColor3 = "Font", PlaceholderColor3 = "FontFaint" },
			Parent = field,
		})

		Library:GiveSignal(hexBox.FocusLost:Connect(function()
			local parsed = Util.FromHex(hexBox.Text)
			if parsed then
				element:SetValue(parsed)
			else
				-- Invalid input never mutates the value; repaint puts the last
				-- good hex back in the box.
				element:Display()
			end
		end))

		local copy = Library:Panel({
			Name = "Copy",
			Position = UDim2.fromOffset(PAD + fieldWidth + GAP, cursorY),
			Size = UDim2.fromOffset(COPY_WIDTH, FIELD_HEIGHT),
			Parent = frame,
		}, "Panel", "Outline")

		Library:Label({
			Name = "Text",
			Text = Library:FormatLabel("Copy"),
			TextSize = sizes.TextSmall,
			TextXAlignment = Enum.TextXAlignment.Center,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 2,
			Parent = copy,
		}, "FontDim")

		local copyHit = Library:HitButton(copy, { Name = "CopyHit" })
		Library:BindHover(copyHit, copy, "Panel", "PanelRaised")

		Library:GiveSignal(copyHit.MouseButton1Click:Connect(function()
			Util.SetClipboard(Util.ToHex(element.Value))
		end))

		return frame
	end

	--==========================================================
	-- api
	--==========================================================

	function element:Display()
		swatch.BackgroundColor3 = self.Value
		swatch.BackgroundTransparency = self.Transparency or 0

		if not popupFrame then
			return self
		end

		svBase.BackgroundColor3 = Color3.fromHSV(self.Hue, 1, 1)
		svCursor.Position = UDim2.fromScale(self.Sat, 1 - self.Val)
		hueMarker.Position = UDim2.fromScale(0.5, self.Hue)

		if alphaFill then
			alphaFill.BackgroundColor3 = self.Value
			alphaMarker.Position = UDim2.fromScale(self.Transparency or 0, 0.5)
		end

		-- Never fight the user mid-edit.
		if not hexBox:IsFocused() then
			hexBox.Text = Util.ToHex(self.Value)
		end

		return self
	end

	function element:SetValue(newValue, silent)
		local color, transparency = decode(newValue)

		if color then
			local newHue, newSat, newVal = color:ToHSV()
			-- Greys and blacks report hue 0; keeping the stored hue means a
			-- round trip through black does not silently turn the picker red.
			if newSat > 0 and newVal > 0 then
				self.Hue = newHue
			end
			self.Sat = newSat
			self.Val = newVal
		end

		if transparency ~= nil and self.Transparency ~= nil then
			self.Transparency = Util.Clamp(transparency, 0, 1)
		end

		commit(silent)
		return self
	end

	--- Linoria compatibility: same thing, always audible.
	function element:SetValueRGB(color, transparency)
		if transparency ~= nil and self.Transparency ~= nil then
			self.Transparency = Util.Clamp(tonumber(transparency) or 0, 0, 1)
		end
		return self:SetValue(color, false)
	end

	function element:SetTransparency(newTransparency, silent)
		if self.Transparency == nil then
			return self
		end
		self.Transparency = Util.Clamp(tonumber(newTransparency) or 0, 0, 1)
		commit(silent)
		return self
	end

	function element:Open()
		if self.Disabled then
			return self
		end

		local frame = buildPopup()
		self:Display()

		popupHandle = Library:OpenPopup(frame, swatch, {
			Width = POPUP_WIDTH,
			Height = popupHeight(),
			Gap = 4,
			OnClose = function()
				dragging = nil
			end,
		})

		return self
	end

	function element:Close()
		if popupHandle then
			Library:ClosePopup(popupHandle)
		end
		return self
	end

	function element:Destroy()
		self:Close()

		if popupFrame then
			pcall(function()
				popupFrame:Destroy()
			end)
			popupFrame = nil
		end

		return Base.Methods.Destroy(self)
	end

	--==========================================================
	-- wiring
	--==========================================================

	Library:GiveSignal(hit.MouseButton1Click:Connect(function()
		if element.Disabled then
			return
		end

		local active = Library.ActivePopup
		if active and popupFrame and active.Frame == popupFrame then
			element:Close()
			return
		end

		element:Open()
	end))

	-- Tracked on the shared signals rather than the track itself so the drag
	-- survives the cursor leaving the popup entirely.
	Library:GiveSignal(Library.InputChanged:Connect(function(input)
		if Library.Unloaded or not dragging then
			return
		end
		if
			input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch
		then
			return
		end
		updateDrag()
	end))

	Library:GiveSignal(Library.InputEnded:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = nil
		end
	end))

	element:Display()

	return Base.Finish(element, Library.Options)
end

--==============================================================
-- constructors
--==============================================================

function ColorPicker.New(Library, container, index, options)
	return build(Library, container, nil, index, options)
end

--- Inline picker: registered in Library.Options exactly like a standalone one,
--- but parented into the host's addon slot and owned by the host's container
--- so Destroy/Resize bookkeeping still lands in the right place.
function ColorPicker.Attach(Library, host, index, options)
	assert(host.Right, "[Sable] host element has no Right slot for a ColorPicker")
	assert(host.Parent, "[Sable] host element has no container")

	local element = build(Library, host.Parent, host, index, options)
	element.Host = host

	return element
end

return ColorPicker
