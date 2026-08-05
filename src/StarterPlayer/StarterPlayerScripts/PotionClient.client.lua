-- PotionClient.client.lua
-- Z key: use whatever potion is currently equipped on the hotbar. Server is fully
-- authoritative (channel timing, cancel-on-damage/move, consumption); this script only
-- plays the use animation/sound cue and shows a simple channel progress bar.
-- Uses Z, not the design doc's suggested F -- InputHandler already binds F to Parry/Block,
-- and a second competing F listener would fire both actions on every press.

local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local UIS        = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local localPlayer = Players.LocalPlayer
local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))

local playerGui = localPlayer:WaitForChild("PlayerGui")
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "PotionUseGui"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.Parent = playerGui

local barBg = Instance.new("Frame")
barBg.Size = UDim2.new(0, 220, 0, 18)
barBg.Position = UDim2.new(0.5, -110, 0.75, 0)
barBg.BackgroundColor3 = Color3.fromRGB(15,12,8)
barBg.BorderSizePixel = 0
barBg.Visible = false
barBg.Parent = screenGui
local barBgCorner = Instance.new("UICorner"); barBgCorner.CornerRadius = UDim.new(0,4); barBgCorner.Parent = barBg
local barStroke = Instance.new("UIStroke"); barStroke.Color = Color3.fromRGB(198,156,55); barStroke.Thickness = 1; barStroke.Parent = barBg

local barFill = Instance.new("Frame")
barFill.Size = UDim2.new(0, 0, 1, 0)
barFill.BackgroundColor3 = Color3.fromRGB(198,156,55)
barFill.BorderSizePixel = 0
barFill.Parent = barBg
local barFillCorner = Instance.new("UICorner"); barFillCorner.CornerRadius = UDim.new(0,4); barFillCorner.Parent = barFill

local label = Instance.new("TextLabel")
label.Size = UDim2.new(1,0,1,0)
label.BackgroundTransparency = 1
label.Font = Enum.Font.GothamBold
label.TextSize = 12
label.TextColor3 = Color3.fromRGB(230,220,200)
label.Parent = barBg

local activeTween = nil
local currentSound = nil

Remotes.PotionUseFeedback.OnClientEvent:Connect(function(data)
	if data.starting then
		local cfg = data
		label.Text = "Using..."
		barBg.Visible = true
		barFill.Size = UDim2.new(0,0,1,0)
		if activeTween then activeTween:Cancel() end
		activeTween = TweenService:Create(barFill, TweenInfo.new(cfg.useTime, Enum.EasingStyle.Linear), { Size = UDim2.new(1,0,1,0) })
		activeTween:Play()

		-- PLACEHOLDER_ANIMATION: potion_use / PLACEHOLDER_SOUND: potion_drink -- both IDs are
		-- currently "rbxassetid://0" in Config.Potions, so LoadAnimation/Sound below are safe
		-- no-ops until real assets are authored (same convention as every other PLACEHOLDER in
		-- this codebase -- 0/blank ids are skipped silently, never erroring).
		local char = localPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum and cfg.useAnimation and cfg.useAnimation ~= "" and cfg.useAnimation ~= "rbxassetid://0" then
			local animator = hum:FindFirstChildOfClass("Animator")
			if animator then
				local anim = Instance.new("Animation")
				anim.AnimationId = cfg.useAnimation
				local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
				if ok and track then track:Play() end
			end
		end
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and cfg.useSound and cfg.useSound ~= "" and cfg.useSound ~= "rbxassetid://0" then
			currentSound = Instance.new("Sound")
			currentSound.SoundId = cfg.useSound
			currentSound.Parent = hrp
			currentSound:Play()
		end
	else
		if activeTween then activeTween:Cancel(); activeTween = nil end
		if currentSound then currentSound:Stop(); currentSound:Destroy(); currentSound = nil end
		label.Text = tostring(data.message)
		barFill.Size = data.ok and UDim2.new(1,0,1,0) or UDim2.new(0,0,1,0)
		task.delay(1.2, function() barBg.Visible = false end)
	end
end)

UIS.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode ~= Enum.KeyCode.Z then return end
	Remotes.RequestUsePotion:FireServer()
end)

print("[PotionClient] Loaded — Z to use the equipped potion")
