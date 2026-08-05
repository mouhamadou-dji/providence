-- PDAnnounceClient
-- Global Permanent Death activation cinematic: every player's screen darkens, a lore
-- line is revealed letter-by-letter with a per-letter sound cue, then it all fades back
-- out. Fired by LoreManager.activatePDE() via the PDGlobalAnnounce RemoteEvent -- this is
-- a whole-server event, not something tied to any one targeted player.
local Players        = game:GetService("Players")
local RepStorage     = game:GetService("ReplicatedStorage")
local TweenService   = game:GetService("TweenService")
local SoundService   = game:GetService("SoundService")

local player = Players.LocalPlayer
local pgui   = player:WaitForChild("PlayerGui")

local remF = RepStorage:WaitForChild("RemoteEvents", 10)
local pdAnnounceRE = remF and remF:WaitForChild("PDGlobalAnnounce", 10)
if not pdAnnounceRE then warn("[PDAnnounceClient] PDGlobalAnnounce remote missing"); return end

local DEFAULT_MESSAGE   = "In this world, there is a time one is forever unable to retrieve."
local LETTER_INTERVAL   = 0.06
local HOLD_DURATION     = 2.5
local FADE_DURATION     = 0.6
local DARKEN_TRANSPARENCY = 0.2
local BAR_TRANSPARENCY    = 0.15

local screenGui, darkenFrame, messageBar, barStroke, textLabel, letterSound

local function ensureGui()
	if screenGui and screenGui.Parent then return end
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "PDAnnounceGui"
	screenGui.IgnoreGuiInset = true
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 200 -- above HUD/notifications, below the mod blind override (10000)
	screenGui.Enabled = false
	screenGui.Parent = pgui

	darkenFrame = Instance.new("Frame")
	darkenFrame.Name = "Darken"
	darkenFrame.Size = UDim2.fromScale(1, 1)
	darkenFrame.BackgroundColor3 = Color3.new(0, 0, 0)
	darkenFrame.BackgroundTransparency = 1
	darkenFrame.BorderSizePixel = 0
	darkenFrame.Parent = screenGui

	messageBar = Instance.new("Frame")
	messageBar.Name = "MessageBar"
	messageBar.AnchorPoint = Vector2.new(0.5, 0.5)
	messageBar.Position = UDim2.fromScale(0.5, 0.72)
	messageBar.Size = UDim2.new(0.7, 0, 0, 70)
	messageBar.BackgroundColor3 = Color3.fromRGB(10, 9, 6)
	messageBar.BackgroundTransparency = 1
	messageBar.BorderSizePixel = 0
	messageBar.Parent = screenGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 2)
	corner.Parent = messageBar

	barStroke = Instance.new("UIStroke")
	barStroke.Color = Color3.fromRGB(78, 60, 30)
	barStroke.Thickness = 1
	barStroke.Transparency = 1
	barStroke.Parent = messageBar

	textLabel = Instance.new("TextLabel")
	textLabel.Name = "Message"
	textLabel.Size = UDim2.new(1, -32, 1, 0)
	textLabel.Position = UDim2.new(0, 16, 0, 0)
	textLabel.BackgroundTransparency = 1
	textLabel.Font = Enum.Font.Antique
	textLabel.TextColor3 = Color3.fromRGB(208, 194, 165)
	textLabel.TextTransparency = 1
	textLabel.TextSize = 24
	textLabel.TextWrapped = true
	textLabel.TextXAlignment = Enum.TextXAlignment.Center
	textLabel.TextYAlignment = Enum.TextYAlignment.Center
	textLabel.Text = ""
	textLabel.Parent = messageBar

	letterSound = Instance.new("Sound")
	letterSound.Name = "PDLetterSound"
	-- PLACEHOLDER_SOUND: PDAnnounceLetter -- replace with a real per-letter scribe/click cue
	letterSound.SoundId = "rbxassetid://0"
	letterSound.Volume = 0.4
	letterSound.Parent = SoundService
end

local playing = false
local function runAnnouncement(message)
	ensureGui()
	screenGui.Enabled = true
	textLabel.Text = ""

	TweenService:Create(darkenFrame, TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Sine), {BackgroundTransparency = DARKEN_TRANSPARENCY}):Play()
	TweenService:Create(messageBar, TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Sine), {BackgroundTransparency = BAR_TRANSPARENCY}):Play()
	TweenService:Create(barStroke, TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Sine), {Transparency = 0.4}):Play()
	task.wait(FADE_DURATION)

	textLabel.TextTransparency = 0
	for i = 1, #message do
		textLabel.Text = string.sub(message, 1, i)
		if string.sub(message, i, i) ~= " " then
			letterSound.TimePosition = 0
			letterSound:Play()
		end
		task.wait(LETTER_INTERVAL)
	end

	task.wait(HOLD_DURATION)

	TweenService:Create(darkenFrame, TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Sine), {BackgroundTransparency = 1}):Play()
	TweenService:Create(messageBar, TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Sine), {BackgroundTransparency = 1}):Play()
	TweenService:Create(barStroke, TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Sine), {Transparency = 1}):Play()
	TweenService:Create(textLabel, TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Sine), {TextTransparency = 1}):Play()
	task.wait(FADE_DURATION)

	screenGui.Enabled = false
end

pdAnnounceRE.OnClientEvent:Connect(function(message)
	if playing then return end
	playing = true
	local ok, err = pcall(runAnnouncement, type(message) == "string" and message or DEFAULT_MESSAGE)
	if not ok then warn("[PDAnnounceClient] error: " .. tostring(err)) end
	playing = false
end)

print("[PDAnnounceClient] ready")
