local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
if not RunService:IsStudio() then return end -- test harness: Studio-only, never runs in a live published server

local function waitFor(name, timeout)
    local t = tick() + (timeout or 8)
    while not _G[name] do if tick()>t then return nil end; task.wait(0.05) end
    return _G[name]
end

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then print("[PM_TEST] PASS: "..name); passed+=1
    else warn("[PM_TEST] FAIL: "..name.." — "..tostring(err)); failed+=1 end
end

local function waitForPlayer(timeout)
    local t = tick()+(timeout or 10)
    repeat task.wait(0.1) until Players:GetPlayers()[1] or tick()>t
    return Players:GetPlayers()[1]
end

local player = waitForPlayer(10)
if not player then warn("[PM_TEST] No player"); return end

local PM = waitFor("ParryManager", 8)
if not PM then warn("[PM_TEST] ParryManager not ready"); return end
local CM = waitFor("CombatManager", 8)
if not CM then warn("[PM_TEST] CombatManager not ready"); return end

print("[PM_TEST] Starting — player: "..player.Name)

local function reset()
    CM.setCombatState(player, "Idle")
    local char=player.Character; if not char then return end
    local hum=char:FindFirstChildOfClass("Humanoid")
    if hum then hum.WalkSpeed=16; hum.JumpPower=50; hum.Health=100 end
end

-- T1: Not parrying initially
test("T1_NotParryingInit", function()
    assert(PM.isParrying(player)==false)
end)

-- T2: activate() opens window
test("T2_ActivateOpens", function()
    reset()
    assert(PM.activate(player)==true)
    assert(PM.isParrying(player)==true)
    PM.checkHit(player,player,"M1")
end)

-- T3: CombatState = Parrying after activate
test("T3_StateParrying", function()
    reset()
    PM.activate(player)
    assert(CM.getCombatState(player)=="Parrying", "got: "..CM.getCombatState(player))
    PM.checkHit(player,player,"M1"); reset()
end)

-- T4: checkHit immediately = Perfect
test("T4_PerfectParry", function()
    reset()
    PM.activate(player)
    local r = PM.checkHit(player,player,"M1")
    assert(r=="Perfect", "Expected Perfect, got: "..tostring(r))
    reset()
end)

-- T5: checkHit after perfect window = Late
test("T5_LateParry", function()
    reset()
    PM.activate(player)
    task.wait(0.08)
    local r = PM.checkHit(player,player,"M1")
    assert(r=="Late", "Expected Late, got: "..tostring(r))
    reset()
end)

-- T6: checkHit after full window = nil
test("T6_ExpiredNil", function()
    reset()
    PM.activate(player)
    task.wait(0.28)
    local r = PM.checkHit(player,player,"M1")
    assert(r==nil, "Expected nil after window, got: "..tostring(r))
    reset()
end)

-- T7: M2 into active parry = Break
test("T7_ParryBreak", function()
    reset()
    PM.activate(player)
    local r = PM.checkHit(player,player,"M2")
    assert(r=="Break", "Expected Break, got: "..tostring(r))
    reset()
end)

-- T8: isParrying false after hit resolves
test("T8_InactiveAfterHit", function()
    reset()
    PM.activate(player)
    PM.checkHit(player,player,"M1")
    assert(PM.isParrying(player)==false)
    reset()
end)

-- T9: whiff auto-expires
test("T9_WhiffExpires", function()
    reset()
    PM.activate(player)
    task.wait(0.30)
    assert(PM.isParrying(player)==false, "Still parrying after timeout")
    assert(CM.getCombatState(player)=="Idle", "Expected Idle, got: "..CM.getCombatState(player))
    reset()
end)

-- T10: getElapsed nil when not parrying
test("T10_ElapsedNilIdle", function()
    reset()
    assert(PM.getElapsed(player)==nil)
end)

-- T11: getElapsed positive immediately after activate
test("T11_ElapsedPositive", function()
    reset()
    PM.activate(player)
    local e = PM.getElapsed(player)
    assert(e~=nil and e>=0 and e<0.05, "elapsed="..tostring(e))
    PM.checkHit(player,player,"M1"); reset()
end)

-- T12: consecutive activations (second immediate activate after first resolves OK)
test("T12_ConsecutiveActivate", function()
    reset()
    PM.activate(player); PM.checkHit(player,player,"M1")
    assert(PM.isParrying(player)==false)
    PM.activate(player)
    assert(PM.isParrying(player)==true)
    PM.checkHit(player,player,"M1"); reset()
end)

print(string.format("[PM_TEST] Done — %d pass / %d fail", passed, failed))
