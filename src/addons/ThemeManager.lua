--!nonstrict
-- Sable :: addons/ThemeManager
--
-- Colour presets, a live per-key editor, and named themes the user saves
-- themselves -- all persisted as hex under <folder>/themes. Reached as
-- Library.ThemeManager -- the spine calls :SetLibrary for you; the method
-- survives being called again so Linoria-style scripts that call it themselves
-- keep working.
--
-- Two kinds of file live in that folder: `default.json`, the pointer at
-- whatever should load on startup, and one `<name>.json` per saved theme
-- holding the whole scheme. "default" is therefore a reserved theme name.
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

--- Stem of the pointer file :SetDefault writes, and therefore the one name a
--- saved theme may not take.
local DEFAULT_STEM = "default"

ThemeManager.Library = nil :: any
ThemeManager.Folder = "Sable"
ThemeManager.Theme = "Sable"
ThemeManager.CustomKeys = KEYS

--- Name of the saved theme currently on screen, or nil while a built-in preset
--- is live. Kept apart from .Theme because a saved theme is a whole scheme read
--- off disk rather than one of the presets.
ThemeManager.CustomTheme = nil :: any

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

ThemeManager.CustomNameIndex = "ThemeManager_CustomName"
ThemeManager.CustomListIndex = "ThemeManager_CustomList"

-- Flat list so SaveManager:IgnoreThemeSettings has one thing to read. Every
-- control this addon owns belongs here: a config that restored the theme
-- editor's own name box would fight with the user.
ThemeManager.Indexes = {
	ThemeManager.ListIndex,
	ThemeManager.CustomNameIndex,
	ThemeManager.CustomListIndex,
}
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
	return ("%s/%s.json"):format(self:ThemesFolder(), DEFAULT_STEM)
end

function ThemeManager:ThemePath(name)
	return ("%s/%s.json"):format(self:ThemesFolder(), name)
end

--- Theme names become file names, so anything that could walk out of the themes
--- folder is stripped rather than rejected -- the same rule SaveManager applies
--- to config names. Leading dots go too, so "../../evil" lands on "evil".
function ThemeManager:Sanitize(name)
	if type(name) ~= "string" then
		return nil
	end

	name = name:gsub("[^%w%-%. _]", "")
	name = name:gsub("^[%.%s]+", ""):gsub("[%.%s]+$", "")

	if name == "" or name:lower() == DEFAULT_STEM then
		return nil
	end

	return name
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
	-- A preset is a whole scheme, so per-key overrides -- and any saved theme
	-- that was on screen -- are done with.
	self.CustomTheme = nil
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

--- Remembers what should load on startup: a preset name (plus whatever per-key
--- overrides sit on top of it) or the name of a saved theme. Defaults to
--- whichever of those is currently on screen.
function ThemeManager:SetDefault(name)
	name = type(name) == "string" and name or (self.CustomTheme or self.Theme)

	local builtIn = self.BuiltInThemes[name] ~= nil
	local saved = nil

	if not builtIn then
		saved = self:Sanitize(name)
		if not saved or not Util.FS.IsFile(self:ThemePath(saved)) then
			return false
		end
	end

	-- The file has to describe what the user is actually looking at, so make the
	-- live scheme agree with the name being written before writing it.
	if builtIn then
		if name ~= self.Theme or self.CustomTheme ~= nil then
			self:ApplyTheme(name)
		end
	elseif saved ~= self.CustomTheme and not self:ApplyCustomTheme(saved) then
		return false
	end

	if not Util.FS.Available() then
		return false
	end

	self:BuildFolders()

	local ok = Util.FS.WriteJSON(self:DefaultPath(), {
		Theme = builtIn and name or saved,
		Kind = builtIn and "builtin" or "custom",
		Custom = Util.DeepCopy(self.Custom),
	})

	return ok and true or false
end

function ThemeManager:LoadDefault()
	local data = Util.FS.ReadJSON(self:DefaultPath())

	local name = data and data.Theme

	-- A name that is not a preset is a saved theme, stored in its own file next
	-- to this one. If it has since been deleted, fall through to the presets.
	if type(name) == "string" and not self.BuiltInThemes[name] then
		local saved = self:Sanitize(name)
		if saved and self:ApplyCustomTheme(saved) then
			return saved
		end
	end

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
-- saved themes
--==============================================================

--- The live scheme as key -> hex. HttpService cannot encode a Color3 -- it is
--- userdata -- so a theme file is strings the whole way down.
function ThemeManager:SchemeHex()
	local Library = self.Library
	local out = {}

	if not Library then
		return out
	end

	for key, color in Library.Scheme do
		if type(key) == "string" and typeof(color) == "Color3" then
			out[key] = Util.ToHex(color)
		end
	end

	return out
end

--- Theme file -> scheme table, plus how many keys survived. Unknown keys and
--- unparseable hex are dropped rather than errored on, so a hand-edited or
--- older file still contributes whatever it got right. A flat key -> hex map is
--- accepted too, because that is the shape someone writing one by hand reaches
--- for.
function ThemeManager:DecodeScheme(data)
	local Library = self.Library
	local scheme, count = {}, 0

	if not Library or type(data) ~= "table" then
		return scheme, count
	end

	local colors = type(data.colors) == "table" and data.colors or data

	for key, hex in colors do
		-- GetColor resolves the Linoria aliases too, so AccentColor lands on
		-- Accent instead of being thrown away.
		if type(key) == "string" and Library:GetColor(key) ~= nil then
			local color = Util.FromHex(hex)
			if color then
				scheme[key] = color
				count += 1
			end
		end
	end

	return scheme, count
end

function ThemeManager:CustomThemeList()
	local list = {}

	for _, path in Util.FS.List(self:ThemesFolder()) do
		if type(path) == "string" and path:sub(-5) == ".json" then
			local stem = Util.FS.Stem(path, ".json")
			-- default.json is the startup pointer, not a theme.
			if stem ~= "" and stem:lower() ~= DEFAULT_STEM then
				table.insert(list, stem)
			end
		end
	end

	table.sort(list)
	return list
end

function ThemeManager:RefreshCustomThemeList()
	local list = self:CustomThemeList()

	local dropdown = self.Objects.CustomList
	if dropdown and dropdown.SetValues then
		dropdown:SetValues(list)
	end

	return list
end

--- Whatever the saved-theme dropdown is pointing at, or nil.
function ThemeManager:SelectedCustom()
	local dropdown = self.Objects.CustomList
	local value = dropdown and dropdown.Value

	if type(value) == "string" and value ~= "" then
		return value
	end

	return nil
end

--- Moves that dropdown onto `name` silently, so a programmatic load cannot
--- recurse back into :LoadCustomTheme through the dropdown's own callback.
function ThemeManager:SelectCustom(name)
	local dropdown = self.Objects.CustomList

	if dropdown and dropdown.SetValue and dropdown.Value ~= name then
		dropdown:SetValue(name, true)
	end

	return self
end

--- The load path :LoadCustomTheme and :LoadDefault share. Returns false plus a
--- reason instead of notifying, so the caller decides whether that reason is
--- worth a notification -- restoring the startup theme quietly is not.
function ThemeManager:ApplyCustomTheme(clean)
	local Library = self.Library

	if not Library or type(clean) ~= "string" then
		return false, "Theme manager is not attached"
	end

	local data = Util.FS.ReadJSON(self:ThemePath(clean))
	if type(data) ~= "table" then
		return false, ("%s could not be read"):format(clean)
	end

	local scheme, count = self:DecodeScheme(data)
	if count == 0 then
		return false, ("%s holds no colours"):format(clean)
	end

	-- A saved theme is a whole scheme, so per-key overrides are done with.
	self.CustomTheme = clean
	table.clear(self.Custom)

	Library:SetScheme(scheme)
	self:SelectCustom(clean)
	self:Sync()

	return true
end

--- Writes the CURRENT scheme -- presets, per-key edits and all -- under `name`.
function ThemeManager:SaveCustomTheme(name)
	local Library = self.Library

	local clean = self:Sanitize(name)
	if not clean then
		notify(Library, "Enter a valid theme name", "risk")
		return false
	end

	if not Library then
		return false
	end

	if not Util.FS.Available() then
		notify(Library, "Filesystem unavailable", "risk")
		return false
	end

	self:BuildFolders()

	local written = Util.FS.WriteJSON(self:ThemePath(clean), {
		name = clean,
		version = 1,
		colors = self:SchemeHex(),
	})

	if not written then
		notify(Library, ("Could not write %s"):format(clean), "risk")
		return false
	end

	-- What is on screen is now exactly this file.
	self.CustomTheme = clean
	self:RefreshCustomThemeList()
	self:SelectCustom(clean)

	notify(Library, ("Saved theme %s"):format(clean), "good")

	return true
end

function ThemeManager:LoadCustomTheme(name)
	local Library = self.Library

	local clean = self:Sanitize(name)
	if not clean then
		notify(Library, "Select a theme first", "risk")
		return false
	end

	if not Util.FS.Available() then
		notify(Library, "Filesystem unavailable", "risk")
		return false
	end

	local ok, reason = self:ApplyCustomTheme(clean)
	if not ok then
		notify(Library, reason or ("%s could not be read"):format(clean), "risk")
		return false
	end

	notify(Library, ("Loaded theme %s"):format(clean), "good")

	return true
end

function ThemeManager:DeleteCustomTheme(name)
	local Library = self.Library

	local clean = self:Sanitize(name)
	if not clean then
		notify(Library, "Select a theme first", "risk")
		return false
	end

	if not Util.FS.Available() then
		notify(Library, "Filesystem unavailable", "risk")
		return false
	end

	local path = self:ThemePath(clean)
	if not Util.FS.IsFile(path) then
		notify(Library, ("%s does not exist"):format(clean), "risk")
		return false
	end

	if not Util.FS.Delete(path) then
		notify(Library, ("Could not delete %s"):format(clean), "risk")
		return false
	end

	-- The colours stay on screen; there is simply no file behind them any more,
	-- so :SetDefault must stop offering to write this name.
	if self.CustomTheme == clean then
		self.CustomTheme = nil
	end

	self:RefreshCustomThemeList()
	notify(Library, ("Deleted %s"):format(clean), "good")

	return true
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
		-- No argument: :SetDefault picks whatever is actually on screen, which
		-- may be a saved theme rather than one of the presets.
		Func = function()
			if self:SetDefault() then
				notify(Library, ("%s saved as default"):format(self.CustomTheme or self.Theme), "good")
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

--- Name box, saved-theme list and the file commands. Split out of
--- :ApplyToGroupbox so a script laying the tab out by hand can place the two
--- halves of the editor wherever it likes.
function ThemeManager:BuildCustomThemeSection(groupbox)
	local Library = self.Library

	if not Library then
		warn("[Sable] ThemeManager:BuildCustomThemeSection called before :SetLibrary")
		return groupbox
	end
	if type(groupbox) ~= "table" or not groupbox.AddInput then
		warn("[Sable] ThemeManager:BuildCustomThemeSection needs a groupbox")
		return groupbox
	end

	self:BuildFolders()

	self.Building = true

	local nameInput = groupbox:AddInput(self.CustomNameIndex, {
		Text = "Theme name",
		Placeholder = "name",
		MaxLength = 40,
		Tooltip = "Used by CREATE",
	})
	self.Objects.CustomName = nameInput

	self.Objects.CustomList = groupbox:AddDropdown(self.CustomListIndex, {
		Text = "Saved themes",
		Values = self:CustomThemeList(),
		-- Starts on whatever :LoadDefault already restored, and on NONE
		-- otherwise: pre-selecting a file nobody applied would read as if that
		-- theme were the live one.
		Default = self.CustomTheme,
		AllowNull = true,
		Tooltip = "Themes on disk; picking one loads it",
		Callback = function(value)
			-- AllowNull hands back nil when the selection is cleared, which is
			-- not a request to load anything.
			if self.Building or type(value) ~= "string" or value == "" then
				return
			end
			self:LoadCustomTheme(value)
		end,
	})

	self.Building = false

	--- CREATE writes the typed name; everything else works on the list
	--- selection and falls back to the typed name, matching the config section.
	local function target()
		return self:SelectedCustom() or (nameInput and nameInput.Value)
	end

	local create = groupbox:AddButton({
		Text = "Create",
		Tooltip = "Save the colours on screen under the typed name",
		Func = function()
			self:SaveCustomTheme(nameInput and nameInput.Value)
		end,
	})

	if create and create.AddButton then
		create:AddButton({
			Text = "Overwrite",
			Tooltip = "Save the colours on screen over the selected theme",
			Func = function()
				self:SaveCustomTheme(target())
			end,
		})
	end

	local load = groupbox:AddButton({
		Text = "Load",
		Tooltip = "Apply the selected theme",
		Func = function()
			self:LoadCustomTheme(target())
		end,
	})

	if load and load.AddButton then
		load:AddButton({
			Text = "Delete",
			DoubleClick = true,
			Tooltip = "Double click to delete the selected theme",
			Func = function()
				self:DeleteCustomTheme(target())
			end,
		})
	end

	groupbox:AddButton({
		Text = "Refresh",
		Tooltip = "Re-read the themes folder",
		Func = function()
			local list = self:RefreshCustomThemeList()
			notify(Library, ("%d theme(s) on disk"):format(#list))
		end,
	})

	return groupbox
end

function ThemeManager:ApplyToTab(tab)
	if type(tab) == "table" and tab.AddLeftGroupbox then
		local groupbox = self:ApplyToGroupbox(tab:AddLeftGroupbox("Theme"))
		self:BuildCustomThemeSection(tab:AddLeftGroupbox("Custom themes"))
		return groupbox
	end

	-- Handed a bare groupbox: there is nowhere to put a second box, so the
	-- saved-theme controls continue inside the one we were given.
	local groupbox = self:ApplyToGroupbox(tab)
	if type(groupbox) == "table" and groupbox.AddInput then
		self:BuildCustomThemeSection(groupbox)
	end

	return groupbox
end

return ThemeManager
