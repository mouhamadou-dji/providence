-- BoatDeckClient -- design doc PART TWO, "Approach B". Confirmed live (BoatManager testing)
-- that a ship hull moved purely via anchored-Part CFrame assignment does NOT carry a standing
-- character horizontally in this engine version -- the character was left behind entirely at
-- normal sailing speed. This script is therefore the REAL mechanism that keeps players glued
-- to a moving deck: every time the server broadcasts a ship's new CFrame (~30Hz, see
-- BoatManager.maybeBroadcast), compute the world-space delta since the last broadcast and, if
-- the local character is currently standing on that ship's deck, apply the same delta to the
-- character's pivot.
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer

local Remotes = RepStorage:WaitForChild("RemoteEvents")
local RE_ShipCFrame = Remotes:WaitForChild("ShipCFrameUpdate")

local lastCFrame = {} -- [hull] = CFrame as of the last update

local function isStandingOnShip(hull)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return false end
	local shipModel = hull.Parent
	if not shipModel then return false end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { char }
	-- A little above the feet down through a little below -- covers normal standing plus a
	-- small hop, without picking up unrelated geometry far below deck level.
	local result = workspace:Raycast(hrp.Position, Vector3.new(0, -6, 0), rp)
	if not result then return false end
	return result.Instance:IsDescendantOf(shipModel)
end

RE_ShipCFrame.OnClientEvent:Connect(function(hull, newCFrame)
	if not hull or not hull.Parent then lastCFrame[hull] = nil; return end
	local old = lastCFrame[hull]
	lastCFrame[hull] = newCFrame
	if not old then return end -- first update for this hull -- nothing to diff against yet
	if not isStandingOnShip(hull) then return end
	local char = player.Character
	if not char then return end
	-- World-space rigid delta: newCFrame * old:Inverse(), applied on the LEFT of the
	-- character's current pivot -- NOT post-multiplied (a local-space post-multiply would
	-- apply the ship's translation rotated into the character's own facing direction, which
	-- is wrong whenever the character isn't facing the ship's forward axis).
	local delta = newCFrame * old:Inverse()
	char:PivotTo(delta * char:GetPivot())
end)

print("[BoatDeckClient] Init")
