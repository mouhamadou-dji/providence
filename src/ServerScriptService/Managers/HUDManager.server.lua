-- HUDManager — Module 13 server
local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local RepStorage = game:GetService("ReplicatedStorage")

local POLL_INTERVAL = 2

local function getOrCreate(name, isFunc)
    local folder = RepStorage:FindFirstChild("RemoteEvents")
        or (function()
            local f = Instance.new("Folder")
            f.Name = "RemoteEvents"
            f.Parent = RepStorage
            return f
        end)()
    local r = folder:FindFirstChild(name)
    if r then return r end
    r = Instance.new(isFunc and "RemoteFunction" or "RemoteEvent")
    r.Name = name
    r.Parent = folder
    return r
end
local updateHUD         = getOrCreate("UpdateHUD")
local updateEclipseMoon = getOrCreate("UpdateEclipseMoon")
local showGlobalMsg     = getOrCreate("ShowGlobalMessage")

local lastStage  = {}
local lastHunger = {}
local lastWater  = {}

local pollAccum = 0
RunService.Heartbeat:Connect(function(dt)
    pollAccum += dt
    if pollAccum < POLL_INTERVAL then return end
    pollAccum = 0

    local dm = _G.DataManager
    local lm = _G.LoreManager

    for _, player in ipairs(Players:GetPlayers()) do
        local uid = player.UserId
        if dm then
            local hunger = dm.getValue(player, "Hunger") or 100
            if hunger ~= lastHunger[uid] then
                lastHunger[uid] = hunger
                updateHUD:FireClient(player, { Hunger = hunger, HungerMax = 100 })
            end
            local water = dm.getValue(player, "Water") or 100
            if water ~= lastWater[uid] then
                lastWater[uid] = water
                updateHUD:FireClient(player, { Water = water, WaterMax = 100 })
            end
        end
        if lm then
            local stage = lm.getStage(player) or 0
            if stage ~= lastStage[uid] then
                lastStage[uid] = stage
                updateEclipseMoon:FireClient(player, stage)
            end
        end
    end
end)

local HUDManager = {}

function HUDManager.notifyHUD(player, data)
    assert(type(data) == "table", "data must be a table")
    updateHUD:FireClient(player, data)
end

function HUDManager.notifyEclipseMoon(player, stage)
    assert(
        type(stage) == "number"
        and stage >= 0 and stage <= 5
        and math.floor(stage) == stage,
        "stage must be integer 0-5"
    )
    lastStage[player.UserId] = stage
    updateEclipseMoon:FireClient(player, stage)
end

function HUDManager.showGlobalMessage(message, color)
    assert(type(message) == "string" and #message > 0,
        "message must be a non-empty string")
    showGlobalMsg:FireAllClients(message, color or Color3.fromRGB(255,240,200))
    print("[HUDManager] Global: " .. message)
end

function HUDManager.getLastStage(player)
    return lastStage[player.UserId]
end

function HUDManager.getLastHunger(player)
    return lastHunger[player.UserId]
end

_G.HUDManager = HUDManager

Players.PlayerAdded:Connect(function(player)
    lastStage[player.UserId]  = nil
    lastHunger[player.UserId] = nil
    lastWater[player.UserId]  = nil
end)
Players.PlayerRemoving:Connect(function(player)
    lastStage[player.UserId]  = nil
    lastHunger[player.UserId] = nil
    lastWater[player.UserId]  = nil
end)
for _, p in ipairs(Players:GetPlayers()) do
    lastStage[p.UserId]  = nil
    lastHunger[p.UserId] = nil
    lastWater[p.UserId]  = nil
end

print("[HUDManager] Init — poll: " .. POLL_INTERVAL .. "s")
