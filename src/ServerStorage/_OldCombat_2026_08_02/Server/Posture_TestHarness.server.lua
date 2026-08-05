local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
if not RunService:IsStudio() then return end -- test harness: Studio-only, never runs in a live published server

local function waitFor(name, timeout)
    local t = tick() + (timeout or 8)
    while not _G[name] do
        if tick() > t then return nil end
        task.wait(0.05)
    end
    return _G[name]
end

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then print("[PT_TEST] PASS: " .. name); passed += 1
    else warn("[PT_TEST] FAIL: " .. name .. " — " .. tostring(err)); failed += 1 end
end

local function waitForPlayer(timeout)
    local t = tick() + (timeout or 10)
    repeat task.wait(0.1) until Players:GetPlayers()[1] or tick() > t
    return Players:GetPlayers()[1]
end

local player = waitForPlayer(10)
if not player then warn("[PT_TEST] No player"); return end

local PM = waitFor("PostureManager", 8)
if not PM then warn("[PT_TEST] PostureManager not ready"); return end
local CM = waitFor("CombatManager", 8)
if not CM then warn("[PT_TEST] CombatManager not ready"); return end

print("[PT_TEST] Starting PostureManager tests — player: " .. player.Name)

local function reset()
    PM.reset(player)
    CM.setCombatState(player, "Idle")
end

test("T1_InitialPostureZero", function()
    reset()
    assert(PM.get(player) == 0, "Expected 0, got: " .. PM.get(player))
end)

test("T2_FillIncreasesPosture", function()
    reset()
    PM.fill(player, 20)
    assert(PM.get(player) == 20, "Expected 20, got: " .. PM.get(player))
    reset()
end)

test("T3_SetClampsToMax", function()
    reset()
    PM.set(player, 999)
    assert(PM.get(player) == 100, "Expected 100 (clamped), got: " .. PM.get(player))
    reset()
end)

test("T4_DrainDecreasesPosture", function()
    reset()
    PM.set(player, 50)
    PM.drain(player, 20)
    assert(PM.get(player) == 30, "Expected 30, got: " .. PM.get(player))
    reset()
end)

test("T5_DrainClampsToZero", function()
    reset()
    PM.set(player, 10)
    PM.drain(player, 50)
    assert(PM.get(player) == 0, "Expected 0 (clamped), got: " .. PM.get(player))
    reset()
end)

test("T6_IsAtMax", function()
    reset()
    PM.set(player, 99)
    assert(PM.isAtMax(player) == false, "Should not be at max at 99")
    PM.set(player, 100)
    assert(PM.isAtMax(player) == true, "Should be at max at 100")
    reset()
end)

test("T7_FillToMaxTriggersGuardBreak", function()
    reset()
    PM.fill(player, 100)
    task.wait(0.05)
    local state = CM.getCombatState(player)
    assert(state == "GuardBroken", "Expected GuardBroken, got: " .. tostring(state))
    assert(PM.get(player) == 0, "Posture should reset to 0, got: " .. PM.get(player))
    task.wait(1.6)
    reset()
end)

test("T8_FillAccumulates", function()
    reset()
    PM.fill(player, 15)
    PM.fill(player, 20)
    PM.fill(player, 10)
    assert(PM.get(player) == 45, "Expected 45, got: " .. PM.get(player))
    reset()
end)

test("T9_ResetToZero", function()
    reset()
    PM.set(player, 60)
    PM.reset(player)
    assert(PM.get(player) == 0, "Expected 0 after reset, got: " .. PM.get(player))
end)

test("T10_IsGuardBrokenDuringBreak", function()
    reset()
    PM.fill(player, 100)
    task.wait(0.05)
    assert(PM.isGuardBroken(player) == true, "Should be guard broken immediately after break")
    task.wait(1.6)
    assert(PM.isGuardBroken(player) == false, "Should NOT be guard broken after duration")
    reset()
end)

test("T11_FillIgnoredDuringGuardBreak", function()
    reset()
    PM.fill(player, 100)
    task.wait(0.05)
    assert(PM.isGuardBroken(player) == true)
    PM.fill(player, 100)
    assert(PM.get(player) == 0, "Posture should remain 0, got: " .. PM.get(player))
    task.wait(1.6)
    reset()
end)

test("T12_NaturalDrainOverTime", function()
    reset()
    PM.set(player, 60)
    task.wait(1.0)
    local val = PM.get(player)
    assert(val < 60 and val > 45, "Expected ~55 after 1s drain, got: " .. tostring(val))
    reset()
end)

test("T13_ManualDrainFaster", function()
    reset()
    PM.set(player, 80)
    PM.setManualDrain(player, true)
    task.wait(1.0)
    PM.setManualDrain(player, false)
    local val = PM.get(player)
    assert(val < 70 and val > 55, "Expected ~65 after 1s manual drain, got: " .. tostring(val))
    reset()
end)

print(string.format("[PT_TEST] Done — %d pass / %d fail", passed, failed))
