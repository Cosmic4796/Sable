--!nonstrict
-- Sable :: elements/init
--
-- Installs the Add* constructors onto the shared container metatable, and the
-- inline picker attachments onto the element base. This is the only place that
-- knows the full element roster.

local Base = require("elements/Base")

local Label = require("elements/Label")
local Button = require("elements/Button")
local Divider = require("elements/Divider")
local Toggle = require("elements/Toggle")
local Slider = require("elements/Slider")
local Input = require("elements/Input")
local Dropdown = require("elements/Dropdown")
local ColorPicker = require("elements/ColorPicker")
local KeyPicker = require("elements/KeyPicker")

local Elements = {}

Elements.Modules = {
	Label = Label,
	Button = Button,
	Divider = Divider,
	Toggle = Toggle,
	Slider = Slider,
	Input = Input,
	Dropdown = Dropdown,
	ColorPicker = ColorPicker,
	KeyPicker = KeyPicker,
}

--- `Container` is the shared __index table used by groupboxes, tabbox tabs and
--- dependency boxes, so installing here covers all three.
function Elements.Install(Library, Container)
	function Container:AddLabel(text, doesWrap)
		return Label.New(Library, self, text, doesWrap)
	end

	function Container:AddButton(...)
		return Button.New(Library, self, ...)
	end

	function Container:AddDivider()
		return Divider.New(Library, self)
	end

	function Container:AddToggle(index, options)
		return Toggle.New(Library, self, index, options)
	end

	function Container:AddSlider(index, options)
		return Slider.New(Library, self, index, options)
	end

	function Container:AddInput(index, options)
		return Input.New(Library, self, index, options)
	end

	function Container:AddDropdown(index, options)
		return Dropdown.New(Library, self, index, options)
	end

	function Container:AddColorPicker(index, options)
		return ColorPicker.New(Library, self, index, options)
	end

	function Container:AddKeyPicker(index, options)
		return KeyPicker.New(Library, self, index, options)
	end

	-- Inline pickers live in an element's `Right` slot, left of its own control.
	function Base.Methods:AddColorPicker(index, options)
		assert(self.Right, ("[Sable] %s does not support an inline ColorPicker"):format(self.Type))
		return ColorPicker.Attach(Library, self, index, options)
	end

	function Base.Methods:AddKeyPicker(index, options)
		assert(self.Right, ("[Sable] %s does not support an inline KeyPicker"):format(self.Type))
		return KeyPicker.Attach(Library, self, index, options)
	end
end

return Elements
