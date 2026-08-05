-- RageClient.client.lua -- own-screen red pulse while in Rage mode (design doc PART THREE).
-- The red glow on the character itself and the scream sound are server-driven (a real
-- Highlight/Sound instance that replicates to nearby clients automatically) -- this only
-- covers the affected player's own screen-space cue, which by definition only they see.
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local localPlayer = Players.LocalPlayer
local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))

local playerGui = localPlayer:WaitForChild("PlayerGui")
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "RageEffectsGui"
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 55
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

-- Full-screen version (reverted from the thin edge-strip pass, then intensified):
-- a red wash over the WHOLE screen that stays faint in the middle, plus a much darker
-- near-black-red vignette pressing in from every border. Layer order: wash under vignette.
local centerWash = Instance.new("Frame")
centerWash.Name = "RageCenterWash"
centerWash.BackgroundColor3 = Color3.fromRGB(170, 0, 0)
centerWash.BorderSizePixel = 0
centerWash.Size = UDim2.new(1, 0, 1, 0)
centerWash.BackgroundTransparency = 1
centerWash.ZIndex = 1
centerWash.Parent = screenGui

local function makeEdge(anchor, size, position, gradRotation)
	local f = Instance.new("Frame")
	f.BackgroundColor3 = Color3.fromRGB(25, 0, 0) -- near-black red: border reads DARK, not bright
	f.BorderSizePixel = 0
	f.AnchorPoint = anchor
	f.Size = size
	f.Position = position
	f.BackgroundTransparency = 1
	f.ZIndex = 2
	f.Parent = screenGui
	local grad = Instance.new("UIGradient")
	grad.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,0),NumberSequenceKeypoint.new(1,1)})
	grad.Rotation = gradRotation
	grad.Parent = f
	return f
end
-- Thicker bands than the old strip pass so the darkness visibly crushes in from the borders.
local edgeTop    = makeEdge(Vector2.new(0,0), UDim2.new(1,0,0.42,0), UDim2.new(0,0,0,0), 90)
local edgeBottom = makeEdge(Vector2.new(0,1), UDim2.new(1,0,0.42,0), UDim2.new(0,0,1,0), -90)
local edgeLeft   = makeEdge(Vector2.new(0,0), UDim2.new(0.32,0,1,0), UDim2.new(0,0,0,0), 0)
local edgeRight  = makeEdge(Vector2.new(1,0), UDim2.new(0.32,0,1,0), UDim2.new(1,0,0,0), 180)
local edges = {edgeTop, edgeBottom, edgeLeft, edgeRight}

-- Lighting-level kick so the WHOLE frame (world included) reads rage, not just the overlay.
local Lighting = game:GetService("Lighting")
local rageCC = Instance.new("ColorCorrectionEffect")
rageCC.Name = "RageColorCorrection"
rageCC.Enabled = false
rageCC.TintColor = Color3.fromRGB(255, 210, 210)
rageCC.Saturation = -0.25
rageCC.Contrast = 0.12
rageCC.Parent = Lighting

local raging = false
task.spawn(function()
	local t = 0
	while true do
		local dt = task.wait(1/60)
		if raging then
			t += dt
			-- Double-thump heartbeat (lub-dub) instead of a smooth sine -- reads as a racing
			-- pulse. Beat period ~0.75s.
			local phase = (t % 0.75) / 0.75
			local thump = math.exp(-12 * phase) + 0.55 * math.exp(-12 * math.max(0, phase - 0.28))
			local beat = math.clamp(thump, 0, 1)
			-- Middle: red and only slightly visible (transparency ~0.9 resting, ~0.78 on thump).
			centerWash.BackgroundTransparency = 0.90 - 0.12 * beat
			-- Border: much darker and much more present (transparency ~0.35 resting, ~0.1 on thump).
			local edgeT = 0.35 - 0.25 * beat
			for _, e in ipairs(edges) do e.BackgroundTransparency = edgeT end
			rageCC.Enabled = true
			rageCC.TintColor = Color3.fromRGB(255, 210 - 25 * beat, 210 - 25 * beat)
		else
			t = 0
			centerWash.BackgroundTransparency = 1
			for _, e in ipairs(edges) do e.BackgroundTransparency = 1 end
			rageCC.Enabled = false
		end
	end
end)

Remotes.RageStateChanged.OnClientEvent:Connect(function(payload)
	if not payload then return end
	raging = payload.active == true
end)

-- In case this client script starts after rage was already active (e.g. late join edge
-- case), fall back to the replicated character Attribute RageManager also sets.
local function syncFromAttribute(char)
	if char:GetAttribute("RageActive") == true then raging = true end
	char:GetAttributeChangedSignal("RageActive"):Connect(function()
		raging = char:GetAttribute("RageActive") == true
	end)
end
if localPlayer.Character then syncFromAttribute(localPlayer.Character) end
localPlayer.CharacterAdded:Connect(syncFromAttribute)

print("[RageClient] Loaded")
