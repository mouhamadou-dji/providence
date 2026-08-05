-- Weather_TestHarness — WeatherManager tests
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
    if ok then print("[WM_TEST] PASS: " .. name); passed += 1
    else warn("[WM_TEST] FAIL: " .. name .. " — " .. tostring(err)); failed += 1 end
end

local function waitForPlayer(timeout)
    local t = tick() + (timeout or 10)
    repeat task.wait(0.1) until Players:GetPlayers()[1] or tick() > t
    return Players:GetPlayers()[1]
end

local player = waitForPlayer(10)
if not player then warn("[WM_TEST] No player"); return end

local WM = waitFor("WeatherManager", 10)
if not WM then warn("[WM_TEST] WeatherManager not ready"); return end
local DM = waitFor("DataManager", 8)
if not DM then warn("[WM_TEST] DataManager not ready"); return end
local ZM = waitFor("ZoneManager", 8)
if not ZM then warn("[WM_TEST] ZoneManager not ready"); return end

local deadline = tick() + 6
while DM.getValue(player, "PlayerState") == nil and tick() < deadline do
    task.wait(0.1)
end
if DM.getValue(player, "PlayerState") == nil then
    warn("[WM_TEST] DataManager not ready — aborting"); return
end

print("[WM_TEST] Starting WeatherManager tests — player: " .. player.Name)

local zonesFolder = workspace:FindFirstChild("Zones")
if not zonesFolder then
    zonesFolder = Instance.new("Folder"); zonesFolder.Name = "Zones"
    zonesFolder.Parent = workspace
end
local fogTestZones = {}
local function makeFogZone(hasFog, density)
    local char = player.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    local pos  = hrp and hrp.Position or Vector3.new(0, 5, 0)
    local part = Instance.new("Part")
    part.Name         = "FogTestZone"
    part.Size         = Vector3.new(60, 30, 60)
    part.CFrame       = CFrame.new(pos)
    part.Anchored     = true
    part.CanCollide   = false
    part.Transparency = 1
    part:SetAttribute("ZoneName",        "FogTestZone")
    part:SetAttribute("ZoneDescription", "Fog test zone")
    part:SetAttribute("ZoneMusic",       "PLACEHOLDER_SOUND: zone_music_fog")
    part:SetAttribute("ZoneFog",         hasFog)
    part:SetAttribute("ZoneFogDensity",  density or 0.3)
    part:SetAttribute("ZoneLocked",      false)
    part.Parent = zonesFolder
    table.insert(fogTestZones, part)
    return part
end
local function cleanupFogZones()
    for _, z in ipairs(fogTestZones) do
        if z and z.Parent then z:Destroy() end
    end
    fogTestZones = {}
end

test("T1_DefaultWeatherClear", function()
    WM.clearWeather()
    WM.setBaseWeather("Clear")
    assert(WM.getWeather() == "Clear", "Default weather should be Clear, got: " .. WM.getWeather())
end)

test("T2_SetWeatherOverride", function()
    WM.setWeather("Fog", 60)
    assert(WM.getWeather() == "Fog", "getWeather should return Fog after override, got: " .. WM.getWeather())
    WM.clearWeather()
end)

test("T3_OverrideExpires", function()
    WM.setBaseWeather("Clear")
    WM.setWeather("Storm", 0.15)
    assert(WM.getWeather() == "Storm", "Should be Storm immediately")
    task.wait(0.3)
    assert(WM.getWeather() == "Clear",
        "Should revert to Clear after override expires, got: " .. WM.getWeather())
end)

test("T4_ClearWeatherReverts", function()
    WM.setBaseWeather("Clear")
    WM.setWeather("Rain", 60)
    assert(WM.getWeather() == "Rain", "Should be Rain during override")
    WM.clearWeather()
    assert(WM.getWeather() == "Clear", "Should be Clear after clearWeather")
end)

test("T5_SetWeatherPermanent", function()
    WM.setWeather("Fog")
    assert(WM.getWeather() == "Fog", "Permanent set should make getWeather return Fog")
    task.wait(0.2)
    assert(WM.getWeather() == "Fog", "Permanent weather should persist after 0.2s")
    WM.setWeather("Clear")
end)

test("T6_SetBaseWeather", function()
    WM.setWeather("Rain", 60)
    WM.setBaseWeather("Fog")
    assert(WM.getWeather() == "Rain", "Active override should still return Rain")
    WM.clearWeather()
    assert(WM.getWeather() == "Fog", "After clear, should return new base Fog")
    WM.setWeather("Clear")
end)

test("T7_GetClockTimeValid", function()
    local t = WM.getClockTime()
    assert(type(t) == "number", "getClockTime should return number")
    assert(t >= 0 and t < 24, "ClockTime out of range: " .. tostring(t))
end)

test("T8_SetClockTime", function()
    WM.setClockTime(12.0)
    local t = WM.getClockTime()
    assert(math.abs(t - 12.0) < 0.05, "Clock should be ~12.0 after set, got: " .. t)
end)

test("T9_SetClockTimeRejectsInvalid", function()
    local ok1 = pcall(function() WM.setClockTime(24) end)
    local ok2 = pcall(function() WM.setClockTime(-1) end)
    local ok3 = pcall(function() WM.setClockTime("noon") end)
    assert(ok1 == false, "Clock=24 should throw")
    assert(ok2 == false, "Clock=-1 should throw")
    assert(ok3 == false, "Non-number should throw")
end)

test("T10_GetTimeOfDay", function()
    WM.setClockTime(6.0)
    assert(WM.getTimeOfDay() == "Dawn",      "6.0 should be Dawn, got: "      .. WM.getTimeOfDay())
    WM.setClockTime(12.0)
    assert(WM.getTimeOfDay() == "Midday",    "12.0 should be Midday, got: "   .. WM.getTimeOfDay())
    WM.setClockTime(21.0)
    assert(WM.getTimeOfDay() == "Night",     "21.0 should be Night, got: "    .. WM.getTimeOfDay())
    WM.setClockTime(3.0)
    assert(WM.getTimeOfDay() == "DeepNight", "3.0 should be DeepNight, got: " .. WM.getTimeOfDay())
end)

test("T11_ClockAdvancesAtRate", function()
    local EXPECTED_RATE = 24 / 1500
    local t0    = WM.getClockTime()
    local start = tick()
    task.wait(1.0)
    local elapsed = tick() - start
    local t1    = WM.getClockTime()
    local delta = (t1 - t0 + 24) % 24
    local expectedDelta = elapsed * EXPECTED_RATE
    local ratio = delta / expectedDelta
    assert(ratio >= 0.5 and ratio <= 1.5,
        string.format("Clock rate off — delta=%.5f expected=%.5f ratio=%.2f",
            delta, expectedDelta, ratio))
end)

test("T12_SetWeatherRejectsNonString", function()
    local ok = pcall(function() WM.setWeather(123) end)
    assert(ok == false, "setWeather with number should throw")
end)

test("T13_ZoneFogDetected", function()
    cleanupFogZones()
    local z = makeFogZone(true, 0.4)
    task.wait(0.05)
    ZM.enterZone(player, z)
    task.wait(0.7)
    assert(WM.getZoneFogState(player) == true,
        "WeatherManager should detect zone fog after check interval")
    ZM.exitZone(player, z)
    z:Destroy()
    cleanupFogZones()
end)

test("T14_ZoneFogClearsOnExit", function()
    cleanupFogZones()
    local z = makeFogZone(true, 0.3)
    task.wait(0.05)
    ZM.enterZone(player, z)
    task.wait(0.7)
    assert(WM.getZoneFogState(player) == true, "Setup: should be in fog zone")
    ZM.exitZone(player, z)
    z:Destroy()  -- remove from allZones so Heartbeat cannot re-enter
    task.wait(0.7)
    assert(WM.getZoneFogState(player) == false,
        "WeatherManager should clear zone fog after player exits")
    cleanupFogZones()
end)

print(string.format("[WM_TEST] Done — %d pass / %d fail", passed, failed))
