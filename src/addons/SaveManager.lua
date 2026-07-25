--!nonstrict
-- Sable :: addons/SaveManager
--
-- Serialises Library.Toggles + Library.Options by index to
-- <folder>/settings/<name>.json, and rebuilds them by calling :SetValue so the
-- script's own callbacks run exactly as if the user had clicked.
--
-- Also turns a config into one line of paste-safe text ("SABLE1:...") so it can
-- be handed to someone else, and back again. Export copies to the clipboard;
-- import reads a TextBox, because setclipboard is near-universal among
-- executors and a working getclipboard is not.
--
-- Reached as Library.SaveManager -- the spine calls :SetLibrary for you; the
-- method survives being called again so ported scripts keep working. Every
-- filesystem call goes through Util.FS, which no-ops outside an executor, so
-- the buttons still respond there -- they just report that nothing was written.

local Util = require("Util")

local NAME_INDEX = "SaveManager_ConfigName"
local LIST_INDEX = "SaveManager_ConfigList"
local SHARE_INDEX = "SaveManager_ConfigShare"

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
SaveManager.Indexes = { NAME_INDEX, LIST_INDEX, SHARE_INDEX }

--- index -> true. Its own three controls are always skipped: a config that
--- restored the config picker -- or pasted a whole other config into the import
--- box -- would fight with the user.
SaveManager.Ignore = {
	[NAME_INDEX] = true,
	[LIST_INDEX] = true,
	[SHARE_INDEX] = true,
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
-- share encoding
--==============================================================

-- A shared config is ONE line: "SABLE1:" followed by base64 of a small payload.
-- The version lives in the prefix so a build that cannot read a string can say
-- so instead of guessing, and the payload's first byte says how the JSON inside
-- was packed -- MODE_RAW for plain text, MODE_LZW for the compressor below.
-- That byte is what lets compression be skipped for a payload it does not help,
-- or fail safe, without a second prefix to explain.
local SHARE_PREFIX = "SABLE"
local SHARE_VERSION = 1
local SHARE_PATTERN = "^" .. SHARE_PREFIX .. "(%d+):(.*)$"

local MODE_RAW = "R"
local MODE_LZW = "Z"

--- LZW codes are a fixed 12 bits, two to every three bytes, and the dictionary
--- FREEZES at this size rather than resetting. A reset has to be synchronised
--- with a decoder that is always exactly one entry behind the encoder; a frozen
--- dictionary needs no synchronisation at all, and configs never come close.
local LZW_MAX_CODES = 4096

local B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local B64_VALUE = {}
for index = 1, #B64_ALPHABET do
	B64_VALUE[B64_ALPHABET:sub(index, index)] = index - 1
end
-- Decode-only tolerance: chat clients and forums love rewriting a pasted "+/"
-- into the url-safe "-_". We never emit those, but we accept them.
B64_VALUE["-"] = 62
B64_VALUE["_"] = 63

local function b64Char(value)
	return B64_ALPHABET:sub(value + 1, value + 1)
end

local function base64Encode(data)
	local out = {}
	local length = #data
	local index = 1

	while index + 2 <= length do
		local a, b, c = data:byte(index, index + 2)
		local packed = a * 65536 + b * 256 + c
		out[#out + 1] = b64Char(math.floor(packed / 262144))
			.. b64Char(math.floor(packed / 4096) % 64)
			.. b64Char(math.floor(packed / 64) % 64)
			.. b64Char(packed % 64)
		index += 3
	end

	local remaining = length - index + 1
	if remaining == 1 then
		local a = data:byte(index)
		out[#out + 1] = b64Char(math.floor(a / 4)) .. b64Char((a % 4) * 16) .. "=="
	elseif remaining == 2 then
		local a, b = data:byte(index, index + 1)
		local packed = a * 256 + b
		out[#out + 1] = b64Char(math.floor(packed / 1024))
			.. b64Char(math.floor(packed / 16) % 64)
			.. b64Char((packed % 16) * 4)
			.. "="
	end

	return table.concat(out)
end

--- Returns nil for anything that is not base64 rather than erroring: this runs
--- on text a user pasted, so "damaged" is an ordinary outcome, not a fault.
local function base64Decode(text)
	if type(text) ~= "string" then
		return nil
	end

	-- Whitespace anywhere is fine: a long string wrapped by a chat client is
	-- still the same string once the newlines come out.
	local clean = (text:gsub("%s", ""))
	clean = (clean:gsub("=+$", ""))
	if clean:find("=", 1, true) then
		return nil
	end

	-- Four base64 digits carry three bytes; a lone leftover digit carries none,
	-- so that length can only mean the string was cut short.
	if #clean % 4 == 1 then
		return nil
	end

	local out = {}
	local accumulator, bits = 0, 0

	for index = 1, #clean do
		local value = B64_VALUE[clean:sub(index, index)]
		if value == nil then
			return nil
		end

		accumulator = accumulator * 64 + value
		bits += 6

		if bits >= 8 then
			bits -= 8
			local scale = 2 ^ bits
			local byte = math.floor(accumulator / scale)
			accumulator -= byte * scale
			out[#out + 1] = string.char(byte)
		end
	end

	return table.concat(out)
end

--- Textbook LZW over the byte string. Single bytes are their own codes, so the
--- dictionary only ever holds sequences of two or more.
local function lzwCompress(data)
	local dictionary = {}
	local nextCode = 256
	local codes = {}
	local word = nil

	local function codeOf(text)
		if #text == 1 then
			return text:byte()
		end
		return dictionary[text]
	end

	for index = 1, #data do
		local char = data:sub(index, index)

		if word == nil then
			word = char
		else
			local candidate = word .. char
			if dictionary[candidate] then
				word = candidate
			else
				codes[#codes + 1] = codeOf(word)
				if nextCode < LZW_MAX_CODES then
					dictionary[candidate] = nextCode
					nextCode += 1
				end
				word = char
			end
		end
	end

	if word ~= nil then
		codes[#codes + 1] = codeOf(word)
	end

	return codes
end

--- The decoder's dictionary is always one entry behind the encoder's, which is
--- why a code can legitimately name the entry that is about to be added -- the
--- KwKwK case below. Any code beyond that is corruption, and returns nil.
local function lzwDecompress(codes)
	local entries = {}
	local nextCode = 256
	local out = {}
	local previous = nil

	for _, code in codes do
		local entry
		if code < 256 then
			entry = string.char(code)
		elseif entries[code] then
			entry = entries[code]
		elseif code == nextCode and previous ~= nil then
			entry = previous .. previous:sub(1, 1)
		else
			return nil
		end

		out[#out + 1] = entry

		if previous ~= nil and nextCode < LZW_MAX_CODES then
			entries[nextCode] = previous .. entry:sub(1, 1)
			nextCode += 1
		end

		previous = entry
	end

	return table.concat(out)
end

--- Two 12-bit codes per three bytes. An odd final code takes two bytes and
--- leaves a zero nibble, which is why the count is stored separately.
local function packCodes(codes)
	local out = {}
	local index = 1
	local count = #codes

	while index <= count do
		local first = codes[index]
		local second = codes[index + 1]

		if second then
			out[#out + 1] = string.char(
				math.floor(first / 16),
				(first % 16) * 16 + math.floor(second / 256),
				second % 256
			)
			index += 2
		else
			out[#out + 1] = string.char(math.floor(first / 16), (first % 16) * 16)
			index += 1
		end
	end

	return table.concat(out)
end

local function unpackCodes(data, count)
	local codes = {}
	local index = 1

	while #codes < count do
		local first, second, third = data:byte(index, index + 2)
		if first == nil or second == nil then
			return nil
		end

		codes[#codes + 1] = first * 16 + math.floor(second / 16)

		if #codes < count then
			if third == nil then
				return nil
			end
			codes[#codes + 1] = (second % 16) * 256 + third
		end

		index += 3
	end

	return codes
end

local function writeUInt32(value)
	return string.char(
		math.floor(value / 16777216) % 256,
		math.floor(value / 65536) % 256,
		math.floor(value / 256) % 256,
		value % 256
	)
end

local function readUInt32(data, index)
	local a, b, c, d = data:byte(index, index + 3)
	if a == nil or b == nil or c == nil or d == nil then
		return nil
	end
	return a * 16777216 + b * 65536 + c * 256 + d
end

--- Payload -> JSON text, or nil plus a reason a human can act on.
local function unpackPayload(payload)
	local mode = payload:sub(1, 1)

	if mode == MODE_RAW then
		return payload:sub(2)
	elseif mode ~= MODE_LZW then
		return nil, "Config string uses a format this build does not know"
	end

	local count = readUInt32(payload, 2)
	if not count then
		return nil, "Config string is damaged (payload is cut short)"
	end

	local codes = unpackCodes(payload:sub(6), count)
	if not codes then
		return nil, "Config string is damaged (payload is cut short)"
	end

	local text = lzwDecompress(codes)
	if not text then
		return nil, "Config string is damaged (could not be unpacked)"
	end

	return text
end

--- JSON text -> the payload the base64 carries.
---
--- The compressed form is DECODED and compared before it is used. Compression
--- is an optimisation; correctness is not. If the two ever disagree -- or if
--- compressing did not actually save anything -- the plain payload ships, and
--- the mode byte tells the far end which it got.
local function packPayload(json)
	local codes = lzwCompress(json)
	local compressed = MODE_LZW .. writeUInt32(#codes) .. packCodes(codes)

	if #compressed < #json + 1 and unpackPayload(compressed) == json then
		return compressed
	end

	return MODE_RAW .. json
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
-- sharing
--==============================================================

--- Config -> one line of paste-safe text, or nil plus a reason.
---
--- A name encodes that saved config exactly as it sits on disk; no name encodes
--- what is on screen right now, so a config can be shared without saving it
--- first.
function SaveManager:ExportConfig(name)
	local objects, label

	if name == nil then
		objects, label = self:Collect(), nil
	else
		local clean = self:Sanitize(name)
		if not clean then
			return nil, "Select a config first"
		end

		if not Util.FS.Available() then
			return nil, "Filesystem unavailable"
		end

		local data = Util.FS.ReadJSON(self:ConfigPath(clean))
		if type(data) ~= "table" or type(data.objects) ~= "table" then
			return nil, ("%s could not be read"):format(clean)
		end

		objects, label = data.objects, clean
	end

	if #objects == 0 then
		return nil, "This config holds no values to share"
	end

	local ok, json = pcall(function()
		return Util.Services.Http:JSONEncode({
			name = label,
			version = 1,
			objects = objects,
		})
	end)

	if not ok or type(json) ~= "string" then
		return nil, "Could not encode this config"
	end

	return ("%s%d:%s"):format(SHARE_PREFIX, SHARE_VERSION, base64Encode(packPayload(json)))
end

--- Text -> config table, or nil plus a reason. Pure: no elements are touched,
--- nothing is written, nothing is notified. Every failure is a return value,
--- because this is the one entry point fed arbitrary text by a human.
function SaveManager:DecodeConfig(text)
	if type(text) ~= "string" then
		return nil, "Paste a config string first"
	end

	local trimmed = (text:gsub("^%s+", ""))
	trimmed = (trimmed:gsub("%s+$", ""))
	if trimmed == "" then
		return nil, "Paste a config string first"
	end

	local version, body = trimmed:match(SHARE_PATTERN)
	if not version then
		return nil, ("Not a Sable config string (it must start with %s%d:)"):format(SHARE_PREFIX, SHARE_VERSION)
	end

	if tonumber(version) ~= SHARE_VERSION then
		return nil, ("Config string is version %s; this build reads version %d"):format(version, SHARE_VERSION)
	end

	local payload = base64Decode(body)
	if not payload then
		return nil, "Config string is damaged (unreadable characters)"
	end

	-- An empty body decodes cleanly to nothing at all, which is a different
	-- fault from a damaged one: the string was cut off at the prefix.
	if payload == "" then
		return nil, "Config string carries nothing after the prefix"
	end

	local json, reason = unpackPayload(payload)
	if not json then
		return nil, reason or "Config string is damaged"
	end

	local ok, decoded = pcall(function()
		return Util.Services.Http:JSONDecode(json)
	end)

	if not ok then
		return nil, "Config string is damaged (contents are not readable)"
	end

	if type(decoded) ~= "table" then
		return nil, ("Config string decoded to a %s, not a config"):format(type(decoded))
	end

	if type(decoded.objects) ~= "table" then
		return nil, "That string decoded, but it is not a config"
	end

	return decoded
end

--- Applies a shared string to the live elements, and -- when a name is given --
--- saves it so it survives the session.
---
--- The FILE is the payload verbatim, not a re-collect of what landed: entries
--- for elements this hub does not have are then still there for the hub that
--- does, and the saved config is byte-for-byte the one that was shared.
function SaveManager:ImportConfig(text, name)
	local Library = self.Library

	local data, reason = self:DecodeConfig(text)
	if not data then
		notify(Library, reason, "risk")
		return false, reason
	end

	local applied = self:Apply(data.objects)

	if type(name) ~= "string" or name == "" then
		notify(Library, ("Imported %d value(s)"):format(applied), "good")
		return true
	end

	-- Saving is the optional half. The values are already in, so a failure past
	-- this point reports what did and did not happen rather than claiming the
	-- whole import failed.
	local clean = self:Sanitize(name)
	if not clean then
		notify(Library, ("Imported %d value(s); the config name is not usable"):format(applied), "risk")
		return true
	end

	if not Util.FS.Available() then
		notify(Library, ("Imported %d value(s); filesystem unavailable, not saved"):format(applied), "risk")
		return true
	end

	self:BuildFolders()

	local written = Util.FS.WriteJSON(self:ConfigPath(clean), {
		name = clean,
		version = 1,
		objects = data.objects,
	})

	if not written then
		notify(Library, ("Imported %d value(s); could not save %s"):format(applied, clean), "risk")
		return true
	end

	self:RefreshConfigList()
	notify(Library, ("Imported %d value(s), saved as %s"):format(applied, clean), "good")

	return true
end

--- Export + clipboard. Returns the string as well, because a host with no
--- working setclipboard still produced one -- the caller can print it, and the
--- user is told the clipboard was the part that failed, not the export.
function SaveManager:CopyConfig(name)
	local Library = self.Library

	local text, reason = self:ExportConfig(name)
	if not text then
		notify(Library, reason or "Could not export this config", "risk")
		return false, nil, reason
	end

	if not Util.SetClipboard(text) then
		notify(Library, "Clipboard unavailable, nothing was copied", "risk")
		return false, text
	end

	local what = name ~= nil and (self:Sanitize(name) or tostring(name)) or "the current values"
	notify(Library, ("Copied %s to the clipboard (%d chars)"):format(what, #text), "good")

	return true, text
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

	-- Sharing. Export writes to the clipboard, import reads a field: setclipboard
	-- is near-universal among executors and a working getclipboard is not, so the
	-- paste has to be done by the user, in a box.
	if groupbox.AddSection then
		groupbox:AddSection("Share")
	else
		groupbox:AddDivider()
	end

	groupbox:AddButton({
		Text = "Copy config",
		Tooltip = "Copy the selected config, or the current values, as one shareable line",
		Func = function()
			self:CopyConfig(self:Selected())
		end,
	})

	local shareInput = groupbox:AddInput(SHARE_INDEX, {
		Text = "Shared string",
		Placeholder = ("%s%d:"):format(SHARE_PREFIX, SHARE_VERSION),
		-- A paste field the box empties the moment it is clicked would lose the
		-- pasted string on the way to reading it back.
		ClearTextOnFocus = false,
		Tooltip = "Paste a config string someone sent you",
	})
	self.Objects.Share = shareInput

	groupbox:AddButton({
		Text = "Import",
		Tooltip = "Apply the pasted string, saving it under the typed config name when there is one",
		Func = function()
			self:ImportConfig(shareInput and shareInput.Value, nameInput and nameInput.Value)
		end,
	})

	return groupbox
end

return SaveManager
