--!nonstrict
-- Sable :: elements/KeyPicker
--
-- A bind capture pill, in two shapes: a standalone row, and an inline addon
-- that rides in a Toggle's / Label's Right slot. State is driven off the
-- library input signals rather than a polling loop, so a Hold bind releases on
-- exactly the frame the key does.

local Util = require("Util")
local Base = require("elements/Base")

local UserInputService = game:GetService("UserInputService")

local KeyPicker = {}

local MODES = { "Toggle", "Hold", "Always" }
local MODE_SET = { Toggle = true, Hold = true, Always = true }

-- Only one pill may be capturing at a time, library-wide: a second click has to
-- cancel the first, or two pickers would swallow the same keystroke.
local ActiveCapture = nil

-- Feeds the stable per-picker id used by the keybind overlay.
local PickerCount = 0

-- A mouse bind resolves on the button *press* that also produces the pill's
-- Click event, so without a short debounce the pill re-enters capture instantly.
local CLICK_DEBOUNCE = 0.2

--==============================================================
-- helpers
--==============================================================

--- Bind names are stored the way Util.InputName produces them (uppercase), so
--- a hand-written Default of "e" still matches a real E press.
local function normalizeKey(key)
	if type(key) ~= "string" or key == "" then
		return "None"
	end

	local upper = key:upper()
	if upper == "NONE" then
		return "None"
	end

	return upper
end

local function normalizeMode(mode)
	if type(mode) ~= "string" or mode == "" then
		return nil
	end

	local canonical = mode:sub(1, 1):upper() .. mode:sub(2):lower()
	if MODE_SET[canonical] then
		return canonical
	end

	return nil
end

--- Swaps a themed colour without leaving a stale registry entry behind. The
--- registry re-applies oldest-entry-last, so simply adding a second entry for
--- the same property would lose to the original on the next theme change.
local function recolor(Library, instance, property, key)
	Library:RemoveFromRegistry(instance)
	Library:AddToRegistry(instance, { [property] = key })
end

--- Inline addons occupy LayoutOrder 10..99 in an element's Right slot, left of
--- the element's own control at 100. Counting what is already there keeps the
--- order stable no matter which addon type was attached first.
local function nextAddonOrder(right)
	local used = 0

	for _, child in right:GetChildren() do
		local gui = child :: any
		if child:IsA("GuiObject") and gui.LayoutOrder >= 10 and gui.LayoutOrder < 100 then
			used += 1
		end
	end

	return 10 + used
end

--- Half a group pad: the library's inner gap unit. Window.lua splits ColumnGap
--- and GroupPad the same way.
local function halfPad(Library)
	return math.ceil(Library.Sizes.GroupPad / 2)
end

--- The pill itself: hairline panel, monospace bind name, auto width.
local function buildPill(Library, parent, standalone, layoutOrder)
	local Sizes = Library.Sizes
	local padX = halfPad(Library)

	local pill, stroke = Library:Panel({
		Name = "Bind",
		AnchorPoint = standalone and Vector2.new(1, 0.5) or Vector2.new(0, 0),
		Position = standalone and UDim2.new(1, 0, 0.5, 0) or UDim2.new(0, 0, 0, 0),
		-- One control square tall plus a row gap of air, so the bind text is not
		-- jammed against the hairline. Still short enough that the pill, its
		-- stroke and a swatch all clear a RowHeight addon slot.
		Size = UDim2.new(0, 0, 0, Sizes.Control + Sizes.RowGap),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = layoutOrder or 1,
		Parent = parent,
	}, "Panel", "Outline")

	Util.Padding(pill, 0, padX, 0, padX)

	local value = Library:Label({
		Name = "Value",
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = Library.Fonts.Value,
		TextSize = Sizes.TextSmall,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "NONE",
		Parent = pill,
	}, "FontDim")

	local hit = Library:HitButton(pill, { Name = "Hit" })

	return pill, stroke, value, hit
end

--==============================================================
-- behaviour
--==============================================================

--- Everything both constructors share. `host` is the element this picker is
--- attached to, or nil for a standalone row.
local function install(Library, element, options, host, pill, stroke, value, hit)
	PickerCount += 1

	local overlayId = ("Sable.KeyPicker.%d.%s"):format(PickerCount, tostring(element.Index))
	local clickCallbacks = {}
	local lastCaptureEnd = 0

	-- SyncToggleState is only meaningful on a host that owns a boolean.
	local sync = host ~= nil and options.SyncToggleState == true and host.Type == "Toggle"
	local syncing = false

	local popupFrame = nil
	local popupHandle = nil
	local popupRows = nil
	local refreshPopup = nil

	element.Value = normalizeKey(options.Default)
	element.Mode = normalizeMode(options.Mode) or "Toggle"
	element.State = false
	element.Capturing = false
	element.NoUI = options.NoUI == true

	--==========================================================
	-- paint
	--==========================================================

	--- The overlay is installed by Overlays, which may not have run when this
	--- module was required -- so it is resolved on every call, never cached.
	local function overlay()
		if element.NoUI then
			return
		end

		local list = Library.KeybindList
		if not list then
			return
		end

		list:Set(overlayId, {
			Text = element.Text,
			Key = element.Value,
			Mode = element.Mode,
			Active = element:GetState(),
		})
	end

	function element:GetState()
		if self.Mode == "Always" then
			return true
		end
		if self.Mode == "Hold" then
			return Util.IsHeld(self.Value)
		end
		return self.State == true
	end

	function element:Display()
		local capturing = self.Capturing

		value.Text = capturing and "..." or Library:FormatLabel(self.Value)

		local textKey
		if self.Disabled then
			textKey = "FontFaint"
		elseif capturing then
			textKey = "Accent"
		elseif self:GetState() then
			textKey = "Font"
		else
			textKey = "FontDim"
		end

		recolor(Library, value, "TextColor3", textKey)
		recolor(Library, stroke, "Color", capturing and "Accent" or (self.Disabled and "OutlineDim" or "Outline"))

		if refreshPopup then
			refreshPopup()
		end
	end

	-- Base repaints the row label on its own; the pill needs the same nudge.
	element.OnDisabledChanged = function()
		element:Display()
	end

	--==========================================================
	-- state
	--==========================================================

	local function fireState()
		Library:SafeCallback(options.Callback, element.State, element)

		for _, callback in clickCallbacks do
			Library:SafeCallback(callback, element.State, element)
		end
	end

	local function setState(state, silent)
		state = state == true
		if element.State == state then
			return
		end

		element.State = state
		element:Display()
		overlay()

		if sync and not syncing then
			syncing = true
			host:SetValue(state)
			syncing = false
		end

		if not silent then
			fireState()
		end
	end

	--- Hold and Always are derived states -- recompute them whenever the bind
	--- or the mode moves. Toggle keeps whatever the user last set.
	local function reconcileState(silent)
		if element.Mode == "Always" then
			setState(true, silent)
		elseif element.Mode == "Hold" then
			setState(Util.IsHeld(element.Value), silent)
		end
	end

	--==========================================================
	-- capture
	--==========================================================

	local function endCapture()
		if not element.Capturing then
			return
		end

		element.Capturing = false
		lastCaptureEnd = os.clock()

		if ActiveCapture == element then
			ActiveCapture = nil
			-- Deferred: handlers further down the same InputBegan dispatch must
			-- still see the flag, or the keystroke just bound here would also
			-- fire whatever else listens for it.
			task.defer(function()
				if not ActiveCapture then
					Library.CapturingInput = false
				end
			end)
		end

		element:Display()
	end

	element.CancelCapture = endCapture

	local function beginCapture()
		if element.Disabled or element.Capturing then
			return
		end
		if os.clock() - lastCaptureEnd < CLICK_DEBOUNCE then
			return
		end

		if ActiveCapture then
			ActiveCapture.CancelCapture()
		end

		Library:ClosePopup()

		element.Capturing = true
		ActiveCapture = element
		Library.CapturingInput = true

		element:Display()
	end

	--==========================================================
	-- mode popup
	--==========================================================

	local Sizes = Library.Sizes
	local padX = halfPad(Library)

	local rowHeight = Sizes.RowHeight
	-- The rows sit inside a one-hairline inset, which the popup has to carry.
	local popupHeight = rowHeight * #MODES + Sizes.Outline * 2
	local popupWidth = 0

	for _, mode in MODES do
		local measured = Util.TextSize(Library:FormatLabel(mode), Sizes.TextSmall, Library.Fonts.Value)
		popupWidth = math.max(popupWidth, measured.X)
	end
	-- Widest mode name, plus each row's own padding and the same hairline inset.
	popupWidth = math.ceil(popupWidth) + padX * 2 + Sizes.Outline * 2

	local function buildPopup()
		if popupFrame then
			return
		end

		local frame = Library:Panel({
			Name = "BindModes",
			Visible = false,
			Size = UDim2.fromOffset(popupWidth, popupHeight),
			Parent = Library.PopupHolder,
		}, "Panel", "Outline")

		-- The ticks must NOT share a parent with the list layout: UIListLayout
		-- positions every GuiObject child with no opt-out, so eight tick frames
		-- would be laid out as rows and shove the real ones out of the popup.
		Library:CornerTicks(frame, "Accent")

		local content = Library:Create("Frame", {
			Name = "Content",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			Parent = frame,
		})

		Util.Padding(content, Sizes.Outline, Sizes.Outline, Sizes.Outline, Sizes.Outline)
		Util.ListLayout(content, 0)

		popupRows = {}

		for order, mode in MODES do
			local rowFrame = Library:Panel({
				Name = mode,
				Size = UDim2.new(1, 0, 0, rowHeight),
				LayoutOrder = order,
				Parent = content,
			}, "Panel", false)

			local rowLabel = Library:Label({
				Name = "Text",
				Size = UDim2.fromScale(1, 1),
				Font = Library.Fonts.Value,
				TextSize = Sizes.TextSmall,
				Text = Library:FormatLabel(mode),
				Parent = rowFrame,
			}, "FontDim")

			Util.Padding(rowLabel, 0, padX, 0, padX)

			local rowHit = Library:HitButton(rowFrame, { Name = "Hit" })
			Library:BindHover(rowHit, rowFrame, "Panel", "PanelRaised")

			Library:GiveSignal(rowHit.MouseButton1Click:Connect(function()
				Library:ClosePopup(popupHandle)
				popupHandle = nil
				element:SetValue({ Key = element.Value, Mode = mode })
			end))

			popupRows[mode] = rowLabel
		end

		popupFrame = frame
	end

	refreshPopup = function()
		if not popupRows then
			return
		end

		for mode, rowLabel in popupRows do
			recolor(Library, rowLabel, "TextColor3", mode == element.Mode and "Accent" or "FontDim")
		end
	end

	local function openModePopup()
		buildPopup()
		refreshPopup()

		popupHandle = Library:OpenPopup(popupFrame, pill, {
			Width = popupWidth,
			Height = popupHeight,
			OnClose = function()
				popupHandle = nil
			end,
		})
	end

	--==========================================================
	-- public value api
	--==========================================================

	--- Accepts "E", { "E", "Hold" } or { Key = "E", Mode = "Hold" }.
	function element:SetValue(newValue, silent)
		local key, mode = self.Value, self.Mode

		if type(newValue) == "table" then
			key = newValue.Key or newValue.key or newValue[1] or key
			mode = newValue.Mode or newValue.mode or newValue[2] or mode
		elseif newValue ~= nil then
			key = newValue
		end

		self.Value = normalizeKey(key)
		self.Mode = normalizeMode(mode) or self.Mode

		reconcileState(silent)
		self:Display()
		overlay()

		if not silent then
			self:Fire()
		end

		return self
	end

	--- KeyPicker splits its callbacks: Callback carries the on/off state, while
	--- Fire (bind or mode changed) drives ChangedCallback and OnChanged.
	function element:Fire()
		Library:SafeCallback(options.ChangedCallback, self.Value, self)

		for _, callback in self.Callbacks do
			Library:SafeCallback(callback, self.Value, self)
		end
	end

	function element:OnClick(callback)
		if type(callback) == "function" then
			table.insert(clickCallbacks, callback)
		end
		return self
	end

	-- The overlay row carries the element's text, so renaming has to repost it.
	local baseSetText = Base.Methods.SetText

	function element:SetText(text)
		baseSetText(self, text)
		overlay()
		return self
	end

	--==========================================================
	-- input
	--==========================================================

	Library:GiveSignal(hit.MouseButton1Click:Connect(function()
		beginCapture()
	end))

	Library:GiveSignal(hit.MouseButton2Click:Connect(function()
		if element.Disabled then
			return
		end
		if element.Capturing then
			endCapture()
			return
		end
		if os.clock() - lastCaptureEnd < CLICK_DEBOUNCE then
			return
		end
		openModePopup()
	end))

	Library:GiveSignal(Library.InputBegan:Connect(function(input)
		-- Destroyed is set by Base:Destroy. Without it this closure keeps the
		-- element alive and a deleted bind still runs the user's callback.
		if Library.Unloaded or element.Destroyed then
			return
		end

		if element.Capturing then
			local name = Util.InputName(input)
			if not name then
				return
			end

			endCapture()
			element:SetValue(name == "ESC" and "None" or name)
			return
		end

		if Library.CapturingInput or element.Disabled then
			return
		end
		if UserInputService:GetFocusedTextBox() then
			return
		end
		if element.Value == "None" or not Util.InputMatches(input, element.Value) then
			return
		end

		if element.Mode == "Toggle" then
			setState(not element.State)
		elseif element.Mode == "Hold" then
			setState(true)
		end
	end))

	Library:GiveSignal(Library.InputEnded:Connect(function(input)
		if Library.Unloaded or element.Destroyed or element.Mode ~= "Hold" then
			return
		end
		if element.Value == "None" or not Util.InputMatches(input, element.Value) then
			return
		end

		-- Releases are honoured even mid-capture or with a textbox focused: a
		-- Hold bind stuck on is far worse than one that drops early.
		setState(false)
	end))

	--==========================================================
	-- teardown
	--==========================================================

	local baseDestroy = Base.Methods.Destroy

	function element:Destroy()
		endCapture()

		if popupHandle then
			Library:ClosePopup(popupHandle)
			popupHandle = nil
		end

		if popupFrame then
			Library:RemoveFromRegistry(popupFrame)
			pcall(function()
				popupFrame:Destroy()
			end)
			popupFrame = nil
			popupRows = nil
		end

		local list = Library.KeybindList
		if list and not self.NoUI then
			list:Remove(overlayId)
		end

		table.clear(clickCallbacks)
		baseDestroy(self)
	end

	Library:OnUnload(function()
		-- Immediate, not deferred: nothing is left running to clear the flag.
		if element.Capturing then
			element.Capturing = false
			if ActiveCapture == element then
				ActiveCapture = nil
			end
			Library.CapturingInput = false
		end
	end)

	--==========================================================
	-- initial state
	--==========================================================

	if sync then
		element.State = host.Value == true

		host:OnChanged(function(hostValue)
			if syncing then
				return
			end
			syncing = true
			setState(hostValue == true)
			syncing = false
		end)
	end

	reconcileState(true)
	element:Display()
	overlay()
end

--==============================================================
-- constructors
--==============================================================

function KeyPicker.New(Library, container, index, options)
	options = options or {}

	local element = Base.Create(Library, container, "KeyPicker", index, options)

	local row = Library:Row(container)
	element.Row = row
	element.ExpandedSize = row.Size

	local label = Library:Label({
		Name = "Label",
		Size = UDim2.new(1, 0, 1, 0),
		Text = Library:FormatLabel(element.Text),
		TextTruncate = Enum.TextTruncate.AtEnd,
		Parent = row,
	}, element.Risky and "Risk" or "Font")
	element.Label = label

	local pill, stroke, value, hit = buildPill(Library, row, true, nil)
	element.Hit = hit

	-- The pill's width is only known once AutomaticSize has run, so the label
	-- reserves its space reactively instead of guessing.
	local labelGap = halfPad(Library)

	Library:GiveSignal(pill:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
		label.Size = UDim2.new(1, -(pill.AbsoluteSize.X + labelGap), 1, 0)
	end))

	install(Library, element, options, nil, pill, stroke, value, hit)

	return Base.Finish(element, Library.Options)
end

function KeyPicker.Attach(Library, host, index, options)
	options = options or {}

	-- Registered against the host's container so the groupbox still owns it,
	-- but the pill (not the host row) is the element's own frame.
	local element = Base.Create(Library, host.Parent, "KeyPicker", index, options)

	local pill, stroke, value, hit = buildPill(Library, host.Right, false, nextAddonOrder(host.Right))
	element.Row = pill
	element.ExpandedSize = pill.Size
	element.Hit = hit
	element.Host = host

	install(Library, element, options, host, pill, stroke, value, hit)

	host.KeyPicker = element

	return Base.Finish(element, Library.Options)
end

return KeyPicker
