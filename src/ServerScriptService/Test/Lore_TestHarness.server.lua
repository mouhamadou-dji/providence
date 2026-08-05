-- Lore_TestHarness — LoreManager tests
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
    if ok then print("[LM_TEST] PASS: " .. name); passed += 1
    else warn("[LM_TEST] FAIL: " .. name .. " — " .. tostring(err)); failed += 1 end
end

local function waitForPlayer(timeout)
    local t = tick() + (timeout or 10)
    repeat task.wait(0.1) until Players:GetPlayers()[1] or tick() > t
    return Players:GetPlayers()[1]
end

local player = waitForPlayer(10)
if not player then warn("[LM_TEST] No player"); return end

local LM = waitFor("LoreManager", 10)
if not LM then warn("[LM_TEST] LoreManager not ready"); return end
local DM = waitFor("DataManager", 8)
if not DM then warn("[LM_TEST] DataManager not ready"); return end

local deadline = tick() + 6
while DM.getValue(player, "PlayerState") == nil and tick() < deadline do
    task.wait(0.1)
end
if DM.getValue(player, "PlayerState") == nil then
    warn("[LM_TEST] DataManager player data not ready — aborting"); return
end

print("[LM_TEST] Starting LoreManager tests — player: " .. player.Name)

local function resetPD()
    DM.setValue(player, "PDStage", 0)
    DM.setValue(player, "PlayerState", "Alive")
    DM.setValue(player, "LoreEchoes", {})
    if LM.isGlobalPDActive() then LM.deactivatePDE() end
end

test("T1_GetStageValid", function()
    resetPD()
    local s = LM.getStage(player)
    assert(type(s) == "number" and s >= 0 and s <= 5,
        "getStage should return 0-5, got: " .. tostring(s))
end)

test("T2_SetStage", function()
    resetPD()
    LM.setStage(player, 3)
    assert(LM.getStage(player) == 3, "getStage should return 3")
    LM.setStage(player, 0)
end)

test("T3_SetStageInvalidThrows", function()
    local ok1 = pcall(function() LM.setStage(player, 6)   end)
    local ok2 = pcall(function() LM.setStage(player, -1)  end)
    local ok3 = pcall(function() LM.setStage(player, 1.5) end)
    assert(ok1 == false, "Stage 6 should throw")
    assert(ok2 == false, "Stage -1 should throw")
    assert(ok3 == false, "Stage 1.5 should throw")
end)

test("T4_EscalateStageIncrements", function()
    resetPD()
    LM.setStage(player, 1)
    local next = LM.escalateStage(player)
    assert(next == 2, "escalateStage should return 2, got: " .. tostring(next))
    assert(LM.getStage(player) == 2, "getStage should be 2")
    LM.setStage(player, 0)
end)

test("T5_EscalateCapAt5", function()
    resetPD()
    LM.setStage(player, 5)
    local result = LM.escalateStage(player)
    assert(result == 5, "escalate at max should return 5, got: " .. tostring(result))
    assert(LM.getStage(player) == 5, "stage should remain 5")
    LM.setStage(player, 0)
end)

test("T6_PDEFalseBelow3", function()
    resetPD()
    LM.setStage(player, 2)
    LM.activatePDE()
    assert(LM.isPDEEligible(player) == false,
        "Should not be eligible at Stage 2 even with global PD active")
    resetPD()
end)

test("T7_PDEFalseWithoutGlobalFlag", function()
    resetPD()
    LM.setStage(player, 3)
    assert(LM.isPDEEligible(player) == false,
        "Should not be eligible at Stage 3 while global PD is inactive")
    LM.setStage(player, 0)
end)

test("T8_PDETrueAt3WithGlobalFlag", function()
    resetPD()
    LM.setStage(player, 3)
    LM.activatePDE()
    assert(LM.isPDEEligible(player) == true,
        "Should be eligible at Stage 3 once global PD is active")
    resetPD()
end)

test("T9_DeactivatePDE", function()
    resetPD()
    LM.setStage(player, 4)
    LM.activatePDE()
    assert(LM.isPDEEligible(player) == true, "Should be eligible before deactivate")
    LM.deactivatePDE()
    assert(LM.isPDEEligible(player) == false, "Should not be eligible after deactivate")
    resetPD()
end)

test("T10_PDEAtStage5", function()
    resetPD()
    LM.setStage(player, 5)
    LM.activatePDE()
    assert(LM.isPDEEligible(player) == true, "Should be eligible at Stage 5")
    resetPD()
end)

test("T10b_GlobalPDAffectsEveryEligiblePlayer", function()
    resetPD()
    LM.setStage(player, 3)
    LM.activatePDE()
    -- The switch itself carries no per-player state -- any other Stage-3+ player in the
    -- server would read isGlobalPDActive()==true too, not just whoever a mod "targeted".
    assert(LM.isGlobalPDActive() == true, "Global PD flag should be active")
    resetPD()
end)

test("T11_LoreEchoes", function()
    resetPD()
    LM.addLoreEcho(player, "I saw the darkness")
    LM.addLoreEcho(player, "The scar remains")
    local echoes = LM.getLoreEchoes(player)
    assert(#echoes == 2, "Should have 2 echoes, got: " .. tostring(#echoes))
    assert(echoes[1].text == "I saw the darkness", "First echo text mismatch")
    assert(echoes[2].text == "The scar remains",   "Second echo text mismatch")
    assert(type(echoes[1].timestamp) == "number",   "Echo should have timestamp")
    assert(type(echoes[1].stage) == "number",       "Echo should have stage")
end)

test("T12_EchoEmptyStringThrows", function()
    local ok = pcall(function() LM.addLoreEcho(player, "") end)
    assert(ok == false, "Empty echo should throw")
end)

test("T13_WriteLoreRecord", function()
    local ok = pcall(function()
        LM.writeLoreRecord(player, "TEST_EVENT", { detail = "module10 test" })
    end)
    assert(ok == true, "writeLoreRecord should not throw")
end)

test("T14_ApplyLoreScar", function()
    local ok = pcall(function()
        LM.applyLoreScar(player, "TestZone_Module10")
    end)
    assert(ok == true, "applyLoreScar should not throw")
    local bad = pcall(function() LM.applyLoreScar(player, "") end)
    assert(bad == false, "Empty zoneName should throw")
end)

test("T15_TriggerPDERejectsIneligible", function()
    resetPD()
    local ok = pcall(function() LM.triggerPDE(player, "SomeZone") end)
    assert(ok == false, "triggerPDE should throw when not eligible")
end)

test("T16_TriggerPDESequence", function()
    resetPD()
    LM.setStage(player, 3)
    LM.activatePDE()
    assert(LM.isPDEEligible(player) == true, "Setup: should be eligible")
    LM.triggerPDE(player, "TestZone_PDE")
    assert(DM.getValue(player, "PlayerState") == "Dead",
        "PlayerState should be Dead after PDE")
    -- Global PD flag is unaffected by any single player's death -- it stays active for
    -- the rest of the server
    assert(LM.isGlobalPDActive() == true, "Global PD should still be active after one PDE death")
    -- Reset so player can continue
    DM.setValue(player, "PlayerState", "Alive")
    LM.setStage(player, 0)
end)

resetPD()
print(string.format("[LM_TEST] Done — %d pass / %d fail", passed, failed))
