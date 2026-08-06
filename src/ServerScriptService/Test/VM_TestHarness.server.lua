-- VM_TestHarness — VelocityManager tests (movement rehaul phase 1, 2026-08-05)
--
-- The headline tests are the FRAMERATE-INDEPENDENCE ones, same as Movement_TestHarness:
-- they are only possible because ReplicatedStorage.Shared.VelocityModel is a pure function
-- of (state, now, dt, ctx) -- we can step a decaying shove at dt=1/240 and dt=1/30 and
-- assert the two cover the same ground. Physics on a client-owned character is NOT
-- server-assertable (a server write is overwritten by the next replication tick), which is
-- why the live tests below lean on applyKnockback's RETURN VALUE for players and only
-- measure real displacement on server-owned rigs.
--
-- This harness also registers the `vmtest` mod command (via ModManager.registerCommand) --
-- the interactive feel-test surface behind the mod menu's Studio-only VELOCITY TEST
-- section. Registered here, not in ModManager, so the command physically does not exist on
-- a live server.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local RepStorage = game:GetService("ReplicatedStorage")
if not RunService:IsStudio() then return end -- test harness: Studio-only, never runs live

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
    if ok then print("[VM_TEST] PASS: " .. name); passed += 1
    else warn("[VM_TEST] FAIL: " .. name .. " — " .. tostring(err)); failed += 1 end
end

local function waitForPlayer(timeout)
    local t = tick() + (timeout or 10)
    repeat task.wait(0.1) until Players:GetPlayers()[1] or tick() > t
    return Players:GetPlayers()[1]
end

local Model  = require(RepStorage.Shared.VelocityModel)
local Config = require(RepStorage.Shared.Config)
local VCFG   = Config.Velocity

local ctx = { config = VCFG }
local X = Vector3.xAxis
local Z = Vector3.zAxis

print("[VM_TEST] Starting velocity tests")

-- ── Pure model ─────────────────────────────────────────────────────────────

test("T1_SumIsVectorSum", function()
    local s = Model.newState()
    s = select(1, Model.add(s, { planar = X * 40 }, 0, ctx))
    s = select(1, Model.add(s, { planar = Z * 30 }, 0, ctx))
    local out = select(1, Model.resolve(s, 0, 0, ctx))
    assert((out.planar - Vector3.new(40, 0, 30)).Magnitude < 1e-6,
        "aligned contributions must vector-sum, got " .. tostring(out.planar))

    s = Model.newState()
    s = select(1, Model.add(s, { planar = X * 40 }, 0, ctx))
    s = select(1, Model.add(s, { planar = X * -25 }, 0, ctx))
    out = select(1, Model.resolve(s, 0, 0, ctx))
    assert((out.planar - X * 15).Magnitude < 1e-6,
        "opposing contributions must cancel to the difference, got " .. tostring(out.planar))
end)

test("T2_ExpiryPrunesAndDeactivates", function()
    local s = select(1, Model.add(Model.newState(), { planar = X * 40, duration = 0.5 }, 0, ctx))
    local out = select(1, Model.resolve(s, 0.49, 0, ctx))
    assert(out.active, "one tick before expiry the contribution must still drive")
    local newState
    out, newState = Model.resolve(s, 0.5, 0, ctx)
    assert(not out.active, "at expiry the output must go inactive")
    assert(out.planar.Magnitude < 1e-6, "expired contribution must stop contributing")
    assert(#newState.contributions == 0, "expired contribution must be pruned from state")
end)

test("T3_LinearDecayIsFramerateIndependent", function()
    -- A 40 studs/s shove fading linearly over 0.5s covers exactly 40*0.5/2 = 10 studs.
    -- resolve integrates each frame's coverage (midpoint + partial-frame scaling), so both
    -- framerates must land on the analytic answer, not just near each other.
    local function integrate(dt)
        local s = select(1, Model.add(Model.newState(),
            { planar = X * 40, duration = 0.5, decay = "linear" }, 0, ctx))
        local dist, now = 0, 0
        while now < 0.6 do
            local out; out, s = Model.resolve(s, now, dt, ctx)
            dist += out.planar.X * dt
            now += dt
        end
        return dist
    end
    local d240, d30 = integrate(1/240), integrate(1/30)
    assert(math.abs(d240 - 10) / 10 < 0.01, string.format("240fps covers %.4f, expected 10", d240))
    assert(math.abs(d30 - 10) / 10 < 0.01, string.format("30fps covers %.4f, expected 10", d30))
end)

test("T3b_ConstantCutIsFramerateIndependent", function()
    -- The nastier case: decay "none" ends in a CUT mid-frame. Without partial-frame
    -- coverage a 30fps client rides a 0.25s shove for 0.283s (+13%% distance).
    local function integrate(dt)
        local s = select(1, Model.add(Model.newState(), { planar = X * 40, duration = 0.25 }, 0, ctx))
        local dist, now = 0, 0
        while now < 0.35 do
            local out; out, s = Model.resolve(s, now, dt, ctx)
            dist += out.planar.X * dt
            now += dt
        end
        return dist
    end
    local d240, d30 = integrate(1/240), integrate(1/30)
    assert(math.abs(d240 - 10) / 10 < 0.01, string.format("240fps covers %.4f, expected 10", d240))
    assert(math.abs(d30 - 10) / 10 < 0.01, string.format("30fps covers %.4f, expected 10", d30))
end)

test("T4_MaxForceComposesByMax", function()
    local s = Model.newState()
    s = select(1, Model.add(s, { planar = X * 10, maxForce = 45000 }, 0, ctx))
    s = select(1, Model.add(s, { planar = X * 10, maxForce = 20000 }, 0, ctx))
    local out = select(1, Model.resolve(s, 0, 0, ctx))
    assert(out.maxForce == 45000,
        "maxForce must compose by MAX (the anti-fling invariant), got " .. out.maxForce)
end)

test("T5_VerticalConsumedExactlyOnce", function()
    local s = select(1, Model.add(Model.newState(),
        { planar = X * 20, vertical = 30, duration = 1 }, 0, ctx))
    local out, s2 = Model.resolve(s, 0, 1/60, ctx)
    assert(out.verticalImpulse == 30, "first resolve must report the vertical impulse")
    out = select(1, Model.resolve(s2, 0.1, 1/60, ctx))
    assert(out.verticalImpulse == 0, "second resolve must NOT re-report the vertical")
    assert(out.planar.Magnitude > 1, "planar must keep driving after the vertical is spent")
end)

test("T6_ZeroContributionsIsInert", function()
    local out = select(1, Model.resolve(Model.newState(), 0, 1/60, ctx))
    assert(not out.active and out.planar.Magnitude == 0 and out.verticalImpulse == 0
        and not out.suppressInput, "an empty state must resolve fully inert")
end)

test("T7_ClampsGuardTypos", function()
    local s, id = Model.add(Model.newState(), { planar = X * 9999, duration = 60 }, 0, ctx)
    assert(id, "a clampable spec is still accepted")
    local rec = s.contributions[1]
    assert(rec.duration <= VCFG.MaxDuration, "duration must clamp to MaxDuration, got " .. rec.duration)
    assert(rec.planar.Magnitude <= VCFG.MaxSpeed + 1e-6, "planar must clamp to MaxSpeed")
    local s2, id2 = Model.add(Model.newState(), { planar = "not a vector" }, 0, ctx)
    assert(id2 == nil and #s2.contributions == 0, "a junk planar must be refused outright")
end)

test("T8_FreshIdsStack_SameIdReplaces", function()
    -- Stacking is the chosen knockback rule: every hit gets a fresh id and vector-sums.
    local s = Model.newState()
    s = select(1, Model.add(s, { planar = X * 10 }, 0, ctx))
    s = select(1, Model.add(s, { planar = X * 10 }, 0, ctx))
    local out = select(1, Model.resolve(s, 0, 0, ctx))
    assert(math.abs(out.planar.X - 20) < 1e-6, "fresh ids must stack, got " .. out.planar.X)

    s = Model.newState()
    s = select(1, Model.add(s, { id = "dash", planar = X * 10 }, 0, ctx))
    s = select(1, Model.add(s, { id = "dash", planar = X * 25 }, 0, ctx))
    assert(#s.contributions == 1, "same id must replace, not accumulate")
    out = select(1, Model.resolve(s, 0, 0, ctx))
    assert(math.abs(out.planar.X - 25) < 1e-6, "replacement must carry the newest values")
end)

test("T9_UpdateRetargetsWithoutResettingClock", function()
    local s = select(1, Model.add(Model.newState(),
        { id = "slide", planar = X * 30, duration = 2, decay = "linear" }, 0, ctx))
    local before = s.contributions[1].expiresAt
    s = Model.update(s, "slide", Z * 30, ctx)
    assert(s.contributions[1].expiresAt == before, "update must not reset the expiry clock")
    local out = select(1, Model.resolve(s, 0, 0, ctx))
    assert(math.abs(out.planar.Z - 30) < 1e-6 and math.abs(out.planar.X) < 1e-6,
        "update must retarget the planar")
end)

test("T10_NilDurationPersistsUntilRemoved", function()
    local s, id = Model.add(Model.newState(), { id = "slide", planar = X * 30 }, 0, ctx)
    local out = select(1, Model.resolve(s, 1e6, 0, ctx))
    assert(out.active, "a durationless contribution must never expire on its own")
    s = Model.remove(s, id)
    out = select(1, Model.resolve(s, 1e6, 0, ctx))
    assert(not out.active, "remove must end it")
end)

-- ── Live server surface ────────────────────────────────────────────────────

local VM = waitFor("VelocityManager", 10)
if not VM then
    warn("[VM_TEST] VelocityManager not ready — skipping live tests")
    print(string.format("[VM_TEST] Done — %d pass / %d fail", passed, failed))
    return
end

-- A minimal server-owned rig: a Model with an unanchored HumanoidRootPart, spawned high
-- above the map so nothing collides. Server physics on it is deterministic -- exactly why
-- the displacement tests use rigs and never the player.
local rigs = {}
local function makeRig(name, pos)
    local m = Instance.new("Model")
    m.Name = name
    local root = Instance.new("Part")
    root.Name = "HumanoidRootPart"
    root.Size = Vector3.new(2, 2, 1)
    root.CFrame = CFrame.new(pos)
    root.Parent = m
    m.PrimaryPart = root
    m.Parent = workspace
    table.insert(rigs, m)
    return m, root
end
local function cleanup()
    for _, m in ipairs(rigs) do if m.Parent then m:Destroy() end end
    rigs = {}
end

test("S1_ManagerAndSeamRegistered", function()
    assert(type(VM.push) == "function" and type(VM.applyKnockback) == "function",
        "_G.VelocityManager surface incomplete")
    local cm = _G.CombatManager
    assert(cm and type(cm.applyKnockback) == "function",
        "CombatCore must delegate applyKnockback (the Shroom/Wolf call site)")
end)

test("S2_NpcPushMovesServerOwnedModel", function()
    cleanup()
    local _, root = makeRig("VM_TestRig", Vector3.new(0, 400, 0))
    local start = root.Position
    local ok = VM.push(root.Parent, { planar = X * 30, duration = 0.4, decay = "none", suppressInput = false })
    assert(ok, "push on a server-owned model must be accepted")
    task.wait(0.5)
    local delta = root.Position - start
    local flat = Vector3.new(delta.X, 0, delta.Z).Magnitude
    -- 30 studs/s * 0.4s = 12 studs nominal; generous band for solver slack and the free fall.
    assert(flat > 8 and flat < 20, string.format("expected ~12 studs flat displacement, got %.1f", flat))
    cleanup()
end)

test("S3_KnockbackResistScalesAndImmovableSkips", function()
    cleanup()
    local att = makeRig("VM_TestAttacker", Vector3.new(0, 400, 20))
    local vic = makeRig("VM_TestVictim", Vector3.new(0, 400, 24))

    vic:SetAttribute("KnockbackResist", 1)
    local spec, reason = VM.applyKnockback(att, vic, 40, nil, nil)
    assert(spec == nil and reason == "immovable", "resist 1 must refuse as immovable, got " .. tostring(reason))

    vic:SetAttribute("KnockbackResist", 0)
    local full = VM.applyKnockback(att, vic, 40, nil, nil)
    assert(full, "resist 0 must produce a spec")
    vic:SetAttribute("KnockbackResist", 0.5)
    local half = VM.applyKnockback(att, vic, 40, nil, nil)
    assert(half, "resist 0.5 must produce a spec")
    local ratio = half.planar.Magnitude / full.planar.Magnitude
    assert(math.abs(ratio - 0.5) < 0.01,
        string.format("resist 0.5 must halve the shove, got ratio %.3f", ratio))
    assert(full.planar.Magnitude > 30, "unresisted knockback should carry (about) the passed force")
    cleanup()
end)

test("S4_KnockbackDirectionIsAwayFromAttacker", function()
    cleanup()
    local att = makeRig("VM_TestAttacker", Vector3.new(0, 400, 0))
    local vic = makeRig("VM_TestVictim", Vector3.new(0, 400, 10))
    local spec = VM.applyKnockback(att, vic, 40, nil, nil)
    assert(spec, "knockback between two rigs must produce a spec")
    local dir = spec.planar.Unit
    assert(dir:Dot(Vector3.new(0, 0, 1)) > 0.99,
        "shove must point victim-away-from-attacker, got " .. tostring(dir))
    -- Lateral component composes on top and inherits resist scaling.
    local swept = VM.applyKnockback(att, vic, 40, Vector3.xAxis, 20)
    assert(swept and swept.planar.X > 15, "lateral shove must add its sideways component")
    cleanup()
end)

local player = waitForPlayer(10)
if not player then
    warn("[VM_TEST] No player — skipping roundtrip test")
else
    test("S5_PlayerPushRoundtripReplicatesBack", function()
        local char = player.Character or player.CharacterAdded:Wait()
        local hrp = char:WaitForChild("HumanoidRootPart", 5)
        assert(hrp, "no HumanoidRootPart")
        local ok = VM.pushPlayer(player, { planar = hrp.CFrame.LookVector * 40, duration = 0.6, decay = "none" })
        assert(ok, "pushPlayer must accept")
        task.wait(0.3)
        -- The client applied it and the velocity replicated back up. DELIBERATELY tolerant:
        -- replication timing makes a tight bound a coin flip, and the pure tests already own
        -- the exact numbers.
        local v = hrp.AssemblyLinearVelocity
        local flat = Vector3.new(v.X, 0, v.Z).Magnitude
        assert(flat >= 15, string.format("expected the client-applied push to replicate back (>=15 studs/s), got %.1f", flat))
        task.wait(0.5) -- let it expire before anyone plays on
    end)
end

print(string.format("[VM_TEST] Done — %d pass / %d fail", passed, failed))

-- ── Interactive feel tests: the `vmtest` mod command ───────────────────────
-- Fired from the mod menu's Studio-only VELOCITY TEST section (or any mod typing it).
-- Every mode routes through the REAL production path -- VelocityManager -> VelocityPush
-- remote -> VelocityClient -> the one VM_Velocity constraint -- so what you feel is what a
-- mob hit ships.
local MM = waitFor("ModManager", 10)
if MM and MM.registerCommand then
    MM.registerCommand("vmtest", function(exec, _, mode)
        local char = exec.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        assert(hrp, "no character to test on")
        local look, right = hrp.CFrame.LookVector, hrp.CFrame.RightVector
        mode = tostring(mode or "kb")

        if mode == "wind" then
            -- Non-suppressing blend: you keep walking while drifting; watch it cut at expiry.
            VM.pushPlayer(exec, { id = "test_wind", planar = look * 20, duration = 2, decay = "none", suppressInput = false })
        elseif mode == "kb" then
            -- The canonical hit-shove: input dead for a quarter second, linear fade.
            VM.pushPlayer(exec, { planar = -look * 40, duration = 0.25, decay = "linear", suppressInput = true })
        elseif mode == "sum" then
            -- Two opposing pushes: you drift at the 15 studs/s NET, decaying proportionally.
            VM.pushPlayer(exec, { planar = right * 45, duration = 1, decay = "linear", suppressInput = false })
            VM.pushPlayer(exec, { planar = -right * 30, duration = 1, decay = "linear", suppressInput = false })
        elseif mode == "launch" then
            -- One-shot vertical + planar: the mini-launch; gravity stays live (Plane mode).
            VM.pushPlayer(exec, { planar = look * 25, vertical = 30, duration = 0.35, decay = "linear", suppressInput = true })
        elseif mode == "hit" then
            -- The FULL knockback decision path (rage immunity, talent mult, direction from a
            -- real attacker) via a throwaway attacker rig conjured 3 studs in front of you.
            local att = Instance.new("Model"); att.Name = "VM_TestAttacker"
            local root = Instance.new("Part")
            root.Name = "HumanoidRootPart"; root.Anchored = true; root.CanCollide = false
            root.Transparency = 0.5; root.Size = Vector3.new(2, 2, 1)
            root.CFrame = CFrame.new(hrp.Position + look * 3, hrp.Position)
            root.Parent = att; att.PrimaryPart = root; att.Parent = workspace
            local spec, reason = VM.applyKnockback(att, char, 40, nil, nil)
            print("[VM_TEST] vmtest hit ->", spec and ("shoved " .. string.format("%.0f studs/s", spec.planar.Magnitude)) or ("refused: " .. tostring(reason)))
            task.delay(1, function() att:Destroy() end)
        elseif mode == "npc" then
            -- A server-owned part shoved in front of you -- the NPC half of the router,
            -- visibly.
            local rig = Instance.new("Model"); rig.Name = "VM_TestNPC"
            local root = Instance.new("Part")
            root.Name = "HumanoidRootPart"; root.Size = Vector3.new(2, 2, 1)
            root.BrickColor = BrickColor.new("Bright red")
            root.CFrame = CFrame.new(hrp.Position + look * 6 + Vector3.yAxis * 3)
            root.Parent = rig; rig.PrimaryPart = root; rig.Parent = workspace
            VM.push(rig, { planar = look * 30, duration = 0.5, decay = "linear", suppressInput = false })
            task.delay(3, function() rig:Destroy() end)
        else
            error("unknown vmtest mode: " .. mode .. " (wind|kb|sum|launch|hit|npc)")
        end
    end)
    print("[VM_TEST] `vmtest` mod command registered (wind|kb|sum|launch|hit|npc)")
else
    warn("[VM_TEST] ModManager.registerCommand unavailable — interactive vmtest not registered")
end
