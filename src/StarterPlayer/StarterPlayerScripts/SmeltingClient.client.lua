-- SmeltingClient.client.lua -- design doc PART THREE. PLACEHOLDER_GUI: SmeltingQTEFrame.
-- Client determines Success/Partial/Fail locally (same trust model as QTEClient's
-- GreenBar/CircleClose -- cooperative flavor minigame, server only sanity-checks timing).
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UIS        = game:GetService("UserInputService")
local SoundService = game:GetService("SoundService")

local localPlayer = Players.LocalPlayer
local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))
local playerGui = localPlayer:WaitForChild("PlayerGui")

local GOLD = Color3.fromRGB(198,156,55)
local PARCHM = Color3.fromRGB(220,215,200)

local SoundsUI = RepStorage:FindFirstChild("_Sounds") and RepStorage._Sounds:FindFirstChild("UI")
local function playSound(name)
	local snd = SoundsUI and SoundsUI:FindFirstChild(name)
	local id = snd and snd.SoundId
	if not id or id=="" or id=="rbxassetid://0" then return end
	local s = Instance.new("Sound"); s.SoundId=id; s.Volume=0.5; s.Parent=SoundService; s:Play()
	s.Ended:Once(function() s:Destroy() end); task.delay(6, function() if s.Parent then s:Destroy() end end)
end

-- ── Ore selection UI ──────────────────────────────────────────────────────────────────
local selectGui = Instance.new("ScreenGui")
selectGui.Name = "SmeltingSelectGui"; selectGui.ResetOnSpawn = false; selectGui.Enabled = false
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
selectTitle.TextColor3=GOLD; selectTitle.Text="SELECT ORE"; selectTitle.TextXAlignment=Enum.TextXAlignment.Left
selectTitle.Parent = selectFrame
local selectList = Instance.new("ScrollingFrame")
selectList.Size = UDim2.new(1,-16,1,-42); selectList.Position=UDim2.new(0,8,0,38)
selectList.BackgroundTransparency=1; selectList.BorderSizePixel=0; selectList.ScrollBarThickness=3
selectList.CanvasSize=UDim2.new(0,0,0,0); selectList.AutomaticCanvasSize=Enum.AutomaticSize.Y
selectList.Parent = selectFrame
do local l=Instance.new("UIListLayout"); l.Padding=UDim.new(0,4); l.Parent=selectList end

local currentSmelterPart = nil
Remotes.SmeltingOpenUI.OnClientEvent:Connect(function(data)
	if not data then return end
	currentSmelterPart = data.smelterPart
	selectList:ClearAllChildren()
	for _, ore in ipairs(data.ores or {}) do
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1,0,0,30); btn.BackgroundColor3 = Color3.fromRGB(28,22,14)
		btn.Font = Enum.Font.Gotham; btn.TextSize = 14; btn.TextColor3 = PARCHM; btn.AutoButtonColor=false
		btn.Text = ore.itemName .. " (x" .. ore.count .. ")"
		btn.Parent = selectList
		do local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,4); c.Parent=btn end
		btn.MouseButton1Click:Connect(function()
			selectGui.Enabled = false
			Remotes.RequestStartSmelt:FireServer(currentSmelterPart, ore.itemName)
		end)
	end
	selectGui.Enabled = true
end)

-- ── Bouncing-bar QTE ───────────────────────────────────────────────────────────────
local qteGui = Instance.new("ScreenGui")
qteGui.Name = "SmeltingQTEGui"; qteGui.ResetOnSpawn = false; qteGui.Enabled = false
qteGui.Parent = playerGui

local TRACK_H, TRACK_W = 400, 60
local track = Instance.new("Frame")
track.AnchorPoint = Vector2.new(0.5,0.5); track.Position = UDim2.new(0.5,0,0.5,0)
track.Size = UDim2.new(0,TRACK_W,0,TRACK_H); track.BackgroundColor3 = Color3.fromRGB(120,20,20)
track.BorderSizePixel = 0; track.ClipsDescendants = false; track.Parent = qteGui
do local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,6); c.Parent=track end

local greenZone = Instance.new("Frame")
greenZone.BackgroundColor3 = Color3.fromRGB(70,190,70); greenZone.BorderSizePixel = 0
greenZone.Size = UDim2.new(1,0,0,80); greenZone.Parent = track

local whiteBar = Instance.new("Frame")
whiteBar.BackgroundColor3 = Color3.fromRGB(230,225,210); whiteBar.BorderSizePixel = 0
whiteBar.Size = UDim2.new(1,8,0,8); whiteBar.Position = UDim2.new(0,-4,0,0); whiteBar.ZIndex = 2
whiteBar.Parent = track

local hintLbl = Instance.new("TextLabel")
hintLbl.AnchorPoint = Vector2.new(0.5,0); hintLbl.Position = UDim2.new(0.5,0,1,10)
hintLbl.Size = UDim2.new(0,260,0,24); hintLbl.BackgroundTransparency = 1
hintLbl.Font = Enum.Font.Gotham; hintLbl.TextSize = 14; hintLbl.TextColor3 = PARCHM
hintLbl.Text = "Press SPACE to stop the bar"; hintLbl.Parent = track

local qteActive = false
local qteConns = {}
local currentSmelterQTEPart = nil
local function clearQTEConns() for _,c in ipairs(qteConns) do c:Disconnect() end; qteConns = {} end

local function bounce(t, speed, range)
	if range <= 0 then return 0 end
	local x = (t * speed) % (2 * range)
	return range - math.abs(x - range)
end

Remotes.SmeltingQTEStart.OnClientEvent:Connect(function(data)
	if not data then return end
	currentSmelterQTEPart = data.smelterPart
	qteActive = true
	clearQTEConns()
	qteGui.Enabled = true
	greenZone.Size = UDim2.new(1, 0, 0, data.greenZoneWidth)
	local greenRange = TRACK_H - data.greenZoneWidth
	local barRange = TRACK_H - 8
	local t0 = tick()
	local outcome = nil

	local rsConn = RunService.RenderStepped:Connect(function()
		if not qteActive then return end
		local t = tick() - t0
		local gy = bounce(t, data.greenZoneSpeed, greenRange)
		local by = bounce(t, data.whiteBarSpeed, barRange)
		greenZone.Position = UDim2.new(0, 0, 0, gy)
		whiteBar.Position = UDim2.new(0, -4, 0, by)
		if t > 10 then
			outcome = "Fail"
			qteActive = false
			clearQTEConns()
			Remotes.SmeltingQTESubmit:FireServer(currentSmelterQTEPart, outcome)
		end
	end)
	table.insert(qteConns, rsConn)

	local inputConn = UIS.InputBegan:Connect(function(input, gpe)
		if not qteActive then return end
		if input.KeyCode ~= Enum.KeyCode.Space then return end
		local t = tick() - t0
		local gy = bounce(t, data.greenZoneSpeed, greenRange)
		local by = bounce(t, data.whiteBarSpeed, barRange)
		-- Bar (white, effectively a point at `by`, 8px tall) vs green zone [gy, gy+width] vs
		-- red track [0, TRACK_H] (always true -- the bar can never leave the track).
		if by >= gy and by <= gy + data.greenZoneWidth then
			outcome = "Success"
		else
			outcome = "Partial"
		end
		qteActive = false
		clearQTEConns()
		Remotes.SmeltingQTESubmit:FireServer(currentSmelterQTEPart, outcome)
	end)
	table.insert(qteConns, inputConn)
end)

Remotes.SmeltingQTEResult.OnClientEvent:Connect(function(data)
	if not data then return end
	hintLbl.Text = data.outcome == "Success" and "Success!" or (data.outcome == "Partial" and "Partial success" or "Failed -- ore lost")
	hintLbl.TextColor3 = data.outcome == "Success" and Color3.fromRGB(90,200,90)
		or (data.outcome == "Partial" and Color3.fromRGB(200,180,60) or Color3.fromRGB(200,80,80))
	playSound(data.outcome == "Success" and "smelting_success" or (data.outcome=="Partial" and "smelting_partial" or "qte_fail"))
	task.delay(1.2, function() qteGui.Enabled = false end)
end)

print("[SmeltingClient] Loaded")
