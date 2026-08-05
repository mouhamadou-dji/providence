-- ZoneNotifyClient — Module 11 client
-- Displays zone name + description at top-center when entering a zone
-- OWNER NOTE: Replace PLACEHOLDER_GUI and PLACEHOLDER_SOUND below with final art
-- Target location: StarterGui/_GUIs/ZoneNotify/ZoneNotifyGui

local Players      = game:GetService("Players")
local RepStorage   = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local StarterGui   = game:GetService("StarterGui")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ── Clone GUI template ────────────────────────────────────────────────────────
-- PLACEHOLDER_GUI: ZoneNotify frame design — replace with actual art
local screenGui = StarterGui:WaitForChild("_GUIs"):WaitForChild("ZoneNotify"):WaitForChild("ZoneNotifyGui"):Clone()
screenGui.Parent = playerGui

local frame     = screenGui:WaitForChild("NotifyFrame")
local nameLabel = frame:WaitForChild("ZoneName")
local descLabel = frame:WaitForChild("ZoneDesc")

-- ── Notification logic ────────────────────────────────────────────────────────
local fadeOutThread = nil

local function showNotify(zoneName, zoneDesc)
    if fadeOutThread then task.cancel(fadeOutThread); fadeOutThread = nil end

    nameLabel.Text = zoneName
    descLabel.Text = zoneDesc
    nameLabel.TextTransparency = 1
    descLabel.TextTransparency = 1

    TweenService:Create(nameLabel,
        TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { TextTransparency = 0 }):Play()
    TweenService:Create(descLabel,
        TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        { TextTransparency = 0 }):Play()

    fadeOutThread = task.delay(3.5, function()
        TweenService:Create(nameLabel,
            TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
            { TextTransparency = 1 }):Play()
        TweenService:Create(descLabel,
            TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
            { TextTransparency = 1 }):Play()
        fadeOutThread = nil
    end)
end

-- ── Zone ambient sound: crossfade to the entered zone's loop, if one exists ────
local SoundService = game:GetService("SoundService")
local AmbientFolder = RepStorage:WaitForChild("_Sounds", 5):WaitForChild("Ambient", 5)
local CROSSFADE_TIME = 1
local currentZoneSound = nil

local function playZoneAmbient(zoneName)
    local soundInst = AmbientFolder:FindFirstChild("Zone_" .. tostring(zoneName))
    local id = soundInst and soundInst.SoundId
    local previous = currentZoneSound

    if previous then
        TweenService:Create(previous, TweenInfo.new(CROSSFADE_TIME), { Volume = 0 }):Play()
        task.delay(CROSSFADE_TIME, function() previous:Destroy() end)
        currentZoneSound = nil
    end

    if not id or id == "" or id == "rbxassetid://0" then return end

    local snd = Instance.new("Sound")
    snd.SoundId = id
    snd.Looped = true
    snd.Volume = 0
    snd.Parent = SoundService
    snd:Play()
    currentZoneSound = snd
    TweenService:Create(snd, TweenInfo.new(CROSSFADE_TIME), { Volume = 0.3 }):Play()
end

-- ── Listen for zone entry events ──────────────────────────────────────────────
local reFolder = RepStorage:WaitForChild("RemoteEvents", 10)
local notify   = reFolder:WaitForChild("ShowZoneNotify", 10)
if notify then
    notify.OnClientEvent:Connect(function(zoneName, zoneDesc)
        showNotify(zoneName, zoneDesc)
        playZoneAmbient(zoneName)
    end)
end

print("[ZoneNotifyClient] Ready")
