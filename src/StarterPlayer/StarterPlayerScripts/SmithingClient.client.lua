-- SmithingClient.client.lua -- design doc PART FIVE. The QTE sequence itself is rendered by
-- the existing QTEClient (Tier2 SequenceInput, reused as-is); this only handles weapon
-- selection and the hammer/spark cue between QTEs. PLACEHOLDER_ANIMATION: forge_hammer,
-- PLACEHOLDER_ASSET: ForgeSparks.
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))
local playerGui = localPlayer:WaitForChild("PlayerGui")

local GOLD = Color3.fromRGB(198,156,55)
local PARCHM = Color3.fromRGB(220,215,200)

local selectGui = Instance.new("ScreenGui")
selectGui.Name = "SmithingSelectGui"; selectGui.ResetOnSpawn = false; selectGui.Enabled = false
selectGui.Parent = playerGui
local selectFrame = Instance.new("Frame")
selectFrame.AnchorPoint = Vector2.new(0.5,0.5); selectFrame.Position = UDim2.new(0.5,0,0.4,0)
selectFrame.Size = UDim2.new(0,260,0,220); selectFrame.BackgroundColor3 = Color3.fromRGB(18,14,10)
selectFrame.Parent = selectGui
do local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,8); c.Parent=selectFrame end
do local s=Instance.new("UIStroke"); s.Color=GOLD; s.Thickness=1; s.Parent=selectFrame end
local selectTitle = Instance.new("TextLabel")
selectTitle.Size = UDim2.new(1,-20,0,26); selectTitle.Position=UDim2.new(0,10,0,8)
selectTitle.BackgroundTransparency=1; selectTitle.Font=Enum.Font.Antique; selectTitle.TextSize=16
selectTitle.TextColor3=GOLD; selectTitle.Text="SELECT WEAPON"; selectTitle.TextXAlignment=Enum.TextXAlignment.Left
selectTitle.Parent = selectFrame
local selectList = Instance.new("ScrollingFrame")
selectList.Size = UDim2.new(1,-16,1,-42); selectList.Position=UDim2.new(0,8,0,38)
selectList.BackgroundTransparency=1; selectList.BorderSizePixel=0; selectList.ScrollBarThickness=3
selectList.CanvasSize=UDim2.new(0,0,0,0); selectList.AutomaticCanvasSize=Enum.AutomaticSize.Y
selectList.Parent = selectFrame
do local l=Instance.new("UIListLayout"); l.Padding=UDim.new(0,4); l.Parent=selectList end

local currentForgePart = nil
Remotes.SmithingOpenUI.OnClientEvent:Connect(function(data)
	if not data then return end
	currentForgePart = data.forgePart
	selectList:ClearAllChildren()
	for _, weaponName in ipairs(data.recipes or {}) do
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1,0,0,30); btn.BackgroundColor3 = Color3.fromRGB(28,22,14)
		btn.Font = Enum.Font.Gotham; btn.TextSize = 14; btn.TextColor3 = PARCHM; btn.AutoButtonColor=false
		btn.Text = weaponName
		btn.Parent = selectList
		do local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,4); c.Parent=btn end
		btn.MouseButton1Click:Connect(function()
			selectGui.Enabled = false
			Remotes.RequestStartSmithing:FireServer(currentForgePart, weaponName)
		end)
	end
	selectGui.Enabled = true
end)

-- ── Hammer-beat cue between QTEs ────────────────────────────────────────────
local hammerGui = Instance.new("ScreenGui")
hammerGui.Name = "SmithingHammerGui"; hammerGui.ResetOnSpawn = false; hammerGui.Enabled = false
hammerGui.Parent = playerGui
local stepLbl = Instance.new("TextLabel")
stepLbl.AnchorPoint = Vector2.new(0.5,0.5); stepLbl.Position = UDim2.new(0.5,0,0.3,0)
stepLbl.Size = UDim2.new(0,200,0,40); stepLbl.BackgroundTransparency = 1
stepLbl.Font = Enum.Font.Antique; stepLbl.TextSize = 22; stepLbl.TextColor3 = GOLD
stepLbl.Parent = hammerGui

local function playAnimPlaceholder(char)
	-- PLACEHOLDER_ANIMATION: forge_hammer -- no real clip authored yet, matches this
	-- codebase's rbxassetid://0 skip-silently convention (see e.g. RageManager's playScream).
end

local function spawnSparks(char)
	-- PLACEHOLDER_ASSET: ForgeSparks -- simple particle burst stand-in until a real asset exists.
	local hrp = char and char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
	local anchor = Instance.new("Part")
	anchor.Anchored=true; anchor.CanCollide=false; anchor.CanQuery=false; anchor.Transparency=1
	anchor.Size=Vector3.new(0.2,0.2,0.2); anchor.CFrame=hrp.CFrame*CFrame.new(0,0,-2); anchor.Parent=workspace
	local e = Instance.new("ParticleEmitter")
	e.Color = ColorSequence.new(Color3.fromRGB(255,170,60))
	e.Size = NumberSequence.new(0.2); e.Speed = NumberRange.new(6,12); e.Lifetime = NumberRange.new(0.2,0.4)
	e.SpreadAngle = Vector2.new(60,60); e.Rate = 0; e.Parent = anchor
	e:Emit(14)
	game:GetService("Debris"):AddItem(anchor, 0.6)
end

Remotes.SmithingHammerBeat.OnClientEvent:Connect(function(data)
	if not data then return end
	hammerGui.Enabled = true
	stepLbl.Text = "STRIKE " .. data.step .. " / " .. data.total
	playAnimPlaceholder(localPlayer.Character)
	spawnSparks(localPlayer.Character)
	task.delay(0.7, function() hammerGui.Enabled = false end)
end)

Remotes.SmithingComplete.OnClientEvent:Connect(function(data)
	if not data then return end
	hammerGui.Enabled = false
end)

print("[SmithingClient] Loaded")
