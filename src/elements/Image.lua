--!nonstrict
-- Sable :: elements/Image
--
-- The one element that shows something Sable did not draw: a hub banner, a
-- diagram, a captured frame. It is framed exactly like a slider trough -- sunken
-- fill, one hairline outline, one hairline of inset -- so an arbitrary bitmap
-- lands inside the instrument rather than on top of it.
--
-- ScaleType defaults to Fit, which letterboxes rather than crops: an asset of
-- unknown proportions is far more often information than decoration, and half a
-- diagram is worse than a smaller one.
--
-- Registered in Library.Options so a hub can swap the asset live. Like
-- ProgressBar it carries no persistent state: SaveManager's serialize() has no
-- case for this type and returns nil, so it never reaches a config file.

local Util = require("Util")
local Base = require("elements/Base")

local Image = {}

-- Four rows tall by default: enough for an image to be an image, still short
-- enough that one does not push every control below the fold.
local DEFAULT_ROWS = 4

-- How far a disabled image fades toward its background, as a share of the
-- transparency it has left. Text goes FontFaint when disabled; a bitmap has no
-- text colour to dim, and tinting it would be a colour Sable does not own.
local DISABLED_FADE = 0.6

function Image.New(Library, container, index, options)
	options = options or {}

	local element = Base.Create(Library, container, "Image", index, options)

	local Sizes = Library.Sizes

	local height = math.floor(tonumber(options.Height) or Sizes.RowHeight * DEFAULT_ROWS)
	-- A panel shorter than a row is a hairline sandwich, not a picture.
	height = math.max(height, Sizes.RowHeight)

	-- An EnumItem or nothing. A string would have to be resolved by indexing
	-- Enum.ScaleType, which THROWS on a typo rather than returning nil.
	local scaleType = typeof(options.ScaleType) == "EnumItem" and options.ScaleType
		or Enum.ScaleType.Fit

	element.Value = options.Image ~= nil and tostring(options.Image) or ""
	element.Transparency = Util.Clamp(tonumber(options.Transparency) or 0, 0, 1)

	local row = Library:Row(container, height)
	row.Name = "ImageRow"

	element.Row = row
	element.ExpandedSize = row.Size

	local panel = Library:Panel({
		Name = "Panel",
		ClipsDescendants = true,
		Size = UDim2.fromScale(1, 1),
		Parent = row,
	}, "PanelSunken", "Outline")
	element.Panel = panel

	-- One hairline of inset, so the bitmap never sits on the outline it is
	-- framed by. The same inset the segmented track gives its cells.
	Util.Padding(panel, Sizes.Outline)

	local image = Library:Create("ImageLabel", {
		Name = "Image",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Image = element.Value,
		ImageTransparency = element.Transparency,
		ScaleType = scaleType,
		Size = UDim2.fromScale(1, 1),
		Parent = panel,
	})
	element.ImageLabel = image

	--- What is actually on screen: the caller's transparency, faded further while
	--- the element is disabled. Display goes through this rather than writing
	--- element.Transparency straight out, or a repaint mid-disable would quietly
	--- un-fade the image.
	local function shownTransparency()
		local rest = element.Transparency
		if element.Disabled then
			return rest + (1 - rest) * DISABLED_FADE
		end
		return rest
	end

	function element:Display()
		image.Image = self.Value
		image.ImageTransparency = shownTransparency()
		return self
	end

	--- The asset id IS the value, so this and :SetValue are the same operation
	--- under two names -- :SetImage reads better at a call site, :SetValue keeps
	--- the element contract.
	function element:SetImage(asset, silent)
		return self:SetValue(asset, silent)
	end

	function element:SetValue(value, silent)
		self.Value = value ~= nil and tostring(value) or ""
		self:Display()

		if not silent then
			self:Fire()
		end

		return self
	end

	function element:SetTransparency(value)
		self.Transparency = Util.Clamp(tonumber(value) or 0, 0, 1)
		return self:Display()
	end

	element.OnDisabledChanged = function()
		image.ImageTransparency = shownTransparency()
	end

	element:Display()

	return Base.Finish(element, Library.Options)
end

return Image
