-- TalentAwakenClient -- design doc PART SIX. Stylized full-screen card shown when the server
-- fires TalentGranted (a real fresh grant only -- see TalentManager.assignTalent, never fired
-- on the CharacterAdded/respawn reapplication pass). Same queued-not-stacked, golden/dark
-- "lore-flavored" card convention already established by ModMenuClient's own notifGui, kept
-- as a fully separate GUI here since talent awakenings are rare/significant events deserving
-- their own bigger presentation, not routed through the routine ShowNotification pipeline.
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local pgui = player:WaitForChild("PlayerGui")

local Remotes = RepStorage:WaitForChild("RemoteEvents")
local RE_TalentGranted = Remotes:WaitForChild("TalentGranted")

local GOLD = Color3.fromRGB(198, 156, 55)
local PARCHM = Color3.fromRGB(224, 216, 196)
local DARK = Color3.fromRGB(8, 6, 4)

local screen = Instance.new("ScreenGui")
screen.Name = "TalentAwakenGui"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.DisplayOrder = 30
screen.Parent = pgui

local darken = Instance.new("Frame")
darken.Size = UDim2.new(1, 0, 1, 0)
darken.BackgroundColor3 = Color3.new(0, 0, 0)
darken.BackgroundTransparency = 1
darken.BorderSizePixel = 0
darken.ZIndex = 1
darken.Parent = screen

local card = Instance.new("Frame")
card.AnchorPoint = Vector2.new(0.5, 0.5)
card.Position = UDim2.new(0.5, 0, 0.42, 0)
card.Size = UDim2.new(0, 460, 0, 190)
card.BackgroundColor3 = DARK
card.BackgroundTransparency = 1
card.BorderSizePixel = 0
card.ZIndex = 2
card.Parent = screen
local cardStroke = Instance.new("UIStroke")
cardStroke.Color = GOLD
cardStroke.Thickness = 1.5
cardStroke.Transparency = 1
cardStroke.Parent = card

local header = Instance.new("TextLabel")
header.Size = UDim2.new(1, -20, 0, 22)
header.Position = UDim2.new(0, 10, 0, 18)
header.BackgroundTransparency = 1
header.Font = Enum.Font.Antique
header.TextSize = 16
header.TextColor3 = GOLD
header.TextTransparency = 1
header.TextStrokeTransparency = 1
header.Text = "A   T A L E N T   A W A K E N S"
header.ZIndex = 2
header.Parent = card

local divider = Instance.new("Frame")
divider.AnchorPoint = Vector2.new(0.5, 0)
divider.Position = UDim2.new(0.5, 0, 0, 46)
divider.Size = UDim2.new(0, 220, 0, 1)
divider.BackgroundColor3 = GOLD
divider.BackgroundTransparency = 1
divider.BorderSizePixel = 0
divider.ZIndex = 2
divider.Parent = card

local nameLabel = Instance.new("TextLabel")
nameLabel.Size = UDim2.new(1, -20, 0, 30)
nameLabel.Position = UDim2.new(0, 10, 0, 60)
nameLabel.BackgroundTransparency = 1
nameLabel.Font = Enum.Font.Antique
nameLabel.TextSize = 24
nameLabel.TextColor3 = PARCHM
nameLabel.TextTransparency = 1
nameLabel.TextStrokeTransparency = 1
nameLabel.Text = ""
nameLabel.ZIndex = 2
nameLabel.Parent = card

local descLabel = Instance.new("TextLabel")
descLabel.Size = UDim2.new(1, -40, 0, 60)
descLabel.Position = UDim2.new(0, 20, 0, 96)
descLabel.BackgroundTransparency = 1
descLabel.Font = Enum.Font.Garamond
descLabel.TextSize = 18
descLabel.TextColor3 = PARCHM
descLabel.TextTransparency = 1
descLabel.TextWrapped = true
descLabel.Text = ""
descLabel.ZIndex = 2
descLabel.Parent = card

local continueBtn = Instance.new("TextButton")
continueBtn.AnchorPoint = Vector2.new(0.5, 1)
continueBtn.Position = UDim2.new(0.5, 0, 1, -14)
continueBtn.Size = UDim2.new(0, 110, 0, 26)
continueBtn.BackgroundColor3 = Color3.fromRGB(20, 16, 10)
continueBtn.BackgroundTransparency = 1
continueBtn.BorderSizePixel = 0
continueBtn.Font = Enum.Font.GothamMedium
continueBtn.TextSize = 13
continueBtn.TextColor3 = PARCHM
continueBtn.TextTransparency = 1
continueBtn.AutoButtonColor = false
continueBtn.Text = "Continue"
continueBtn.ZIndex = 2
continueBtn.Parent = card
local btnStroke = Instance.new("UIStroke")
btnStroke.Color = GOLD
btnStroke.Transparency = 1
btnStroke.Parent = continueBtn

-- PLACEHOLDER_SOUND: talent_awaken_chime
local chime = Instance.new("Sound")
chime.SoundId = "rbxassetid://0"
chime.Volume = 0.6
chime.Parent = screen

local fadables = { darken, card, cardStroke, header, divider, nameLabel, descLabel, continueBtn, btnStroke }
local function setTransparency(alpha)
	for _, obj in ipairs(fadables) do
		if obj:IsA("TextLabel") or obj:IsA("TextButton") then
			obj.TextTransparency = alpha
			if obj.TextStrokeTransparency then obj.TextStrokeTransparency = math.max(alpha, 0.5) end
		elseif obj:IsA("UIStroke") then
			obj.Transparency = alpha
		else
			obj.BackgroundTransparency = (obj == darken) and math.min(1, alpha + 0.55) or alpha
		end
	end
end
setTransparency(1)

local queue = {}
local playing = false

local function showOne(data)
	nameLabel.Text = string.upper(tostring(data.id or "?"))
	descLabel.Text = tostring(data.description or "")
	if chime.SoundId ~= "" and chime.SoundId ~= "rbxassetid://0" then chime:Play() end

	local tin = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for a = 0, 20 do
		task.wait(0.5 / 20)
		setTransparency(1 - a / 20)
	end

	local dismissed = false
	local conn
	conn = continueBtn.MouseButton1Click:Connect(function() dismissed = true end)
	local waited = 0
	while not dismissed and waited < 6 do
		task.wait(0.1); waited += 0.1
	end
	conn:Disconnect()

	for a = 20, 0, -1 do
		task.wait(0.4 / 20)
		setTransparency(1 - a / 20)
	end
end

local function drain()
	if playing then return end
	playing = true
	while #queue > 0 do
		showOne(table.remove(queue, 1))
	end
	playing = false
end

RE_TalentGranted.OnClientEvent:Connect(function(data)
	if not data then return end
	table.insert(queue, data)
	task.spawn(drain)
end)

print("[TalentAwakenClient] Init")
