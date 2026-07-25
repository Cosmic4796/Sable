--!nonstrict
-- Sable :: addons/ThemeManager
--
-- Colour presets plus a live per-key editor, persisted as hex under
-- <folder>/themes. Reached as Library.ThemeManager -- the spine calls
-- :SetLibrary for you; the method survives being called again so Linoria-style
-- scripts that call it themselves keep working.
--
-- Every preset keeps the warm, dark, low-chroma neutrals of the stock scheme.
-- A theme moves the accent and nudges the greys; it never turns Sable into a
-- bright or pastel menu.

local Util = require("Util")

local ThemeManager = {}

--- The keys the editor exposes. Everything else in a scheme is derived from
--- the preset (AccentDim follows Accent inside Library:SetScheme).
local KEYS = { "Accent", "Background", "Panel", "Outline", "Font" }

--- Presentation order for the dropdown; unknown extras are appended sorted.
local ORDER = { "Sable", "Ember", "Signal", "Ice", "Void", "Mono" }

ThemeManager.Library = nil :: any
ThemeManager.Folder = "Sable"
ThemeManager.Theme = "Sable"
ThemeManager.CustomKeys = KEYS

--- key -> hex string, only for colours the user overrode on top of the preset.
ThemeManager.Custom = {}
--- Elements built by :ApplyToGroupbox, so a later theme change can resync them.
ThemeManager.Objects = {}

--- True only while :ApplyToGroupbox constructs its controls, so the elements'
--- initial callbacks cannot stomp a theme that was already loaded from disk.
ThemeManager.Building = false

ThemeManager.ListIndex = "ThemeManager_ThemeList"
ThemeManager.PickerIndexes = {
	Accent = "ThemeManager_AccentColor",
	Background = "ThemeManager_BackgroundColor",
	Panel = "ThemeManager_PanelColor",
	Outline = "ThemeManager_OutlineColor",
	Font = "ThemeManager_FontColor",
}

-- Flat list so SaveManager:IgnoreThemeSettings has one thing to read.
ThemeManager.Indexes = { ThemeManager.ListIndex }
for _, key in KEYS do
	table.insert(ThemeManager.Indexes, ThemeManager.PickerIndexes[key])
end

--==============================================================
-- presets
--==============================================================

ThemeManager.BuiltInThemes = {
	-- Mirrored from Theme.Default in :SetLibrary; kept here in full so the
	-- table is complete even if the addon is used before the spine runs.
	Sable = {
		Background = Color3.fromRGB(18, 17, 15),
		Panel = Color3.fromRGB(26, 25, 22),
		PanelRaised = Color3.fromRGB(34, 32, 29),
		PanelSunken = Color3.fromRGB(13, 12, 11),
		Outline = Color3.fromRGB(52, 49, 44),
		OutlineDim = Color3.fromRGB(36, 34, 30),
		Accent = Color3.fromRGB(233, 161, 59),
		AccentDim = Color3.fromRGB(126, 88, 34),
		Font = Color3.fromRGB(218, 213, 204),
		FontDim = Color3.fromRGB(124, 117, 107),
		FontFaint = Color3.fromRGB(84, 79, 72),
		Risk = Color3.fromRGB(226, 78, 63),
		Good = Color3.fromRGB(126, 176, 106),
		Black = Color3.fromRGB(0, 0, 0),
	},

	-- Brick red. Deliberately deeper than Risk so a risky label still reads as
	-- a warning and not as an active control.
	Ember = {
		Background = Color3.fromRGB(20, 16, 15),
		Panel = Color3.fromRGB(29, 23, 22),
		PanelRaised = Color3.fromRGB(37, 30, 28),
		PanelSunken = Color3.fromRGB(14, 11, 11),
		Outline = Color3.fromRGB(57, 45, 43),
		OutlineDim = Color3.fromRGB(40, 32, 30),
		Accent = Color3.fromRGB(198, 64, 44),
		AccentDim = Color3.fromRGB(106, 34, 23),
		Font = Color3.fromRGB(219, 209, 205),
		FontDim = Color3.fromRGB(126, 114, 110),
		FontFaint = Color3.fromRGB(86, 76, 73),
		Risk = Color3.fromRGB(232, 96, 82),
		Good = Color3.fromRGB(126, 176, 106),
		Black = Color3.fromRGB(0, 0, 0),
	},

	Signal = {
		Background = Color3.fromRGB(16, 18, 15),
		Panel = Color3.fromRGB(23, 26, 22),
		PanelRaised = Color3.fromRGB(30, 34, 29),
		PanelSunken = Color3.fromRGB(12, 13, 11),
		Outline = Color3.fromRGB(46, 53, 44),
		OutlineDim = Color3.fromRGB(32, 37, 30),
		Accent = Color3.fromRGB(96, 196, 84),
		AccentDim = Color3.fromRGB(48, 101, 42),
		Font = Color3.fromRGB(211, 216, 205),
		FontDim = Color3.fromRGB(117, 122, 109),
		FontFaint = Color3.fromRGB(79, 84, 73),
		Risk = Color3.fromRGB(226, 78, 63),
		Good = Color3.fromRGB(148, 190, 120),
		Black = Color3.fromRGB(0, 0, 0),
	},

	Ice = {
		Background = Color3.fromRGB(15, 18, 19),
		Panel = Color3.fromRGB(21, 26, 27),
		PanelRaised = Color3.fromRGB(28, 34, 35),
		PanelSunken = Color3.fromRGB(11, 13, 14),
		Outline = Color3.fromRGB(44, 52, 54),
		OutlineDim = Color3.fromRGB(30, 36, 38),
		Accent = Color3.fromRGB(78, 178, 196),
		AccentDim = Color3.fromRGB(38, 92, 102),
		Font = Color3.fromRGB(206, 214, 217),
		FontDim = Color3.fromRGB(110, 119, 123),
		FontFaint = Color3.fromRGB(74, 81, 84),
		Risk = Color3.fromRGB(226, 78, 63),
		Good = Color3.fromRGB(126, 176, 106),
		Black = Color3.fromRGB(0, 0, 0),
	},

	Void = {
		Background = Color3.fromRGB(18, 16, 20),
		Panel = Color3.fromRGB(26, 24, 30),
		PanelRaised = Color3.fromRGB(34, 31, 38),
		PanelSunken = Color3.fromRGB(13, 12, 15),
		Outline = Color3.fromRGB(52, 48, 58),
		OutlineDim = Color3.fromRGB(36, 33, 41),
		Accent = Color3.fromRGB(148, 124, 190),
		AccentDim = Color3.fromRGB(78, 64, 101),
		Font = Color3.fromRGB(214, 209, 219),
		FontDim = Color3.fromRGB(121, 116, 128),
		FontFaint = Color3.fromRGB(82, 78, 88),
		Risk = Color3.fromRGB(226, 78, 63),
		Good = Color3.fromRGB(126, 176, 106),
		Black = Color3.fromRGB(0, 0, 0),
	},

	-- No hue at all: "on" is simply brighter than the text around it. Text is
	-- pulled down a step so the accent still separates from a plain label.
	Mono = {
		Background = Color3.fromRGB(18, 17, 15),
		Panel = Color3.fromRGB(26, 25, 22),
		PanelRaised = Color3.fromRGB(34, 32, 29),
		PanelSunken = Color3.fromRGB(13, 12, 11),
		Outline = Color3.fromRGB(52, 49, 44),
		OutlineDim = Color3.fromRGB(36, 34, 30),
		Accent = Color3.fromRGB(231, 227, 219),
		AccentDim = Color3.fromRGB(122, 118, 111),
		Font = Color3.fromRGB(199, 194, 186),
		FontDim = Color3.fromRGB(118, 112, 103),
		FontFaint = Color3.fromRGB(82, 77, 70),
		Risk = Color3.fromRGB(226, 78, 63),
		Good = Color3.fromRGB(126, 176, 106),
		Black = Color3.fromRGB(0, 0, 0),
	},
}

--==============================================================
-- plumbing
--==============================================================

local function notify(Library, description, kind)
	if not Library or not Library.Notify then
		return
	end
	Library:Notify({
		Title = "Theme",
		Description = description,
		Time = 4,
		Good = kind == "good",
		Risk = kind == "risk",
	})
end

function ThemeManager:SetLibrary(Library)
	if type(Library) ~= "table" then
		return self
	end

	self.Library = Library

	-- Theme.lua owns the stock palette, so mirror it rather than letting the
	-- copy above drift away from it.
	if type(Library.ThemeDefaults) == "table" then
		self.BuiltInThemes.Sable = Util.DeepCopy(Library.ThemeDefaults)
	end

	return self
end

function ThemeManager:SetFolder(path)
	if type(path) == "string" and path ~= "" then
		self.Folder = path
	end
	self:BuildFolders()
	return self
end

function ThemeManager:ThemesFolder()
	return self.Folder .. "/themes"
end

function ThemeManager:DefaultPath()
	return self:ThemesFolder() .. "/default.json"
end

function ThemeManager:BuildFolders()
	if not Util.FS.Available() then
		return false
	end
	return Util.FS.EnsureFolder(self:ThemesFolder())
end

function ThemeManager:ThemeNames()
	local names = {}

	for _, name in ORDER do
		if self.BuiltInThemes[name] then
			table.insert(names, name)
		end
	end

	for _, name in Util.SortedKeys(self.BuiltInThemes) do
		if not table.find(names, name) then
			table.insert(names, name)
		end
	end

	return names
end

--==============================================================
-- applying
--==============================================================

--- Pushes the live scheme back into the editor controls without re-firing
--- their callbacks.
function ThemeManager:Sync()
	local Library = self.Library
	if not Library then
		return self
	end

	local list = self.Objects.List
	if list and list.SetValue and list.Value ~= self.Theme then
		list:SetValue(self.Theme, true)
	end

	for _, key in KEYS do
		local picker = self.Objects[key]
		local color = Library.Scheme[key]
		if picker and picker.SetValue and color and picker.Value ~= color then
			picker:SetValue(color, true)
		end
	end

	return self
end

function ThemeManager:ApplyTheme(name)
	local Library = self.Library
	local theme = type(name) == "string" and self.BuiltInThemes[name] or nil

	if not Library or not theme then
		return false
	end

	self.Theme = name
	-- A preset is a whole scheme, so per-key overrides are done with.
	table.clear(self.Custom)

	Library:SetScheme(theme)
	self:Sync()

	return true
end

--- One key of the live scheme, remembered as an override so :SetDefault can
--- write it back out.
function ThemeManager:SetColor(key, color)
	local Library = self.Library
	if not Library or typeof(color) ~= "Color3" then
		return false
	end
	if Library.Scheme[key] == nil then
		return false
	end

	self.Custom[key] = Util.ToHex(color)
	Library:SetScheme(key, color)

	return true
end

--- Back to stock: the Sable preset, no overrides, no stored default.
function ThemeManager:Reset()
	self:ApplyTheme("Sable")
	Util.FS.Delete(self:DefaultPath())
	return true
end

function ThemeManager:SetDefault(name)
	name = type(name) == "string" and name or self.Theme

	if not self.BuiltInThemes[name] then
		return false
	end

	if name ~= self.Theme then
		self:ApplyTheme(name)
	end

	if not Util.FS.Available() then
		return false
	end

	self:BuildFolders()

	local ok = Util.FS.WriteJSON(self:DefaultPath(), {
		Theme = name,
		Custom = Util.DeepCopy(self.Custom),
	})

	return ok and true or false
end

function ThemeManager:LoadDefault()
	local data = Util.FS.ReadJSON(self:DefaultPath())

	local name = data and data.Theme
	if type(name) ~= "string" or not self.BuiltInThemes[name] then
		name = "Sable"
	end

	self:ApplyTheme(name)

	if data and type(data.Custom) == "table" then
		for key, hex in data.Custom do
			local color = Util.FromHex(hex)
			if color then
				self:SetColor(key, color)
			end
		end
	end

	self:Sync()

	return self.Theme
end

--==============================================================
-- ui
--==============================================================

function ThemeManager:ApplyToGroupbox(groupbox)
	local Library = self.Library

	if not Library then
		warn("[Sable] ThemeManager:ApplyToGroupbox called before :SetLibrary")
		return groupbox
	end
	if type(groupbox) ~= "table" or not groupbox.AddDropdown then
		warn("[Sable] ThemeManager:ApplyToGroupbox needs a groupbox")
		return groupbox
	end

	local names = self:ThemeNames()

	self.Building = true

	self.Objects.List = groupbox:AddDropdown(self.ListIndex, {
		Text = "Theme",
		Values = names,
		Default = table.find(names, self.Theme) or 1,
		Tooltip = "Built-in colour schemes",
		Callback = function(value)
			if self.Building then
				return
			end
			self:ApplyTheme(value)
		end,
	})

	for _, key in KEYS do
		self.Objects[key] = groupbox:AddColorPicker(self.PickerIndexes[key], {
			Text = key,
			Title = key,
			Default = Library.Scheme[key],
			Tooltip = ("Overrides the %s colour of the selected theme"):format(key:lower()),
			Callback = function(color)
				if self.Building then
					return
				end
				self:SetColor(key, color)
			end,
		})
	end

	local setDefault = groupbox:AddButton({
		Text = "Set as default",
		Tooltip = "Apply this theme automatically on load",
		Func = function()
			if self:SetDefault(self.Theme) then
				notify(Library, ("%s saved as default"):format(self.Theme), "good")
			else
				notify(Library, "Filesystem unavailable", "risk")
			end
		end,
	})

	if setDefault and setDefault.AddButton then
		setDefault:AddButton({
			Text = "Reset",
			Tooltip = "Back to the stock Sable scheme",
			Func = function()
				self:Reset()
				notify(Library, "Reset to Sable", "good")
			end,
		})
	end

	self.Building = false

	-- The controls were built from whatever the scheme already was; make sure
	-- they agree with it now that callbacks are live again.
	self:Sync()

	return groupbox
end

function ThemeManager:ApplyToTab(tab)
	if type(tab) == "table" and tab.AddLeftGroupbox then
		return self:ApplyToGroupbox(tab:AddLeftGroupbox("Theme"))
	end
	return self:ApplyToGroupbox(tab)
end

return ThemeManager
