--!nonstrict
-- Sable :: Window
--
-- Window chrome plus the container object model: window -> tab -> column ->
-- groupbox / tabbox / dependency box.
--
-- Every container type is built from ONE metatable, so elements/init installs
-- its Add* constructors a single time and groupboxes, tabbox tabs and
-- dependency boxes all gain them together. Containers never measure their own
-- children: they read UIListLayout.AbsoluteContentSize and resize from that,
-- which is why an element only has to create its row.

local Util = require("Util")
local Elements = require("elements/init")

local Window = {}

-- Indexes AddSettingsTab registers. "MenuKeybind" keeps its plain Linoria name
-- so ported scripts reading Options.MenuKeybind still find it; the other two are
-- prefixed, because a hub is far more likely to own "Watermark" than
-- "SableWatermark" and a collision would silently replace its element.
local MENU_KEYBIND_INDEX = "MenuKeybind"
local WATERMARK_INDEX = "SableWatermark"
local KEYBIND_LIST_INDEX = "SableKeybindList"

function Window.Install(Library)
	local Sizes = Library.Sizes

	-- How far a groupbox header reaches inside the box whose hairline it cuts.
	local HeaderDrop = math.ceil(Sizes.GroupHeader / 2)
	-- Groupbox content starts clear of that header, then a half pad of air.
	local GroupTop = HeaderDrop + math.floor(Sizes.GroupPad / 2)
	-- A column must reserve room above its first groupbox for the header that
	-- overhangs it, or the ScrollingFrame clips the header in half.
	local ColumnTop = HeaderDrop + Sizes.RowGap
	local ChromeHeight = Sizes.TitleBar + Sizes.TabStrip
	local HalfGap = math.ceil(Sizes.ColumnGap / 2)
	local TabboxStrip = Sizes.RowHeight
	local TitlePad = Sizes.GroupPad + Sizes.Tick -- clears the corner ticks

	-- Square scrollbar caps. The stock end textures are rounded, which is the
	-- one place Roblox would sneak a radius into the menu.
	local FLAT_SCROLL = "rbxasset://textures/ui/Scroll/scroll-middle.png"

	--- Swaps an instance's themed colours without stacking registry entries.
	--- Always pass the FULL map: the old entry is dropped wholesale.
	local function retheme(instance, properties)
		Library:RemoveFromRegistry(instance)
		Library:AddToRegistry(instance, properties)
	end

	local function hairline(parent, y, colorKey, zIndex)
		return Library:Create("Frame", {
			Name = "Rule",
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(0, y),
			Size = UDim2.new(1, 0, 0, Sizes.Outline),
			ZIndex = zIndex or 1,
			Theme = { BackgroundColor3 = colorKey },
			Parent = parent,
		})
	end

	--==============================================================
	-- containers
	--==============================================================

	-- Forward declarations: the container methods below close over these.
	local newDependencyBox

	local Container = {}
	Container.__index = Container

	--- Recompute this container's height, then let whatever owns it do the
	--- same. Idempotent, so calling it when nothing changed costs one layout
	--- read and stops.
	function Container:Resize()
		if self.Recompute then
			self:Recompute()
		end

		local owner = self.Owner
		if owner and owner.Resize then
			owner:Resize()
		end

		return self
	end

	function Container:AddDependencyBox()
		return newDependencyBox(self)
	end

	Elements.Install(Library, Container)

	local function newContainer(frame, owner)
		return setmetatable({
			Library = Library,
			Container = frame,
			Elements = {},
			Owner = owner,
		}, Container)
	end

	--==============================================================
	-- dependency box
	--==============================================================

	function newDependencyBox(parent)
		local frame = Library:Create("Frame", {
			Name = "DependencyBox",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ClipsDescendants = true,
			Size = UDim2.new(1, 0, 0, 0),
			Visible = false,
			Parent = parent.Container,
		})

		local layout = Util.ListLayout(frame, Sizes.RowGap)

		local box = newContainer(frame, parent)
		box.Type = "DependencyBox"
		box.Frame = frame
		box.Layout = layout
		box.Dependencies = {}
		box.Shown = false

		-- The box occupies a slot in its parent's list, so it must occupy one in
		-- Elements too -- otherwise the next element reuses its LayoutOrder.
		-- Base.Create appends before Library:Row reads the count, so a slot's
		-- LayoutOrder is its index + 1; match that exactly or the box ties with
		-- the element above it.
		table.insert(parent.Elements, box)
		frame.LayoutOrder = #parent.Elements + 1

		function box:Recompute()
			frame.Visible = self.Shown
			frame.Size = UDim2.new(1, 0, 0, self.Shown and math.ceil(layout.AbsoluteContentSize.Y) or 0)
		end

		function box:Evaluate()
			local shown = true

			for _, pair in self.Dependencies do
				local element = pair[1]
				if not element or element.Value ~= pair[2] then
					shown = false
					break
				end
			end

			self.Shown = shown
			self:Resize()

			return shown
		end

		--- list is { { element, expectedValue }, ... }; the box is visible only
		--- while every pair matches.
		function box:SetupDependencies(list)
			self.Dependencies = list or {}

			for _, pair in self.Dependencies do
				local element = pair[1]
				if element and element.OnChanged then
					element:OnChanged(function()
						box:Evaluate()
					end)
				end
			end

			self:Evaluate()
			return self
		end

		Library:GiveSignal(layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
			box:Resize()
		end))

		return box
	end

	--==============================================================
	-- groupbox
	--==============================================================

	local function newGroupbox(tab, side, name)
		local column = side == "Right" and tab.Right or tab.Left
		tab.Order[side] += 1

		local frame = Library:Panel({
			Name = "Groupbox",
			Size = UDim2.new(1, 0, 0, Sizes.GroupHeader + Sizes.GroupPad),
			LayoutOrder = tab.Order[side],
			Parent = column,
		}, "Panel", "Outline")

		-- Signature detail: the title interrupts the top hairline rather than
		-- sitting inside the box. An opaque Background fill over a higher ZIndex
		-- makes the cut; the padding sets how wide the gap in the line is.
		local header = Library:Create("TextLabel", {
			Name = "Header",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromOffset(Sizes.GroupPad, 0),
			-- Height is the width of the CUT in the hairline, not the text box.
			-- Roblox draws TextLabel text outside its frame, so the caption is
			-- unaffected. At Sizes.GroupHeader (18) the opaque fill spanned
			-- +/-9px and reached across the GroupGap to punch a hole through
			-- the bottom hairline of the groupbox above.
			Size = UDim2.new(0, 0, 0, Sizes.GroupPad - 2),
			AutomaticSize = Enum.AutomaticSize.X,
			BorderSizePixel = 0,
			Font = Library.Fonts.Title,
			Text = Library:Chrome(name or ""),
			TextSize = Sizes.TextSmall,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Center,
			ZIndex = 4,
			Theme = { BackgroundColor3 = "Background", TextColor3 = "FontDim" },
			Parent = frame,
		})
		Util.Padding(header, 0, 4, 0, 4)

		local content = Library:Create("Frame", {
			Name = "Content",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			Parent = frame,
		})
		Util.Padding(content, GroupTop, Sizes.GroupPad, Sizes.GroupPad, Sizes.GroupPad)

		local layout = Util.ListLayout(content, Sizes.RowGap)

		local box = newContainer(content, nil)
		box.Type = "Groupbox"
		box.Frame = frame
		box.Header = header
		box.Layout = layout

		function box:Recompute()
			local height = layout.AbsoluteContentSize.Y + GroupTop + Sizes.GroupPad
			frame.Size = UDim2.new(1, 0, 0, math.ceil(height))
		end

		function box:SetTitle(text)
			header.Text = Library:Chrome(text or "")
			return self
		end

		Library:GiveSignal(layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
			box:Resize()
		end))

		table.insert(tab.Boxes, box)
		box:Recompute()

		return box
	end

	--==============================================================
	-- tabbox
	--==============================================================

	local function newTabbox(tab, side)
		local column = side == "Right" and tab.Right or tab.Left
		tab.Order[side] += 1

		local shell = Library:Panel({
			Name = "Tabbox",
			Size = UDim2.new(1, 0, 0, TabboxStrip + Sizes.GroupPad * 2),
			LayoutOrder = tab.Order[side],
			Parent = column,
		}, "Panel", "Outline")

		local strip = Library:Create("Frame", {
			Name = "Strip",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, TabboxStrip),
			ZIndex = 2,
			Parent = shell,
		})

		hairline(shell, TabboxStrip - Sizes.Outline, "OutlineDim", 1)

		local indicator = Library:Create("Frame", {
			Name = "Indicator",
			AnchorPoint = Vector2.new(0, 1),
			BorderSizePixel = 0,
			Position = UDim2.new(0, 0, 1, 0),
			Size = UDim2.new(0, 0, 0, Sizes.Indicator),
			Visible = false,
			ZIndex = 3,
			Theme = { BackgroundColor3 = "Accent" },
			Parent = strip,
		})

		local tabbox = {
			Library = Library,
			Frame = shell,
			Tabs = {},
			Active = nil,
		}

		local function resizeShell()
			local active = tabbox.Active
			local inner = active and active.Layout.AbsoluteContentSize.Y or 0
			shell.Size = UDim2.new(1, 0, 0, math.ceil(TabboxStrip + inner + Sizes.GroupPad * 2))
		end

		local function placeIndicator(animate)
			local count = #tabbox.Tabs
			local index = tabbox.Active and table.find(tabbox.Tabs, tabbox.Active) or nil

			if not index or count == 0 then
				indicator.Visible = false
				return
			end

			indicator.Visible = true

			local position = UDim2.new((index - 1) / count, 0, 1, 0)
			local size = UDim2.new(1 / count, 0, 0, Sizes.Indicator)

			if animate then
				Library:Tween(indicator, { Position = position, Size = size }, Library.Motion.Fast)
			else
				indicator.Position = position
				indicator.Size = size
			end
		end

		local function layoutButtons()
			local count = #tabbox.Tabs
			if count == 0 then
				return
			end

			for index, entry in tabbox.Tabs do
				entry.Button.Position = UDim2.new((index - 1) / count, 0, 0, 0)
				entry.Button.Size = UDim2.new(1 / count, 0, 1, 0)
			end

			placeIndicator(false)
		end

		function tabbox:SetTab(target)
			if not target then
				return self
			end

			for _, entry in self.Tabs do
				local on = entry == target
				entry.Container.Visible = on
				retheme(entry.Label, { TextColor3 = on and "Font" or "FontDim" })
			end

			-- Slide the underline only if it was already somewhere; the first
			-- placement should not animate in from zero width.
			local placed = indicator.Visible

			self.Active = target
			placeIndicator(placed)
			target:Resize()

			return self
		end

		function tabbox:AddTab(name)
			local content = Library:Create("Frame", {
				Name = "Tab",
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Position = UDim2.fromOffset(0, TabboxStrip),
				Size = UDim2.new(1, 0, 1, -TabboxStrip),
				Visible = false,
				Parent = shell,
			})
			Util.Padding(content, Sizes.GroupPad, Sizes.GroupPad, Sizes.GroupPad, Sizes.GroupPad)

			local layout = Util.ListLayout(content, Sizes.RowGap)

			-- The label is a separate instance so switching tabs can retheme the
			-- text without wiping the button's hover colour out of the registry.
			local button = Library:Create("TextButton", {
				Name = "Button",
				AutoButtonColor = false,
				BorderSizePixel = 0,
				Position = UDim2.fromScale(0, 0),
				Size = UDim2.new(1, 0, 1, 0),
				Text = "",
				Theme = { BackgroundColor3 = "Panel" },
				Parent = strip,
			})

			local label = Library:Label({
				Name = "Label",
				Font = Library.Fonts.Title,
				Size = UDim2.fromScale(1, 1),
				Text = Library:Chrome(name or ""),
				TextSize = Sizes.TextSmall,
				TextTruncate = Enum.TextTruncate.AtEnd,
				TextXAlignment = Enum.TextXAlignment.Center,
				Parent = button,
			}, "FontDim")

			Library:BindHover(button, button, "Panel", "PanelRaised")

			local entry = newContainer(content, nil)
			entry.Type = "TabboxTab"
			entry.Name = name
			entry.Button = button
			entry.Label = label
			entry.Layout = layout
			entry.Tabbox = tabbox

			function entry:Recompute()
				resizeShell()
			end

			table.insert(tabbox.Tabs, entry)
			table.insert(tab.Boxes, entry)

			Library:GiveSignal(layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
				entry:Resize()
			end))

			Library:GiveSignal(button.MouseButton1Click:Connect(function()
				tabbox:SetTab(entry)
			end))

			layoutButtons()

			if #tabbox.Tabs == 1 then
				tabbox:SetTab(entry)
			end

			return entry
		end

		resizeShell()

		return tabbox
	end

	--==============================================================
	-- tab
	--==============================================================

	local function newColumn(page, side)
		local isLeft = side == "Left"

		local column = Library:Create("ScrollingFrame", {
			Name = side,
			-- Active so touch drag-scrolling works; the mouse wheel does not
			-- care either way.
			Active = true,
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			BottomImage = FLAT_SCROLL,
			CanvasSize = UDim2.fromOffset(0, 0),
			ElasticBehavior = Enum.ElasticBehavior.Never,
			Position = isLeft and UDim2.fromScale(0, 0) or UDim2.new(0.5, HalfGap, 0, 0),
			ScrollBarImageTransparency = 0,
			ScrollBarThickness = Sizes.ScrollBar,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			Size = UDim2.new(0.5, -HalfGap, 1, 0),
			TopImage = FLAT_SCROLL,
			VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
			Theme = { ScrollBarImageColor3 = "Outline" },
			Parent = page,
		})

		-- Side padding is a hairline wide so a groupbox's UIStroke, which draws
		-- outside the frame, is not eaten by the ScrollingFrame's clipping.
		Util.Padding(column, ColumnTop, Sizes.Outline, Sizes.GroupGap, Sizes.Outline)
		Util.ListLayout(column, Sizes.GroupGap)

		return column
	end

	local Tab = {}
	Tab.__index = Tab

	function Tab:AddLeftGroupbox(name)
		return newGroupbox(self, "Left", name)
	end

	function Tab:AddRightGroupbox(name)
		return newGroupbox(self, "Right", name)
	end

	function Tab:AddLeftTabbox()
		return newTabbox(self, "Left")
	end

	function Tab:AddRightTabbox()
		return newTabbox(self, "Right")
	end

	function Tab:Show()
		self.Window:SetTab(self)
		return self
	end

	function Tab:Resize()
		for _, box in self.Boxes do
			box:Resize()
		end
		return self
	end

	--==============================================================
	-- window
	--==============================================================

	local WindowMeta = {}
	WindowMeta.__index = WindowMeta

	function WindowMeta:SetTitle(text)
		self.Title = tostring(text or "")
		self.TitleLabel.Text = Library:Chrome(self.Title)
		return self
	end

	function WindowMeta:SetFooter(text)
		self.Footer = tostring(text or "")
		self.FooterLabel.Text = Library:FormatLabel(self.Footer)
		return self
	end

	function WindowMeta:PlaceIndicator(animate)
		local count = #self.Tabs
		local index = self.ActiveTab and table.find(self.Tabs, self.ActiveTab) or nil

		if not index or count == 0 then
			self.Indicator.Visible = false
			return self
		end

		self.Indicator.Visible = true

		local position = UDim2.new((index - 1) / count, 0, 1, 0)
		local size = UDim2.new(1 / count, 0, 0, Sizes.Indicator)

		if animate then
			Library:Tween(self.Indicator, { Position = position, Size = size }, Library.Motion.Fast)
		else
			self.Indicator.Position = position
			self.Indicator.Size = size
		end

		return self
	end

	function WindowMeta:LayoutTabs()
		local count = #self.Tabs
		if count == 0 then
			return self
		end

		for index, tab in self.Tabs do
			tab.Button.Position = UDim2.new((index - 1) / count, 0, 0, 0)
			tab.Button.Size = UDim2.new(1 / count, 0, 1, 0)
		end

		self:PlaceIndicator(false)
		return self
	end

	--- Accepts a tab object or a tab name.
	function WindowMeta:SetTab(target)
		local resolved = target

		if type(target) == "string" then
			resolved = nil
			for _, candidate in self.Tabs do
				if candidate.Name == target then
					resolved = candidate
					break
				end
			end
		end

		if type(resolved) ~= "table" or resolved.Window ~= self then
			return self
		end

		Library:ClosePopup()

		-- Only slide the underline when it already had a home.
		local placed = self.Indicator.Visible
		self.ActiveTab = resolved

		for _, candidate in self.Tabs do
			local on = candidate == resolved
			candidate.Page.Visible = on
			retheme(candidate.Label, { TextColor3 = on and "Font" or "FontDim" })
		end

		self:PlaceIndicator(placed)
		resolved:Resize()

		return self
	end

	function WindowMeta:AddTab(name)
		local page = Library:Create("Frame", {
			Name = "Page",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.fromScale(1, 1),
			Visible = false,
			Parent = self.Body,
		})

		local button = Library:Create("TextButton", {
			Name = "Tab",
			AutoButtonColor = false,
			BorderSizePixel = 0,
			Position = UDim2.fromScale(0, 0),
			Size = UDim2.new(1, 0, 1, 0),
			Text = "",
			Theme = { BackgroundColor3 = "Background" },
			Parent = self.TabStrip,
		})

		-- Text lives on its own label: SetTab rethemes the label, which would
		-- otherwise drop the button's hover colour out of the registry with it.
		local label = Library:Label({
			Name = "Label",
			Font = Library.Fonts.Title,
			Size = UDim2.fromScale(1, 1),
			Text = Library:Chrome(name or ""),
			TextSize = Sizes.TextSmall,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Center,
			Parent = button,
		}, "FontDim")

		Library:BindHover(button, button, "Background", "Panel")

		local tab = setmetatable({
			Library = Library,
			Window = self,
			Name = name or "",
			Page = page,
			Button = button,
			Label = label,
			Boxes = {},
			Order = { Left = 0, Right = 0 },
		}, Tab)

		tab.Left = newColumn(page, "Left")
		tab.Right = newColumn(page, "Right")

		table.insert(self.Tabs, tab)

		Library:GiveSignal(button.MouseButton1Click:Connect(function()
			self:SetTab(tab)
		end))

		self:LayoutTabs()

		if #self.Tabs == 1 then
			self:SetTab(tab)
		end

		return tab
	end

	--- Both addons ship with a folder already set, so this only fills in a
	--- manager whose folder a host script cleared. SetFolder is called rather
	--- than assigning `.Folder` because it also creates the directory on disk.
	local function defaultFolder(manager)
		if type(manager) ~= "table" or type(manager.SetFolder) ~= "function" then
			return
		end
		if type(manager.Folder) == "string" and manager.Folder ~= "" then
			return
		end
		manager:SetFolder(Library.Name)
	end

	--- The whole settings tab in one call: menu preferences, the theme editor
	--- and the config section. Every index it registers is added to the
	--- SaveManager ignore list, so a config file carries game settings only and
	--- never another machine's menu keybind.
	---
	--- Both addons are optional here. A build with either one stripped out still
	--- gets the Menu groupbox and a usable tab.
	function WindowMeta:AddSettingsTab(name)
		local tab = self:AddTab(type(name) == "string" and name ~= "" and name or "Settings")

		local menu = tab:AddLeftGroupbox("Menu")

		menu:AddKeyPicker(MENU_KEYBIND_INDEX, {
			Default = Library.MenuKeybind,
			Mode = "Toggle",
			Text = "Menu",
			-- The bind that opens the menu has no business in the keybind list:
			-- it is the one bind the user cannot forget.
			NoUI = true,
			Tooltip = "Opens and closes the menu",
			ChangedCallback = function(value)
				Library:SetMenuKeybind(value)
			end,
		})

		menu:AddToggle(WATERMARK_INDEX, {
			Text = "Watermark",
			Default = true,
			Callback = function(value)
				Library:SetWatermarkVisibility(value)
			end,
		})

		menu:AddToggle(KEYBIND_LIST_INDEX, {
			Text = "Keybind list",
			Default = true,
			Callback = function(value)
				Library:SetKeybindVisibility(value)
			end,
		})

		menu:AddDivider()

		menu:AddButton({
			Text = "Unload",
			DoubleClick = true,
			Tooltip = "Double click to remove the menu",
			Func = function()
				Library:Unload()
			end,
		})

		local themeManager = Library.ThemeManager
		local saveManager = Library.SaveManager

		defaultFolder(themeManager)
		defaultFolder(saveManager)

		if type(saveManager) == "table" then
			-- Menu preferences belong to the person, not to the config. Both
			-- calls ADD to the ignore set, so whatever the host script already
			-- ignored survives.
			saveManager:IgnoreThemeSettings()
			saveManager:SetIgnoreIndexes({ MENU_KEYBIND_INDEX, WATERMARK_INDEX, KEYBIND_LIST_INDEX })

			saveManager:BuildConfigSection(tab)
		end

		if type(themeManager) == "table" then
			themeManager:ApplyToTab(tab)
		end

		return tab
	end

	--- Library:SetOpen drives this; it is required on every window.
	function WindowMeta:SetVisible(visible)
		visible = visible == true
		self.Shown = visible

		local fade = math.max(tonumber(Library.MenuFadeTime) or 0, 0)
		local info = TweenInfo.new(fade, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		local goal = visible and 0 or 1

		if visible then
			self.Frame.Visible = true
		end

		Library:Tween(self.Frame, { BackgroundTransparency = goal }, info)
		Library:Tween(self.Stroke, { Transparency = goal }, info)
		Library:Tween(self.Canvas, { GroupTransparency = goal }, info)

		self.FadeToken += 1
		local token = self.FadeToken

		if not visible then
			-- Only hide once this particular fade finishes: a re-open mid-fade
			-- bumps the token and this delayed call becomes a no-op.
			task.delay(fade, function()
				if Library.Unloaded then
					return
				end
				if self.FadeToken == token and not self.Shown then
					self.Frame.Visible = false
				end
			end)
		end

		return self
	end

	--==============================================================
	-- constructor
	--==============================================================

	function Library:CreateWindow(config)
		config = config or {}

		if type(config.MenuFadeTime) == "number" then
			Library.MenuFadeTime = config.MenuFadeTime
		end

		local sizeUDim = typeof(config.Size) == "UDim2" and config.Size
			or UDim2.fromOffset(Sizes.WindowWidth, Sizes.WindowHeight)

		local root, stroke = Library:Panel({
			Name = "Window",
			Active = true,
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			Position = typeof(config.Position) == "UDim2" and config.Position or UDim2.fromOffset(48, 48),
			Size = sizeUDim,
			Visible = false,
			Parent = Library.WindowHolder,
		}, "Background", "Outline")
		stroke.Transparency = 1

		-- Everything except the frame fill and its hairline lives in the canvas,
		-- so the menu fades as one object instead of a hundred transparencies.
		local canvas = Library:Create("CanvasGroup", {
			Name = "Canvas",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			GroupTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Parent = root,
		})

		Library:CornerTicks(canvas, "Accent")

		local titleBar = Library:Create("Frame", {
			Name = "TitleBar",
			Active = true,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, Sizes.TitleBar),
			ZIndex = 2,
			Parent = canvas,
		})

		local titleLabel = Library:Label({
			Name = "Title",
			Font = Library.Fonts.Title,
			Position = UDim2.fromOffset(TitlePad, 0),
			Size = UDim2.new(0.62, -TitlePad, 1, 0),
			Text = Library:Chrome(config.Title or Library.Name),
			TextSize = Sizes.TextTitle,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = titleBar,
		}, "Font")

		local footerLabel = Library:Label({
			Name = "Footer",
			Position = UDim2.new(0.62, 0, 0, 0),
			Size = UDim2.new(0.38, -TitlePad, 1, 0),
			Text = Library:FormatLabel(config.Footer or ("v" .. tostring(Library.Version))),
			TextSize = Sizes.TextSmall,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = titleBar,
		}, "FontDim")

		-- Rules are parented to the canvas, not to the bars, so no padding on a
		-- bar can ever shorten them.
		hairline(canvas, Sizes.TitleBar - Sizes.Outline, "Outline", 1)
		hairline(canvas, ChromeHeight - Sizes.Outline, "OutlineDim", 1)

		local tabStrip = Library:Create("Frame", {
			Name = "TabStrip",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(0, Sizes.TitleBar),
			Size = UDim2.new(1, 0, 0, Sizes.TabStrip),
			ZIndex = 2,
			Parent = canvas,
		})

		local indicator = Library:Create("Frame", {
			Name = "Indicator",
			AnchorPoint = Vector2.new(0, 1),
			BorderSizePixel = 0,
			Position = UDim2.new(0, 0, 1, 0),
			Size = UDim2.new(0, 0, 0, Sizes.Indicator),
			Visible = false,
			ZIndex = 3,
			Theme = { BackgroundColor3 = "Accent" },
			Parent = tabStrip,
		})

		local body = Library:Create("Frame", {
			Name = "Body",
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Position = UDim2.fromOffset(0, ChromeHeight),
			Size = UDim2.new(1, 0, 1, -ChromeHeight),
			Parent = canvas,
		})
		Util.Padding(body, Sizes.RowGap, Sizes.GroupPad, Sizes.GroupPad, Sizes.GroupPad)

		local window = setmetatable({
			Library = Library,
			Frame = root,
			Stroke = stroke,
			Canvas = canvas,
			TitleBar = titleBar,
			TitleLabel = titleLabel,
			FooterLabel = footerLabel,
			TabStrip = tabStrip,
			Indicator = indicator,
			Body = body,
			Tabs = {},
			ActiveTab = nil,
			Title = tostring(config.Title or Library.Name),
			Footer = tostring(config.Footer or ("v" .. tostring(Library.Version))),
			Shown = false,
			FadeToken = 0,
		}, WindowMeta)

		Library:MakeDraggable(titleBar, root)

		if config.Center and not (typeof(config.Position) == "UDim2") then
			-- AbsoluteSize is still zero this frame, so centre from the intended
			-- size and retry once the layout has run if the viewport is not up yet.
			local function centre()
				local viewport = Library.ScreenGui.AbsoluteSize
				if viewport.X <= 0 or viewport.Y <= 0 then
					return false
				end

				local width = sizeUDim.X.Scale * viewport.X + sizeUDim.X.Offset
				local height = sizeUDim.Y.Scale * viewport.Y + sizeUDim.Y.Offset

				root.Position = UDim2.fromOffset(
					math.floor((viewport.X - width) / 2),
					math.floor((viewport.Y - height) / 2)
				)
				return true
			end

			if not centre() then
				-- The ScreenGui has not been measured yet; try again each frame
				-- until it has, then stop.
				local connection
				connection = Library:GiveSignal(Library.RenderStepped:Connect(function()
					if Library.Unloaded or centre() then
						connection:Disconnect()
					end
				end))
			end
		end

		if config.Resizable ~= false then
			local grip = Library:Create("Frame", {
				Name = "Grip",
				AnchorPoint = Vector2.new(1, 1),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				Position = UDim2.new(1, -3, 1, -3),
				Size = UDim2.fromOffset(16, 16),
				ZIndex = 11,
				Parent = canvas,
			})

			for index, length in { 9, 5 } do
				Library:Create("Frame", {
					Name = ("Mark%d"):format(index),
					AnchorPoint = Vector2.new(1, 1),
					BorderSizePixel = 0,
					Position = UDim2.new(1, 0, 1, -(index - 1) * 3),
					Size = UDim2.fromOffset(length, Sizes.Outline),
					ZIndex = 11,
					Theme = { BackgroundColor3 = "Outline" },
					Parent = grip,
				})
			end

			local hit = Library:HitButton(grip, { ZIndex = 12 })

			local resizing = false
			local startMouse = Vector2.zero
			local startSize = Vector2.zero

			Library:GiveSignal(hit.InputBegan:Connect(function(input)
				if
					input.UserInputType ~= Enum.UserInputType.MouseButton1
					and input.UserInputType ~= Enum.UserInputType.Touch
				then
					return
				end
				resizing = true
				startMouse = Util.MousePosition()
				startSize = root.AbsoluteSize
				Library:ClosePopup()
			end))

			Library:GiveSignal(Library.InputChanged:Connect(function(input)
				if not resizing then
					return
				end
				if
					input.UserInputType ~= Enum.UserInputType.MouseMovement
					and input.UserInputType ~= Enum.UserInputType.Touch
				then
					return
				end

				local delta = Util.MousePosition() - startMouse
				local viewport = Library.ScreenGui.AbsoluteSize

				local width = Util.Clamp(
					startSize.X + delta.X,
					Sizes.WindowMinWidth,
					math.max(Sizes.WindowMinWidth, viewport.X)
				)
				local height = Util.Clamp(
					startSize.Y + delta.Y,
					Sizes.WindowMinHeight,
					math.max(Sizes.WindowMinHeight, viewport.Y)
				)

				root.Size = UDim2.fromOffset(math.floor(width), math.floor(height))
			end))

			Library:GiveSignal(Library.InputEnded:Connect(function(input)
				if
					input.UserInputType == Enum.UserInputType.MouseButton1
					or input.UserInputType == Enum.UserInputType.Touch
				then
					resizing = false
				end
			end))
		end

		table.insert(Library.Windows, window)

		if config.AutoShow then
			Library:SetOpen(true)
		end

		return window
	end
end

return Window
