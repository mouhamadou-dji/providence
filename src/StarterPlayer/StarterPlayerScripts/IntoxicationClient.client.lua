-- IntoxicationClient -- design doc PART FOUR, Wine/Ale side effect. Deliberately COSMETIC
-- only (camera sway) -- does not touch WASD/MoveDirection at all. This codebase's movement
-- system has a well-documented history of multi-round bugs from exactly that kind of input
-- interference (see [[project_abyss]]'s crouch-freeze saga), so "reduced accuracy" is
-- represented here as a camera wobble instead of actually degrading movement input --
-- reads as tipsy without risking the fragile movement code. The real, mechanical penalty
-- (stamina regen) is applied server-side in StaminaManager off the same IntoxicatedUntil
-- attribute this sets, not here.
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local intoxCfg = Config.Intoxication

local Remotes = RepStorage:WaitForChild("RemoteEvents")
local RE_ApplyIntoxication = Remotes:WaitForChild("ApplyIntoxication")

local player = Players.LocalPlayer
local intoxicatedUntil = 0
local swayConn

local function startSway()
	if swayConn then return end
	swayConn = RunService.RenderStepped:Connect(function()
		if tick() >= intoxicatedUntil then
			swayConn:Disconnect(); swayConn = nil
			return
		end
		local camera = workspace.CurrentCamera
		if not camera then return end
		local t = tick()
		local yaw = math.sin(t * 1.3) * math.rad(intoxCfg.SwayAmplitude)
		local pitch = math.sin(t * 0.9 + 1) * math.rad(intoxCfg.SwayAmplitude * 0.5)
		camera.CFrame = camera.CFrame * CFrame.Angles(pitch, yaw, 0)
	end)
end

RE_ApplyIntoxication.OnClientEvent:Connect(function(data)
	if not data then return end
	intoxicatedUntil = math.max(intoxicatedUntil, tick() + (data.duration or 30))
	startSway()
end)

print("[IntoxicationClient] Init")
