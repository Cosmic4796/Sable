--[[
	Sable :: example
	Exercises every element type, both addon managers, and the overlays.
	Use it as a smoke test after a rebuild -- if anything here errors or looks
	wrong, the library is wrong.

	Loading (pick one):
		local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/Cosmic4796/Sable/main/Sable.lua"))()
		local Library = loadstring(readfile("Sable.lua"))()   -- local copy
]]

local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/Cosmic4796/Sable/main/Sable.lua"))()

local ThemeManager = Library.ThemeManager
local SaveManager = Library.SaveManager

local Window = Library:CreateWindow({
	Title = "Sable",
	Footer = "sys " .. Library.Version,
	Center = true,
	AutoShow = true,
	Resizable = true,
})

local Tabs = {
	Main = Window:AddTab("Main"),
	Visuals = Window:AddTab("Visuals"),
	Player = Window:AddTab("Player"),
}

--==============================================================
-- Main
--==============================================================

local Aimbot = Tabs.Main:AddLeftGroupbox("Aimbot")

-- A picker attached to a toggle renders inline, to the left of the toggle's own
-- control. Hold mode: on for exactly as long as the key is down.
Aimbot:AddToggle("AimbotEnabled", {
	Text = "Enabled",
	Default = false,
	Tooltip = "Master switch for the aim assist",
}):AddKeyPicker("AimbotKey", {
	Default = "MB2",
	Mode = "Hold",
	Text = "Aimbot",
	SyncToggleState = false,
})

Aimbot:AddToggle("AimbotTeamCheck", { Text = "Team check", Default = true })
Aimbot:AddToggle("AimbotWallCheck", { Text = "Wall check", Default = true })

-- A section breaks a long groupbox into named parts. It holds no value and is
-- never saved: it is a divider with a name on it.
Aimbot:AddSection("Tuning")

Aimbot:AddSlider("AimbotFOV", {
	Text = "FOV",
	Default = 120,
	Min = 0,
	Max = 500,
	Rounding = 0,
	Suffix = "px",
})

Aimbot:AddSlider("AimbotSmoothing", {
	Text = "Smoothing",
	Default = 0.35,
	Min = 0,
	Max = 1,
	Rounding = 2,
})

Aimbot:AddDropdown("AimbotBone", {
	Text = "Bone",
	Values = { "Head", "UpperTorso", "HumanoidRootPart", "LowerTorso" },
	Default = 1,
})

-- Searchable puts a filter field above the list, which is what makes a long one
-- usable. AllowNull lets a single-select dropdown be emptied again, and
-- MaxVisibleDropdownItems caps how tall the popup grows before it scrolls.
Aimbot:AddDropdown("AimbotPriority", {
	Text = "Priority",
	Values = {
		"Closest to crosshair",
		"Closest to camera",
		"Lowest health",
		"Highest threat",
		"Most visible",
		"Least recently hit",
	},
	Default = 1,
	Searchable = true,
	AllowNull = true,
	MaxVisibleDropdownItems = 4,
})

Aimbot:AddDivider()

-- One element can carry both inline pickers. :AddColorPicker returns the PICKER
-- rather than the host, so two of them cannot be chained -- keep the toggle.
local ShowFov = Aimbot:AddToggle("AimbotShowFOV", { Text = "Draw FOV circle", Default = true })
ShowFov:AddColorPicker("AimbotFOVColor", { Default = Color3.fromRGB(233, 161, 59), Title = "FOV circle" })
ShowFov:AddKeyPicker("AimbotFOVKey", { Default = "F2", Mode = "Toggle", Text = "FOV circle" })

-- A dependency box is visible only while every pair it was given matches.
local FovBox = Aimbot:AddDependencyBox()
FovBox:AddSlider("AimbotFOVThickness", { Text = "Circle thickness", Default = 1, Min = 1, Max = 5, Rounding = 0 })
-- Compact drops the label and gives the whole row to the track, for a value the
-- row above has already named.
FovBox:AddSlider("AimbotFOVOpacity", {
	Text = "Circle opacity",
	Default = 60,
	Min = 0,
	Max = 100,
	Rounding = 0,
	Suffix = "%",
	Compact = true,
})
FovBox:SetupDependencies({ { Library.Toggles.AimbotShowFOV, true } })

local Trigger = Tabs.Main:AddRightGroupbox("Triggerbot")

Trigger:AddToggle("TriggerEnabled", { Text = "Enabled", Default = false })
	:AddKeyPicker("TriggerKey", { Default = "C", Mode = "Toggle", Text = "Triggerbot" })

Trigger:AddSlider("TriggerDelay", {
	Text = "Delay",
	Default = 60,
	Min = 0,
	Max = 500,
	Rounding = 0,
	Suffix = "ms",
})

-- Numeric keeps everything but digits out of the field. This one fires on every
-- keystroke, which is the default.
Trigger:AddInput("TriggerHitChance", {
	Text = "Hit chance",
	Default = "100",
	Numeric = true,
	MaxLength = 3,
})

-- Finished = true fires only on Enter or focus loss instead -- what a field
-- someone types a whole sentence into wants.
Trigger:AddInput("TriggerWhitelist", {
	Text = "Ignore",
	Placeholder = "player names, comma separated",
	Finished = true,
})

-- :AddButton on a button splits the row into equal columns.
local ResetTrigger = Trigger:AddButton({
	Text = "Reset triggerbot",
	Func = function()
		Library.Options.TriggerDelay:SetValue(60)
		Library.Toggles.TriggerEnabled:SetValue(false)
		Library:Notify("Triggerbot reset", 3)
	end,
})
ResetTrigger:AddButton({
	Text = "Test",
	Func = function()
		Library:Notify({ Title = "Triggerbot", Description = "Fired once", Time = 3 })
	end,
})

local Risky = Tabs.Main:AddRightGroupbox("Risky")
Risky:AddToggle("SilentAim", { Text = "Silent aim", Default = false, Risky = true })
Risky:AddToggle("AutoShoot", {
	Text = "Auto shoot",
	Default = false,
	Risky = true,
	Disabled = true,
	DisabledTooltip = "Unavailable in this game",
})

--==============================================================
-- Visuals
--==============================================================

local ESP = Tabs.Visuals:AddLeftGroupbox("ESP")

ESP:AddSection("Overlays")

ESP:AddToggle("EspEnabled", { Text = "Enabled", Default = true })
ESP:AddToggle("EspBoxes", { Text = "Boxes", Default = true })
	:AddColorPicker("EspBoxColor", { Default = Color3.fromRGB(218, 213, 204) })
ESP:AddToggle("EspNames", { Text = "Names", Default = false })
	:AddColorPicker("EspNameColor", { Default = Color3.fromRGB(233, 161, 59) })
ESP:AddToggle("EspTracers", { Text = "Tracers", Default = false })
	:AddColorPicker("EspTracerColor", { Default = Color3.fromRGB(226, 78, 63), Transparency = 0 })

ESP:AddSection("Limits")

ESP:AddSlider("EspFill", { Text = "Box fill", Default = 40, Min = 0, Max = 100, Rounding = 0, Suffix = "%" })
ESP:AddSlider("EspMaxDistance", { Text = "Max distance", Default = 500, Min = 50, Max = 2000, Rounding = 0 })

ESP:AddDropdown("EspTeams", {
	Text = "Show",
	Values = { "Enemies", "Team", "Everyone" },
	Default = "Enemies",
})

local Chams = Tabs.Visuals:AddRightGroupbox("Chams")
Chams:AddToggle("ChamsEnabled", { Text = "Enabled", Default = false })
Chams:AddDropdown("ChamsParts", {
	Text = "Parts",
	Values = { "Head", "Torso", "Arms", "Legs" },
	Default = { Head = true, Torso = true },
	Multi = true,
})
Chams:AddColorPicker("ChamsVisible", { Default = Color3.fromRGB(126, 176, 106), Title = "Visible" })
Chams:AddColorPicker("ChamsHidden", { Default = Color3.fromRGB(226, 78, 63), Title = "Hidden" })

-- Transparency = <number> adds an alpha bar to the popup and gives the picker a
-- .Transparency field. Leave it nil and the picker is colour only.
Chams:AddColorPicker("ChamsFill", {
	Default = Color3.fromRGB(233, 161, 59),
	Title = "Fill",
	Transparency = 0.5,
})

-- A Label takes inline pickers too, for a colour with no toggle of its own.
Chams:AddLabel("Outline"):AddColorPicker("ChamsOutline", { Default = Color3.fromRGB(52, 49, 44) })

local WorldBox = Tabs.Visuals:AddRightTabbox()
local WorldA = WorldBox:AddTab("World")
WorldA:AddToggle("FullBright", { Text = "Fullbright", Default = false })
WorldA:AddSlider("Ambient", { Text = "Ambient", Default = 50, Min = 0, Max = 100, Rounding = 0 })

local WorldB = WorldBox:AddTab("Camera")
WorldB:AddSlider("FieldOfView", { Text = "FOV", Default = 70, Min = 40, Max = 120, Rounding = 0 })
WorldB:AddToggle("ThirdPerson", { Text = "Third person", Default = false })

--==============================================================
-- Player
--==============================================================

local Movement = Tabs.Player:AddLeftGroupbox("Movement")

Movement:AddToggle("SpeedEnabled", { Text = "Walk speed", Default = false })
	:AddKeyPicker("SpeedKey", { Default = "LSHIFT", Mode = "Hold", Text = "Speed" })
Movement:AddSlider("SpeedValue", { Text = "Speed", Default = 16, Min = 16, Max = 200, Rounding = 0 })

Movement:AddToggle("JumpEnabled", { Text = "Jump power", Default = false })
Movement:AddSlider("JumpValue", { Text = "Power", Default = 50, Min = 50, Max = 300, Rounding = 0 })

Movement:AddToggle("Noclip", { Text = "Noclip", Default = false, Risky = true })
	:AddKeyPicker("NoclipKey", { Default = "N", Mode = "Toggle", Text = "Noclip" })

-- The third bind mode. Hold is true while the key is down, Toggle flips on each
-- press, and Always is simply on -- for a feature with no off switch. A picker
-- added to a groupbox rather than to a toggle gets a row of its own.
Movement:AddKeyPicker("AntiAfk", { Default = "None", Mode = "Always", Text = "Anti-AFK" })

Movement:AddButton({ Text = "Reset character", Func = function()
	Library:Notify({ Title = "Character", Description = "Respawn requested", Time = 3, Good = true })
end })

local Danger = Tabs.Player:AddRightGroupbox("Danger")
Danger:AddButton({
	Text = "Kick self",
	DoubleClick = true,
	Func = function()
		Library:Notify({ Title = "Kicked", Description = "Confirmed double click", Time = 4, Risk = true })
	end,
})

local Info = Tabs.Player:AddRightGroupbox("Info")
Info:AddLabel("Executor: " .. Library.Util.ExecutorName())
Info:AddLabel("A wrapping label, used for longer explanatory copy that needs more than one line to say what it means.", true)

-- A paragraph is the wrapping label with a heading on it: instructions, a
-- changelog, a warning. Title cased like a label, body left as written.
Info:AddParagraph(
	"How this works",
	"Everything on this tab is a demonstration. Values are stored in Options and "
		.. "Toggles by index, and configs restore them by calling :SetValue, so your "
		.. "callbacks run exactly as if the control had been clicked."
)

Info:AddSection("Session")

-- Read only: the script drives it, the user watches it. It lives in Options so
-- it can be driven by index, but progress is runtime state and is never saved.
Info:AddProgressBar("SessionProgress", {
	Text = "Farm progress",
	Default = 0,
	Min = 0,
	Max = 100,
	Rounding = 0,
	Suffix = "%",
	Tooltip = "Driven by the script, not by the user",
})

-- Driven live, so it is obvious this is a readout and not a slider: there is
-- nothing to grab and the value moves on its own. Every RenderStepped handler
-- must bail once the menu is unloaded -- the signal is the library's, and it
-- outlives the elements it touches.
local farmed = 0
Library:GiveSignal(Library.RenderStepped:Connect(function(delta)
	if Library.Unloaded then
		return
	end
	farmed = farmed >= 100 and 0 or farmed + delta * 8
	Library.Options.SessionProgress:SetValue(farmed)
end))

-- rbxasset:// paths are shipped with the client, so this one resolves without
-- an upload. A hub would use rbxassetid://<id> for its own art.
Info:AddImage("InfoBanner", {
	Image = "rbxasset://textures/ui/GuiImagePlaceholder.png",
	Height = 96,
	Tooltip = "Swap it live with :SetImage",
})

--==============================================================
-- Settings
--==============================================================

Library:SetWatermark("SABLE")

-- Per-hub folders, so two scripts using Sable cannot overwrite each other's
-- configs. Set these BEFORE AddSettingsTab -- it only fills in a folder that
-- has not been chosen.
ThemeManager:SetFolder("Sable")
SaveManager:SetFolder("Sable/example")
-- Where the dragged watermark / keybind list positions are remembered.
Library:SetHudFolder("Sable/example")

-- One call builds the whole tab: the Menu groupbox (keybind, watermark,
-- keybind list, HUD reset, unload), the theme editor and the config section,
-- with the menu preferences already excluded from saved configs. It also
-- restores the HUD layout saved by the last drag.
Tabs.Settings = Window:AddSettingsTab()

-- AddSettingsTab returns the tab, so a hub can keep adding to it.
--
-- Sharing is an API as well as the two buttons in the Configuration groupbox,
-- and a hub is free to build its own front end for it:
--
--   local text, why = SaveManager:ExportConfig()          -- live values -> "SABLE1:..."
--   local text, why = SaveManager:ExportConfig("legit")   -- a saved config instead
--   local data, why = SaveManager:DecodeConfig(text)      -- pure: no elements, no files
--   local ok,   why = SaveManager:ImportConfig(text)             -- apply it
--   local ok,   why = SaveManager:ImportConfig(text, "friend")   -- apply it and save it
--
-- DecodeConfig never errors on a bad paste; it returns nil plus the reason, so
-- a hub can word its own message instead of guessing.
local Share = Tabs.Settings:AddRightGroupbox("Sharing")

Share:AddButton({
	Text = "Copy my setup",
	Tooltip = "Exports the values on screen as one line of paste-safe text",
	Func = function()
		-- CopyConfig notifies on its own; the return values are for the hub. The
		-- string comes back even when the clipboard is missing, which is the one
		-- failure worth saying something else about.
		local copied, text = SaveManager:CopyConfig()
		Library:Notify({
			Title = copied and "Shared" or "Not copied",
			Description = text and (#text .. " characters, paste it to a friend") or "nothing to share",
			Time = 4,
			Good = copied,
			Risk = not copied,
		})
	end,
})

-- Restores the theme picked with "set as default" on a previous run. Without
-- this, that button appears to do nothing across sessions.
ThemeManager:LoadDefault()
SaveManager:LoadAutoloadConfig()

Library:Notify({ Title = "Sable", Description = "Example hub loaded", Time = 4 })
