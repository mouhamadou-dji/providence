-- EmoteWheelClient.client.lua
-- PLACEHOLDER_GUI: EmoteWheel / EmoteSlot_1..12 / PLACEHOLDER_ASSET: EmoteIcon_1..12
-- Ring-style radial wheel (donut band, icon+label per slot, center pointer, name tag,
-- page dots) on the Y key -- built at runtime, same convention as ClashClient/QTEClient.
local Players             = game:GetService("Players")
local RepStorage          = game:GetService("ReplicatedStorage")
local UIS                 = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local localPlayer = Players.LocalPlayer
local playerGui   = localPlayer:WaitForChild("PlayerGui")

local reFolder = RepStorage:WaitForChild("RemoteEvents", 10)
local RE_RequestPlayEmote = reFolder:WaitForChild("RequestPlayEmote", 5)
local RE_OnPlayEmote      = reFolder:WaitForChild("OnPlayEmote", 5)
local RE_RequestStopEmote = reFolder:WaitForChild("RequestStopEmote", 5)
local RE_OnFocusUpdate    = reFolder:WaitForChild("OnFocusUpdate", 5)

local PAGES = { Config.EmoteWheel.Page1, Config.EmoteWheel.Page2, Config.EmoteWheel.Page3 }

-- Blocked-state list mirrors CombatManager's isActionBlocked() blocked list (read off the
-- replicated CombatState attribute, same pattern InputHandler already uses) plus "Attacking"
-- (not in that list server-side, checked separately there too) -- covers "cannot open wheel
-- in combat state / downed / guard broken". "Carrying" is a separate IsCarrying attribute
-- since the carrier's own CombatState stays "Idle".
local WHEEL_BLOCKED_STATES = {
    Dead = true, Staggered = true, GuardBroken = true, Clashing = true,
    Downed = true, BeingCarried = true, BeingExecuted = true, Executing = true,
    Attacking = true,
}
local function isWheelBlocked()
    local char = localPlayer.Character
    if not char then return true end
    local state = char:GetAttribute("CombatState")
    if state ~= nil and WHEEL_BLOCKED_STATES[state] then return true end
    if char:GetAttribute("IsCarrying") then return true end
    return false
end

-- ── GUI ───────────────────────────────────────────────────────────────────────
local gui = Instance.new("ScreenGui")
gui.Name = "EmoteWheelGui"; gui.ResetOnSpawn = false; gui.Enabled = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local root = Instance.new("Frame")
root.AnchorPoint = Vector2.new(0.5, 0.5)
root.Position = UDim2.new(0.5, 0, 0.5, 0)
root.Size = UDim2.new(0, 420, 0, 420)
root.BackgroundTransparency = 1
root.Parent = gui

local ringOutline = Instance.new("Frame")
ringOutline.AnchorPoint = Vector2.new(0.5, 0.5)
ringOutline.Position = UDim2.new(0.5, 0, 0.5, 0)
ringOutline.Size = UDim2.new(0, 300, 0, 300)
ringOutline.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
ringOutline.BackgroundTransparency = 0.45
ringOutline.Parent = root
do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(1, 0); c.Parent = ringOutline end
do local s = Instance.new("UIStroke"); s.Color = Color3.fromRGB(230, 225, 210); s.Thickness = 2; s.Transparency = 0.3; s.Parent = ringOutline end

local innerHole = Instance.new("Frame")
innerHole.AnchorPoint = Vector2.new(0.5, 0.5)
innerHole.Position = UDim2.new(0.5, 0, 0.5, 0)
innerHole.Size = UDim2.new(0, 150, 0, 150)
innerHole.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
innerHole.BackgroundTransparency = 0.15
innerHole.ZIndex = 2
innerHole.Parent = root
do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(1, 0); c.Parent = innerHole end

local nameTag = Instance.new("TextLabel")
nameTag.AnchorPoint = Vector2.new(0.5, 1)
nameTag.Position = UDim2.new(0.5, 0, 0, -6)
nameTag.Size = UDim2.new(0, 240, 0, 24)
nameTag.BackgroundTransparency = 1
nameTag.Font = Enum.Font.Antique
nameTag.TextSize = 20
nameTag.TextColor3 = Color3.fromRGB(230, 225, 210)
nameTag.Text = localPlayer.DisplayName
nameTag.Parent = root

local centerArrow = Instance.new("TextLabel")
centerArrow.AnchorPoint = Vector2.new(0.5, 0.5)
centerArrow.Position = UDim2.new(0.5, 0, 0.5, 0)
centerArrow.Size = UDim2.new(0, 40, 0, 40)
centerArrow.BackgroundTransparency = 1
centerArrow.Font = Enum.Font.GothamBold
centerArrow.TextSize = 26
centerArrow.TextColor3 = Color3.fromRGB(230, 225, 210)
centerArrow.Text = ""
centerArrow.ZIndex = 3
centerArrow.Parent = root

local pageDotsRow = Instance.new("Frame")
pageDotsRow.AnchorPoint = Vector2.new(0.5, 0)
pageDotsRow.Position = UDim2.new(0.5, 0, 1, 4)
pageDotsRow.Size = UDim2.new(0, 60, 0, 12)
pageDotsRow.BackgroundTransparency = 1
pageDotsRow.Parent = root
do
    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Horizontal
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.Padding = UDim.new(0, 6)
    layout.Parent = pageDotsRow
end
local pageDots = {}
for i = 1, #PAGES do
    local dot = Instance.new("Frame")
    dot.Size = UDim2.new(0, 8, 0, 8)
    dot.BackgroundColor3 = Color3.fromRGB(230, 225, 210)
    dot.BackgroundTransparency = 0.7
    dot.Parent = pageDotsRow
    do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(1, 0); c.Parent = dot end
    pageDots[i] = dot
end

-- 4 slots evenly spaced (top/right/bottom/left), matching "4 emotes per page"
local SLOT_ANGLES = { -90, 0, 90, 180 }
local SLOT_RADIUS = 150
local slotButtons = {}
for i = 1, 4 do
    local rad = math.rad(SLOT_ANGLES[i])
    local x = math.cos(rad) * SLOT_RADIUS
    local y = math.sin(rad) * SLOT_RADIUS

    local btn = Instance.new("TextButton")
    btn.AnchorPoint = Vector2.new(0.5, 0.5)
    btn.Position = UDim2.new(0.5, x, 0.5, y)
    btn.Size = UDim2.new(0, 84, 0, 64)
    btn.BackgroundTransparency = 1
    btn.AutoButtonColor = false
    btn.Text = ""
    btn.ZIndex = 3
    btn.Parent = root

    local icon = Instance.new("Frame")
    icon.AnchorPoint = Vector2.new(0.5, 0)
    icon.Position = UDim2.new(0.5, 0, 0, 0)
    icon.Size = UDim2.new(0, 40, 0, 40)
    icon.BackgroundColor3 = Color3.fromRGB(180, 175, 165)
    icon.BackgroundTransparency = 0.15
    icon.Parent = btn
    do local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(1, 0); c.Parent = icon end
    do local s = Instance.new("UIStroke"); s.Color = Color3.fromRGB(198, 156, 55); s.Thickness = 1; s.Transparency = 0.4; s.Parent = icon end

    local label = Instance.new("TextLabel")
    label.AnchorPoint = Vector2.new(0.5, 0)
    label.Position = UDim2.new(0.5, 0, 0, 44)
    label.Size = UDim2.new(1, 0, 0, 18)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.GothamBold
    label.TextSize = 14
    label.TextColor3 = Color3.fromRGB(230, 225, 210)
    label.Text = ""
    label.Parent = btn

    slotButtons[i] = { btn = btn, icon = icon, label = label, angle = SLOT_ANGLES[i] }
end

-- ── State ───────────────────────────────────────────────────────────────────
local wheelOpen = false
local currentPage = 1
local prevMouseBehavior = Enum.MouseBehavior.Default
local prevMouseIconEnabled = true

local localEmoteTrack = nil -- self's currently playing one-shot/loop emote track
local localFocusType  = nil -- "meditate" | "pushups" | nil
local currentEmoteId  = nil -- last emote id selected via the wheel (used to detect "sleep" on movement)
local focusAuraPart   = nil

local function getAnimator(char)
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    return hum and hum:FindFirstChildOfClass("Animator")
 end

local function stopLocalEmoteTrack()
    if localEmoteTrack and localEmoteTrack.IsPlaying then
        localEmoteTrack:Stop(0.1)
    end
    localEmoteTrack = nil
end

local function clearFocusAura()
    if focusAuraPart then focusAuraPart:Destroy(); focusAuraPart = nil end
end

-- PLACEHOLDER_ASSET: MeditationAura -- subtle aura shown during deep-stage meditation.
local function applyFocusAura(char)
    clearFocusAura()
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end
    local part = Instance.new("ParticleEmitter")
    part.Name = "FocusAura"
    part.Color = ColorSequence.new(Color3.fromRGB(220, 200, 140))
    part.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 0)})
    part.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(1, 1)})
    part.Lifetime = NumberRange.new(0.8, 1.4)
    part.Rate = 6
    part.Speed = NumberRange.new(0.2, 0.6)
    part.Parent = hrp
    focusAuraPart = part
end

local function stopFocusVisual()
    stopLocalEmoteTrack()
    clearFocusAura()
    localFocusType = nil
end

-- Movement cancels any active emote immediately (Part One rule). Special (focus) emotes
-- also need the server told, so MeditationManager/PushupsManager end their loop/QTE state.
local MOVE_KEYS = { [Enum.KeyCode.W]=true, [Enum.KeyCode.A]=true, [Enum.KeyCode.S]=true, [Enum.KeyCode.D]=true }
UIS.InputBegan:Connect(function(input, gpe)
    if not MOVE_KEYS[input.KeyCode] then return end
    if localFocusType then
        RE_RequestStopEmote:FireServer()
        stopFocusVisual()
    elseif localEmoteTrack then
        -- "sleep" isn't a QTE-driven focus type, but it IS a server-tracked loop (real-time
        -- sanity recovery) -- movement has to tell the server to stop it too, not just kill
        -- the local animation track.
        if currentEmoteId == "sleep" then RE_RequestStopEmote:FireServer() end
        stopLocalEmoteTrack()
        currentEmoteId = nil
    end
end)

-- ── Wheel open/close ───────────────────────────────────────────────────────
local function refreshPage()
    local page = PAGES[currentPage] or {}
    for i, slot in ipairs(slotButtons) do
        local def = page[i]
        if def then
            slot.btn.Visible = true
            slot.label.Text = def.id:sub(1,1):upper() .. def.id:sub(2)
            slot.icon.BackgroundColor3 = def.special and Color3.fromRGB(198, 156, 55) or Color3.fromRGB(180, 175, 165)
        else
            slot.btn.Visible = false
        end
    end
    for i, dot in ipairs(pageDots) do
        dot.BackgroundTransparency = (i == currentPage) and 0.1 or 0.7
    end
    centerArrow.Text = ""
end

local function openWheel()
    if wheelOpen then return end
    if isWheelBlocked() then return end
    wheelOpen = true
    prevMouseBehavior = UIS.MouseBehavior
    prevMouseIconEnabled = UIS.MouseIconEnabled
    UIS.MouseBehavior = Enum.MouseBehavior.Default
    UIS.MouseIconEnabled = true
    refreshPage()
    gui.Enabled = true
end

local function closeWheel()
    if not wheelOpen then return end
    wheelOpen = false
    gui.Enabled = false
    UIS.MouseBehavior = prevMouseBehavior
    UIS.MouseIconEnabled = prevMouseIconEnabled
end

local function selectEmote(def)
    RE_RequestPlayEmote:FireServer(def.id)
    currentEmoteId = def.id
    closeWheel()
end

for i, slot in ipairs(slotButtons) do
    slot.btn.MouseEnter:Connect(function()
        centerArrow.Rotation = slot.angle
        centerArrow.Text = ">"
    end)
    slot.btn.MouseLeave:Connect(function()
        centerArrow.Text = ""
    end)
    slot.btn.MouseButton1Click:Connect(function()
        local page = PAGES[currentPage] or {}
        local def = page[i]
        if def then selectEmote(def) end
    end)
end

-- Bound via ContextActionService (not a plain UIS.InputBegan) at a high priority so it wins
-- over any other default/engine binding on this key -- this is what fixed the original O
-- keybind, where Roblox's own default CameraModule.CameraInput silently sank O (grouped with
-- I/Left/Right as a legacy camera-pan control) before a plain InputBegan listener ever saw it
-- with gameProcessedEvent==false. Now on Y per user request (was unable to open the wheel on
-- O in their environment -- switched as a quick fix, keeping the same robust binding style).
local function handleWheelKey(_actionName, inputState, _inputObj)
    if inputState == Enum.UserInputState.Begin then
        openWheel()
        return Enum.ContextActionResult.Sink
    elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
        closeWheel()
        return Enum.ContextActionResult.Sink
    end
    return Enum.ContextActionResult.Pass
end
ContextActionService:BindActionAtPriority("ABYSS_EmoteWheel", handleWheelKey, false, 3000, Enum.KeyCode.Y)

-- Scroll wheel cycles pages while open
UIS.InputChanged:Connect(function(input, gpe)
    if gpe or not wheelOpen then return end
    if input.UserInputType ~= Enum.UserInputType.MouseWheel then return end
    if input.Position.Z > 0 then
        currentPage = (currentPage % #PAGES) + 1
    else
        currentPage = ((currentPage - 2) % #PAGES) + 1
    end
    refreshPage()
end)

localPlayer.CharacterAdded:Connect(function()
    closeWheel()
    stopFocusVisual()
end)

-- ── Remote handlers ─────────────────────────────────────────────────────
RE_OnPlayEmote.OnClientEvent:Connect(function(fromPlayer, animId, loop, emoteId)
    local char = fromPlayer and fromPlayer.Character
    local animator = char and getAnimator(char)
    if not animator then return end
    if not animId or animId == "" or animId == "rbxassetid://0" then return end
    local anim = Instance.new("Animation")
    anim.AnimationId = animId
    local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
    if not ok or not track then return end
    track.Looped = loop and true or false
    track:Play()
    if fromPlayer == localPlayer then
        stopLocalEmoteTrack()
        localEmoteTrack = track
    end
end)

RE_OnFocusUpdate.OnClientEvent:Connect(function(data)
    if not data then return end
    if data.event == "Start" then
        localFocusType = data.type == "Meditation" and "meditate" or "pushups"
        local char = localPlayer.Character
        local animator = char and getAnimator(char)
        local def = (data.type == "Meditation") and Config.EmoteWheel.Page2[1] or Config.EmoteWheel.Page2[2]
        if animator and def and def.anim ~= "" and def.anim ~= "rbxassetid://0" then
            local anim = Instance.new("Animation"); anim.AnimationId = def.anim
            local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
            if ok and track then
                track.Looped = true; track:Play()
                localEmoteTrack = track
            end
        end
    elseif data.event == "DeepEnter" then
        local char = localPlayer.Character
        if char then applyFocusAura(char) end
    elseif data.event == "End" then
        stopFocusVisual()
    end
end)

print("[EmoteWheelClient] Loaded — Y to open, scroll to page, click to select")
