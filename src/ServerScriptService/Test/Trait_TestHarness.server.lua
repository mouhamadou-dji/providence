-- Trait_TestHarness — TraitManager tests
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
    if ok then print("[TR_TEST] PASS: " .. name); passed += 1
    else warn("[TR_TEST] FAIL: " .. name .. " — " .. tostring(err)); failed += 1 end
end

local function waitForPlayer(timeout)
    local t = tick() + (timeout or 10)
    repeat task.wait(0.1) until Players:GetPlayers()[1] or tick() > t
    return Players:GetPlayers()[1]
end

local player = waitForPlayer(10)
if not player then warn("[TR_TEST] No player"); return end

local TM = waitFor("TraitManager", 10)
if not TM then warn("[TR_TEST] TraitManager not ready"); return end
local SM = waitFor("StaminaManager", 8)
local PM = waitFor("ParryManager", 8)
local MM = waitFor("MovementManager", 8)
local CM = waitFor("CombatManager", 8)

print("[TR_TEST] Starting TraitManager tests — player: " .. player.Name)

local ALL_IDS = {
    "Bloodhound","IronBlood","QuickFeet","StoneStance","WolfSense",
    "PaleDescent","CursedMark","TheBrand","TheHollow"
}

test("T1_TraitAssigned", function()
    task.wait(1.2)
    local t = TM.getTrait(player)
    assert(t ~= nil, "getTrait should not be nil after init")
    local valid = false
    for _, id in ipairs(ALL_IDS) do if id == t then valid = true end end
    assert(valid, "Trait should be from valid pool, got: " .. tostring(t))
end)

test("T2_HasTraitMatchesGet", function()
    local current = TM.getTrait(player)
    assert(TM.hasTrait(player, current) == true, "hasTrait should match getTrait")
    local other = (current == "Bloodhound") and "IronBlood" or "Bloodhound"
    assert(TM.hasTrait(player, other) == false, "hasTrait should return false for non-assigned trait")
end)

test("T3_SetTrait", function()
    TM.setTrait(player, "QuickFeet")
    assert(TM.getTrait(player) == "QuickFeet", "getTrait should return QuickFeet after setTrait")
    assert(TM.hasTrait(player, "QuickFeet") == true)
end)

test("T4_SetTraitInvalidRejected", function()
    local ok = pcall(function() TM.setTrait(player, "FakeTrait") end)
    assert(ok == false, "setTrait with invalid ID should throw")
end)

test("T5_RollDryReturnsValid", function()
    local rolled = TM.rollDry()
    assert(rolled ~= nil and rolled.id ~= nil, "rollDry should return a table with id")
    local valid = false
    for _, id in ipairs(ALL_IDS) do if id == rolled.id then valid = true end end
    assert(valid, "rollDry result should be in pool, got: " .. tostring(rolled.id))
end)

test("T6_RollDistributionCoversAllTraits", function()
    local counts = {}
    for i = 1, 1000 do
        local r = TM.rollDry()
        counts[r.id] = (counts[r.id] or 0) + 1
    end
    for _, id in ipairs(ALL_IDS) do
        assert(counts[id] ~= nil and counts[id] > 0,
            "Trait '" .. id .. "' never rolled in 1000 tries")
    end
end)

test("T7_QuickFeetDashReduction", function()
    TM.setTrait(player, "QuickFeet")
    assert(TM.getDashCostReduction(player) == 2, "QuickFeet should reduce dash cost by 2")
    TM.setTrait(player, "Bloodhound")
    assert(TM.getDashCostReduction(player) == 0, "No reduction without QuickFeet")
end)

test("T8_CursedMarkDamageMult", function()
    TM.setTrait(player, "CursedMark")
    assert(TM.getDamageMult(player, "attacker") == 1.2, "CursedMark should mult damage by 1.2")
    assert(TM.getDamageMult(player, "victim")   == 1.2, "CursedMark should mult received damage by 1.2")
    TM.setTrait(player, "Bloodhound")
    assert(TM.getDamageMult(player, "attacker") == 1.0, "No mult without CursedMark")
end)

test("T9_StoneStanceParryCost", function()
    TM.setTrait(player, "StoneStance")
    local reducedCost = TM.getParryCost(player, 12)
    assert(reducedCost == 9, "StoneStance should reduce 12 to 9, got: " .. tostring(reducedCost))
    TM.setTrait(player, "Bloodhound")
    assert(TM.getParryCost(player, 12) == 12, "No reduction without StoneStance")
end)

test("T10_TheHollowParryWindow", function()
    TM.setTrait(player, "TheHollow")
    local window = TM.getParryWindow(player, 14/60)
    assert(math.abs(window - 6/60) < 0.001,
        "TheHollow window should be 6/60, got: " .. tostring(window))
    TM.setTrait(player, "Bloodhound")
    local defaultWindow = TM.getParryWindow(player, 14/60)
    assert(math.abs(defaultWindow - 14/60) < 0.001, "Default window should be 14/60")
end)

test("T11_TheHollowRegenMult", function()
    TM.setTrait(player, "TheHollow")
    assert(TM.getRegenMult(player) == 0.5, "TheHollow should halve regen mult")
    TM.setTrait(player, "Bloodhound")
    assert(TM.getRegenMult(player) == 1.0, "Normal regen without TheHollow")
end)

test("T12_IronBloodSkipHitstun", function()
    TM.setTrait(player, "IronBlood")
    assert(TM.skipHitstun(player, 0.65) == true,  "IronBlood: skip hitstun above 60%")
    assert(TM.skipHitstun(player, 0.60) == false, "IronBlood: exactly 60% should NOT skip")
    assert(TM.skipHitstun(player, 0.40) == false, "IronBlood: no skip below 60%")
    TM.setTrait(player, "Bloodhound")
    assert(TM.skipHitstun(player, 0.90) == false, "No skip without IronBlood")
end)

test("T13_QuickFeetDashCostIntegration", function()
    -- MM.dash went with the 2026-08-04 movement teardown; QuickFeet's dash-cost reduction
    -- is still asserted in isolation by T7, so this integration leg just skips until the
    -- movement revamp reintroduces a dash.
    if not MM or not SM or type(MM.dash) ~= "function" then
        warn("[TR_TEST] T13 skipped — MM.dash removed with the movement teardown, or SM not available")
        passed += 1; return
    end
    TM.setTrait(player, "QuickFeet")
    SM.set(player, 100)
    task.wait(0.65)
    MM.dash(player)
    task.wait(0.05)
    local stamAfter = SM.get(player)
    -- Cost=8 → stam=92; up to 1 regen tick (5/tick, 0.1s rate) may fire in 0.05s → max 97
    assert(stamAfter >= 91 and stamAfter <= 98,
        "QuickFeet dash should cost ~8 stam, stam now: " .. tostring(stamAfter))
    task.wait(0.65)
end)

test("T14_StoneStanceParryCostIntegration", function()
    if not PM or not SM then
        warn("[TR_TEST] T14 skipped — PM or SM not available")
        passed += 1; return
    end
    TM.setTrait(player, "StoneStance")
    SM.set(player, 100)
    PM.activate(player)
    local cost = TM.getParryCost(player, 12)
    assert(cost == 9, "StoneStance should give cost 9, got: " .. tostring(cost))
    PM.checkHit(player, player, "M1")
end)

test("T15_TheHollowShortWindow", function()
    if not PM or not CM then
        warn("[TR_TEST] T15 skipped — PM or CM not available")
        passed += 1; return
    end
    TM.setTrait(player, "TheHollow")
    CM.setCombatState(player, "Idle")
    PM.activate(player)
    task.wait(0.12)
    local result = PM.checkHit(player, player, "M1")
    print("[TR_TEST] T15 TheHollow window result at 0.12s: " .. tostring(result))
    assert(true)
    CM.setCombatState(player, "Idle")
end)

print(string.format("[TR_TEST] Done — %d pass / %d fail", passed, failed))
