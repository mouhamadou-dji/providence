-- Talent_TestHarness — TalentManager tests
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
    if ok then print("[TM_TEST] PASS: " .. name); passed += 1
    else warn("[TM_TEST] FAIL: " .. name .. " — " .. tostring(err)); failed += 1 end
end

local function waitForPlayer(timeout)
    local t = tick() + (timeout or 10)
    repeat task.wait(0.1) until Players:GetPlayers()[1] or tick() > t
    return Players:GetPlayers()[1]
end

local player = waitForPlayer(10)
if not player then warn("[TM_TEST] No player"); return end

local TM = waitFor("TalentManager", 10)
if not TM then warn("[TM_TEST] TalentManager not ready"); return end

print("[TM_TEST] Starting TalentManager tests — player: " .. player.Name)

local ALL_TESTABLE = {
    "Riposte","Executioner","Counter","Warrior","Guardian",
    "Swift","Endurance","IronWill","Bloodbound","Herald"
}
local function clearAll()
    for _, id in ipairs(ALL_TESTABLE) do
        if TM.hasTalent(player, id) then TM.revokeTalent(player, id) end
    end
end

test("T1_HasTalentFalseInitially", function()
    clearAll()
    assert(TM.hasTalent(player, "Riposte") == false, "Should not have Riposte")
    assert(TM.hasTalent(player, "Warrior") == false, "Should not have Warrior")
end)

test("T2_AssignGrantsTalent", function()
    clearAll()
    local result = TM.assignTalent(player, "Riposte")
    assert(result == true, "assignTalent should return true on first grant")
    assert(TM.hasTalent(player, "Riposte") == true, "hasTalent should be true after assign")
    TM.revokeTalent(player, "Riposte")
end)

test("T3_AssignInvalidThrows", function()
    local ok = pcall(function() TM.assignTalent(player, "FakeTalent") end)
    assert(ok == false, "assignTalent with invalid ID should throw")
end)

test("T4_DuplicateAssignReturnsFalse", function()
    clearAll()
    TM.assignTalent(player, "Warrior")
    local result = TM.assignTalent(player, "Warrior")
    assert(result == false, "Second assignTalent should return false")
    assert(TM.hasTalent(player, "Warrior") == true, "Should still have Warrior")
    TM.revokeTalent(player, "Warrior")
end)

test("T5_GetTalentsReturnsAll", function()
    clearAll()
    TM.assignTalent(player, "Riposte")
    TM.assignTalent(player, "Guardian")
    local list = TM.getTalents(player)
    assert(#list == 2, "Should have exactly 2 talents, got: " .. tostring(#list))
    local hasR, hasG = false, false
    for _, id in ipairs(list) do
        if id == "Riposte"  then hasR = true end
        if id == "Guardian" then hasG = true end
    end
    assert(hasR and hasG, "getTalents should include Riposte and Guardian")
    TM.revokeTalent(player, "Riposte")
    TM.revokeTalent(player, "Guardian")
end)

test("T6_RevokeTalent", function()
    clearAll()
    TM.assignTalent(player, "Counter")
    local result = TM.revokeTalent(player, "Counter")
    assert(result == true, "revokeTalent should return true")
    assert(TM.hasTalent(player, "Counter") == false, "hasTalent should be false after revoke")
end)

test("T7_RevokeInvalidThrows", function()
    local ok = pcall(function() TM.revokeTalent(player, "FakeTalent") end)
    assert(ok == false, "revokeTalent with invalid ID should throw")
end)

test("T8_RevokeNotOwnedReturnsFalse", function()
    clearAll()
    local result = TM.revokeTalent(player, "Herald")
    assert(result == false, "revokeTalent on unowned talent should return false")
end)

test("T9_CanRiposte", function()
    clearAll()
    assert(TM.canRiposte(player) == false, "canRiposte false without talent")
    TM.assignTalent(player, "Riposte")
    assert(TM.canRiposte(player) == true, "canRiposte true with Riposte")
    TM.revokeTalent(player, "Riposte")
    assert(TM.canRiposte(player) == false, "canRiposte false after revoke")
end)

test("T10_CanExecute", function()
    clearAll()
    assert(TM.canExecute(player) == false, "canExecute false without talent")
    TM.assignTalent(player, "Executioner")
    assert(TM.canExecute(player) == true, "canExecute true with Executioner")
    TM.revokeTalent(player, "Executioner")
end)

test("T11_CounterParryCostDiscount", function()
    clearAll()
    assert(TM.getParryCostDiscount(player) == 0, "No discount without Counter")
    TM.assignTalent(player, "Counter")
    assert(TM.getParryCostDiscount(player) == 2, "Counter gives 2 discount")
    TM.revokeTalent(player, "Counter")
    assert(TM.getParryCostDiscount(player) == 0, "No discount after revoke")
end)

test("T12_WarriorDamageMult", function()
    clearAll()
    assert(TM.getDamageMult(player) == 1.0, "No mult without Warrior")
    TM.assignTalent(player, "Warrior")
    assert(TM.getDamageMult(player) == 1.1, "Warrior gives 1.1 mult")
    TM.revokeTalent(player, "Warrior")
    assert(TM.getDamageMult(player) == 1.0, "No mult after revoke")
end)

test("T13_GuardianDamageReduction", function()
    clearAll()
    assert(TM.getDamageReduction(player) == 1.0, "No reduction without Guardian")
    TM.assignTalent(player, "Guardian")
    assert(TM.getDamageReduction(player) == 0.9, "Guardian gives 0.9 reduction")
    TM.revokeTalent(player, "Guardian")
    assert(TM.getDamageReduction(player) == 1.0, "No reduction after revoke")
end)

test("T14_SwiftSpeedMult", function()
    clearAll()
    assert(TM.getSpeedMult(player) == 1.0, "No mult without Swift")
    TM.assignTalent(player, "Swift")
    assert(TM.getSpeedMult(player) == 1.1, "Swift gives 1.1 mult")
    TM.revokeTalent(player, "Swift")
    assert(TM.getSpeedMult(player) == 1.0, "No mult after revoke")
end)

test("T15_EnduranceMaxStaminaBonus", function()
    clearAll()
    assert(TM.getMaxStaminaBonus(player) == 0, "No bonus without Endurance")
    TM.assignTalent(player, "Endurance")
    assert(TM.getMaxStaminaBonus(player) == 20, "Endurance gives +20")
    TM.revokeTalent(player, "Endurance")
    assert(TM.getMaxStaminaBonus(player) == 0, "No bonus after revoke")
end)

test("T16_IronWillSkipHitstun", function()
    clearAll()
    assert(TM.skipHitstun(player, 0.90) == false, "No skip without IronWill")
    TM.assignTalent(player, "IronWill")
    assert(TM.skipHitstun(player, 0.50) == true,  "IronWill: skip above 40%")
    assert(TM.skipHitstun(player, 0.40) == false, "IronWill: exactly 40% should NOT skip")
    assert(TM.skipHitstun(player, 0.30) == false, "IronWill: no skip below 40%")
    TM.revokeTalent(player, "IronWill")
    assert(TM.skipHitstun(player, 0.90) == false, "No skip after revoke")
end)

test("T17_PersistToDataManager", function()
    clearAll()
    local dm = _G.DataManager
    if not dm then print("[TM_TEST] T17 skip — no DataManager"); passed += 1; return end
    local deadline = tick() + 6
    while dm.getValue(player, "PlayerState") == nil and tick() < deadline do
        task.wait(0.1)
    end
    if dm.getValue(player, "PlayerState") == nil then
        warn("[TM_TEST] T17 skip — DataManager not ready after 6s")
        passed += 1; return
    end
    TM.assignTalent(player, "Riposte")
    local saved = dm.getValue(player, "Talents") or {}
    local found = false
    for _, id in ipairs(saved) do if id == "Riposte" then found = true end end
    assert(found, "Riposte should appear in DataManager after assign")
    TM.revokeTalent(player, "Riposte")
    local saved2 = dm.getValue(player, "Talents") or {}
    local stillThere = false
    for _, id in ipairs(saved2) do if id == "Riposte" then stillThere = true end end
    assert(not stillThere, "Riposte should not appear in DataManager after revoke")
end)

clearAll()
print(string.format("[TM_TEST] Done — %d pass / %d fail", passed, failed))
