-- LightingMoodClient.client.lua -- subtle always-on screen vignette for the base dark-
-- medieval mood (design doc PART TWO). Same 4-edge Frame+UIGradient technique already used
-- by InjuryEffectsClient's Bad Vision and RageClient's edge pulse -- stacks fine alongside
-- those since it's just another independent Frame layered underneath.
local Players = game:GetService("Players")
local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "LightingMoodGui"
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 5 -- below every status-effect overlay (Sanity=~default, Rage=55, Feelings=52)
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

local function makeEdge(anchor, size, position, rotation, gradRotation)
	local f = Instance.new("Frame")
	f.BackgroundColor3 = Color3.new(0, 0, 0)
	f.BorderSizePixel = 0
	f.AnchorPoint = anchor
	f.Size = size
	f.Position = position
	f.Rotation = rotation or 0
	f.BackgroundTransparency = 0.82 -- subtle, constant -- not a status effect, just base mood
	f.Parent = screenGui
	local grad = Instance.new("UIGradient")
	grad.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,0),NumberSequenceKeypoint.new(1,1)})
	grad.Rotation = gradRotation
	grad.Parent = f
end

-- Same rotation values as InjuryEffectsClient's Bad Vision vignette (proven correct there --
-- gradient fades from opaque at the true screen edge to transparent toward center).
makeEdge(Vector2.new(0,0), UDim2.new(1,0,0.18,0), UDim2.new(0,0,0,0), 0, 90)
makeEdge(Vector2.new(0,1), UDim2.new(1,0,0.18,0), UDim2.new(0,1,1,0), 180, 90)
makeEdge(Vector2.new(0,0), UDim2.new(0.12,0,1,0), UDim2.new(0,0,0,0), 0, 0)
makeEdge(Vector2.new(1,0), UDim2.new(0.12,0,1,0), UDim2.new(1,1,0,0), 0, 180)

print("[LightingMoodClient] Loaded")
