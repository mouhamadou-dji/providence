-- BoatClient -- design doc PART TWO. Handles the two interactive seats a player can occupy
-- once BoatManager grants them (the initial "E" take/man happens through the ship's own
-- ProximityPrompts server-side, see BoatManager.createShip -- this script only starts once
-- RE_BoatFeedback confirms control was actually granted): the wheel (WASD + Space to release)
-- and a cannon (mouse aim + click to fire).
local Players          = game:GetService("Players")
local RepStorage       = game:GetService("ReplicatedStorage")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local Remotes = RepStorage:WaitForChild("RemoteEvents")
local RE_ShipWheel    = Remotes:WaitForChild("RequestShipWheel")
local RE_ShipInput    = Remotes:WaitForChild("RequestShipInput")
local RE_FireCannon   = Remotes:WaitForChild("RequestFireCannon")
local RE_BoatFeedback = Remotes:WaitForChild("BoatFeedback")

local controlling = "none" -- "none" | "wheel" | "cannon"
local controlHull, controlCannon
local lastSentThrottle, lastSentTurn = 0, 0

local function keyDown(code) return UserInputService:IsKeyDown(code) end

RunService.Heartbeat:Connect(function()
	if controlling == "wheel" and controlHull and controlHull.Parent then
		local throttle = 0
		if keyDown(Enum.KeyCode.W) then throttle = 1
		elseif keyDown(Enum.KeyCode.S) then throttle = -1 end
		local turn = 0
		if keyDown(Enum.KeyCode.A) then turn = -1
		elseif keyDown(Enum.KeyCode.D) then turn = 1 end
		if throttle ~= lastSentThrottle or turn ~= lastSentTurn then
			RE_ShipInput:FireServer(controlHull, throttle, turn)
			lastSentThrottle, lastSentTurn = throttle, turn
		else
			-- Heartbeat resend every ~0.5s anyway as a keepalive -- BoatManager's helmsman
			-- watchdog releases the wheel if it hears nothing for 5s (disconnect/crash safety).
			if tick() % 0.5 < 1/60 then RE_ShipInput:FireServer(controlHull, throttle, turn) end
		end
	elseif controlling == "wheel" then
		controlling = "none"; controlHull = nil
	end
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if controlling == "wheel" and input.KeyCode == Enum.KeyCode.Space then
		if controlHull then
			RE_ShipInput:FireServer(controlHull, 0, 0)
			RE_ShipWheel:FireServer(controlHull, false)
		end
		controlling = "none"; controlHull = nil
	elseif controlling == "cannon" and input.UserInputType == Enum.UserInputType.MouseButton1 then
		if not controlCannon or not controlCannon.Parent then return end
		local camera = workspace.CurrentCamera
		local mousePos = UserInputService:GetMouseLocation()
		local unitRay = camera:ViewportPointToRay(mousePos.X, mousePos.Y)
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.FilterDescendantsInstances = { player.Character }
		local result = workspace:Raycast(unitRay.Origin, unitRay.Direction * 500, rp)
		local targetPoint = result and result.Position or (unitRay.Origin + unitRay.Direction * 300)
		local aimDir = (targetPoint - controlCannon.Position)
		if aimDir.Magnitude > 0.01 then
			RE_FireCannon:FireServer(controlCannon, aimDir.Unit)
		end
	end
end)

RE_BoatFeedback.OnClientEvent:Connect(function(data)
	if not data then return end
	if data.controlling == "wheel" then
		controlling = "wheel"; controlHull = data.hull; controlCannon = nil
	elseif data.controlling == "cannon" then
		controlling = "cannon"; controlCannon = data.cannonPart; controlHull = nil
	elseif data.controlling == "none" then
		if controlling == "wheel" and controlHull then RE_ShipInput:FireServer(controlHull, 0, 0) end
		controlling = "none"; controlHull = nil; controlCannon = nil
	end
end)

print("[BoatClient] Init")
