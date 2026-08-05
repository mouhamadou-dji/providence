local Players      = game:GetService("Players")
local RepStorage   = game:GetService("ReplicatedStorage")
local RunService   = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local StarterGui   = game:GetService("StarterGui")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))

-- Preload every real sound asset once at session start. Freshly-created Sound instances
-- audibly lag on their first Play() while Roblox streams the asset in -- this is what read
-- as "parry whiff sound is delayed" (and would affect any other combat sound on its first
-- use per session). Warming the cache here means every later :Play() across every script
-- is instant instead of a one-shot stall.
task.spawn(function()
	local soundsRoot = RepStorage:FindFirstChild("_Sounds")
	if not soundsRoot then return end
	local toPreload = {}
	for _, inst in ipairs(soundsRoot:GetDescendants()) do
		if inst:IsA("Sound") and inst.SoundId ~= "" and inst.SoundId ~= "rbxassetid://0" then
			table.insert(toPreload, inst)
		end
	end
	if #toPreload > 0 then
		game:GetService("ContentProvider"):PreloadAsync(toPreload)
	end
end)

-- _GUIs is a direct child of StarterGui, so it auto-clones into PlayerGui on spawn.
-- ABYSSHud lives at PlayerGui._GUIs.HUD.ABYSSHud — reference it directly.
local abyssHud = playerGui
	:WaitForChild("_GUIs", 10)
	:WaitForChild("HUD", 10)
	:WaitForChild("ABYSSHud", 10)
if not abyssHud then
	warn("[HUDManager] ABYSSHud not found in PlayerGui._GUIs.HUD")
end

-- HP_BG (ZIndex=3) = HP fill, ST_BG (ZIndex=3) = stamina fill.
-- Instead of resizing (which distorted the bar art at low widths), a UIGradient
-- Transparency sequence masks off a portion of the always-full-size fill image -- the
-- art itself never resizes, only how much of it is revealed.
local hp_fill, st_fill
local hpFillNV, stFillNV

local barFrame = abyssHud:FindFirstChild("Frame")
if barFrame then
	hp_fill = barFrame:FindFirstChild("HP_BG")
	st_fill = barFrame:FindFirstChild("ST_BG")
end

-- Builds/reuses a UIGradient plus a child NumberValue ("FillFraction", 0..1) on `fill`.
-- TweenService can't tween an arbitrary Attribute directly -- confirmed live, it throws
-- "no property named 'FillFraction'" and silently never animates -- but tweening a real
-- NumberValue's Value property is a standard, fully-supported pattern.
local function setupFillGradient(fill)
	if not fill then return nil, nil end
	local grad = fill:FindFirstChildOfClass("UIGradient") or Instance.new("UIGradient")
	grad.Parent = fill
	local nv = fill:FindFirstChild("FillFraction")
	if not nv or not nv:IsA("NumberValue") then
		if nv then nv:Destroy() end
		nv = Instance.new("NumberValue")
		nv.Name = "FillFraction"
		nv.Value = 1
		nv.Parent = fill
	end
	return grad, nv
end

-- `fixedEdge` says which side of the bar stays visible as it drains: "right" hides from
-- the left inward (HP), "left" hides from the right inward (ST) -- matches the old
-- Size-based drain directions exactly.
local function applyFillGradient(grad, nv, fixedEdge)
	if not grad or not nv then return end
	local fraction = math.clamp(nv.Value, 0, 1)
	local hiddenFirst = fixedEdge == "right"
	local cutoff = math.clamp(hiddenFirst and (1 - fraction) or fraction, 0.001, 0.999)
	grad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, hiddenFirst and 1 or 0),
		NumberSequenceKeypoint.new(cutoff, hiddenFirst and 1 or 0),
		NumberSequenceKeypoint.new(cutoff, hiddenFirst and 0 or 1),
		NumberSequenceKeypoint.new(1, hiddenFirst and 0 or 1),
	})
end

local function wireFillGradient(fill, fixedEdge)
	local grad, nv = setupFillGradient(fill)
	if not grad then return nil end
	applyFillGradient(grad, nv, fixedEdge)
	nv:GetPropertyChangedSignal("Value"):Connect(function()
		applyFillGradient(grad, nv, fixedEdge)
	end)
	return nv
end

hpFillNV = wireFillGradient(hp_fill, "right")
stFillNV = wireFillGradient(st_fill, "left")

local function setHP(cur, maxVal)
	if not hpFillNV then return end
	local r = math.clamp(cur / math.max(maxVal, 1), 0, 1)
	TweenService:Create(hpFillNV, TweenInfo.new(0.15), { Value = r }):Play()
end

local function setST(cur, maxVal)
	if not stFillNV then return end
	local r = math.clamp(cur / math.max(maxVal, 1), 0, 1)
	TweenService:Create(stFillNV, TweenInfo.new(0.15), { Value = r }):Play()
end

-- Eclipse Moon
local ECLIPSE_ASSETS = {
	[0] = "",
	[1] = "rbxassetid://108241160322217",
	[2] = "rbxassetid://99460232916259",
	[3] = "rbxassetid://111950146788259",
	[4] = "rbxassetid://101372223637262",
	[5] = "rbxassetid://128652096286557",
}

local moonImg = Instance.new("ImageLabel")
moonImg.Name                   = "EclipseMoon"
moonImg.AnchorPoint            = Vector2.new(1, 1)
moonImg.Position               = UDim2.new(1, -16, 1, -16)
moonImg.Size                   = UDim2.new(0, 100, 0, 100)
moonImg.BackgroundTransparency = 1
moonImg.ScaleType              = Enum.ScaleType.Fit
moonImg.Image                  = ""
moonImg.Visible                = false
moonImg.Parent                 = abyssHud

-- Global message -- sits just above the HP/stamina bar frame (which is anchored at
-- (0.5,0), positioned at Y=0.740406334 scale, 145px tall). Bottom-anchored so the text
-- grows upward from a fixed baseline just above the bar.
local globalFrame = Instance.new("Frame")
globalFrame.Name                   = "GlobalMessage"
globalFrame.AnchorPoint            = Vector2.new(0.5, 1)
globalFrame.Position               = UDim2.new(0.5, 0, 0.740406334, -15)
globalFrame.Size                   = UDim2.new(0.5, 0, 0.06, 0)
globalFrame.BackgroundTransparency = 1
globalFrame.Visible                = false
globalFrame.Parent                 = abyssHud

local globalLbl = Instance.new("TextLabel")
globalLbl.Size                   = UDim2.new(1, 0, 1, 0)
globalLbl.BackgroundTransparency = 1
globalLbl.TextColor3             = Color3.fromRGB(255, 240, 200)
globalLbl.TextScaled             = true
globalLbl.Font                   = Enum.Font.GothamBold
globalLbl.Text                   = ""
globalLbl.Parent                 = globalFrame

-- HP polling (every 0.5s)
local hpAccum = 0
RunService.Heartbeat:Connect(function(dt)
	hpAccum += dt
	if hpAccum < 0.5 then return end
	hpAccum = 0
	local char = player.Character
	local hum  = char and char:FindFirstChildWhichIsA("Humanoid")
	if hum then setHP(hum.Health, hum.MaxHealth) end
end)

Remotes.UpdateHUD.OnClientEvent:Connect(function(data)
	if data.Stamina ~= nil then setST(data.Stamina, data.StaminaMax or 100) end
end)

Remotes.UpdateEclipseMoon.OnClientEvent:Connect(function(stage)
	local asset = ECLIPSE_ASSETS[stage] or ""
	moonImg.Image   = asset
	moonImg.Visible = stage > 0
	print("[HUDManager] Eclipse Moon -> Stage " .. tostring(stage))
end)

local SoundsFolder = RepStorage:WaitForChild("_Sounds", 5)
local UISounds = SoundsFolder and SoundsFolder:FindFirstChild("UI")

local function playUISound(name, volume)
	local snd = UISounds and UISounds:FindFirstChild(name)
	local id = snd and snd.SoundId
	if not id or id == "" or id == "rbxassetid://0" then return end
	local s = Instance.new("Sound")
	s.SoundId = id; s.Volume = volume or 0.6
	s.Parent = game:GetService("SoundService")
	s:Play()
	-- Destroy once actually finished, not on a fixed timer -- a fixed Debris delay can
	-- destroy the instance before a slower-to-stream asset ever finishes playing.
	local cleaned = false
	local function cleanup() if not cleaned then cleaned = true; if s.Parent then s:Destroy() end end end
	s.Ended:Once(cleanup)
	task.delay(8, cleanup)
end

-- One-shot ambience on world entry; HUDManager's top level only runs once per client
-- session (not per respawn), so this naturally fires exactly on join.
playUISound("Spawn_Ambience", 0.5)

local gThread = nil
Remotes.ShowGlobalMessage.OnClientEvent:Connect(function(message, color)
	if gThread then task.cancel(gThread); gThread = nil end
	globalFrame.Visible = true; globalLbl.Text = ""; globalLbl.TextTransparency = 0
	globalLbl.TextColor3 = color or Color3.fromRGB(255, 240, 200)
	playUISound("Global_Message", 0.6)
	gThread = task.spawn(function()
		for i = 1, #message do globalLbl.Text = message:sub(1, i); task.wait(0.04) end
		task.wait(4)
		TweenService:Create(globalLbl, TweenInfo.new(0.5), {TextTransparency = 1}):Play()
		task.wait(0.5); globalFrame.Visible = false; globalLbl.TextTransparency = 0; gThread = nil
	end)
end)

-- Re-acquire GUI refs after each respawn (_GUIs is cloned fresh from StarterGui)
local function reinitHUDRefs()
	task.wait(0.25)
	local _g = playerGui:FindFirstChild("_GUIs") or playerGui:WaitForChild("_GUIs", 5)
	if not _g then return end
	local _h = _g:FindFirstChild("HUD"); if not _h then return end
	abyssHud = _h:FindFirstChild("ABYSSHud"); if not abyssHud then return end
	local _bf = abyssHud:FindFirstChild("Frame")
	if _bf then
		hp_fill = _bf:FindFirstChild("HP_BG")
		st_fill = _bf:FindFirstChild("ST_BG")
	end
	hpFillNV = wireFillGradient(hp_fill, "right")
	stFillNV = wireFillGradient(st_fill, "left")
end
player.CharacterAdded:Connect(reinitHUDRefs)

print("[HUDManager] Init — HP/Stamina from ABYSSHud frame | hunger/eclipse/global ready")
