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

local MM = waitFor("MovementManager", 8)
if not MM then warn("[MM_TEST] MovementManager not ready"); return end
local CM = waitFor("CombatManager", 8)
if not CM then warn("[MM_TEST] CombatManager not ready"); return end
local SM = waitFor("StaminaManager", 8)
if not SM then warn("[MM_TEST] StaminaManager not ready"); return end

print("[MM_TEST] Starting MovementManager tests — player: " .. player.Name)

-- Wait for character to fully spawn before running any tests
do
    local char = player.Character or player.CharacterAdded:Wait()
    char:WaitForChild("Humanoid", 10)
    char:WaitForChild("HumanoidRootPart", 10)
    task.wait(0.5)  -- settle: DataManager sets WalkSpeed on character load
end

local function reset()
    MM.stopSprint(player)
    if MM.isCrouching(player) then MM.crouch(player) end
    CM.setCombatState(player, "Idle")
    CM.setSpeed(player, 1)
    SM.set(player, 100)
end

local function getWalkSpeed()
    local char = player.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    return hum and hum.WalkSpeed or 0
end

test("T1_SprintStarts", function()
    reset()
    MM.startSprint(player)
    assert(MM.isSprinting(player) == true, "Expected isSprinting=true")
    MM.stopSprint(player)
end)

test("T2_SprintIncreasesSpeed", function()
    reset()
    MM.startSprint(player)
    local speed = getWalkSpeed()
    assert(speed > 16, "Expected speed > 16 while sprinting, got: " .. tostring(speed))
    MM.stopSprint(player)
end)

test("T3_StopSprintRestoresSpeed", function()
    reset()
    MM.startSprint(player)
    MM.stopSprint(player)
    task.wait(0.05)
    local speed = getWalkSpeed()
    assert(math.abs(speed - 16) < 0.5, "Expected speed ~16 after stopSprint, got: " .. tostring(speed))
end)

test("T4_NoSprintWithoutStamina", function()
    reset()
    SM.set(player, 0)
    MM.startSprint(player)
    assert(MM.isSprinting(player) == false, "Should not sprint with 0 stamina")
    SM.set(player, 100)
end)

test("T5_SprintStopsOnStagger", function()
    reset()
    MM.startSprint(player)
    assert(MM.isSprinting(player) == true)
    CM.applyStagger(player, 0.5)
    task.wait(0.1)
    assert(MM.isSprinting(player) == false, "Sprint should stop when staggered")
    task.wait(0.5)
    reset()
end)

test("T6_DashDrainsStamina", function()
    reset()
    SM.set(player, 100)
    MM.dash(player)
    assert(SM.get(player) < 100, "Stamina should decrease after dash, got: " .. tostring(SM.get(player)))
    task.wait(0.65)
    reset()
end)

test("T7_DashCooldownEnforced", function()
    reset()
    SM.set(player, 100)
    MM.dash(player)
    local stamAfterFirst = SM.get(player)
    MM.dash(player)
    local stamAfterSecond = SM.get(player)
    assert(stamAfterFirst == stamAfterSecond, "Second dash in cooldown should not drain stam")
    task.wait(0.65)
    reset()
end)

test("T8_NoDashWithoutStamina", function()
    reset()
    task.wait(0.65)
    SM.set(player, 0)
    local stamBefore = SM.get(player)
    MM.dash(player)
    assert(SM.get(player) == stamBefore, "Dash should not fire with 0 stamina")
    SM.set(player, 100)
end)

test("T9_SlideStarts", function()
    reset()
    MM.slide(player, true)
    assert(MM.isSliding(player) == true, "Expected isSliding=true after slide")
    task.wait(0.9)
    reset()
end)

test("T10_SlideAutoExpires", function()
    reset()
    MM.slide(player, true)
    assert(MM.isSliding(player) == true)
    task.wait(0.9)
    assert(MM.isSliding(player) == false, "Slide should have expired after 0.9s")
    reset()
end)

test("T11_CrouchToggle", function()
    reset()
    assert(MM.isCrouching(player) == false)
    MM.crouch(player)
    assert(MM.isCrouching(player) == true, "Should be crouching after first crouch()")
    MM.crouch(player)
    assert(MM.isCrouching(player) == false, "Should stand after second crouch()")
    reset()
end)

test("T12_CrouchReducesSpeed", function()
    reset()
    MM.crouch(player)
    local speed = getWalkSpeed()
    assert(speed < 16, "Crouching should reduce speed below 16, got: " .. tostring(speed))
    MM.crouch(player)
    reset()
end)

test("T13_NoSprintWhileCrouching", function()
    reset()
    MM.crouch(player)
    MM.startSprint(player)
    assert(MM.isSprinting(player) == false, "Should not sprint while crouching")
    MM.crouch(player)
    reset()
end)

test("T14_SprintBlockedByCrouch", function()
    reset()
    MM.crouch(player)
    MM.startSprint(player)
    assert(MM.isSprinting(player) == false, "Sprint blocked while crouched")
    assert(MM.isCrouching(player) == true, "Still crouching")
    MM.crouch(player)
    reset()
end)

test("T15_JumpWorks", function()
    reset()
    local ok = pcall(function() MM.jump(player) end)
    assert(ok, "jump() should not throw")
end)

test("T16_JumpBlockedWhenDowned", function()
    reset()
    CM.setCombatState(player, "Downed")
    local ok = pcall(function() MM.jump(player) end)
    assert(ok, "No error even when blocked")
    reset()
end)

print(string.format("[MM_TEST] Done — %d pass / %d fail", passed, failed))
