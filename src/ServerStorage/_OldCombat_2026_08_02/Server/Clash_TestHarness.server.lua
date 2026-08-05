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
    if ok then print("[CL_TEST] PASS: " .. name); passed += 1
    else warn("[CL_TEST] FAIL: " .. name .. " — " .. tostring(err)); failed += 1 end
end

local function waitForPlayer(timeout)
    local t = tick() + (timeout or 10)
    repeat task.wait(0.1) until Players:GetPlayers()[1] or tick() > t
    return Players:GetPlayers()[1]
end

local player = waitForPlayer(10)
if not player then warn("[CL_TEST] No player"); return end

local CM_G = waitFor("ClashManager", 8)
if not CM_G then warn("[CL_TEST] ClashManager not ready"); return end
local CM   = waitFor("CombatManager", 8)
if not CM then warn("[CL_TEST] CombatManager not ready"); return end
local SM   = waitFor("StaminaManager", 8)
if not SM then warn("[CL_TEST] StaminaManager not ready"); return end

print("[CL_TEST] Starting ClashManager tests — player: " .. player.Name)

local function reset()
    CM.setCombatState(player, "Idle")
    CM.setSpeed(player, 1)
    SM.set(player, 100)
end

test("T1_RegisterM2Swing", function()
    CM_G.registerM2Swing(player)
    assert(CM_G ~= nil)
end)

test("T2_NoSelfClash", function()
    CM_G.registerM2Swing(player)
    local result = CM_G.checkClash(player, player)
    assert(result == false, "Self-clash should return false")
end)

test("T3_NotClashingInitially", function()
    reset()
    assert(CM_G.isClashing(player) == false)
end)

test("T4_StartClashSetsState", function()
    reset()
    CM_G.startClash(player, player)
    task.wait(0.05)
    assert(CM_G.isClashing(player) == true, "Should be clashing after startClash")
    assert(CM.getCombatState(player) == "Clashing", "CombatState should be Clashing, got: " .. CM.getCombatState(player))
    task.wait(3.1)
    reset()
end)

test("T5_SequenceLength", function()
    reset()
    CM_G.startClash(player, player)
    task.wait(0.05)
    local seq = CM_G.getSequence(player)
    assert(seq ~= nil, "Sequence should exist while clashing")
    assert(#seq == 5, "Expected 5-element sequence, got: " .. tostring(#seq))
    task.wait(3.1)
    reset()
end)

test("T6_SequenceValidInputs", function()
    reset()
    CM_G.startClash(player, player)
    task.wait(0.05)
    local seq = CM_G.getSequence(player)
    for _, v in ipairs(seq) do
        assert(v >= 1 and v <= 4, "Input out of range: " .. tostring(v))
    end
    task.wait(3.1)
    reset()
end)

test("T7_CorrectInputAdvances", function()
    reset()
    CM_G.startClash(player, player)
    task.wait(0.05)
    local seq = CM_G.getSequence(player)
    assert(CM_G.getProgress(player) == 0, "Progress should start at 0")
    CM_G.submitInput(player, seq[1])
    assert(CM_G.getProgress(player) == 1, "Progress should be 1, got: " .. tostring(CM_G.getProgress(player)))
    task.wait(3.1)
    reset()
end)

test("T8_WrongInputIgnored", function()
    reset()
    CM_G.startClash(player, player)
    task.wait(0.05)
    local seq = CM_G.getSequence(player)
    local wrong = (seq[1] % 4) + 1
    CM_G.submitInput(player, wrong)
    assert(CM_G.getProgress(player) == 0, "Progress should stay 0, got: " .. tostring(CM_G.getProgress(player)))
    task.wait(3.1)
    reset()
end)

test("T9_CompleteSequenceWins", function()
    reset()
    SM.set(player, 100)
    CM_G.startClash(player, player)
    task.wait(0.05)
    local seq = CM_G.getSequence(player)
    for _, v in ipairs(seq) do
        CM_G.submitInput(player, v)
    end
    task.wait(0.1)
    assert(CM_G.isClashing(player) == false, "Should not be clashing after completing sequence")
    reset()
end)

test("T10_StateResolvesAfterWin", function()
    reset()
    SM.set(player, 100)
    CM_G.startClash(player, player)
    task.wait(0.05)
    local seq = CM_G.getSequence(player)
    for _, v in ipairs(seq) do
        CM_G.submitInput(player, v)
    end
    task.wait(0.1)
    local state = CM.getCombatState(player)
    assert(state ~= "Clashing", "Should not be Clashing after resolve, got: " .. state)
    task.wait(1.0)
    reset()
end)

test("T11_NoDoubleClash", function()
    reset()
    CM_G.startClash(player, player)
    task.wait(0.05)
    assert(CM_G.isClashing(player) == true)
    local seq1 = CM_G.getSequence(player)
    CM_G.startClash(player, player)
    local seq2 = CM_G.getSequence(player)
    assert(seq1 == seq2, "Sequence should not change on double-start")
    task.wait(3.1)
    reset()
end)

test("T12_TimeoutDraw", function()
    reset()
    CM_G.startClash(player, player)
    task.wait(0.05)
    assert(CM_G.isClashing(player) == true)
    task.wait(3.1)
    assert(CM_G.isClashing(player) == false, "Should not be clashing after timeout")
    assert(CM.getCombatState(player) == "Idle", "Should be Idle after timeout, got: " .. CM.getCombatState(player))
    reset()
end)

print(string.format("[CL_TEST] Done — %d pass / %d fail", passed, failed))
