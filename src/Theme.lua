--!nonstrict
-- Sable :: Theme
-- The design system: palette, metrics, fonts, and the live colour registry.
--
-- LOOK: "tactical / instrument". Warm dark grey, one amber accent, hard 1px
-- hairlines, zero corner radius, uppercase letterspaced chrome, monospace
-- numerals. Deliberately NOT: rounded cards, gradients as decoration, glow,
-- blur, emoji, pastel accents.

local Util = require("Util")

local Theme = {}

--==============================================================
-- palette
--==============================================================

-- Warm greys: every neutral carries a little orange so the amber accent reads
-- as part of the same family instead of a sticker on top of a blue-grey UI.
Theme.Default = {
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
}

-- Linoria-flavoured names, so ported scripts and old configs keep working.
Theme.Aliases = {
	MainColor = "Panel",
	BackgroundColor = "Background",
	AccentColor = "Accent",
	OutlineColor = "Outline",
	FontColor = "Font",
	RiskColor = "Risk",
}

--==============================================================
-- metrics
--==============================================================

-- Dense on purpose. Instrument panels pack information; they do not breathe.
Theme.Sizes = {
	WindowWidth = 566,
	WindowHeight = 604,
	WindowMinWidth = 420,
	WindowMinHeight = 320,

	TitleBar = 30,
	TabStrip = 26,

	RowHeight = 20,
	RowGap = 2,

	GroupPad = 8,
	GroupGap = 8,
	ColumnGap = 8,
	GroupHeader = 18,

	Outline = 1,
	Tick = 7, -- corner tick arm length
	TickThickness = 1,

	Text = 12, -- element labels
	TextSmall = 11, -- readouts, captions, footer
	TextTitle = 13, -- window title, group headers

	Control = 13, -- checkbox / swatch square edge
	Track = 8, -- slider bar height
	Segments = 16, -- slider segment count
	Indicator = 2, -- active-tab underline thickness

	PopupWidth = 0, -- 0 = match anchor width
	PopupMaxItems = 9,

	ScrollBar = 3,
}

-- Monospace throughout. Mixing a proportional UI font in is the single fastest
-- way to make this read as a generic dashboard.
Theme.Fonts = {
	Label = Enum.Font.Code,
	Value = Enum.Font.Code,
	Title = Enum.Font.Code,
}

Theme.Motion = {
	Fast = TweenInfo.new(0.09, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	Slow = TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
	Fade = 0.14,
}

--==============================================================
-- install
--==============================================================

function Theme.Install(Library)
	Library.Scheme = table.clone(Theme.Default)
	Library.Sizes = table.clone(Theme.Sizes)
	Library.Fonts = table.clone(Theme.Fonts)
	Library.Motion = table.clone(Theme.Motion)
	Library.Registry = {}
	-- [Instance] = entry, so re-registration is O(1) and can merge in place.
	Library.RegistryIndex = {}

	--- Resolves a scheme key (or alias) to a live colour.
	function Library:GetColor(key)
		if typeof(key) == "Color3" then
			return key
		end
		if type(key) ~= "string" then
			return nil
		end
		local resolved = Theme.Aliases[key] or key
		return self.Scheme[resolved]
	end

	--- properties maps an instance property name to either a scheme key
	--- ("Accent") or a function(scheme) -> value for derived colours.
	---
	---   Library:AddToRegistry(frame, { BackgroundColor3 = "Panel" })
	---
	--- `isHud` marks chrome that stays visible while the menu is closed
	--- (watermark, keybind list) so themes can treat it separately.
	--- Re-registering the SAME instance MERGES into its existing entry rather
	--- than appending a second one. Two entries for one instance would fight
	--- over the same property and the winner would depend on registry iteration
	--- order -- which silently beat state-dependent colours (a toggle's label
	--- reverting to a static colour after any theme switch) and leaked an entry
	--- on every state flip.
	function Library:AddToRegistry(instance, properties, isHud)
		local existing = self.RegistryIndex[instance]
		if existing and not existing.Dead then
			for property, source in properties do
				existing.Properties[property] = source
			end
			if isHud then
				existing.Hud = true
			end
			self:ApplyRegistryEntry(existing)
			return existing
		end

		local entry = {
			Instance = instance,
			Properties = properties,
			Hud = isHud or false,
		}
		table.insert(self.Registry, entry)
		self.RegistryIndex[instance] = entry
		self:ApplyRegistryEntry(entry)
		return entry
	end

	--- The source currently mapped to a property, so a caller can restore an
	--- element's own (possibly function-based) colour rule after temporarily
	--- overriding it.
	function Library:GetRegistrySource(instance, property)
		local entry = self.RegistryIndex[instance]
		if entry and not entry.Dead then
			return entry.Properties[property]
		end
		return nil
	end

	--- Same behaviour as AddToRegistry; the separate name states the intent
	--- that you are changing an existing mapping (on/off, enabled/disabled).
	function Library:Retheme(instance, properties)
		return self:AddToRegistry(instance, properties)
	end

	--- Also drops entries for DESCENDANTS of `instance`. Writing to a destroyed
	--- Instance does not throw in Roblox, so the dead-entry pruning in
	--- UpdateColorsUsingRegistry never reclaims a destroyed element's children
	--- on its own.
	function Library:RemoveFromRegistry(instance)
		for index = #self.Registry, 1, -1 do
			local entry = self.Registry[index]
			local target = entry.Instance

			local matches = target == instance
			if not matches then
				local ok, isDescendant = pcall(function()
					return target:IsDescendantOf(instance)
				end)
				matches = ok and isDescendant
			end

			if matches then
				self.RegistryIndex[target] = nil
				table.remove(self.Registry, index)
			end
		end
	end

	function Library:ApplyRegistryEntry(entry)
		local instance = entry.Instance
		if entry.Dead then
			return false
		end

		for property, source in entry.Properties do
			local value
			if type(source) == "function" then
				local ok, result = pcall(source, self.Scheme)
				value = ok and result or nil
			else
				value = self:GetColor(source)
			end

			if value ~= nil then
				local ok = pcall(function()
					instance[property] = value
				end)
				if not ok then
					-- Instance was destroyed, or the property does not exist.
					entry.Dead = true
					return false
				end
			end
		end

		return true
	end

	--- Re-applies every registered colour. Cheap enough to call on any change;
	--- dead entries are pruned as they are found.
	function Library:UpdateColorsUsingRegistry()
		for index = #self.Registry, 1, -1 do
			local entry = self.Registry[index]
			if not self:ApplyRegistryEntry(entry) then
				self.RegistryIndex[entry.Instance] = nil
				table.remove(self.Registry, index)
			end
		end
	end

	--- SetScheme("Accent", color) or SetScheme({ Accent = color, ... })
	function Library:SetScheme(keyOrTable, color)
		if type(keyOrTable) == "table" then
			for key, value in keyOrTable do
				local resolved = Theme.Aliases[key] or key
				if self.Scheme[resolved] ~= nil and typeof(value) == "Color3" then
					self.Scheme[resolved] = value
				end
			end
		else
			local resolved = Theme.Aliases[keyOrTable] or keyOrTable
			if self.Scheme[resolved] == nil then
				return false
			end
			self.Scheme[resolved] = color
		end

		-- Accent drives a derived shade; keep it consistent unless explicitly set.
		if
			(type(keyOrTable) == "table" and keyOrTable.Accent and not keyOrTable.AccentDim)
			or (keyOrTable == "Accent" or keyOrTable == "AccentColor")
		then
			self.Scheme.AccentDim = Util.Shift(self.Scheme.Accent, 0.55)
		end

		self:UpdateColorsUsingRegistry()
		return true
	end

	function Library:ResetScheme()
		self.Scheme = table.clone(Theme.Default)
		self:UpdateColorsUsingRegistry()
	end

	Library.ThemeDefaults = Theme.Default
	Library.ThemeAliases = Theme.Aliases
end

return Theme
