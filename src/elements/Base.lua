--!nonstrict
-- Sable :: elements/Base
--
-- Shared behaviour for every control. Element modules call Base.Create to get
-- an object with change notification, visibility, disabled state and tooltip
-- handling already wired, then attach their own visuals and :SetValue.
--
-- CONTRACT for element authors -- after Base.Create you MUST set:
--   element.Row    the row Frame you created with Library:Row(container, h)
--   element.Value  the current value
-- and you SHOULD set:
--   element.Label  the TextLabel showing element.Text, if the control has one
--   element.Hit    the TextButton used for hit testing, if the control has one
-- and you MUST implement on the element (not on Base):
--   element:SetValue(value, silent)  apply + repaint + Fire unless silent
--   element:Display()                repaint visuals from element.Value

local Base = {}

local Methods = {}
Methods.__index = Methods
Base.Methods = Methods

--- kind is the element type name ("Toggle", "Slider", ...). `index` is the key
--- it will be registered under in Library.Toggles / Library.Options.
function Base.Create(Library, container, kind, index, options)
	options = options or {}

	local element = setmetatable({}, Methods)

	element.Library = Library
	element.Parent = container
	element.Type = kind
	element.Index = index
	element.Opts = options
	element.Callbacks = {}

	element.Text = options.Text or (type(index) == "string" and index) or ""
	element.Tooltip = options.Tooltip
	element.DisabledTooltip = options.DisabledTooltip
	element.Disabled = options.Disabled == true
	element.Visible = options.Visible ~= false
	element.Risky = options.Risky == true

	table.insert(container.Elements, element)

	return element
end

--- Call once at the end of an element's constructor: registers it in the right
--- store and applies tooltip / disabled / visible state.
---
--- It deliberately does NOT fire the callback: constructing a menu would
--- otherwise run every callback in the script during layout. Callers that want
--- the initial value delivered should use `:OnChanged(fn, true)`.
function Base.Finish(element, store)
	local Library = element.Library

	if element.Index ~= nil and store then
		store[element.Index] = element
		element.Store = store
	end

	if element.Tooltip or element.DisabledTooltip then
		local target = element.Hit or element.Row
		if target then
			element.UpdateTooltip = Library:GiveTooltip(target, element.Tooltip, element.DisabledTooltip)
		end
	end

	if element.Disabled then
		element:SetDisabled(true)
	end

	if not element.Visible then
		element:SetVisible(false)
	end

	return element
end

--==============================================================
-- change notification
--==============================================================

--- Subscribe to value changes. Pass callNow = true to also run immediately
--- with the current value.
function Methods:OnChanged(callback, callNow)
	table.insert(self.Callbacks, callback)
	if callNow then
		self.Library:SafeCallback(callback, self.Value, self)
	end
	return self
end

--- Runs the option Callback first, then every OnChanged subscriber.
function Methods:Fire()
	local Library = self.Library

	if self.Opts.Callback then
		Library:SafeCallback(self.Opts.Callback, self.Value, self)
	end

	for _, callback in self.Callbacks do
		Library:SafeCallback(callback, self.Value, self)
	end
end

--==============================================================
-- state
--==============================================================

function Methods:SetVisible(visible)
	visible = visible ~= false
	self.Visible = visible

	-- UIListLayout already skips invisible children, so toggling Visible is
	-- enough -- the groupbox's AbsoluteContentSize follows on its own. Do not
	-- also zero the row's size; that loses the size with nothing restoring it.
	if self.Row then
		self.Row.Visible = visible
	end

	if self.Parent and self.Parent.Resize then
		self.Parent:Resize()
	end

	return self
end

function Methods:SetDisabled(disabled)
	disabled = disabled == true
	self.Disabled = disabled

	if self.Row then
		self.Row:SetAttribute("SableDisabled", disabled)
	end
	if self.Hit then
		self.Hit:SetAttribute("SableDisabled", disabled)
		self.Hit.Active = not disabled
		self.Hit.Interactable = not disabled
	end

	-- Retheme, not AddToRegistry: adding would stack a second entry for the
	-- same instance every time disabled state flipped.
	--
	-- The element's own rule is captured once and restored on re-enable.
	-- Elements like Toggle register a FUNCTION source that derives the label
	-- colour from live state; overwriting it with a flat key here left OFF
	-- toggles repainting as ON after any theme change.
	if self.Label then
		if self.LabelColourSource == nil then
			self.LabelColourSource = self.Library:GetRegistrySource(self.Label, "TextColor3")
				or (self.Risky and "Risk" or "Font")
		end

		self.Library:Retheme(self.Label, {
			TextColor3 = disabled and "FontFaint" or self.LabelColourSource,
		})
	end

	if self.OnDisabledChanged then
		self.Library:SafeCallback(self.OnDisabledChanged, disabled, self)
	end

	return self
end

function Methods:SetText(text)
	self.Text = text or ""
	if self.Label then
		self.Label.Text = self.Library:FormatLabel(self.Text)
	end
	return self
end

function Methods:SetTooltip(text, disabledText)
	self.Tooltip = text
	self.DisabledTooltip = disabledText
	if self.UpdateTooltip then
		self.UpdateTooltip(text, disabledText)
	end
	return self
end

--==============================================================
-- teardown
--==============================================================

function Methods:Destroy()
	-- Library signals are plain Lua signals, not RBXScriptConnections, so
	-- destroying instances does NOT silence handlers that closed over this
	-- element. Any handler an element registers on Library.InputBegan and
	-- friends MUST bail on this flag, or a destroyed bind keeps firing the
	-- user's callback.
	self.Destroyed = true

	-- Inline pickers live inside THIS element's row but are registered as
	-- independent elements. Destroying only ourselves would take their visuals
	-- away while leaving their store entry, input handlers and keybind-list row
	-- alive forever -- a dead bind that still fires the user's callback.
	if self.Row and self.Parent and self.Parent.Elements then
		for _, other in table.clone(self.Parent.Elements) do
			if other ~= self and other.Row and other.Row ~= self.Row then
				local ok, isDescendant = pcall(function()
					return other.Row:IsDescendantOf(self.Row)
				end)
				if ok and isDescendant then
					other:Destroy()
				end
			end
		end
	end

	if self.Store and self.Index ~= nil and self.Store[self.Index] == self then
		self.Store[self.Index] = nil
	end

	if self.Parent and self.Parent.Elements then
		local index = table.find(self.Parent.Elements, self)
		if index then
			table.remove(self.Parent.Elements, index)
		end
	end

	if self.Row then
		self.Library:RemoveFromRegistry(self.Row)
		pcall(function()
			self.Row:Destroy()
		end)
	end

	table.clear(self.Callbacks)

	if self.Parent and self.Parent.Resize then
		self.Parent:Resize()
	end
end

return Base
