-- Zone_TestHarness — ZoneManager tests
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
if not RunService:IsStudio() then return end -- test harness: Studio-only, never runs in a live published server

local function waitFor(name, timeout)
    local t = tick() + (timeout or 10)
    while not _G[name] do
        if tick() > t then return nil end
        task.wait(0.05)
    end
    return _G[name]
end

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then print("[ZM_TEST] PASS: " .. name); passed += 1
    else warn("[ZM_TEST] FAIL: " .. name .. " — " .. tostring(err)); failed += 1 end
end

local function waitForPlayer(timeout)
    local t = tick() + (timeout or 10)
    repeat task.wait(0.1) until Players:GetPlayers()[1] or tick() > t
    return Players:GetPlayers()[1]
end

local player = waitForPlayer(10)
if not player then warn("[ZM_TEST] No player"); return end

local ZM = waitFor("ZoneManager", 10)
if not ZM then warn("[ZM_TEST] ZoneManager not ready"); return end
local DM = waitFor("DataManager", 8)
if not DM then warn("[ZM_TEST] DataManager not ready"); return end

-- Wait for DM player data to load
local deadline = tick() + 6
while DM.getValue(player, "PlayerState") == nil and tick() < deadline do
    task.wait(0.1)
end
if DM.getValue(player, "PlayerState") == nil then
    warn("[ZM_TEST] DataManager not ready — aborting"); return
end

print("[ZM_TEST] Starting ZoneManager tests — player: " .. player.Name)

-- Zone factory
local zonesFolder = workspace:FindFirstChild("Zones")
if not zonesFolder then
    zonesFolder = Instance.new("Folder")
    zonesFolder.Name = "Zones"
    zonesFolder.Parent = workspace
end

local testZones = {}

local function makeZone(name, desc, locked, size, offset)
    local char = player.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    local pos  = hrp and hrp.Position or Vector3.new(0, 5, 0)
    local part = Instance.new("Part")
    part.Name         = name
    part.Size         = size or Vector3.new(60, 30, 60)
    part.CFrame       = CFrame.new(pos + (offset or Vector3.new(0, 0, 0)))
    part.Anchored     = true
    part.CanCollide   = false
    part.Transparency = 1
    part:SetAttribute("ZoneName",        name)
    part:SetAttribute("ZoneDescription", desc or ("A zone called " .. name))
    part:SetAttribute("ZoneMusic",       "PLACEHOLDER_SOUND: zone_music_" .. name)
    part:SetAttribute("ZoneFog",         false)
    part:SetAttribute("ZoneFogDensity",  0)
    part:SetAttribute("ZoneLocked",      locked or false)
    part.Parent = zonesFolder
    table.insert(testZones, part)
    return part
end

local function cleanup()
    for _, z in ipairs(testZones) do
        if z and z.Parent then z:Destroy() end
    end
    testZones = {}
    DM.setValue(player, "DiscoveredZones", {})
end

-- T1: enterZone (direct) sets getCurrentZone
test("T1_EnterZoneDirect", function()
    cleanup()
    local z = makeZone("TestGrove", "A quiet grove.", false)
    task.wait(0.05)
    ZM.enterZone(player, z)
    assert(ZM.getCurrentZone(player) == z, "getCurrentZone should be z after enterZone")
end)

-- T2: exitZone (direct) clears getCurrentZone
test("T2_ExitZoneDirect", function()
    local z = ZM.getCurrentZone(player)
    assert(z ~= nil, "Should still be in zone from T1")
    ZM.exitZone(player, z)
    assert(ZM.getCurrentZone(player) == nil, "getCurrentZone should be nil after exitZone")
end)

-- T3: Heartbeat detection — zone placed at player position is detected
test("T3_HeartbeatDetectsEntry", function()
    cleanup()
    local z = makeZone("HeartbeatZone", "Detected via Heartbeat.", false)
    task.wait(0.45)
    assert(ZM.getCurrentZone(player) == z,
        "Heartbeat should have detected player inside HeartbeatZone")
end)

-- T4: Heartbeat detects exit when zone removed
test("T4_HeartbeatDetectsExit", function()
    local z = ZM.getCurrentZone(player)
    assert(z ~= nil, "Should be in zone from T3")
    z:Destroy()
    task.wait(0.45)
    assert(ZM.getCurrentZone(player) == nil,
        "Heartbeat should detect exit after zone destroyed")
    cleanup()
end)

-- T5: enterZone fires ShowZoneNotify without error
test("T5_ShowZoneNotifyFires", function()
    cleanup()
    local z = makeZone("NotifyZone", "This fires a notification.", false)
    task.wait(0.05)
    local ok = pcall(function() ZM.enterZone(player, z) end)
    assert(ok, "enterZone should not throw when firing ShowZoneNotify")
    ZM.exitZone(player, z)
end)

-- T6: enterZone marks zone as discovered in DiscoveredZones
test("T6_DiscoveryMarked", function()
    cleanup()
    local z = makeZone("IronHollow", "A hollow of iron.", false)
    task.wait(0.05)
    ZM.enterZone(player, z)
    assert(ZM.isDiscovered(player, "IronHollow") == true,
        "IronHollow should be in DiscoveredZones after enterZone")
    ZM.exitZone(player, z)
end)

-- T7: Entering same zone twice doesn't duplicate DiscoveredZones
test("T7_NoDuplicateDiscovery", function()
    cleanup()
    local z = makeZone("IronHollow2", "No dup test.", false)
    task.wait(0.05)
    ZM.enterZone(player, z)
    ZM.exitZone(player, z)
    ZM.enterZone(player, z)
    ZM.exitZone(player, z)
    local discovered = DM.getValue(player, "DiscoveredZones") or {}
    local count = 0
    for _, n in ipairs(discovered) do
        if n == "IronHollow2" then count += 1 end
    end
    assert(count == 1, "IronHollow2 should appear exactly once, got: " .. count)
end)

-- T8: Discovery at Stage 0 does NOT write LoreRecord (no crash either)
test("T8_DiscoveryStage0NoLoreRecord", function()
    local lm = _G.LoreManager
    cleanup()
    if lm then lm.setStage(player, 0) end
    local z = makeZone("Stage0Zone", "Stage 0 zone.", false)
    task.wait(0.05)
    local ok = pcall(function() ZM.enterZone(player, z) end)
    assert(ok, "enterZone at Stage 0 should not throw")
    ZM.exitZone(player, z)
    if lm then lm.setStage(player, 0) end
end)

-- T9: Discovery at Stage 2 writes to LoreRecord (no crash)
test("T9_DiscoveryStage2WritesLoreRecord", function()
    local lm = _G.LoreManager
    cleanup()
    if lm then lm.setStage(player, 2) end
    local z = makeZone("Stage2Zone", "Stage 2 zone.", false)
    task.wait(0.05)
    local ok = pcall(function() ZM.enterZone(player, z) end)
    assert(ok, "enterZone at Stage 2 should not throw (LoreRecord written)")
    ZM.exitZone(player, z)
    if lm then lm.setStage(player, 0) end
end)

-- T10: Locked zone entry does not update getCurrentZone
test("T10_LockedZoneBlocksEntry", function()
    cleanup()
    local z = makeZone("LockedRuins", "No entry.", true)
    task.wait(0.05)
    ZM.enterZone(player, z)
    assert(ZM.getCurrentZone(player) == nil,
        "getCurrentZone should remain nil after entering locked zone")
end)

-- T11: setZoneLocked changes attribute on zone
test("T11_SetZoneLocked", function()
    cleanup()
    local z = makeZone("ToggleZone", "Toggle test.", false)
    task.wait(0.05)
    local result = ZM.setZoneLocked("ToggleZone", true)
    assert(result == true, "setZoneLocked should return true when zone found")
    assert(ZM.getZoneAttribute(z, "ZoneLocked") == true,
        "ZoneLocked attribute should be true after setZoneLocked")
    ZM.setZoneLocked("ToggleZone", false)
    assert(ZM.getZoneAttribute(z, "ZoneLocked") == false,
        "ZoneLocked should be false after second setZoneLocked")
end)

-- T12: setZoneLocked on missing zone returns false
test("T12_SetZoneLockedMissingZone", function()
    local result = ZM.setZoneLocked("NonExistentZone_XYZ", true)
    assert(result == false, "setZoneLocked on missing zone should return false")
end)

-- T13: isDiscovered returns false for unknown zone
test("T13_IsDiscoveredFalseForUnknown", function()
    cleanup()
    assert(ZM.isDiscovered(player, "NeverVisitedZone") == false,
        "isDiscovered should be false for zone never entered")
end)

-- T14: getZoneAttribute reads Part attributes correctly
test("T14_GetZoneAttribute", function()
    cleanup()
    local z = makeZone("AttrZone", "Attribute test.", false)
    z:SetAttribute("ZoneFog", true)
    z:SetAttribute("ZoneFogDensity", 0.4)
    task.wait(0.05)
    assert(ZM.getZoneAttribute(z, "ZoneName") == "AttrZone",
        "ZoneName attribute mismatch")
    assert(ZM.getZoneAttribute(z, "ZoneFog") == true,
        "ZoneFog attribute mismatch")
    assert(math.abs((ZM.getZoneAttribute(z, "ZoneFogDensity") or 0) - 0.4) < 0.001,
        "ZoneFogDensity attribute mismatch")
end)

cleanup()
print(string.format("[ZM_TEST] Done — %d pass / %d fail", passed, failed))
