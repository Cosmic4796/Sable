--[[
	Sable :: example
	Exercises every element type, both addon managers, and the overlays.
	Use it as a smoke test after a rebuild -- if anything here errors or looks
	wrong, the library is wrong.

	Loading (pick one):
		local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/Cosmic4796/Sable/main/dist/Sable.lua"))()
		local Library = loadstring(readfile("Sable.lua"))()   -- local copy
]]

local Library = loadstring(game:HttpGet("https://raw.githubusercontent.com/Cosmic4796/Sable/main/dist/Sable.lua"))()

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

Aimbot:AddDivider()

Aimbot:AddToggle("AimbotShowFOV", { Text = "Draw FOV circle", Default = true })
	:AddColorPicker("AimbotFOVColor", { Default = Color3.fromRGB(233, 161, 59), Title = "FOV circle" })

local FovBox = Aimbot:AddDependencyBox()
FovBox:AddSlider("AimbotFOVThickness", { Text = "Circle thickness", Default = 1, Min = 1, Max = 5, Rounding = 0 })
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

Trigger:AddInput("TriggerWhitelist", {
	Text = "Ignore",
	Placeholder = "player names, comma separated",
	Finished = true,
})

Trigger:AddButton({
	Text = "Reset triggerbot",
	Func = function()
		Library.Options.TriggerDelay:SetValue(60)
		Library.Toggles.TriggerEnabled:SetValue(false)
		Library:Notify("Triggerbot reset", 3)
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

Info:AddButton({
	Text = "Advance progress",
	Func = function()
		local bar = Library.Options.SessionProgress
		bar:SetValue(bar.Value >= bar.Max and 0 or bar.Value + 10)
	end,
})

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

-- Restores the theme picked with "set as default" on a previous run. Without
-- this, that button appears to do nothing across sessions.
ThemeManager:LoadDefault()
SaveManager:LoadAutoloadConfig()

Library:Notify({ Title = "Sable", Description = "Example hub loaded", Time = 4 })
