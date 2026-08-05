-- InjuryEffectsClient.client.lua
-- Renders the visual side of every Injury: Half/Full Blind overlays, Bad Vision's ramping
-- peripheral blur, Concussed camera jerk, and Insanity's hallucination events (fake figure,
-- face vanish -- chat distortion is server-side text, see ChatManager.applyLanguage).
-- All persistent injury state is read off Character Attributes (Injury_<Type>[/_Side/
-- _Severity]), mirrored by InjuryManager.applyVisuals -- same convention as CombatState/
-- Talent_<id>. Only the one-shot hallucination events arrive over a RemoteEvent.

local Players       = game:GetService("Players")
local RepStorage    = game:GetService("ReplicatedStorage")
local TweenService  = game:GetService("TweenService")
local RunService    = game:GetService("RunService")
local Lighting      = game:GetService("Lighting")

local localPlayer = Players.LocalPlayer
local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))

local playerGui = localPlayer:WaitForChild("PlayerGui")
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "InjuryEffectsGui"
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 50 -- above HUD, below any hard blocking modal
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

-- ── Half/Full Blind overlays ────────────────────────────────
local blindFrame = Instance.new("Frame")
blindFrame.Name = "BlindOverlay"
blindFrame.BackgroundColor3 = Color3.new(0,0,0)
blindFrame.BorderSizePixel = 0
blindFrame.BackgroundTransparency = 1
blindFrame.Size = UDim2.new(0.5,0,1,0)
blindFrame.Visible = false
blindFrame.Parent = screenGui

local function setBlind(halfSide, fullBlind)
	if fullBlind then
		blindFrame.Size = UDim2.new(1,0,1,0)
		blindFrame.Position = UDim2.new(0,0,0,0)
		blindFrame.BackgroundTransparency = 0
		blindFrame.Visible = true
	elseif halfSide == "Left" or halfSide == "Right" then
		blindFrame.Size = UDim2.new(0.5,0,1,0)
		blindFrame.Position = (halfSide == "Left") and UDim2.new(0,0,0,0) or UDim2.new(0.5,0,0,0)
		blindFrame.BackgroundTransparency = 0
		blindFrame.Visible = true
	else
		blindFrame.Visible = false
	end
end

-- ── Bad Vision: ramping peripheral darkening + a small genuine Lighting blur ─────────────
-- Honest limitation: Roblox's Lighting BlurEffect only blurs the WHOLE 3D viewport, there is
-- no per-region (edges-only) blur available without a custom shader. This approximates
-- "peripheral blur, clear center" with a vignette (4 edge-anchored gradient frames darkening
-- inward) plus a small overall BlurEffect that scales gently with severity -- reads as
-- "vision degrading" even though it isn't a literal edges-only blur.
local vignette = Instance.new("Frame")
vignette.Name = "BadVisionVignette"
vignette.BackgroundTransparency = 1
vignette.Size = UDim2.new(1,0,1,0)
vignette.Visible = false
vignette.Parent = screenGui

local function makeEdge(anchor, size, position, rotation)
	local f = Instance.new("Frame")
	f.BackgroundColor3 = Color3.new(0,0,0)
	f.BorderSizePixel = 0
	f.AnchorPoint = anchor
	f.Size = size
	f.Position = position
	f.Rotation = rotation or 0
	f.Parent = vignette
	local grad = Instance.new("UIGradient")
	grad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	grad.Rotation = 90
	grad.Parent = f
	return f, grad
end
local edgeTop    = makeEdge(Vector2.new(0,0), UDim2.new(1,0,0.22,0), UDim2.new(0,0,0,0))
local edgeBottom = makeEdge(Vector2.new(0,1), UDim2.new(1,0,0.22,0), UDim2.new(0,1,1,0))
local edgeLeft   = makeEdge(Vector2.new(0,0), UDim2.new(0.16,0,1,0), UDim2.new(0,0,0,0))
local edgeRight  = makeEdge(Vector2.new(1,0), UDim2.new(0.16,0,1,0), UDim2.new(1,1,0,0))
-- Bottom/left/right gradients need to darken toward their own outer edge, not top's direction
edgeBottom.Rotation = 180
local leftGrad = edgeLeft:FindFirstChildOfClass("UIGradient"); leftGrad.Rotation = 0
local rightGrad = edgeRight:FindFirstChildOfClass("UIGradient"); rightGrad.Rotation = 180

local badVisionBlur = Instance.new("BlurEffect")
badVisionBlur.Name = "BadVisionBlur"
badVisionBlur.Size = 0
badVisionBlur.Parent = Lighting

local function setBadVision(active, severity)
	vignette.Visible = active
	if not active then badVisionBlur.Size = 0; return end
	local t = math.clamp((severity or 0) / 100, 0, 1)
	for _, edge in ipairs({edgeTop, edgeBottom, edgeLeft, edgeRight}) do
		edge.BackgroundTransparency = 1 - (0.15 + 0.55 * t) -- ramps from a faint edge tint to a heavy dark border
	end
	badVisionBlur.Size = 6 * t -- small overall blur, scales with severity (see limitation note above)
end

-- ── Concussed: occasional small camera jerk ──────────────────────────
local concussedActive = false
task.spawn(function()
	while true do
		task.wait(math.random(4, 9))
		if concussedActive then
			local cam = workspace.CurrentCamera
			if cam then
				local jerk = CFrame.Angles(math.rad(math.random(-2,2)), math.rad(math.random(-2,2)), 0)
				local original = cam.CFrame
				cam.CFrame = original * jerk
				task.wait(0.08)
				if cam.CFrame == original * jerk then cam.CFrame = original end
			end
		end
	end
end)

-- ── Insanity hallucinations ───────────────────────────────────
local function spawnFakePlayerFigure(position)
	if not position then return end
	local desc = Instance.new("HumanoidDescription")
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R6)
	end)
	if not ok or not model then return end
	model.Name = "PhantomFigure" -- PLACEHOLDER_ASSET: PhantomFigureModel (uses a plain default R6 dummy for now)
	local animate = model:FindFirstChild("Animate"); if animate then animate:Destroy() end
	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then hum.PlatformStand = true end
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then part.CanCollide = false; part.CanQuery = false end
	end
	local hrp = model:FindFirstChild("HumanoidRootPart")
	if hrp then hrp.CFrame = CFrame.new(position) end
	model.Parent = workspace

	local parts = {}
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") or part:IsA("Decal") then table.insert(parts, part) end
	end
	for _, part in ipairs(parts) do part.Transparency = 1 end
	local fadeIn, fadeOut = {}, {}
	for _, part in ipairs(parts) do
		TweenService:Create(part, TweenInfo.new(0.5), {Transparency = 0.35}):Play()
	end
	task.delay(2.5, function()
		for _, part in ipairs(parts) do
			TweenService:Create(part, TweenInfo.new(0.5), {Transparency = 1}):Play()
		end
		task.delay(0.6, function() if model.Parent then model:Destroy() end end)
	end)
end

local function vanishFace(targetUserId)
	local target = Players:GetPlayerByUserId(targetUserId)
	local char = target and target.Character
	local head = char and char:FindFirstChild("Head")
	local face = head and head:FindFirstChild("face")
	if not face then return end
	local original = face.Transparency
	face.Transparency = 1
	task.delay(1, function() if face.Parent then face.Transparency = original end end)
end

Remotes.InsanityHallucination.OnClientEvent:Connect(function(payload)
	if payload.kind == "FakePlayerFigure" then
		spawnFakePlayerFigure(payload.position)
	elseif payload.kind == "FaceVanish" then
		vanishFace(payload.targetUserId)
	end
end)

-- ── BlindSight talent: red silhouettes of nearby entities while Full Blind ───────────────
local blindSightHighlights = {}
local function clearBlindSightHighlights()
	for _, hl in pairs(blindSightHighlights) do hl:Destroy() end
	blindSightHighlights = {}
end
task.spawn(function()
	while true do
		task.wait(0.5)
		local char = localPlayer.Character
		local hasFullBlind = char and char:GetAttribute("Injury_FullBlind") == true
		local hasBlindSight = char and char:GetAttribute("Talent_BlindSight") == true
		if hasFullBlind and hasBlindSight then
			clearBlindSightHighlights()
			local hrp = char:FindFirstChild("HumanoidRootPart")
			if hrp then
				for _, other in ipairs(Players:GetPlayers()) do
					if other ~= localPlayer and other.Character then
						local ohrp = other.Character:FindFirstChild("HumanoidRootPart")
						if ohrp and (ohrp.Position - hrp.Position).Magnitude <= 40 then
							local hl = Instance.new("Highlight")
							hl.FillColor = Color3.fromRGB(180,20,20)
							hl.OutlineColor = Color3.fromRGB(255,60,60)
							hl.FillTransparency = 0.5
							hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
							hl.Adornee = other.Character
							hl.Parent = other.Character
							blindSightHighlights[other] = hl
						end
					end
				end
			end
		elseif not hasFullBlind then
			clearBlindSightHighlights()
		end
	end
end)

-- ── Attribute watcher ───────────────────────────────────────────────────
local function hookCharacter(char)
	local function refresh()
		local halfBlind = char:GetAttribute("Injury_HalfBlind")
		local halfSide = char:GetAttribute("Injury_HalfBlind_Side")
		local fullBlind = char:GetAttribute("Injury_FullBlind")
		setBlind(halfBlind and halfSide or nil, fullBlind == true)

		local badVision = char:GetAttribute("Injury_BadVision")
		local severity = char:GetAttribute("Injury_BadVision_Severity")
		setBadVision(badVision == true, severity)

		concussedActive = char:GetAttribute("Injury_ConcussedMind") == true
	end
	refresh()
	for _, attr in ipairs({"Injury_HalfBlind","Injury_HalfBlind_Side","Injury_FullBlind","Injury_BadVision","Injury_BadVision_Severity","Injury_ConcussedMind"}) do
		char:GetAttributeChangedSignal(attr):Connect(refresh)
	end
end

localPlayer.CharacterAdded:Connect(hookCharacter)
if localPlayer.Character then hookCharacter(localPlayer.Character) end

print("[InjuryEffectsClient] Loaded")
