-- ClashClient.client.lua
-- PLACEHOLDER_GUI: ClashInputRace — replace with final design
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local UIS        = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")

local reFolder         = RepStorage:WaitForChild("RemoteEvents", 10)
local RE_OnClashStart  = reFolder:WaitForChild("OnClashStart",       10)
local RE_OnClashResult = reFolder:WaitForChild("OnClashResult",      10)
local RE_ClashInput    = reFolder:WaitForChild("RequestClashInput",   5)

-- Minimal placeholder clash UI
local gui = Instance.new("ScreenGui")
gui.Name = "ClashGui"; gui.ResetOnSpawn = false
gui.Enabled = false; gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local frame = Instance.new("Frame")
frame.AnchorPoint = Vector2.new(0.5, 0.5)
frame.Position = UDim2.new(0.5, 0, 0.5, 0)
frame.Size = UDim2.new(0, 420, 0, 130)
frame.BackgroundColor3 = Color3.fromRGB(15, 15, 15)
frame.BackgroundTransparency = 0.25
frame.BorderSizePixel = 0
frame.Parent = gui
local _c = Instance.new("UICorner"); _c.CornerRadius = UDim.new(0, 8); _c.Parent = frame

local function makeLabel(yPos, height, defaultText, color, bold)
    local l = Instance.new("TextLabel")
    l.Size = UDim2.new(1, -20, height, 0)
    l.Position = UDim2.new(0, 10, yPos, 0)
    l.BackgroundTransparency = 1
    l.TextColor3 = color or Color3.fromRGB(220, 220, 220)
    l.TextScaled = true
    l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
    l.Text = defaultText
    l.Parent = frame
    return l
end

local titleLbl = makeLabel(0.02, 0.32, "CLASH!",    Color3.fromRGB(255, 200, 50), true)
local seqLbl   = makeLabel(0.37, 0.33, "",          Color3.fromRGB(200, 200, 200), false)
local progLbl  = makeLabel(0.73, 0.25, "",          Color3.fromRGB(150, 150, 150), false)

local KEY_MAP = {
    [Enum.KeyCode.One]   = 1, [Enum.KeyCode.Two]   = 2,
    [Enum.KeyCode.Three] = 3, [Enum.KeyCode.Four]  = 4,
}

local clashActive = false
local clashSeq    = {}
local clashProg   = 0
local inputConn   = nil
local titleDefault = Color3.fromRGB(255, 200, 50)

local function buildSeqText()
    local parts = {}
    for i, num in ipairs(clashSeq) do
        parts[i] = (i <= clashProg) and ("["..num.."]" ) or tostring(num)
    end
    seqLbl.Text  = "Press: " .. table.concat(parts, "  ")
    progLbl.Text = clashProg .. " / " .. #clashSeq
end

local function endClash()
    clashActive = false; clashSeq = {}; clashProg = 0
    if inputConn then inputConn:Disconnect(); inputConn = nil end
    gui.Enabled = false
    titleLbl.TextColor3 = titleDefault
end

RE_OnClashStart.OnClientEvent:Connect(function(data)
    clashSeq  = data.sequence or {}
    clashProg = 0
    titleLbl.Text      = "CLASH vs " .. (data.opponentName or "?") .. "!"
    titleLbl.TextColor3 = titleDefault
    buildSeqText()
    gui.Enabled  = true
    clashActive  = true
    -- PLACEHOLDER_ANIMATION: clash_cinematic — replace with camera lock + effect
    -- Clash impact sound is played server-side (3D, heard by both fighters) by ClashManager
    inputConn = UIS.InputBegan:Connect(function(input, gpe)
        if gpe or not clashActive then return end
        local num = KEY_MAP[input.KeyCode]
        if num then
            if RE_ClashInput then RE_ClashInput:FireServer({ input = num }) end
            clashProg = math.min(clashProg + 1, #clashSeq)
            buildSeqText()
        end
    end)
    task.delay((data.duration or 3) + 0.5, function()
        if clashActive then endClash() end
    end)
end)

RE_OnClashResult.OnClientEvent:Connect(function(data)
    if not clashActive then return end
    if data.result == "Win" then
        titleLbl.Text = "YOU WIN!"
        titleLbl.TextColor3 = Color3.fromRGB(80, 255, 80)
    elseif data.result == "Loss" then
        titleLbl.Text = "YOU LOST"
        titleLbl.TextColor3 = Color3.fromRGB(255, 80, 80)
    else
        titleLbl.Text = "DRAW"
        titleLbl.TextColor3 = Color3.fromRGB(180, 180, 180)
    end
    task.delay(1.5, endClash)
end)

print("[ClashClient] Loaded — PLACEHOLDER_GUI: ClashInputRace")