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

-- Dense, but not cramped. Instrument panels pack information; they still need
-- enough air that a row reads as a row. EVERY size in the library must come
-- from this table -- a hardcoded pixel is a bug, because it will not move when
-- these numbers do.
Theme.Sizes = {
	WindowWidth = 620,
	WindowHeight = 660,
	WindowMinWidth = 460,
	WindowMinHeight = 360,

	TitleBar = 34,
	TabStrip = 30,

	RowHeight = 26,
	RowGap = 4,

	GroupPad = 12,
	GroupGap = 12,
	ColumnGap = 12,
	GroupHeader = 20,

	Outline = 1,
	Tick = 8, -- corner tick arm length
	TickThickness = 1,

	Text = 13, -- element labels
	TextSmall = 12, -- readouts, captions, footer
	TextTitle = 14, -- window title, group headers

	Control = 15, -- checkbox / swatch square edge
	Track = 9, -- slider bar height
	Segments = 16, -- slider segment count
	Indicator = 2, -- active-tab underline thickness

	-- The ColorPicker's saturation/value canvas. It is the one content surface
	-- in the library that is not a row, a control or a column, so there is
	-- nothing honest to derive it from -- it belongs here rather than as a magic
	-- number inside the element.
	PickerSquare = 144,

	PopupWidth = 0, -- 0 = match anchor width
	-- Floor for popups that otherwise match their anchor's width, so a narrow
	-- control cannot open a sliver of a list. Roughly one groupbox column.
	PopupMinWidth = 140,
	PopupMaxItems = 9,

	ScrollBar = 3,
	-- The stock scrollbar is the last piece of default Roblox chrome left in the
	-- design, so it is invisible at rest and never comes back further than this:
	-- enough to read a position from, not enough to become furniture. The bar
	-- keeps its thickness while hidden -- a zero-width bar has no drag target.
	ScrollBarFaint = 0.5,
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
	-- Seconds a scrollbar stays up after the last scroll, once the cursor is no
	-- longer over the column. Long enough to finish the gesture, short enough
	-- that a still menu has no scrollbars in it at all.
	ScrollBarIdle = 0.6,
}

--==============================================================
-- install
--==============================================================

--==============================================================
-- touch metrics
--==============================================================

-- Overrides applied when the UI is driven by a thumb instead of a cursor.
--
-- Deliberately NOT a blanket scale factor. A finger needs a bigger TARGET, but
-- text does not need to be much bigger to stay legible, and padding blown up by
-- the same factor wastes the little screen a phone has. So only the things you
-- actually hit grow, plus one step on the type so it survives a smaller
-- viewport.
--
-- 44 for RowHeight is the number both Apple and Google land on for a minimum
-- touch target, and a row is the primary hit surface here: a toggle's whole row
-- is clickable, not just its 15px box.
Theme.TouchSizes = {
	RowHeight = 44,
	RowGap = 6,

	TitleBar = 44, -- also the drag handle, so it must be grabbable
	TabStrip = 40,

	Control = 24, -- checkbox / swatch square
	Track = 14, -- slider bar; the hit area grows with RowHeight on top

	Text = 14,
	TextSmall = 13,
	TextTitle = 15,

	-- A phone in landscape is not much taller than the desktop minimum, so the
	-- floor has to come down or the window cannot fit at all.
	WindowMinWidth = 300,
	WindowMinHeight = 260,

	PickerSquare = 160,
}

--- Pure: base metrics -> touch metrics. Separate from Install so it can be
--- tested without standing up a whole library on a device that does not exist.
function Theme.TouchMetrics(base)
	local out = table.clone(base)
	for key, value in Theme.TouchSizes do
		out[key] = value
	end
	return out
end

function Theme.Install(Library)
	Library.Scheme = table.clone(Theme.Default)

	-- Chosen ONCE, at install. Every element derives its geometry from this
	-- table at construction, so flipping it later would leave already-built
	-- rows at the old size while new ones came out bigger.
	local touch = type(Library.IsTouchUI) == "function" and Library:IsTouchUI()
	Library.Sizes = touch and Theme.TouchMetrics(Theme.Sizes) or table.clone(Theme.Sizes)
	Library.TouchMetricsActive = touch == true

	--- What touch mode WOULD produce from a given base table. Exposed so the
	--- transform is testable off-device, and so a host can show the user what
	--- mobile mode changes without having to be on a phone to find out.
	function Library:TouchMetricsOf(base)
		return Theme.TouchMetrics(base or Theme.Sizes)
	end
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
