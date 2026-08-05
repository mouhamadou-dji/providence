-- ZoneManager — Module 11
local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local RepStorage = game:GetService("ReplicatedStorage")

local CHECK_INTERVAL = 0.3

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
local showZoneNotify = getOrCreate("ShowZoneNotify")

local allZones = {}

local function addZone(part)
    if part:IsA("BasePart") and part:GetAttribute("ZoneName") then
        table.insert(allZones, part)
    end
end
local function removeZone(part)
    for i, z in ipairs(allZones) do
        if z == part then table.remove(allZones, i); return end
    end
end
local function scanZones()
    local folder = workspace:FindFirstChild("Zones")
    if not folder then
        folder = Instance.new("Folder"); folder.Name = "Zones"; folder.Parent = workspace
    end
    allZones = {}
    for _, child in ipairs(folder:GetChildren()) do addZone(child) end
    folder.ChildAdded:Connect(addZone)
    folder.ChildRemoved:Connect(removeZone)
    print(string.format("[ZoneManager] Scanned %d zone(s)", #allZones))
    return folder
end

local playerZone  = {}
local lastSafePos = {}

local function isInsideZone(hrp, zonePart)
    if not zonePart or not zonePart.Parent then return false end
    local localPos = zonePart.CFrame:PointToObjectSpace(hrp.Position)
    local hs = zonePart.Size * 0.5
    return math.abs(localPos.X) <= hs.X
        and math.abs(localPos.Y) <= hs.Y
        and math.abs(localPos.Z) <= hs.Z
end

local function processEntry(player, zonePart)
    local zoneName = zonePart:GetAttribute("ZoneName") or "???"
    if zonePart:GetAttribute("ZoneLocked") then
        local safePos = lastSafePos[player.UserId]
        if safePos then
            local char = player.Character
            local hrp  = char and char:FindFirstChild("HumanoidRootPart")
            if hrp then hrp.CFrame = CFrame.new(safePos + Vector3.new(0, 0.1, 0)) end
        end
        print(string.format("[ZoneManager] %s blocked from locked zone: %s", player.Name, zoneName))
        return
    end
    playerZone[player.UserId] = zonePart
    local zoneDesc = zonePart:GetAttribute("ZoneDescription") or "???"
    showZoneNotify:FireClient(player, zoneName, zoneDesc)
    local dm = _G.DataManager
    if dm then
        local discovered = dm.getValue(player, "DiscoveredZones") or {}
        local alreadyKnown = false
        for _, n in ipairs(discovered) do if n == zoneName then alreadyKnown = true; break end end
        if not alreadyKnown then
            table.insert(discovered, zoneName)
            dm.setValue(player, "DiscoveredZones", discovered)
            local lm    = _G.LoreManager
            local stage = lm and lm.getStage(player) or 0
            if stage >= 2 and lm then
                lm.writeLoreRecord(player, "ZONE_DISCOVERY", { zone = zoneName })
            end
            print(string.format("[ZoneManager] %s first discovery: %s (Stage %d)", player.Name, zoneName, stage))
        end
    end
    print(string.format("[ZoneManager] %s entered: %s", player.Name, zoneName))
end

local function processExit(player, zonePart)
    playerZone[player.UserId] = nil
    local zoneName = "unknown"
    if zonePart and zonePart.Parent then
        zoneName = zonePart:GetAttribute("ZoneName") or "???"
    end
    print(string.format("[ZoneManager] %s exited: %s", player.Name, zoneName))
end

local checkAccum = 0
RunService.Heartbeat:Connect(function(dt)
    checkAccum += dt
    if checkAccum < CHECK_INTERVAL then return end
    checkAccum = 0
    for _, player in ipairs(Players:GetPlayers()) do
        local char = player.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then continue end
        local current = playerZone[player.UserId]
        local newZone = nil
        for _, zone in ipairs(allZones) do
            if isInsideZone(hrp, zone) then newZone = zone; break end
        end
        if newZone ~= current then
            if current then processExit(player, current) end
            if newZone then processEntry(player, newZone)
            else playerZone[player.UserId] = nil end
        end
        local inLocked = newZone and newZone:GetAttribute("ZoneLocked")
        if not inLocked then lastSafePos[player.UserId] = hrp.Position end
    end
end)

local ZoneManager = {}
function ZoneManager.getCurrentZone(player) return playerZone[player.UserId] end
function ZoneManager.isDiscovered(player, zoneName)
    local dm = _G.DataManager
    if not dm then return false end
    local discovered = dm.getValue(player, "DiscoveredZones") or {}
    for _, n in ipairs(discovered) do if n == zoneName then return true end end
    return false
end
function ZoneManager.setZoneLocked(zoneName, locked)
    for _, zone in ipairs(allZones) do
        if zone:GetAttribute("ZoneName") == zoneName then
            zone:SetAttribute("ZoneLocked", locked)
            print(string.format("[ZoneManager] Zone '%s' ZoneLocked=%s", zoneName, tostring(locked)))
            return true
        end
    end
    warn("[ZoneManager] setZoneLocked: zone not found: " .. tostring(zoneName))
    return false
end
function ZoneManager.getZoneAttribute(zonePart, attr) return zonePart:GetAttribute(attr) end
function ZoneManager.getAllZones() return allZones end
function ZoneManager.enterZone(player, zonePart) processEntry(player, zonePart) end
function ZoneManager.exitZone(player, zonePart) processExit(player, zonePart) end
_G.ZoneManager = ZoneManager

Players.PlayerAdded:Connect(function(player)
    playerZone[player.UserId]  = nil
    lastSafePos[player.UserId] = Vector3.new(0, 5, 0)
    player.CharacterAdded:Connect(function() playerZone[player.UserId] = nil end)
end)
Players.PlayerRemoving:Connect(function(player)
    playerZone[player.UserId]  = nil
    lastSafePos[player.UserId] = nil
end)
for _, p in ipairs(Players:GetPlayers()) do
    playerZone[p.UserId]  = nil
    local char = p.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    lastSafePos[p.UserId] = hrp and hrp.Position or Vector3.new(0, 5, 0)
end
scanZones()
print("[ZoneManager] Init")
