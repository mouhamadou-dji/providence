-- RitualClient.client.lua
-- T key: if standing near an existing ritual circle, adds the currently-equipped hotbar
-- item to it; otherwise (holding a Ritual Stone) draws a new circle at your feet. Server
-- is authoritative on both (fires only, same "client fires, server validates" convention
-- as InputHandler) -- this script never blocks a press locally beyond the basic distance
-- check, since the server re-checks everything anyway.
-- Uses T, not the design doc's suggested E -- InputHandler already binds E to the fist
-- equip/unequip toggle, and a second competing E listener would silently double-fire both
-- actions on every press.

local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local UIS        = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))
local Config  = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))

local equippedSlot = nil
Remotes.UpdateInventory.OnClientEvent:Connect(function(_, equipped)
	equippedSlot = equipped
end)

local function nearestCircle()
	local char = localPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end
	local folder = workspace:FindFirstChild("RitualCircles")
	if not folder then return nil end
	local best, bestDist = nil, Config.Ritual.PlaceItemRange
	for _, part in ipairs(folder:GetChildren()) do
		if part:GetAttribute("IsRitualCircle") then
			local d = (part.Position - hrp.Position).Magnitude
			if d < bestDist then best = part; bestDist = d end
		end
	end
	return best
end

UIS.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode ~= Enum.KeyCode.T then return end
	local circle = nearestCircle()
	if circle then
		if equippedSlot then
			Remotes.RequestPlaceRitualItem:FireServer(circle, equippedSlot)
		end
	else
		Remotes.RequestPlaceRitualCircle:FireServer()
	end
end)

print("[RitualClient] Loaded — T to draw a circle (Ritual Stone) or place an equipped item in a nearby circle")
