-- PostureBarClient — Module 5 (client)
-- Renders a BillboardGui posture bar above the local player
-- Receives UpdatePostureBar from server; never sends posture values
-- OWNER NOTE: Replace PLACEHOLDER_GUI, PLACEHOLDER_SOUND, and PLACEHOLDER_ANIMATION below with final assets
-- Target location: StarterGui/_GUIs/PostureBar/PostureBillboard (BillboardGui template — cloned onto HumanoidRootPart each spawn)

local Players      = game:GetService("Players")
local RepStorage   = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local StarterGui   = game:GetService("StarterGui")

local LocalPlayer = Players.LocalPlayer

-- ── Billboard template ────────────────────────────────────────────────────────
-- PLACEHOLDER_GUI: PostureBarBackground (BG.PostureBarBackground) — replace with designed background art
-- PLACEHOLDER_GUI: PostureBarFill (BG.Fill.PostureBarFill) — replace with designed fill bar art
local billboardTemplate = StarterGui:WaitForChild("_GUIs"):WaitForChild("PostureBar"):WaitForChild("PostureBillboard")

-- ── Remotes ───────────────────────────────────────────────────────────────────
local reFolder = RepStorage:WaitForChild("RemoteEvents", 10)
local function waitRemote(name)
    return reFolder:WaitForChild(name, 10)
end

local RE_UpdatePostureBar = waitRemote("UpdatePostureBar")
local RE_OnGuardBreak     = waitRemote("OnGuardBreak")

-- ── GUI Construction ──────────────────────────────────────────────────────────
local function buildPostureBar(character)
    local hrp = character:WaitForChild("HumanoidRootPart", 5)
    if not hrp then return nil end

    local old = hrp:FindFirstChild("PostureBillboard")
    if old then old:Destroy() end

    local billboard = billboardTemplate:Clone()
    billboard.Enabled = true
    billboard.Adornee = hrp
    billboard.Parent  = hrp

    local bg   = billboard:WaitForChild("BG")
    local fill = bg:WaitForChild("Fill")

    bg.BackgroundTransparency   = 1
    fill.BackgroundTransparency = 1

    return { billboard = billboard, bg = bg, fill = fill }
end

-- ── Color based on posture fraction ──────────────────────────────────────────
local function postureColor(fraction)
    if fraction < 0.5 then
        return Color3.fromRGB(255, 255, 255)
    elseif fraction < 0.75 then
        return Color3.fromRGB(255, 210, 50)
    else
        return Color3.fromRGB(220, 50, 50)
    end
end

-- ── Tween helpers ─────────────────────────────────────────────────────────────
local FADE_INFO = TweenInfo.new(0.15, Enum.EasingStyle.Linear)

local function setBarAlpha(gui, alpha)
    TweenService:Create(gui.bg,   FADE_INFO, { BackgroundTransparency = alpha }):Play()
    TweenService:Create(gui.fill, FADE_INFO, { BackgroundTransparency = alpha }):Play()
end

-- ── State ─────────────────────────────────────────────────────────────────────
local guiRef  = nil
local visible = false

local function onUpdate(data)
    if not guiRef then return end
    local posture   = data.posture or 0
    local maxP      = data.max     or 100
    local fraction  = posture / maxP
    local fillWidth = math.clamp(fraction, 0, 1)

    -- Fill grows UPWARD (Y axis) from the bottom -- the template's Fill frame has
    -- AnchorPoint(0,1)/Position(0,1,0,0) so shrinking/growing its Y size keeps it pinned
    -- to the bottom edge and builds upward, per spec.
    guiRef.fill.Size             = UDim2.new(1, 0, fillWidth, 0)
    guiRef.fill.BackgroundColor3 = postureColor(fraction)

    if posture > 0 and not visible then
        visible = true
        setBarAlpha(guiRef, 0)
    elseif posture <= 0 and visible then
        visible = false
        setBarAlpha(guiRef, 1)
    end
end

local SoundsFolder = RepStorage:WaitForChild("_Sounds", 5)
local GuardBreakSound = SoundsFolder and SoundsFolder:FindFirstChild("Combat") and SoundsFolder.Combat:FindFirstChild("Guard_Break")

local function onGuardBreak()
    if not guiRef then return end
    guiRef.fill.BackgroundColor3 = Color3.fromRGB(255, 30, 30)
    task.delay(0.1, function()
        guiRef.fill.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    end)
    local id = GuardBreakSound and GuardBreakSound.SoundId
    if id and id ~= "" and id ~= "rbxassetid://0" then
        local snd = Instance.new("Sound")
        snd.SoundId = id
        snd.Volume = 0.5
        snd.RollOffMaxDistance = 0
        snd.Parent = game:GetService("SoundService")
        snd:Play()
        -- Destroy once actually finished, not on a fixed timer -- a fixed Debris delay can
        -- destroy the instance before a slower-to-stream asset ever finishes playing.
        local cleaned = false
        local function cleanup() if not cleaned then cleaned = true; if snd.Parent then snd:Destroy() end end end
        snd.Ended:Once(cleanup)
        task.delay(8, cleanup)
    end
    -- PLACEHOLDER_ANIMATION: guard_break_flash — replace with actual screen effect
end

-- ── Character lifecycle ───────────────────────────────────────────────────────
local function onCharacterAdded(character)
    guiRef  = buildPostureBar(character)
    visible = false
end

if LocalPlayer.Character then
    onCharacterAdded(LocalPlayer.Character)
end
LocalPlayer.CharacterAdded:Connect(onCharacterAdded)

-- ── Remote listeners ──────────────────────────────────────────────────────────
RE_UpdatePostureBar.OnClientEvent:Connect(onUpdate)
RE_OnGuardBreak.OnClientEvent:Connect(onGuardBreak)
