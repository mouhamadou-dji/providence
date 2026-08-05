-- HUD_TestHarness — HUDManager tests
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
    if ok then print("[HUD_TEST] PASS: " .. name); passed += 1
    else warn("[HUD_TEST] FAIL: " .. name .. " — " .. tostring(err)); failed += 1 end
end

local function waitForPlayer(timeout)
    local t = tick() + (timeout or 10)
    repeat task.wait(0.1) until Players:GetPlayers()[1] or tick() > t
    return Players:GetPlayers()[1]
end

local player = waitForPlayer(10)
if not player then warn("[HUD_TEST] No player"); return end

local HM = waitFor("HUDManager", 10)
if not HM then warn("[HUD_TEST] HUDManager not ready"); return end
local DM = waitFor("DataManager", 8)
if not DM then warn("[HUD_TEST] DataManager not ready"); return end
local LM = waitFor("LoreManager", 8)
if not LM then warn("[HUD_TEST] LoreManager not ready"); return end

local deadline = tick() + 6
while DM.getValue(player, "PlayerState") == nil and tick() < deadline do task.wait(0.1) end
if DM.getValue(player, "PlayerState") == nil then warn("[HUD_TEST] DataManager not ready — aborting"); return end

print("[HUD_TEST] Starting HUDManager tests — player: " .. player.Name)

test("T1_HUDManagerExists", function()
    assert(_G.HUDManager ~= nil, "HUDManager should be in _G")
    assert(type(HM.notifyHUD) == "function",         "notifyHUD missing")
    assert(type(HM.notifyEclipseMoon) == "function", "notifyEclipseMoon missing")
    assert(type(HM.showGlobalMessage) == "function", "showGlobalMessage missing")
end)

test("T2_NotifyHUDNoError", function()
    local ok = pcall(function() HM.notifyHUD(player, {Stamina=80,StaminaMax=100}) end)
    assert(ok, "notifyHUD should not throw with valid data")
end)

test("T3_NotifyHUDHunger", function()
    local ok = pcall(function() HM.notifyHUD(player, {Hunger=60,HungerMax=100}) end)
    assert(ok, "notifyHUD with Hunger should not throw")
end)

test("T4_NotifyHUDRejectsNonTable", function()
    local ok = pcall(function() HM.notifyHUD(player, "bad") end)
    assert(ok == false, "notifyHUD with string should throw")
end)

test("T5_EclipseStage0", function()
    local ok = pcall(function() HM.notifyEclipseMoon(player, 0) end)
    assert(ok, "notifyEclipseMoon(0) should not throw")
end)

test("T6_EclipseAllStages", function()
    for stage = 0, 5 do
        local ok, err = pcall(function() HM.notifyEclipseMoon(player, stage) end)
        assert(ok, "Stage " .. stage .. " should not throw: " .. tostring(err))
    end
end)

test("T7_EclipseRejectsStage6", function()
    local ok = pcall(function() HM.notifyEclipseMoon(player, 6) end)
    assert(ok == false, "Stage 6 should throw")
end)

test("T8_EclipseRejectsNegative", function()
    local ok = pcall(function() HM.notifyEclipseMoon(player, -1) end)
    assert(ok == false, "Stage -1 should throw")
end)

test("T9_EclipseRejectsFloat", function()
    local ok = pcall(function() HM.notifyEclipseMoon(player, 1.5) end)
    assert(ok == false, "Stage 1.5 should throw")
end)

test("T10_GlobalMessageNoError", function()
    local ok = pcall(function() HM.showGlobalMessage("Test announcement from Module 13") end)
    assert(ok, "showGlobalMessage should not throw")
end)

test("T11_GlobalMessageWithColor", function()
    local ok = pcall(function() HM.showGlobalMessage("Colored message", Color3.fromRGB(255,100,100)) end)
    assert(ok, "showGlobalMessage with color should not throw")
end)

test("T12_GlobalMessageRejectsEmpty", function()
    local ok = pcall(function() HM.showGlobalMessage("") end)
    assert(ok == false, "Empty global message should throw")
end)

test("T13_EclipseStagePolls", function()
    LM.setStage(player, 0)
    task.wait(2.5)
    LM.setStage(player, 3)
    task.wait(2.5)
    local last = HM.getLastStage(player)
    assert(last == 3, "getLastStage should be 3 after poll, got: " .. tostring(last))
    LM.setStage(player, 0)
end)

test("T14_HungerPolls", function()
    DM.setValue(player, "Hunger", 100)
    task.wait(2.5)
    DM.setValue(player, "Hunger", 42)
    task.wait(2.5)
    local last = HM.getLastHunger(player)
    assert(last == 42, "getLastHunger should be 42 after poll, got: " .. tostring(last))
    DM.setValue(player, "Hunger", 100)
end)

print(string.format("[HUD_TEST] Done — %d pass / %d fail", passed, failed))
