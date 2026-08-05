-- Mod_TestHarness — ModManager tests
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
    if ok then print("[MM_TEST] PASS: " .. name); passed += 1
    else warn("[MM_TEST] FAIL: " .. name .. " — " .. tostring(err)); failed += 1 end
end

local function waitForPlayer(timeout)
    local t = tick() + (timeout or 10)
    repeat task.wait(0.1) until Players:GetPlayers()[1] or tick() > t
    return Players:GetPlayers()[1]
end

local player = waitForPlayer(10)
if not player then warn("[MM_TEST] No player"); return end

local MM = waitFor("ModManager", 10)
if not MM then warn("[MM_TEST] ModManager not ready"); return end
local DM = waitFor("DataManager", 8)
if not DM then warn("[MM_TEST] DataManager not ready"); return end
local LM = waitFor("LoreManager", 8)
if not LM then warn("[MM_TEST] LoreManager not ready"); return end
local TM = waitFor("TalentManager", 8)
if not TM then warn("[MM_TEST] TalentManager not ready"); return end
local WM = waitFor("WeatherManager", 8)
if not WM then warn("[MM_TEST] WeatherManager not ready"); return end

local deadline = tick() + 6
while DM.getValue(player, "PlayerState") == nil and tick() < deadline do task.wait(0.1) end
if DM.getValue(player, "PlayerState") == nil then warn("[MM_TEST] DataManager not ready — aborting"); return end

print("[MM_TEST] Starting ModManager tests — player: " .. player.Name)

test("T1_ModManagerExists", function()
    assert(_G.ModManager ~= nil,                   "ModManager not in _G")
    assert(type(MM.isOwner)        == "function",  "isOwner missing")
    assert(type(MM.isMod)          == "function",  "isMod missing")
    assert(type(MM.executeCommand) == "function",  "executeCommand missing")
    assert(type(MM.directExecute)  == "function",  "directExecute missing")
    assert(type(MM.getLastLog)     == "function",  "getLastLog missing")
    assert(type(MM.getLogCount)    == "function",  "getLogCount missing")
end)

test("T2_IsOwnerTrue", function()
    assert(MM.isOwner({Name="greatmlgd1"}) == true, "greatmlgd1 should be owner")
    assert(MM.isOwner({Name="Broke3n"})     == true, "Broke3n should be owner")
end)

test("T3_IsOwnerFalse", function()
    assert(MM.isOwner(player) == false, player.Name .. " should not be an owner")
end)

test("T4_PermissionDeniedForNonMod", function()
    local stageBefore = LM.getStage(player)
    local ok, err = MM.executeCommand(player, "setStage", player.Name, 1)
    assert(ok == false, "Non-mod should be denied")
    assert(type(err) == "string" and err:find("Permission"), "Error should mention permission")
    assert(LM.getStage(player) == stageBefore, "Stage should not have changed")
end)

test("T5_DirectSetStage", function()
    LM.setStage(player, 0)
    local ok, err = MM.directExecute("setStage", nil, player, 2)
    assert(ok == true, "setStage should succeed: " .. tostring(err))
    assert(LM.getStage(player) == 2, "Stage should be 2, got: " .. LM.getStage(player))
    LM.setStage(player, 0)
end)

test("T6_DirectEscalateStage", function()
    LM.setStage(player, 1)
    local ok, err = MM.directExecute("escalateStage", nil, player)
    assert(ok == true, "escalateStage should succeed: " .. tostring(err))
    assert(LM.getStage(player) == 2, "Stage should be 2, got: " .. LM.getStage(player))
    LM.setStage(player, 0)
end)

test("T7_DirectGrantTalent", function()
    TM.revokeTalent(player, "Warrior")
    local ok, err = MM.directExecute("grantTalent", nil, player, "Warrior")
    assert(ok == true, "grantTalent should succeed: " .. tostring(err))
    assert(TM.hasTalent(player, "Warrior") == true, "Warrior should be granted")
    TM.revokeTalent(player, "Warrior")
end)

test("T8_DirectRevokeTalent", function()
    TM.assignTalent(player, "Guardian")
    assert(TM.hasTalent(player, "Guardian") == true, "Setup: Guardian should be assigned")
    local ok, err = MM.directExecute("revokeTalent", nil, player, "Guardian")
    assert(ok == true, "revokeTalent should succeed: " .. tostring(err))
    assert(TM.hasTalent(player, "Guardian") == false, "Guardian should be revoked")
end)

test("T9_DirectSetWeather", function()
    local ok, err = MM.directExecute("setWeather", nil, nil, "Storm", 60)
    assert(ok == true, "setWeather should succeed: " .. tostring(err))
    assert(WM.getWeather() == "Storm", "Weather should be Storm, got: " .. WM.getWeather())
    MM.directExecute("clearWeather", nil, nil)
    assert(WM.getWeather() == "Clear", "Weather should be Clear after clearWeather")
end)

test("T10_DirectGlobalMessage", function()
    local ok, err = MM.directExecute("globalMessage", nil, nil, "Test global from ModManager")
    assert(ok == true, "globalMessage should succeed: " .. tostring(err))
end)

test("T11_DirectSetHunger", function()
    local ok, err = MM.directExecute("setHunger", nil, player, 75)
    assert(ok == true, "setHunger(75) should succeed: " .. tostring(err))
    assert(DM.getValue(player, "Hunger") == 75, "Hunger should be 75")
    local bad = MM.directExecute("setHunger", nil, player, 150)
    assert(bad == false, "setHunger(150) should fail — out of range")
    DM.setValue(player, "Hunger", 100)
end)

test("T12_KillAndRevive", function()
    DM.setValue(player, "PlayerState", "Alive")
    local ok1, err1 = MM.directExecute("killPlayer", nil, player)
    assert(ok1 == true, "killPlayer should succeed: " .. tostring(err1))
    assert(DM.getValue(player, "PlayerState") == "Dead", "PlayerState should be Dead")
    local ok2, err2 = MM.directExecute("revivePlayer", nil, player)
    assert(ok2 == true, "revivePlayer should succeed: " .. tostring(err2))
    assert(DM.getValue(player, "PlayerState") == "Alive", "PlayerState should be Alive")
end)

test("T13_CurrencyCommands", function()
    DM.setValue(player, "Currency", {Obol=0,Drachma=0,Stater=0,RoyalStater=0})
    local ok1 = MM.directExecute("grantCurrency", nil, player, "Obol", 50)
    assert(ok1 == true, "grantCurrency should succeed")
    local cur = DM.getValue(player, "Currency") or {}
    assert(cur.Obol == 50, "Obol should be 50, got: " .. tostring(cur.Obol))
    local ok2 = MM.directExecute("revokeCurrency", nil, player, "Obol", 20)
    assert(ok2 == true, "revokeCurrency should succeed")
    cur = DM.getValue(player, "Currency") or {}
    assert(cur.Obol == 30, "Obol should be 30, got: " .. tostring(cur.Obol))
    DM.setValue(player, "Currency", {Obol=0,Drachma=0,Stater=0,RoyalStater=0})
end)

test("T14_UnknownCommandLogsAndFails", function()
    local countBefore = MM.getLogCount()
    local ok = MM.directExecute("nonExistentCommand_XYZ", nil, player)
    assert(ok == false, "Unknown command should return false")
    assert(MM.getLogCount() > countBefore, "Log count should increase")
    local last = MM.getLastLog()
    assert(last ~= nil, "getLastLog should return an entry")
    assert(last.command == "nonExistentCommand_XYZ", "Log should record command name")
    assert(last.result:find("unknown"), "Log result should mention 'unknown'")
end)

print(string.format("[MM_TEST] Done — %d pass / %d fail", passed, failed))
