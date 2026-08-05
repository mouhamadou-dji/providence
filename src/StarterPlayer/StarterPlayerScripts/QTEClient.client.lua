-- QTEClient.client.lua
-- PLACEHOLDER_GUI: QTE_Sequence / QTE_MonkeyType / QTE_GreenBar / QTE_CircleClose
-- Renders all 5 QTE tiers driven by QTEManager. Built at runtime (same convention as
-- ClashClient) rather than editing the empty StarterGui._GUIs.QTE placeholder folder.
local Players     = game:GetService("Players")
local RepStorage  = game:GetService("ReplicatedStorage")
local UIS         = game:GetService("UserInputService")
local RunService  = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")

local reFolder       = RepStorage:WaitForChild("RemoteEvents", 10)
local RE_QTEStart    = reFolder:WaitForChild("QTEStart", 10)
local RE_QTESubmit   = reFolder:WaitForChild("QTESubmitResult", 5)
local RE_QTEOutcome  = reFolder:WaitForChild("QTEOutcome", 5)

local SoundsUI = RepStorage:FindFirstChild("_Sounds") and RepStorage._Sounds:FindFirstChild("UI")
local function playUISound(name)
    local snd = SoundsUI and SoundsUI:FindFirstChild(name)
    local id = snd and snd.SoundId
    if not id or id == "" or id == "rbxassetid://0" then return end
    local s = Instance.new("Sound")
    s.SoundId = id; s.Volume = 0.5; s.Parent = SoundService
    s:Play()
    local cleaned = false
    local function cleanup() if not cleaned then cleaned = true; if s.Parent then s:Destroy() end end end
    s.Ended:Once(cleanup)
    task.delay(6, cleanup)
end

-- ── GUI shell ─────────────────────────────────────────────────────────────────
local gui = Instance.new("ScreenGui")
gui.Name = "QTEGui"; gui.ResetOnSpawn = false; gui.Enabled = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local frame = Instance.new("Frame")
frame.AnchorPoint = Vector2.new(0.5, 0.5)
frame.Position = UDim2.new(0.5, 0, 0.78, 0)
frame.Size = UDim2.new(0, 440, 0, 150)
frame.BackgroundColor3 = Color3.fromRGB(12, 10, 8)
frame.BackgroundTransparency = 0.1
frame.BorderSizePixel = 0
frame.Parent = gui
do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 8); c.Parent = frame end
do local s = Instance.new("UIStroke"); s.Color = Color3.fromRGB(198, 156, 55); s.Thickness = 1; s.Parent = frame end

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1, -20, 0, 26)
titleLbl.Position = UDim2.new(0, 10, 0, 8)
titleLbl.BackgroundTransparency = 1
titleLbl.Font = Enum.Font.GothamBold
titleLbl.TextSize = 16
titleLbl.TextColor3 = Color3.fromRGB(198, 156, 55)
titleLbl.Text = "FOCUS"
titleLbl.Parent = frame

local bodyFrame = Instance.new("Frame")
bodyFrame.Size = UDim2.new(1, -30, 1, -70)
bodyFrame.Position = UDim2.new(0, 15, 0, 38)
bodyFrame.BackgroundTransparency = 1
bodyFrame.Parent = frame

local timeBarTrack = Instance.new("Frame")
timeBarTrack.Size = UDim2.new(1, -20, 0, 6)
timeBarTrack.Position = UDim2.new(0, 10, 1, -16)
timeBarTrack.BackgroundColor3 = Color3.fromRGB(30, 24, 16)
timeBarTrack.BorderSizePixel = 0
timeBarTrack.Parent = frame
do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 3); c.Parent = timeBarTrack end
local timeBarFill = Instance.new("Frame")
timeBarFill.Size = UDim2.new(1, 0, 1, 0)
timeBarFill.BackgroundColor3 = Color3.fromRGB(198, 156, 55)
timeBarFill.BorderSizePixel = 0
timeBarFill.Parent = timeBarTrack
do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 3); c.Parent = timeBarFill end

local active = false
local activeInstanceId = nil
local activeConns = {}
local function clearConns()
    for _, c in ipairs(activeConns) do c:Disconnect() end
    activeConns = {}
end
local function clearBody()
    bodyFrame:ClearAllChildren()
end

local function submitResult(success)
    if not active then return end
    active = false
    clearConns()
    if RE_QTESubmit then RE_QTESubmit:FireServer(activeInstanceId, success) end
    playUISound(success and "qte_success" or "qte_fail")
end

local function endUI()
    active = false; clearConns(); clearBody(); gui.Enabled = false; activeInstanceId = nil
end

-- ── Tier1/2: SequenceInput ───────────────────────────────────────────────────
local KEY_TEXT = {
    [Enum.KeyCode.W] = "W", [Enum.KeyCode.A] = "A", [Enum.KeyCode.S] = "S", [Enum.KeyCode.D] = "D",
    [Enum.KeyCode.Space] = "Space",
    [Enum.KeyCode.One] = "1", [Enum.KeyCode.Two] = "2", [Enum.KeyCode.Three] = "3",
    [Enum.KeyCode.Four] = "4", [Enum.KeyCode.Five] = "5",
}
local function runSequenceInput(content)
    local seq = content.sequence
    local prog = 0
    local seqLbl = Instance.new("TextLabel")
    seqLbl.Size = UDim2.new(1, 0, 0.6, 0); seqLbl.BackgroundTransparency = 1
    seqLbl.Font = Enum.Font.GothamBold; seqLbl.TextSize = 22
    seqLbl.TextColor3 = Color3.fromRGB(220, 215, 200); seqLbl.Parent = bodyFrame
    local progLbl = Instance.new("TextLabel")
    progLbl.Size = UDim2.new(1, 0, 0.4, 0); progLbl.Position = UDim2.new(0, 0, 0.6, 0)
    progLbl.BackgroundTransparency = 1; progLbl.Font = Enum.Font.Gotham; progLbl.TextSize = 14
    progLbl.TextColor3 = Color3.fromRGB(150, 140, 120); progLbl.Parent = bodyFrame
    local function refresh()
        local parts = {}
        for i, k in ipairs(seq) do parts[i] = (i <= prog) and ("[" .. k .. "]") or k end
        seqLbl.Text = "Press: " .. table.concat(parts, "  ")
        progLbl.Text = prog .. " / " .. #seq
    end
    refresh()
    -- Deliberately ignores gameProcessedEvent (see the gpe caveat noted on the other two
    -- InputBegan listeners in this file) -- kept simple here since W/A/S/D/Space/1-5 were
    -- confirmed live to arrive with gpe==false, but matching the same defensive pattern.
    local conn = UIS.InputBegan:Connect(function(input, _gpe)
        if not active then return end
        local k = KEY_TEXT[input.KeyCode]
        if not k then return end
        if k == seq[prog + 1] then
            prog += 1; refresh()
            if prog >= #seq then submitResult(true) end
        else
            submitResult(false)
        end
    end)
    table.insert(activeConns, conn)
end

-- ── Tier3: MonkeyType ────────────────────────────────────────────────────────
local function runMonkeyType(content)
    local words = content.words
    local target = table.concat(words, " ")
    local wordLbl = Instance.new("TextLabel")
    wordLbl.Size = UDim2.new(1, 0, 0.45, 0); wordLbl.BackgroundTransparency = 1
    wordLbl.Font = Enum.Font.GothamBold; wordLbl.TextSize = 20
    wordLbl.TextColor3 = Color3.fromRGB(220, 215, 200); wordLbl.Text = target; wordLbl.Parent = bodyFrame
    local box = Instance.new("TextBox")
    box.Size = UDim2.new(1, 0, 0, 30); box.Position = UDim2.new(0, 0, 0.55, 0)
    box.BackgroundColor3 = Color3.fromRGB(20, 16, 10); box.TextColor3 = Color3.fromRGB(230, 225, 210)
    box.Font = Enum.Font.Gotham; box.TextSize = 16; box.ClearTextOnFocus = false; box.Text = ""
    box.PlaceholderText = "type it..."; box.Parent = bodyFrame
    do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 4); c.Parent = box end
    box:CaptureFocus()
    local conn = box:GetPropertyChangedSignal("Text"):Connect(function()
        if not active then return end
        if box.Text == target then submitResult(true)
        elseif #box.Text >= #target then submitResult(false) end
    end)
    table.insert(activeConns, conn)
end

-- ── Tier4: GreenBar ──────────────────────────────────────────────────────────
local function runGreenBar(tierCfg)
    local barTrack = Instance.new("Frame")
    barTrack.Size = UDim2.new(1, 0, 0, 20); barTrack.Position = UDim2.new(0, 0, 0.4, 0)
    barTrack.BackgroundColor3 = Color3.fromRGB(30, 24, 16); barTrack.BorderSizePixel = 0
    barTrack.ClipsDescendants = false; barTrack.Parent = bodyFrame
    do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 4); c.Parent = barTrack end
    local zoneW = tierCfg.greenZoneWidth
    local greenZone = Instance.new("Frame")
    greenZone.Size = UDim2.new(zoneW, 0, 1, 0); greenZone.Position = UDim2.new(0.5 - zoneW / 2, 0, 0, 0)
    greenZone.BackgroundColor3 = Color3.fromRGB(70, 170, 70); greenZone.BorderSizePixel = 0
    greenZone.Parent = barTrack
    local marker = Instance.new("Frame")
    marker.Size = UDim2.new(0, 4, 1, 4); marker.Position = UDim2.new(0, -2, 0, -2)
    marker.BackgroundColor3 = Color3.fromRGB(230, 225, 210); marker.BorderSizePixel = 0
    marker.ZIndex = 2; marker.Parent = barTrack
    local infoLbl = Instance.new("TextLabel")
    infoLbl.Size = UDim2.new(1, 0, 0, 20); infoLbl.Position = UDim2.new(0, 0, 0.65, 0)
    infoLbl.BackgroundTransparency = 1; infoLbl.Font = Enum.Font.Gotham; infoLbl.TextSize = 14
    infoLbl.TextColor3 = Color3.fromRGB(150, 140, 120); infoLbl.Parent = bodyFrame

    local attempts, hits, t0 = 0, 0, tick()
    local needed = math.floor(tierCfg.attempts / 2) + 1
    local function markerFrac()
        local t = tick() - t0
        return (math.sin(t * tierCfg.barSpeed * math.pi * 2) + 1) / 2
    end
    local rsConn = RunService.RenderStepped:Connect(function()
        if not active then return end
        marker.Position = UDim2.new(markerFrac(), -2, 0, -2)
        infoLbl.Text = string.format("%d/%d needed hits — click in the green (%d/%d tries)",
            hits, needed, attempts, tierCfg.attempts)
    end)
    table.insert(activeConns, rsConn)
    -- Same gpe caveat as SequenceInput above -- Space is sunk by ControlModule's jumpAction.
    local inputConn = UIS.InputBegan:Connect(function(input, _gpe)
        if not active then return end
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.KeyCode ~= Enum.KeyCode.Space then return end
        attempts += 1
        if math.abs(markerFrac() - 0.5) <= zoneW / 2 then hits += 1 end
        if hits >= needed then submitResult(true)
        elseif attempts >= tierCfg.attempts then submitResult(false) end
    end)
    table.insert(activeConns, inputConn)
end

-- ── Tier5: CircleClose ───────────────────────────────────────────────────────
local function runCircleClose(tierCfg)
    local outer = Instance.new("Frame")
    outer.AnchorPoint = Vector2.new(0.5, 0.5); outer.Position = UDim2.new(0.5, 0, 0.4, 0)
    outer.Size = UDim2.new(0, 90, 0, 90); outer.BackgroundTransparency = 1; outer.Parent = bodyFrame
    local ring = Instance.new("Frame")
    ring.AnchorPoint = Vector2.new(0.5, 0.5); ring.Position = UDim2.new(0.5, 0, 0.5, 0)
    ring.Size = UDim2.new(0, 26, 0, 26); ring.BackgroundTransparency = 1; ring.Parent = outer
    do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(1, 0); c.Parent = ring end
    do local s = Instance.new("UIStroke"); s.Color = Color3.fromRGB(198, 156, 55); s.Thickness = 2; s.Parent = ring end
    local circle = Instance.new("Frame")
    circle.AnchorPoint = Vector2.new(0.5, 0.5); circle.Position = UDim2.new(0.5, 0, 0.5, 0)
    circle.Size = UDim2.new(0, 90, 0, 90); circle.BackgroundColor3 = Color3.fromRGB(220, 215, 200)
    circle.BackgroundTransparency = 0.35; circle.Parent = outer
    do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(1, 0); c.Parent = circle end
    local hintLbl = Instance.new("TextLabel")
    hintLbl.Size = UDim2.new(1, 0, 0, 20); hintLbl.Position = UDim2.new(0, 0, 0.85, 0)
    hintLbl.BackgroundTransparency = 1; hintLbl.Font = Enum.Font.Gotham; hintLbl.TextSize = 14
    hintLbl.TextColor3 = Color3.fromRGB(150, 140, 120); hintLbl.Text = "click when it reaches the ring"
    hintLbl.Parent = bodyFrame

    local t0 = tick()
    local dur = tierCfg.circleDuration
    local rsConn = RunService.RenderStepped:Connect(function()
        if not active then return end
        local t = tick() - t0
        local frac = math.clamp(1 - t / dur, 0, 1)
        local sz = 26 + (90 - 26) * frac
        circle.Size = UDim2.new(0, sz, 0, sz)
        if t > dur + tierCfg.toleranceWindow + 0.5 then submitResult(false) end
    end)
    table.insert(activeConns, rsConn)
    -- Same gpe caveat as SequenceInput above -- Space is sunk by ControlModule's jumpAction.
    local inputConn = UIS.InputBegan:Connect(function(input, _gpe)
        if not active then return end
        if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.KeyCode ~= Enum.KeyCode.Space then return end
        local t = tick() - t0
        submitResult(math.abs(t - dur) <= tierCfg.toleranceWindow)
    end)
    table.insert(activeConns, inputConn)
end

-- ── Mining: ReactiveClick ───────────────────────────────────────────────────
local function runReactiveClick(tierCfg)
	local circle = Instance.new("Frame")
	circle.AnchorPoint = Vector2.new(0.5, 0.5); circle.Position = UDim2.new(0.5, 0, 0.35, 0)
	circle.Size = UDim2.new(0, 80, 0, 80); circle.BackgroundColor3 = Color3.fromRGB(200, 180, 60)
	circle.Parent = bodyFrame
	do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(1, 0); c.Parent = circle end
	local countLbl = Instance.new("TextLabel")
	countLbl.Size = UDim2.new(1, 0, 1, 0); countLbl.BackgroundTransparency = 1
	countLbl.Font = Enum.Font.GothamBold; countLbl.TextSize = 30; countLbl.TextColor3 = Color3.new(0, 0, 0)
	countLbl.Text = ""; countLbl.Parent = circle
	local progLbl = Instance.new("TextLabel")
	progLbl.Size = UDim2.new(1, 0, 0, 20); progLbl.Position = UDim2.new(0, 0, 0.78, 0)
	progLbl.BackgroundTransparency = 1; progLbl.Font = Enum.Font.Gotham; progLbl.TextSize = 14
	progLbl.TextColor3 = Color3.fromRGB(150, 140, 120); progLbl.Parent = bodyFrame

	local perClick = 3 / (tierCfg.countdownSpeed or 1)
	local toleranceSec = (tierCfg.toleranceMs or 400) / 1000
	local clicksDone = 0
	local clickWindowOpen = false
	local clickWindowStart = 0
	local roundToken = 0

	local function updateProg() progLbl.Text = clicksDone .. " / " .. tierCfg.clickCount end
	updateProg()

	local function runRound()
		roundToken += 1
		local myToken = roundToken
		clickWindowOpen = false
		circle.BackgroundColor3 = Color3.fromRGB(200, 180, 60)
		task.spawn(function()
			for n = 3, 1, -1 do
				if not active or roundToken ~= myToken then return end
				countLbl.Text = tostring(n)
				playUISound("mining_tick")
				task.wait(perClick / 3)
			end
			if not active or roundToken ~= myToken then return end
			countLbl.Text = "CLICK!"
			circle.BackgroundColor3 = Color3.fromRGB(70, 200, 70)
			clickWindowOpen = true
			clickWindowStart = tick()
			task.delay(toleranceSec, function()
				if active and roundToken == myToken and clickWindowOpen then
					clickWindowOpen = false
					circle.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
					playUISound("mining_fail")
					submitResult(false)
				end
			end)
		end)
	end

	task.delay(3, function() if active then runRound() end end) -- 3s tension build before the first round

	local inputConn = UIS.InputBegan:Connect(function(input, _gpe)
		if not active then return end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		if not clickWindowOpen then
			-- clicked too early (or the window already closed) -- counts as a miss
			playUISound("mining_fail")
			submitResult(false)
			return
		end
		local elapsed = tick() - clickWindowStart
		if elapsed <= toleranceSec then
			clickWindowOpen = false
			clicksDone += 1
			updateProg()
			playUISound("mining_hit")
			if clicksDone >= tierCfg.clickCount then submitResult(true) else runRound() end
		end
	end)
	table.insert(activeConns, inputConn)
end

-- ── Dispatch ─────────────────────────────────────────────────────────────────
RE_QTEStart.OnClientEvent:Connect(function(data)
    endUI() -- cancel any stale prior QTE UI first
    active = true
    activeInstanceId = data.instanceId
    clearBody()
    titleLbl.Text = (data.tierConfig and data.tierConfig.name or "FOCUS"):upper()
    titleLbl.TextColor3 = Color3.fromRGB(198, 156, 55)
    gui.Enabled = true
    playUISound("qte_start")
    local kind = data.tierConfig and data.tierConfig.type
    if kind == "SequenceInput" then runSequenceInput(data.content)
    elseif kind == "MonkeyType" then runMonkeyType(data.content)
    elseif kind == "GreenBar" then runGreenBar(data.tierConfig)
    elseif kind == "CircleClose" then runCircleClose(data.tierConfig)
    elseif kind == "ReactiveClick" then runReactiveClick(data.tierConfig)
    end
    local dur = data.window or 10
    local t0 = tick()
    local tbConn = RunService.RenderStepped:Connect(function()
        local frac = math.clamp(1 - (tick() - t0) / dur, 0, 1)
        timeBarFill.Size = UDim2.new(frac, 0, 1, 0)
    end)
    table.insert(activeConns, tbConn)
end)

RE_QTEOutcome.OnClientEvent:Connect(function(data)
    if data.instanceId ~= activeInstanceId then return end
    titleLbl.Text = data.success and "SUCCESS" or "FAILED"
    titleLbl.TextColor3 = data.success and Color3.fromRGB(90, 200, 90) or Color3.fromRGB(200, 80, 80)
    local finishedId = data.instanceId
    task.delay(0.8, function()
        if activeInstanceId == finishedId then endUI() end
    end)
end)

print("[QTEClient] Loaded — Tier1-5 renderers ready")
