-- CombatTagClient
-- Shows/hides the "In Combat" indicator (StarterGui._GUIs."In Combat") whenever the player
-- is combat-tagged (StaminaManager.tagCombat -- fired on landing OR taking a hit; see
-- CombatManager.onHitLanded and applyCombatTag). The server only tells the client when
-- tagging happens plus the tag duration; the client owns its own countdown/hide timer
-- locally instead of the server continuously polling everyone's inCombat() every frame.
-- The skull stays visible for the whole tag duration; the label/timer text is hidden
-- until the player hovers the mouse over the skull.

local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local RE_CombatTagged = RepStorage:WaitForChild("RemoteEvents",10):WaitForChild("CombatTagged",10)

local label, skull
local combatUntil = 0
local hovering = false

local function updateLabelVisibility()
	if label then label.Visible = hovering and combatUntil > tick() end
end

local function acquireGui()
	local guiRoot = playerGui:WaitForChild("_GUIs", 10)
	local folder  = guiRoot:WaitForChild("In Combat", 10)
	local sg      = folder:WaitForChild("CombatTagGui", 10)
	label = sg:WaitForChild("CombatTagLabel", 10)
	skull = sg:FindFirstChild("CombatSkull")
	hovering = false
	-- A tag from just before this respawn's GUI re-clone finished shouldn't leave a stale
	-- "IN COMBAT" indicator stuck visible with no countdown driving it back down.
	local active = combatUntil > tick()
	if skull then
		skull.Visible = active
		skull.MouseEnter:Connect(function()
			hovering = true
			updateLabelVisibility()
		end)
		skull.MouseLeave:Connect(function()
			hovering = false
			updateLabelVisibility()
		end)
	end
	updateLabelVisibility()
end
acquireGui()
-- _GUIs re-clones fresh from StarterGui on every respawn (same pattern as HUDManager/
-- SurvivalBarsClient's own GUI ref re-acquisition).
player.CharacterAdded:Connect(function() task.wait(0.25); acquireGui() end)

RE_CombatTagged.OnClientEvent:Connect(function(duration)
	combatUntil = tick() + (duration or 60)
	if skull then skull.Visible = true end
	updateLabelVisibility()
end)

RunService.Heartbeat:Connect(function()
	if not label then return end
	local remaining = combatUntil - tick()
	if remaining <= 0 then
		if skull and skull.Visible then skull.Visible = false end
		updateLabelVisibility()
		return
	end
	label.Text = string.format("IN COMBAT (%ds)", math.ceil(remaining))
end)

print("[CombatTagClient] ready")
