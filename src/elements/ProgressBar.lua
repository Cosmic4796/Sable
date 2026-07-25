--!nonstrict
-- Sable :: elements/ProgressBar
--
-- A read-only readout wearing the slider's clothes: same segmented track, same
-- right-aligned monospace value. Farm progress, a cooldown, a health bar --
-- anything the SCRIPT knows and the user only watches.
--
-- What makes it a readout rather than a control is everything it does not have:
-- no hit button, no drag, no hover, and a value column that never brightens,
-- because nothing the user does can move it. The row itself is elements/Numeric
-- and the bar inside it is elements/Track, both shared with Slider -- one set of
-- arithmetic, two meanings. This file is the absence of the interaction.
--
-- It is registered in Library.Options so a script can drive it by index, but it
-- carries no persistent state -- SaveManager's serialize() has no case for this
-- type and returns nil, so it never reaches a config file.

local Base = require("elements/Base")
local Numeric = require("elements/Numeric")

local ProgressBar = {}

function ProgressBar.New(Library, container, index, options)
	options = options or {}

	local element = Base.Create(Library, container, "ProgressBar", index, options)

	-- Percent by default, because the overwhelmingly common progress readout is
	-- one; and zero by default, because progress starts at nothing rather than at
	-- whatever the low bound happens to be.
	Numeric.New(Library, element, options, { Suffix = "%", Default = 0 })

	return Base.Finish(element, Library.Options)
end

return ProgressBar
