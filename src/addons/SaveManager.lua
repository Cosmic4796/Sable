--!nonstrict
-- Sable :: addons/SaveManager
--
-- Serialises Library.Toggles + Library.Options by index to
-- <folder>/settings/<name>.json, and rebuilds them by calling :SetValue so the
-- script's own callbacks run exactly as if the user had clicked.
--
-- Reached as Library.SaveManager -- the spine calls :SetLibrary for you; the
-- method survives being called again so ported scripts keep working. Every
-- filesystem call goes through Util.FS, which no-ops outside an executor, so
-- the buttons still respond there -- they just report that nothing was written.

local Util = require("Util")

local NAME_INDEX = "SaveManager_ConfigName"
local LIST_INDEX = "SaveManager_ConfigList"

--- Fallback for :IgnoreThemeSettings when the ThemeManager is not reachable.
--- Mirrors ThemeManager.Indexes; keep the two in step.
local THEME_INDEXES = {
	"ThemeManager_ThemeList",
	"ThemeManager_CustomName",
	"ThemeManager_CustomList",
	"ThemeManager_AccentColor",
	"ThemeManager_BackgroundColor",
	"ThemeManager_PanelColor",
	"ThemeManager_OutlineColor",
	"ThemeManager_FontColor",
}

local SaveManager = {}

SaveManager.Library = nil :: any
SaveManager.Folder = "Sable"
SaveManager.AutoloadName = nil :: any
SaveManager.Indexes = { NAME_INDEX, LIST_INDEX }

--- index -> true. Its own two controls are always skipped: a config that
--- restored the config picker would fight with the user.
SaveManager.Ignore = {
	[NAME_INDEX] = true,
	[LIST_INDEX] = true,
}

--- Elements built by :BuildConfigSection.
SaveManager.Objects = {}

--==============================================================
-- serialisation
--==============================================================

--- Element -> plain JSON-safe entry, or nil for types configs do not carry.
local function serialize(index, element)
	local kind = element.Type

	if kind == "Toggle" then
		return { type = "Toggle", idx = index, value = element.Value == true }
	elseif kind == "Slider" then
		local number = tonumber(element.Value)
		if not number then
			return nil
		end
		return { type = "Slider", idx = index, value = number }
	elseif kind == "Input" then
		return { type = "Input", idx = index, value = tostring(element.Value or "") }
	elseif kind == "Dropdown" then
		local value = element.Value

		if type(value) == "table" then
			local set = {}
			for name, on in value do
				if on then
					set[tostring(name)] = true
				end
			end
			return { type = "Dropdown", idx = index, multi = true, value = set }
		end

		-- AllowNull dropdowns need the empty selection to survive a round trip,
		-- and JSON has no way to store a nil field.
		if value == nil then
			return { type = "Dropdown", idx = index, multi = false, null = true, value = "" }
		end

		return { type = "Dropdown", idx = index, multi = false, value = tostring(value) }
	elseif kind == "ColorPicker" then
		if typeof(element.Value) ~= "Color3" then
			return nil
		end
		return {
			type = "ColorPicker",
			idx = index,
			value = {
				hex = Util.ToHex(element.Value),
				transparency = tonumber(element.Transparency),
			},
		}
	elseif kind == "KeyPicker" then
		return {
			type = "KeyPicker",
			idx = index,
			value = {
				key = tostring(element.Value or "None"),
				mode = tostring(element.Mode or "Toggle"),
			},
		}
	end

	return nil
end

--- Entry -> element, through :SetValue so callbacks fire. Returns false when
--- the payload is malformed; the caller skips it silently.
local function deserialize(element, entry)
	local kind = element.Type
	local value = entry.value

	if kind == "Toggle" then
		if type(value) ~= "boolean" then
			return false
		end
		element:SetValue(value)
	elseif kind == "Slider" then
		local number = tonumber(value)
		if not number then
			return false
		end
		element:SetValue(number)
	elseif kind == "Input" then
		if type(value) ~= "string" then
			return false
		end
		element:SetValue(value)
	elseif kind == "Dropdown" then
		if type(value) == "table" then
			local set = {}
			for name, on in value do
				if on then
					set[tostring(name)] = true
				end
			end
			element:SetValue(set)
		elseif entry.null == true then
			element:SetValue(nil)
		elseif type(value) == "string" then
			element:SetValue(value)
		else
			return false
		end
	elseif kind == "ColorPicker" then
		if type(value) ~= "table" then
			return false
		end

		local color = Util.FromHex(value.hex or value[1])
		if not color then
			return false
		end

		-- Transparency rides along with the colour, so stage it before the
		-- repaint that :SetValue triggers.
		local transparency = tonumber(value.transparency or value[2])
		if transparency and element.Transparency ~= nil then
			if type(element.SetTransparency) == "function" then
				element:SetTransparency(transparency)
			else
				element.Transparency = transparency
			end
		end

		element:SetValue(color)
	elseif kind == "KeyPicker" then
		if type(value) ~= "table" then
			return false
		end

		local key = value.key or value[1]
		if type(key) ~= "string" then
			return false
		end

		local mode = value.mode or value[2]
		element:SetValue({ key, type(mode) == "string" and mode or element.Mode })
	else
		return false
	end

	return true
end

--==============================================================
-- plumbing
--==============================================================

local function notify(Library, description, kind)
	if not Library or not Library.Notify then
		return
	end
	Library:Notify({
		Title = "Config",
		Description = description,
		Time = 4,
		Good = kind == "good",
		Risk = kind == "risk",
	})
end

function SaveManager:SetLibrary(Library)
	if type(Library) ~= "table" then
		return self
	end
	self.Library = Library
	return self
end

function SaveManager:SetFolder(path)
	if type(path) == "string" and path ~= "" then
		self.Folder = path
	end
	self:BuildFolders()
	return self
end

function SaveManager:SettingsFolder()
	return self.Folder .. "/settings"
end

function SaveManager:ConfigPath(name)
	return ("%s/%s.json"):format(self:SettingsFolder(), name)
end

function SaveManager:AutoloadPath()
	return self:SettingsFolder() .. "/autoload.txt"
end

function SaveManager:BuildFolders()
	if not Util.FS.Available() then
		return false
	end
	return Util.FS.EnsureFolder(self:SettingsFolder())
end

--- Accepts either an array of indexes or a set; both forms show up in scripts
--- ported from other libraries.
function SaveManager:SetIgnoreIndexes(list)
	if type(list) ~= "table" then
		return self
	end

	for key, value in list do
		if type(key) == "number" then
			if value ~= nil then
				self.Ignore[value] = true
			end
		else
			self.Ignore[key] = value == true
		end
	end

	return self
end

function SaveManager:IgnoreThemeSettings()
	local manager = self.Library and self.Library.ThemeManager
	local indexes = (type(manager) == "table" and type(manager.Indexes) == "table") and manager.Indexes
		or THEME_INDEXES

	for _, index in indexes do
		self.Ignore[index] = true
	end

	return self
end

--- Config names become file names, so anything that could walk out of the
--- settings folder is stripped rather than rejected. Leading dots go too:
--- "../../evil" has to land on "evil", not on a hidden file.
function SaveManager:Sanitize(name)
	if type(name) ~= "string" then
		return nil
	end

	name = name:gsub("[^%w%-%. _]", "")
	name = name:gsub("^[%.%s]+", ""):gsub("[%.%s]+$", "")

	if name == "" or name == "autoload" then
		return nil
	end

	return name
end

--==============================================================
-- config data
--==============================================================

function SaveManager:Collect()
	local Library = self.Library
	local objects = {}

	local function scan(store)
		if type(store) ~= "table" then
			return
		end

		-- Sorted so a config file diffs cleanly between saves.
		for _, index in Util.SortedKeys(store) do
			local element = store[index]
			if type(element) == "table" and not self.Ignore[index] then
				local ok, entry = pcall(serialize, index, element)
				if ok and entry then
					table.insert(objects, entry)
				end
			end
		end
	end

	scan(Library and Library.Toggles)
	scan(Library and Library.Options)

	return objects
end

--- Returns how many entries were applied. Anything unknown, ignored, or of the
--- wrong shape is skipped without erroring.
function SaveManager:Apply(objects)
	local Library = self.Library
	if not Library or type(objects) ~= "table" then
		return 0
	end

	local applied = 0

	-- Selecting a theme clears custom colours and applies the whole preset, so
	-- it has to land BEFORE the per-key colour entries. Collect() emits indexes
	-- alphabetically, which put ThemeManager_ThemeList last and silently threw
	-- away every custom colour the config had just restored.
	local themeListIndex = Library.ThemeManager and Library.ThemeManager.ListIndex
	local ordered, rest = {}, {}
	for _, entry in objects do
		if themeListIndex and type(entry) == "table" and entry.idx == themeListIndex then
			table.insert(ordered, entry)
		else
			table.insert(rest, entry)
		end
	end
	table.move(rest, 1, #rest, #ordered + 1, ordered)

	for _, entry in ordered do
		if type(entry) == "table" and entry.idx ~= nil and not self.Ignore[entry.idx] then
			local element = Library.Toggles[entry.idx] or Library.Options[entry.idx]
			if type(element) == "table" and element.Type == entry.type then
				local ok, result = pcall(deserialize, element, entry)
				if ok and result then
					applied += 1
				end
			end
		end
	end

	return applied
end

function SaveManager:ConfigList()
	local list = {}

	for _, path in Util.FS.List(self:SettingsFolder()) do
		if type(path) == "string" and path:sub(-5) == ".json" then
			local stem = Util.FS.Stem(path, ".json")
			if stem ~= "" then
				table.insert(list, stem)
			end
		end
	end

	table.sort(list)
	return list
end

--==============================================================
-- operations
--==============================================================

function SaveManager:Save(name)
	local Library = self.Library

	local clean = self:Sanitize(name)
	if not clean then
		notify(Library, "Enter a valid config name", "risk")
		return false
	end

	if not Util.FS.Available() then
		notify(Library, "Filesystem unavailable", "risk")
		return false
	end

	self:BuildFolders()

	local written = Util.FS.WriteJSON(self:ConfigPath(clean), {
		name = clean,
		version = 1,
		objects = self:Collect(),
	})

	if not written then
		notify(Library, ("Could not write %s"):format(clean), "risk")
		return false
	end

	notify(Library, ("Saved %s"):format(clean), "good")
	self:RefreshConfigList()

	return true
end

function SaveManager:Load(name)
	local Library = self.Library

	local clean = self:Sanitize(name)
	if not clean then
		notify(Library, "Select a config first", "risk")
		return false
	end

	if not Util.FS.Available() then
		notify(Library, "Filesystem unavailable", "risk")
		return false
	end

	local data = Util.FS.ReadJSON(self:ConfigPath(clean))
	if type(data) ~= "table" or type(data.objects) ~= "table" then
		notify(Library, ("%s could not be read"):format(clean), "risk")
		return false
	end

	local applied = self:Apply(data.objects)
	notify(Library, ("Loaded %s (%d values)"):format(clean, applied), "good")

	return true
end

function SaveManager:Delete(name)
	local Library = self.Library

	local clean = self:Sanitize(name)
	if not clean then
		notify(Library, "Select a config first", "risk")
		return false
	end

	if not Util.FS.Available() then
		notify(Library, "Filesystem unavailable", "risk")
		return false
	end

	local path = self:ConfigPath(clean)
	if not Util.FS.IsFile(path) then
		notify(Library, ("%s does not exist"):format(clean), "risk")
		return false
	end

	if not Util.FS.Delete(path) then
		notify(Library, ("Could not delete %s"):format(clean), "risk")
		return false
	end

	if self.AutoloadName == clean then
		self:ClearAutoload()
	end

	notify(Library, ("Deleted %s"):format(clean), "good")
	self:RefreshConfigList()

	return true
end

function SaveManager:SetAutoload(name)
	local Library = self.Library

	local clean = self:Sanitize(name)
	if not clean then
		notify(Library, "Select a config first", "risk")
		return false
	end

	if not Util.FS.Available() then
		notify(Library, "Filesystem unavailable", "risk")
		return false
	end

	if not Util.FS.IsFile(self:ConfigPath(clean)) then
		notify(Library, ("%s does not exist"):format(clean), "risk")
		return false
	end

	self:BuildFolders()

	if not Util.FS.Write(self:AutoloadPath(), clean) then
		notify(Library, "Could not write autoload", "risk")
		return false
	end

	self.AutoloadName = clean
	self:UpdateAutoloadLabel()
	notify(Library, ("%s will autoload"):format(clean), "good")

	return true
end

function SaveManager:ClearAutoload()
	Util.FS.Delete(self:AutoloadPath())
	self.AutoloadName = nil
	self:UpdateAutoloadLabel()
	return true
end

--- Reads (and caches) the autoload name without loading it.
function SaveManager:ReadAutoload()
	local contents = Util.FS.Read(self:AutoloadPath())
	self.AutoloadName = self:Sanitize(contents)
	return self.AutoloadName
end

function SaveManager:LoadAutoloadConfig()
	local name = self:ReadAutoload()
	if not name then
		return false
	end

	self:UpdateAutoloadLabel()
	return self:Load(name)
end

--==============================================================
-- ui
--==============================================================

function SaveManager:UpdateAutoloadLabel()
	local label = self.Objects.AutoloadLabel
	if label and label.SetText then
		label:SetText(("Autoload: %s"):format(self.AutoloadName or "none"))
	end
	return self
end

function SaveManager:RefreshConfigList()
	local list = self:ConfigList()

	local dropdown = self.Objects.List
	if dropdown and dropdown.SetValues then
		dropdown:SetValues(list)
	end

	return list
end

--- Whatever the list is pointing at, or nil when nothing is selected.
function SaveManager:Selected()
	local dropdown = self.Objects.List
	local value = dropdown and dropdown.Value
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

function SaveManager:BuildConfigSection(tab)
	local Library = self.Library

	if not Library then
		warn("[Sable] SaveManager:BuildConfigSection called before :SetLibrary")
		return tab
	end

	local groupbox = tab
	if type(tab) == "table" and tab.AddRightGroupbox then
		groupbox = tab:AddRightGroupbox("Configuration")
	end
	if type(groupbox) ~= "table" or not groupbox.AddInput then
		warn("[Sable] SaveManager:BuildConfigSection needs a tab or groupbox")
		return groupbox
	end

	self:BuildFolders()
	self:ReadAutoload()

	local nameInput = groupbox:AddInput(NAME_INDEX, {
		Text = "Config name",
		Placeholder = "name",
		MaxLength = 40,
		Tooltip = "Used by CREATE",
	})
	self.Objects.Name = nameInput

	self.Objects.List = groupbox:AddDropdown(LIST_INDEX, {
		Text = "Config list",
		Values = self:ConfigList(),
		Default = 1,
		AllowNull = true,
		Tooltip = "Configs found on disk",
	})

	--- The typed name wins for CREATE; every other action works on the list
	--- selection and falls back to the typed name.
	local function target()
		return self:Selected() or (nameInput and nameInput.Value)
	end

	local create = groupbox:AddButton({
		Text = "Create",
		Tooltip = "Write the current values to the typed name",
		Func = function()
			self:Save(nameInput and nameInput.Value)
		end,
	})

	if create and create.AddButton then
		create:AddButton({
			Text = "Overwrite",
			Tooltip = "Write the current values over the selected config",
			Func = function()
				self:Save(target())
			end,
		})
	end

	local load = groupbox:AddButton({
		Text = "Load",
		Tooltip = "Apply the selected config",
		Func = function()
			self:Load(target())
		end,
	})

	if load and load.AddButton then
		load:AddButton({
			Text = "Delete",
			DoubleClick = true,
			Tooltip = "Double click to delete the selected config",
			Func = function()
				self:Delete(target())
			end,
		})
	end

	groupbox:AddButton({
		Text = "Refresh list",
		Tooltip = "Re-read the settings folder",
		Func = function()
			local list = self:RefreshConfigList()
			notify(Library, ("%d config(s) on disk"):format(#list))
		end,
	})

	groupbox:AddButton({
		Text = "Set as autoload",
		Tooltip = "Load the selected config on the next run",
		Func = function()
			self:SetAutoload(target())
		end,
	})

	self.Objects.AutoloadLabel = groupbox:AddLabel("Autoload: none")
	self:UpdateAutoloadLabel()

	return groupbox
end

return SaveManager
