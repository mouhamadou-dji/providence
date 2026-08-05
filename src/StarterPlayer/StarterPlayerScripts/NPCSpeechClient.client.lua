-- NPCSpeechClient.client.lua
-- PLACEHOLDER_GUI: NPCSpeechBubble
-- Mirrors ChatUI's player speech bubble style, but keyed off a Head Instance passed
-- directly by the server (NPCs aren't Players, so ChatUI's Players:FindFirstChild(name)
-- lookup pattern doesn't apply here).
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))

local BUBBLE_BG = Color3.fromRGB(15, 12, 8)
local BUBBLE_BORDER = Color3.fromRGB(198, 156, 55)
local TEXT_COLOR = Color3.fromRGB(220, 60, 60)

local function spawnNPCBubble(head, npcName, text)
    if not head or not head.Parent then return end

    local bb = Instance.new("BillboardGui")
    bb.Name = "NPCSpeechBubble"
    bb.MaxDistance = 74
    bb.Size = UDim2.new(0, math.clamp(#text * 7 + 30, 90, 300), 0, 40)
    bb.StudsOffset = Vector3.new(0, 3.2, 0)
    bb.LightInfluence = 0.3
    bb.Parent = head

    local bg = Instance.new("Frame")
    bg.Size = UDim2.new(1, 0, 1, 0)
    bg.BackgroundColor3 = BUBBLE_BG
    bg.BorderSizePixel = 0
    bg.Parent = bb
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 4); corner.Parent = bg
    local stroke = Instance.new("UIStroke"); stroke.Color = BUBBLE_BORDER; stroke.Thickness = 1; stroke.Parent = bg

    local nameLbl = Instance.new("TextLabel")
    nameLbl.Size = UDim2.new(1, -8, 0, 14)
    nameLbl.Position = UDim2.new(0, 4, 0, 2)
    nameLbl.BackgroundTransparency = 1
    nameLbl.Font = Enum.Font.GothamBold; nameLbl.TextSize = 11
    nameLbl.TextColor3 = BUBBLE_BORDER
    nameLbl.TextXAlignment = Enum.TextXAlignment.Center
    nameLbl.Text = npcName
    nameLbl.Parent = bg

    local textLbl = Instance.new("TextLabel")
    textLbl.Size = UDim2.new(1, -8, 1, -18)
    textLbl.Position = UDim2.new(0, 4, 0, 16)
    textLbl.BackgroundTransparency = 1
    textLbl.Font = Enum.Font.SourceSansItalic; textLbl.TextSize = 14
    textLbl.TextColor3 = TEXT_COLOR
    textLbl.TextWrapped = true
    textLbl.TextXAlignment = Enum.TextXAlignment.Center
    textLbl.Text = "\"" .. text .. "\""
    textLbl.Parent = bg

    task.delay(5, function()
        if not bb.Parent then return end
        TweenService:Create(bg, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play()
        TweenService:Create(nameLbl, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
        TweenService:Create(textLbl, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
        TweenService:Create(stroke, TweenInfo.new(0.4), { Transparency = 1 }):Play()
        task.delay(0.45, function() if bb.Parent then bb:Destroy() end end)
    end)
end

Remotes.NPCSpeak.OnClientEvent:Connect(function(head, npcName, text)
    spawnNPCBubble(head, npcName, text)
end)

print("[NPCSpeechClient] Loaded")
