-- HUDToggleClient
-- Hunger/water vials are hidden by default and toggled together with one key (H).
--
-- HEALTH IS NEVER TOGGLED. It used to ride along with hunger/water, which was wrong: health
-- is moment-to-moment combat information, not a survival stat you dip into occasionally --
-- same reasoning that already kept the stamina bar permanently visible. This script now
-- actively forces the health bar visible on every refresh, so it comes back even if a
-- respawn or an authored GUI value left it hidden.
--
-- Why one script instead of a flag in each bar's own client: the hunger/water vials live in
-- SurvivalBarsClient's "Blood bar" tree and the health bar lives in HUDManager's ABYSSHud
-- tree. Owning both here keeps them from desyncing after a respawn re-clone.
--
-- The BLOOD vial is deliberately NOT toggled here -- SurvivalBarsClient reveals it whenever
-- blood is actually rising and hides it otherwise, which is independent of this preference.

local Players             = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local TOGGLE_KEY = Enum.KeyCode.H -- verified unbound across every other client script
local ACTION     = "ABYSS_ToggleVitals"

local shown = false -- hunger/water hidden by default, per design
local tracked = {}  -- GuiObjects the H key owns the visibility of
local alwaysOn = {} -- GuiObjects forced visible regardless of the toggle

local function collect()
	tracked, alwaysOn = {}, {}
	local guis = playerGui:FindFirstChild("_GUIs")
	if not guis then return end

	-- Health: HP_BG (fill) + HP_BG1 (track). Always on. NOT "bar outline" -- that ImageLabel
	-- spans both the health AND stamina bars, so it belongs to neither exclusively and is left
	-- alone entirely.
	local hud = guis:FindFirstChild("HUD")
	local abyssHud = hud and hud:FindFirstChild("ABYSSHud")
	local barFrame = abyssHud and abyssHud:FindFirstChild("Frame")
	if barFrame then
		for _, n in ipairs({"HP_BG", "HP_BG1"}) do
			local o = barFrame:FindFirstChild(n)
			if o then alwaysOn[#alwaysOn+1] = o end
		end
	end

	-- Hunger + water vials -- the only things H toggles. Water rides along with hunger: they're
	-- the same class of survival meter sitting side by side in one vial cluster, and hiding one
	-- while showing the other reads as a broken HUD rather than a deliberate setting.
	local bloodFolder = guis:FindFirstChild("Blood bar")
	local screenGui   = bloodFolder and bloodFolder:FindFirstChild("ScreenGui")
	local frame       = screenGui and screenGui:FindFirstChild("Frame")
	if frame then
		for _, n in ipairs({"FoodBar", "WaterBar"}) do
			local o = frame:FindFirstChild(n)
			if o then tracked[#tracked+1] = o end
		end
	end
end

local function apply()
	for _, o in ipairs(tracked) do
		if o and o.Parent then o.Visible = shown end
	end
	for _, o in ipairs(alwaysOn) do
		if o and o.Parent then o.Visible = true end
	end
end

local function refresh()
	collect()
	apply()
end

local function onKey(_actionName, inputState)
	if inputState ~= Enum.UserInputState.Begin then return end
	shown = not shown
	apply()
end

ContextActionService:BindAction(ACTION, onKey, false, TOGGLE_KEY)

-- _GUIs is re-cloned from StarterGui on every respawn, so the old references go stale and
-- the fresh copies come back Visible=true from the authored GUI. Re-collect and re-apply so
-- the player's choice survives dying (same re-acquire pattern HUDManager/SurvivalBarsClient use).
player.CharacterAdded:Connect(function()
	task.wait(0.35) -- let the GUI re-clone land, slightly after SurvivalBarsClient's 0.25
	refresh()
end)

task.spawn(function()
	-- Initial hide: wait for the bars to exist rather than racing the GUI clone on join.
	for _ = 1, 40 do
		refresh()
		if #tracked > 0 and #alwaysOn > 0 then break end
		task.wait(0.25)
	end
	if #tracked == 0 then warn("[HUDToggleClient] no hunger/water bars found to toggle") end
	if #alwaysOn == 0 then warn("[HUDToggleClient] health bar not found to pin visible") end
end)

print("[HUDToggleClient] ready -- press H to toggle hunger/water (health is always shown)")
