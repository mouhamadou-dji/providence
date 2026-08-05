-- TailoringClient.client.lua -- design doc PART FOUR ("Squid Game cookie" path trace).
-- PLACEHOLDER_GUI: TailoringQTEFrame. Client tracks cursor-vs-path deviation and progress
-- along the path, determines the outcome locally, submits it (same trust model as the rest
-- of this codebase's cooperative minigames).
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

-- ── Garment selection UI ──────────────────────────────────────────────────────────────────
local selectGui = Instance.new("ScreenGui")
selectGui.Name = "TailoringSelectGui"; selectGui.ResetOnSpawn = false; selectGui.Enabled = false
selectGui.Parent = playerGui
local selectFrame = Instance.new("Frame")
selectFrame.AnchorPoint = Vector2.new(0.5,0.5); selectFrame.Position = UDim2.new(0.5,0,0.4,0)
selectFrame.Size = UDim2.new(0,240,0,180); selectFrame.BackgroundColor3 = Color3.fromRGB(18,14,10)
selectFrame.Parent = selectGui
do local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,8); c.Parent=selectFrame end
do local s=Instance.new("UIStroke"); s.Color=GOLD; s.Thickness=1; s.Parent=selectFrame end
local selectTitle = Instance.new("TextLabel")
selectTitle.Size = UDim2.new(1,-20,0,26); selectTitle.Position=UDim2.new(0,10,0,8)
selectTitle.BackgroundTransparency=1; selectTitle.Font=Enum.Font.Antique; selectTitle.TextSize=16
selectTitle.TextColor3=GOLD; selectTitle.Text="SELECT GARMENT"; selectTitle.TextXAlignment=Enum.TextXAlignment.Left
selectTitle.Parent = selectFrame
local selectList = Instance.new("ScrollingFrame")
selectList.Size = UDim2.new(1,-16,1,-42); selectList.Position=UDim2.new(0,8,0,38)
selectList.BackgroundTransparency=1; selectList.BorderSizePixel=0; selectList.ScrollBarThickness=3
selectList.CanvasSize=UDim2.new(0,0,0,0); selectList.AutomaticCanvasSize=Enum.AutomaticSize.Y
selectList.Parent = selectFrame
do local l=Instance.new("UIListLayout"); l.Padding=UDim.new(0,4); l.Parent=selectList end

local currentStationPart = nil
Remotes.TailoringOpenUI.OnClientEvent:Connect(function(data)
	if not data then return end
	currentStationPart = data.stationPart
	selectList:ClearAllChildren()
	for _, garmentName in ipairs(data.recipes or {}) do
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1,0,0,30); btn.BackgroundColor3 = Color3.fromRGB(28,22,14)
		btn.Font = Enum.Font.Gotham; btn.TextSize = 14; btn.TextColor3 = PARCHM; btn.AutoButtonColor=false
		btn.Text = garmentName
		btn.Parent = selectList
		do local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,4); c.Parent=btn end
		btn.MouseButton1Click:Connect(function()
			selectGui.Enabled = false
			Remotes.RequestStartTailoring:FireServer(currentStationPart, garmentName)
		end)
	end
	selectGui.Enabled = true
end)

-- ── Path-trace QTE ────────────────────────────────────────────────────────────────
local qteGui = Instance.new("ScreenGui")
qteGui.Name = "TailoringQTEGui"; qteGui.ResetOnSpawn = false; qteGui.Enabled = false
qteGui.Parent = playerGui

local CANVAS_SIZE = 320
local canvas = Instance.new("Frame")
canvas.AnchorPoint = Vector2.new(0.5,0.5); canvas.Position = UDim2.new(0.5,0,0.45,0)
canvas.Size = UDim2.new(0,CANVAS_SIZE,0,CANVAS_SIZE); canvas.BackgroundColor3 = Color3.fromRGB(20,16,12)
canvas.BorderSizePixel = 0; canvas.Parent = qteGui
do local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,8); c.Parent=canvas end
do local s=Instance.new("UIStroke"); s.Color=GOLD; s.Thickness=1; s.Parent=canvas end

local hintLbl = Instance.new("TextLabel")
hintLbl.AnchorPoint = Vector2.new(0.5,0); hintLbl.Position = UDim2.new(0.5,0,1,10)
hintLbl.Size = UDim2.new(0,300,0,24); hintLbl.BackgroundTransparency = 1
hintLbl.Font = Enum.Font.Gotham; hintLbl.TextSize = 14; hintLbl.TextColor3 = PARCHM
hintLbl.Text = "Hold LMB and trace the outline"; hintLbl.Parent = canvas

local timeBarTrack = Instance.new("Frame")
timeBarTrack.AnchorPoint = Vector2.new(0.5,0); timeBarTrack.Position = UDim2.new(0.5,0,1,40)
timeBarTrack.Size = UDim2.new(0,300,0,6); timeBarTrack.BackgroundColor3 = Color3.fromRGB(30,24,16)
timeBarTrack.BorderSizePixel = 0; timeBarTrack.Parent = canvas
local timeBarFill = Instance.new("Frame")
timeBarFill.Size = UDim2.new(1,0,1,0); timeBarFill.BackgroundColor3 = GOLD; timeBarFill.BorderSizePixel = 0
timeBarFill.Parent = timeBarTrack

local segFrames = {}
local function clearSegs() for _,f in ipairs(segFrames) do f:Destroy() end; segFrames = {} end
local function pxPos(pt) return Vector2.new(pt.X * CANVAS_SIZE, pt.Y * CANVAS_SIZE) end

local function buildPath(points)
	clearSegs()
	local cum = { 0 }
	for i = 1, #points - 1 do
		local a, b = pxPos(points[i]), pxPos(points[i+1])
		local len = (b - a).Magnitude
		cum[i+1] = cum[i] + len
		local mid = (a + b) / 2
		local angle = math.atan2(b.Y - a.Y, b.X - a.X)
		local seg = Instance.new("Frame")
		seg.AnchorPoint = Vector2.new(0.5, 0.5)
		seg.Position = UDim2.new(0, mid.X, 0, mid.Y)
		seg.Size = UDim2.new(0, len, 0, 4)
		seg.Rotation = math.deg(angle)
		seg.BackgroundColor3 = Color3.fromRGB(160, 40, 40)
		seg.BorderSizePixel = 0
		seg.Parent = canvas
		table.insert(segFrames, seg)
	end
	return cum
end

local cursorDot = Instance.new("Frame")
cursorDot.AnchorPoint = Vector2.new(0.5,0.5); cursorDot.Size = UDim2.new(0,10,0,10)
cursorDot.BackgroundColor3 = Color3.fromRGB(230,225,210); cursorDot.ZIndex = 3; cursorDot.Visible = false
do local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(1,0); c.Parent=cursorDot end
cursorDot.Parent = canvas

local qteActive = false
local qteConns = {}
local currentStationQTEPart = nil
local function clearQTEConns() for _,c in ipairs(qteConns) do c:Disconnect() end; qteConns = {} end

-- Closest point on segment [a,b] to point p, returns (distance, arcLenAtClosest given cumA/cumB)
local function closestOnSegment(p, a, b, cumA, cumB)
	local ab = b - a
	local len2 = ab:Dot(ab)
	local t = len2 > 0 and math.clamp((p - a):Dot(ab) / len2, 0, 1) or 0
	local closest = a + ab * t
	return (p - closest).Magnitude, cumA + (cumB - cumA) * t
end

Remotes.TailoringStart.OnClientEvent:Connect(function(data)
	if not data then return end
	currentStationQTEPart = data.stationPart
	qteActive = true
	clearQTEConns()
	qteGui.Enabled = true
	hintLbl.Text = "Hold LMB and trace the outline"
	local points = data.shape.points
	local tolerance = data.shape.tolerance
	local cum = buildPath(points)
	local totalLen = cum[#cum]
	local maxProgress = 0
	local t0 = tick()
	local timeLimit = data.timeLimit or 30
	local holding = false

	local function finish(outcome)
		if not qteActive then return end
		qteActive = false
		clearQTEConns()
		playSound(outcome == "Success" and "qte_success" or "qte_fail")
		Remotes.TailoringSubmitResult:FireServer(currentStationQTEPart, outcome)
	end

	local rsConn = RunService.RenderStepped:Connect(function()
		if not qteActive then return end
		local elapsed = tick() - t0
		timeBarFill.Size = UDim2.new(math.clamp(1 - elapsed / timeLimit, 0, 1), 0, 1, 0)
		if elapsed > timeLimit then finish("Timeout"); return end
		if not holding then return end

		local mouse = UIS:GetMouseLocation()
		local topLeft = canvas.AbsolutePosition
		local local2 = Vector2.new(mouse.X - topLeft.X, mouse.Y - topLeft.Y)
		cursorDot.Position = UDim2.new(0, local2.X, 0, local2.Y)

		local bestDist, bestArc = math.huge, 0
		for i = 1, #points - 1 do
			local a, b = pxPos(points[i]), pxPos(points[i+1])
			local d, arc = closestOnSegment(local2, a, b, cum[i], cum[i+1])
			if d < bestDist then bestDist = d; bestArc = arc end
		end
		if bestDist > tolerance then
			finish("Rip")
			return
		end
		if bestArc > maxProgress then maxProgress = bestArc end
		if maxProgress >= totalLen * 0.98 then
			finish("Success")
		end
	end)
	table.insert(qteConns, rsConn)

	local downConn = UIS.InputBegan:Connect(function(input, gpe)
		if not qteActive then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			holding = true; cursorDot.Visible = true
		end
	end)
	local upConn = UIS.InputEnded:Connect(function(input, gpe)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			holding = false
		end
	end)
	table.insert(qteConns, downConn)
	table.insert(qteConns, upConn)
end)

Remotes.TailoringResult.OnClientEvent:Connect(function(data)
	if not data then return end
	hintLbl.Text = data.outcome == "Success" and "Success!" or (data.outcome == "Rip" and "The fabric ripped!" or "Out of time!")
	hintLbl.TextColor3 = data.outcome == "Success" and Color3.fromRGB(90,200,90) or Color3.fromRGB(200,80,80)
	cursorDot.Visible = false
	task.delay(1.2, function() qteGui.Enabled = false end)
end)

print("[TailoringClient] Loaded")
