-- Movement_TestHarness — movement revamp pass 1 (2026-08-04)
--
-- The headline tests are the FRAMERATE-INDEPENDENCE ones. They are only possible because
-- ReplicatedStorage.Shared.MovementModel is a pure function of (state, dt, dir, ctx): we can
-- step it 480x at 1/240 and 60x at 1/30 and assert the two cover the same ground. You cannot
-- write that test against a controller that reads RunService itself, which is exactly why
-- the maths was split out of MovementClient.
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
    if ok then print("[MV_TEST] PASS: " .. name); passed += 1
    else warn("[MV_TEST] FAIL: " .. name .. " — " .. tostring(err)); failed += 1 end
end

local function waitForPlayer(timeout)
    local t = tick() + (timeout or 10)
    repeat task.wait(0.1) until Players:GetPlayers()[1] or tick() > t
    return Players:GetPlayers()[1]
end

local Model  = require(RepStorage.Shared.MovementModel)
local Config = require(RepStorage.Shared.Config)
local MCFG   = Config.Movement
local MODEL  = MCFG.Model

local FORWARD = Vector3.new(0, 0, -1)
local BACK    = Vector3.new(0, 0, 1)

-- Integrate the model over a fixed wall-clock duration at a given dt, returning total
-- distance covered (in walkPower-seconds) and the final power.
local function integrate(dt, seconds, dir, ctx)
    local s = Model.newState()
    local dist, elapsed = 0, 0
    while elapsed < seconds - 1e-9 do
        s = Model.step(s, dt, dir, ctx)
        -- appliedPower, not walkPower: that is what moveVector() hands the Humanoid, and it
        -- is the frame AVERAGE, which is what makes short ramps integrate identically at
        -- any dt. Summing the endpoint instead is a left-Riemann sum and drifts ~13% at 30fps.
        dist = dist + s.appliedPower * dt
        elapsed = elapsed + dt
    end
    return dist, s.walkPower, s
end

local groundCtx = { config = MODEL, grounded = true }
-- THE FIXTURE THAT WAS MISSING. groundCtx passes no ceilingSpeed, so the model defaults it to
-- BaseSpeed (16), which is BELOW MomentumSpeedThreshold (20) -- meaning `heavy` can never be
-- true and the turn bleed can never fire. Two tests were asserting a sprint-only mechanic
-- through a walking context and had been failing ever since weight was moved up to sprint.
-- Momentum is deliberately a sprint-only phenomenon; testing it needs a sprint ceiling.
local sprintCtx = { config = MODEL, grounded = true, ceilingSpeed = MCFG.SprintSpeed, baseSpeed = MCFG.BaseWalkSpeed }

print("[MV_TEST] Starting movement tests")

-- ── Pure model ─────────────────────────────────────────────────────────────
test("M0_ResponseIsInstant", function()
    -- The entire point of removing the acceleration ramp: pressing a direction moves you at
    -- full speed on the FIRST frame, not a third of a second later. An accel ramp is input
    -- latency by another name, and combat cannot afford it.
    local s = Model.step(Model.newState(), 1/60, FORWARD, groundCtx)
    assert(s.walkPower >= 0.999,
        "first frame from a standstill must be full power, got " .. string.format("%.4f", s.walkPower))

    -- ...including when the stale heading points somewhere else entirely. At rest there is
    -- no momentum to redirect, so the heading snaps; without that the alignment gate would
    -- sit at zero and the character would refuse to set off for several frames.
    local s2 = Model.newState()
    s2.currentDir = BACK
    s2 = Model.step(s2, 1/60, FORWARD, groundCtx)
    assert(s2.walkPower >= 0.999,
        "a cold start in a new direction must also be instant, got " .. string.format("%.4f", s2.walkPower))
    assert(Model.angleBetweenDeg(s2.currentDir, FORWARD) < 1, "heading must snap to input while at rest")
end)

test("M1_SteadyStateIsFramerateIndependent", function()
    local d240 = integrate(1/240, 2.0, FORWARD, groundCtx)
    local d120 = integrate(1/120, 2.0, FORWARD, groundCtx)
    local d60  = integrate(1/60,  2.0, FORWARD, groundCtx)
    local d30  = integrate(1/30,  2.0, FORWARD, groundCtx)
    for _, pair in ipairs({{d120,"120"},{d60,"60"},{d30,"30"}}) do
        local drift = math.abs(pair[1] - d240) / d240
        assert(drift < 0.02, string.format("%sfps drifts %.3f%% from 240fps (limit 2%%)", pair[2], drift*100))
    end
end)

test("M2_DecelIsFramerateIndependent", function()
    -- Ramp to full, then release input and measure the skid at two very different dts.
    local function skid(dt)
        local s = Model.newState()
        for _ = 1, math.floor(1.0/dt) do s = Model.step(s, dt, FORWARD, groundCtx) end
        local dist, elapsed = 0, 0
        while elapsed < 1.0 - 1e-9 do
            s = Model.step(s, dt, nil, groundCtx)
            dist = dist + s.appliedPower * dt
            elapsed = elapsed + dt
        end
        return dist
    end
    local a, b = skid(1/240), skid(1/30)
    assert(math.abs(a - b) / a < 0.02, string.format("skid drifts %.3f%%", math.abs(a-b)/a*100))
    assert(a > 0.01, "releasing input should still carry the character forward (skid), got " .. tostring(a))
end)

test("M3_TurnLerpIsFramerateIndependent", function()
    -- The direction lerp uses 1-exp(-k*dt), not dt*k, precisely so this holds.
    local function turnAfter(dt)
        local s = Model.newState()
        s.currentDir = FORWARD
        for _ = 1, math.floor(0.5/dt) do s = Model.step(s, dt, Vector3.new(1,0,0), groundCtx) end
        return s.currentDir
    end
    local a, b = turnAfter(1/240), turnAfter(1/30)
    assert(Model.angleBetweenDeg(a, b) < 3, string.format("turn differs by %.2f deg across framerates", Model.angleBetweenDeg(a,b)))
end)

test("M4_SharpTurnCostsMomentum", function()
    -- Runs on sprintCtx: cornering is free below MomentumSpeedThreshold by design, so a walk
    -- context cannot observe this at all. (The old `forcedDecel` assertion went with the
    -- forced-decel mechanic itself -- step() has not returned that field since acceleration
    -- was removed, so it was comparing against nil.)
    local s = Model.newState()
    for _ = 1, 240 do s = Model.step(s, 1/60, FORWARD, sprintCtx) end
    assert(s.walkPower > 0.99, "should be at full power after 4s, got " .. tostring(s.walkPower))

    local lowest = s.walkPower
    for _ = 1, 45 do -- hold the reverse for 0.75s and watch the dip
        s = Model.step(s, 1/60, BACK, sprintCtx)
        lowest = math.min(lowest, s.walkPower)
    end
    assert(lowest < 1.0, string.format("a 180 at sprint speed must cost momentum, dipped only to %.4f", lowest))
end)

test("M5_GentleTurnCostsLessThanSharpTurn", function()
    -- Measured as the DIP over a sustained turn, not the value one frame later: accel is
    -- refilling the whole time, so a single-frame sample just reads 1.0 for both.
    -- sprintCtx, for the same reason as M4: a turn below the momentum threshold is free by
    -- design, so on groundCtx both of these read exactly 1.0 and the comparison is vacuous.
    -- `hard` is a full 180 rather than 90 degrees because SharpTurnAngle is 100 -- a 90 degree
    -- turn is deliberately inside the free band.
    local function minPowerThroughTurn(newDir)
        local s = Model.newState()
        for _ = 1, 240 do s = Model.step(s, 1/60, FORWARD, sprintCtx) end
        local lowest = s.walkPower
        for _ = 1, 45 do -- 0.75s of holding the new direction
            s = Model.step(s, 1/60, newDir, sprintCtx)
            lowest = math.min(lowest, s.walkPower)
        end
        return lowest
    end
    local gentle = minPowerThroughTurn(Vector3.new(0.26, 0, -0.97).Unit) -- ~15 deg
    local hard   = minPowerThroughTurn(BACK)                             -- 180 deg
    assert(gentle > hard, string.format("gentle turn (%.4f) should retain more than hard turn (%.4f)", gentle, hard))
    assert(hard < 0.95, string.format("a 180 at full sprint should visibly cost momentum, dipped only to %.4f", hard))
end)

test("M5b_TurnCostIsFramerateIndependent", function()
    -- The bug this guards: charging the bleed on the angle REMAINING to the target made a
    -- 240fps client pay 4x what a 60fps client paid for an identical turn.
    local function minPowerAt(dt)
        local s = Model.newState()
        for _ = 1, math.floor(4.0/dt) do s = Model.step(s, dt, FORWARD, sprintCtx) end
        local lowest = s.walkPower
        for _ = 1, math.floor(0.75/dt) do
            s = Model.step(s, dt, BACK, sprintCtx)
            lowest = math.min(lowest, s.walkPower)
        end
        return lowest
    end
    local a, b = minPowerAt(1/240), minPowerAt(1/30)
    assert(math.abs(a - b) < 0.06,
        string.format("turn cost differs across framerates: 240fps dipped to %.4f, 30fps to %.4f", a, b))
end)

test("M6_AerialPowerIsClampedButNeverDead", function()
    -- The committed-jump rule is "you cannot GAIN momentum in the air", and it is enforced by
    -- clamping to the power you took off with. Taken literally that made a jump from a
    -- STANDSTILL lock at zero -- no air control at all, for the whole jump -- which is the
    -- real bug the old version of this test was reporting sideways (it asked for a partial
    -- takeoff power by coasting for 8 frames, but GroundDecelTime is 0.06s, so 8 frames at
    -- 60fps lands at exactly 0). MinAirPower is the floor that separates the two.
    local airCtx = { config = MODEL, grounded = false }

    -- (a) A standing jump must still steer.
    local s = Model.newState()
    s = Model.step(s, 1/60, nil, airCtx) -- take off from a dead stop
    for _ = 1, 60 do s = Model.step(s, 1/60, FORWARD, airCtx) end
    assert(s.walkPower > 0.01,
        "a jump from a standstill must still have air control, got " .. string.format("%.4f", s.walkPower))
    assert(math.abs(s.walkPower - MODEL.MinAirPower) < 1e-3,
        string.format("standing-jump air power should settle at MinAirPower (%.2f), got %.4f",
            MODEL.MinAirPower, s.walkPower))

    -- (b) ...and a fast takeoff still cannot be exceeded, which is the part that matters.
    local f = Model.newState()
    for _ = 1, 60 do f = Model.step(f, 1/60, FORWARD, sprintCtx) end
    local takeoff = f.walkPower
    assert(takeoff > 0.99, "setup: should be at full power before taking off")
    local airSprint = { config = MODEL, grounded = false, ceilingSpeed = MCFG.SprintSpeed, baseSpeed = MCFG.BaseWalkSpeed }
    for _ = 1, 120 do f = Model.step(f, 1/60, FORWARD, airSprint) end
    assert(f.walkPower <= takeoff + 1e-6,
        string.format("air power %.4f exceeded takeoff power %.4f -- committed jumps broken", f.walkPower, takeoff))
end)

test("M6b_LightTurnsResolveFast", function()
    -- Weight belongs at sprint. At walking pace the heading has to arrive essentially when you
    -- press the key: TurnSmoothness alone swept a 90 degree turn over ~0.18s at every speed,
    -- so pressing S mid-run carved a full-speed U-turn instead of reversing.
    local RIGHT = Vector3.new(1, 0, 0)
    local function headingAfter(seconds, dt, ctx)
        local s = Model.newState()
        for _ = 1, math.floor(0.5/dt) do s = Model.step(s, dt, FORWARD, ctx) end
        for _ = 1, math.floor(seconds/dt) do s = Model.step(s, dt, RIGHT, ctx) end
        return Model.angleBetweenDeg(s.currentDir, RIGHT)
    end
    local left = headingAfter(0.1, 1/60, groundCtx)
    assert(left < 5,
        string.format("a 90 degree turn at walk should be done inside 0.1s, still %.1f deg out", left))
    -- ...and the snap must not have cost the framerate independence M3 guards.
    local a, b = headingAfter(0.1, 1/240, groundCtx), headingAfter(0.1, 1/30, groundCtx)
    assert(math.abs(a - b) < 3, string.format("light turn differs by %.2f deg across framerates", math.abs(a - b)))
end)

test("M7_ContextMultipliersActuallyApply", function()
    -- maxPower is how a surface or condition slows you now that acceleration is instant --
    -- an accelMult would have no ramp left to modulate.
    local mud = { config = MODEL, grounded = true, maxPower = 0.7 }
    local s = Model.newState()
    for _ = 1, 60 do s = Model.step(s, 1/60, FORWARD, mud) end
    assert(math.abs(s.walkPower - 0.7) < 0.01,
        string.format("maxPower must cap walkPower at 0.70, got %.4f", s.walkPower))

    -- decelMult is the other half of a surface's character: how long you slide.
    local function skidWith(decelMult)
        local c = { config = MODEL, grounded = true, decelMult = decelMult }
        local st = Model.newState()
        for _ = 1, 60 do st = Model.step(st, 1/60, FORWARD, c) end
        local d = 0
        for _ = 1, 90 do st = Model.step(st, 1/60, nil, c); d = d + st.appliedPower * (1/60) end
        return d
    end
    local slippery, grippy = skidWith(0.25), skidWith(1.6)
    assert(slippery > grippy * 2,
        string.format("ice should slide far further than grippy ground (%.3f vs %.3f)", slippery, grippy))
end)

test("M8_HugeDtIsClampedNotIntegratedWhole", function()
    -- A tab-out or a hitch can hand the model a multi-second dt. The clamp promises that a 5s
    -- frame is treated as a 0.1s one -- it does NOT promise you keep momentum, and asserting
    -- that was the stale part: GroundDecelTime is 0.06s, so even the clamped 0.1s legitimately
    -- stops you dead. Assert the clamp itself, which is the thing that actually holds.
    local function after(dt)
        local s = Model.newState()
        for _ = 1, 60 do s = Model.step(s, 1/60, FORWARD, groundCtx) end
        return Model.step(s, dt, nil, groundCtx)
    end
    local huge, clamped = after(5.0), after(0.1)
    assert(huge.walkPower >= 0, "walkPower must stay clamped")
    assert(math.abs(huge.walkPower - clamped.walkPower) < 1e-6,
        string.format("a 5s dt must behave exactly like a 0.1s one (%.4f vs %.4f)",
            huge.walkPower, clamped.walkPower))

    -- The clamp must also not let a hitch travel further than 0.1s of movement could.
    assert(huge.appliedPower * 0.1 < 0.06,
        string.format("a hitched frame covered too much ground: %.4f", huge.appliedPower * 0.1))
end)

test("M9_NoInputHoldsDirectionRatherThanZeroingIt", function()
    local s = Model.newState()
    for _ = 1, 60 do s = Model.step(s, 1/60, FORWARD, groundCtx) end
    local before = s.currentDir
    s = Model.step(s, 1/60, nil, groundCtx)
    assert(Model.angleBetweenDeg(before, s.currentDir) < 0.001, "currentDir must be held while coasting")
end)

-- The dash momentum curve, mirrored from MovementClient/MovementSystem so the tests can assert
-- distances rather than trusting either of them.
local function dashSpeedFor(speedNow)
    local d = MCFG.Dash
    local frac = math.clamp(speedNow / MCFG.SprintSpeed, 0, 1) ^ d.MomentumCurve
    return d.MinSpeed + (d.MaxSpeed - d.MinSpeed) * frac
end
local function dashStuds(speedNow) return dashSpeedFor(speedNow) * MCFG.Dash.Duration end

test("M10_DashDistanceIsConstantByConstruction", function()
    -- The dash is a timed LinearVelocity, so for a GIVEN launch speed its distance is
    -- speed x duration with no frame term at all. The speed now scales with momentum; the
    -- DURATION deliberately does not, because that fixed window is the whole mechanism.
    local d = MCFG.Dash
    assert(type(d.MinSpeed) == "number" and type(d.MaxSpeed) == "number" and type(d.Duration) == "number",
        "dash must be speed x time")
    assert(d.Duration > 0 and d.Duration < 1, "dash duration should be a short fixed window")
    assert(d.MaxSpeed > d.MinSpeed, "the curve needs somewhere to go")
    assert(d.Speed == nil, "Dash.Speed is gone -- a flat speed is what made a standing dodge a launch")
end)

test("M10b_DashScalesWithMomentum", function()
    -- The complaint this fixes: a dash from a standstill covered the same 17.6 studs as one
    -- out of a full sprint, so a standing dodge read as a launch.
    local standing = dashStuds(0)
    local walking  = dashStuds(MCFG.BaseWalkSpeed)
    local sprinting = dashStuds(MCFG.SprintSpeed)

    assert(standing < walking and walking < sprinting,
        string.format("dash must scale with momentum: %.1f / %.1f / %.1f", standing, walking, sprinting))
    assert(standing >= 5 and standing <= 9,
        string.format("a standing dash should be a dodge step (~7 studs), got %.1f", standing))
    assert(walking >= 9 and walking <= 13,
        string.format("a walking dash should land near 11 studs, got %.1f", walking))
    assert(sprinting >= 14 and sprinting <= 18,
        string.format("a sprinting dash should be a committed lunge (~16 studs), got %.1f", sprinting))
    -- Above the sprint ceiling the curve must saturate rather than keep growing -- otherwise a
    -- slide-cancel into a dash would launch you.
    assert(math.abs(dashStuds(MCFG.SprintSpeed * 3) - sprinting) < 1e-6, "dash speed must clamp at the top")
end)

test("M10c_DashHandbackDoesNotSaturate", function()
    -- MomentumCarry used to be billed against a constant 80 studs/s, so 0.4 x 80 = 32 was
    -- above every walk ceiling and EVERY dash -- including one from a dead stop -- ended
    -- clamped at walkPower 1. Billed against the dash's own speed it has to mean less at the
    -- bottom of the curve than at the top.
    local carry = MCFG.Dash.MomentumCarry
    local standingPower = math.clamp(dashSpeedFor(0) * carry / MCFG.BaseWalkSpeed, 0, 1)
    local sprintPower   = math.clamp(dashSpeedFor(MCFG.SprintSpeed) * carry / MCFG.SprintSpeed, 0, 1)
    assert(standingPower < 0.99,
        string.format("a standing dash must not hand back full momentum, got %.4f", standingPower))
    assert(standingPower > 0.1, "...but it should still flow into a run, got " .. string.format("%.4f", standingPower))
    assert(sprintPower > standingPower, "handback must scale with the dash it came from")
end)

test("M11_SlideIsACommitmentNotATeleport", function()
    -- EntryImpulse 55 meant a slide STARTED at 71 studs/s from a walk and covered ~62 studs on
    -- flat ground. Model the flat-ground case the way MovementClient integrates it: constant
    -- friction from the entry speed down to MinSlideSpeed.
    local S = MCFG.Slide
    local function flatDistance(entrySpeed)
        local v0 = math.min(S.MaxSpeed, entrySpeed + S.EntryImpulse)
        local t  = (v0 - S.MinSlideSpeed) / S.FlatFriction
        return (v0 + S.MinSlideSpeed) * 0.5 * t
    end
    local fromWalk   = flatDistance(MCFG.BaseWalkSpeed)
    local fromSprint = flatDistance(MCFG.SprintSpeed)
    assert(fromWalk >= 10 and fromWalk <= 22,
        string.format("a flat slide from a walk should cover ~15 studs, got %.1f", fromWalk))
    assert(fromSprint > fromWalk, "sliding from a sprint must go further than from a walk")
    assert(fromSprint <= 35,
        string.format("even a sprinting flat slide should stay a commitment, got %.1f studs", fromSprint))
    assert(S.MinSpeedToSlide > S.MinSlideSpeed,
        "you must not be able to enter a slide at a speed it would immediately end at")

    -- A HILL MUST NOT BE FREE SPEED. Slope acceleration competes with friction; it does not
    -- replace it. When it replaced it, every slope steeper than MinSlopeToSlide had zero drag
    -- and simply pinned you at MaxSpeed -- a measured slide down a gentle 11 degree hill ran
    -- 90 studs. Assert the crossover sits somewhere sane and steep.
    local function netAccelAt(deg) return S.SlopeAccelFactor * math.sin(math.rad(deg)) - S.FlatFriction end
    assert(netAccelAt(11) < 0, "a gentle hill must still bleed speed, not accelerate")
    assert(netAccelAt(20) < 0, "a moderate hill must still bleed speed")
    assert(netAccelAt(S.MaxSlopeAngle - 1) > 0,
        "...but a near-maximum slope must genuinely accelerate you, or the mechanic has no payoff")
end)

-- ── Live server surface ─────────────────────────────────────────────────────
local player = waitForPlayer(10)
if not player then warn("[MV_TEST] No player — skipping live tests"); return end

local MS = waitFor("MovementSystem", 10)
local MM = waitFor("MovementManager", 10)
local CM = waitFor("CombatManager", 10)
local SM = waitFor("StaminaManager", 10)

task.wait(1) -- let the character finish spawning

test("S1_SeamDelegatesToMovementSystem", function()
    assert(MS ~= nil, "_G.MovementSystem should be registered")
    assert(MM ~= nil, "_G.MovementManager must still exist — PotionManager calls it unguarded")
    -- The whole point of the seam: MovementManager's stubs now answer via MovementSystem.
    assert(type(MM.isSprinting) == "function" and MM.isSprinting(player) == false, "isSprinting should delegate and be false at rest")
    assert(type(MM.isDashing) == "function" and MM.isDashing(player) == false, "isDashing should delegate and be false at rest")
end)

test("S2_SprintRaisesCeilingThroughCombatCore", function()
    local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
    assert(hum, "no humanoid")
    if SM then SM.set(player, 100) end
    local base = hum.WalkSpeed
    -- Checked synchronously: setCeiling -> CombatCore.setSpeed writes WalkSpeed before
    -- startSprint returns. Waiting first would race the Heartbeat auto-cancel below, which
    -- is exactly what S2b covers.
    local ok, reason = MS.startSprint(player)
    assert(ok, "startSprint refused: " .. tostring(reason))
    assert(MS.isSprinting(player), "sprint should be active immediately")
    assert(hum.WalkSpeed > base, string.format("sprint must raise the ceiling (%.1f -> %.1f)", base, hum.WalkSpeed))
    MS.stopSprint(player)
    assert(not MS.isSprinting(player), "sprint should have stopped")
    assert(math.abs(hum.WalkSpeed - base) < 0.01, "ceiling should return to base")
end)

test("S2b_SprintAutoCancelsWhileStationary", function()
    -- Server-side anti-exploit: sprint is dropped the moment MoveDirection goes quiet, so a
    -- client that simply never sends SprintEnd cannot keep a free permanent speed boost.
    -- MoveDirection is replicated, so this is honest server state, not a client claim.
    if SM then SM.set(player, 100) end
    local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
    local ok = MS.startSprint(player)
    assert(ok, "setup: sprint should have started")
    task.wait(0.3) -- a few Heartbeats with the character standing still
    assert(not MS.isSprinting(player), "a stationary player must not stay sprinting")
end)

test("S3_IframesBlockDamageThroughTheRealFunnel", function()
    local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
    assert(hum, "no humanoid")
    hum.Health = hum.MaxHealth
    CM.grantIframes(player, 0.5)
    assert(CM.hasIframes(player), "iframes should be active")
    CM.applyDamage(hum, 25, player, "Player")
    assert(hum.Health == hum.MaxHealth, "damage must be ignored during iframes, health=" .. tostring(hum.Health))
    CM.grantIframes(player, -1) -- expire immediately
    CM.applyDamage(hum, 10, player, "Player")
    assert(hum.Health < hum.MaxHealth, "damage must land once iframes lapse")
    hum.Health = hum.MaxHealth
end)

test("S4_LagRefundReturnsRecentDamageAndIsCapped", function()
    local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
    assert(hum, "no humanoid")
    assert(type(CM.refundRecentDamage) == "function", "refundRecentDamage missing")
    hum.Health = hum.MaxHealth
    CM.grantIframes(player, -1)
    CM.applyDamage(hum, 20, player, "Player")
    local hurt = hum.Health
    assert(hurt < hum.MaxHealth, "setup damage should have landed")
    local refunded = CM.refundRecentDamage(player, 1.0, 100)
    assert(refunded > 0, "a hit inside the window should refund")
    assert(hum.Health > hurt, "health should have been restored")
    -- Consumed: refunding again must not pay out twice for the same hit.
    local second = CM.refundRecentDamage(player, 1.0, 100)
    assert(second == 0, "the same damage must not be refunded twice, got " .. tostring(second))
    hum.Health = hum.MaxHealth
end)

test("S5_RefundIsBoundedByMaxRefund", function()
    local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
    hum.Health = hum.MaxHealth
    CM.grantIframes(player, -1)
    CM.applyDamage(hum, 40, player, "Player")
    local refunded = CM.refundRecentDamage(player, 1.0, 5)
    assert(refunded <= 5, "refund must respect maxRefund, got " .. tostring(refunded))
    hum.Health = hum.MaxHealth
end)

test("S6_DodgeEconomyBurstsThenFatigues", function()
    -- Asserted as a BEHAVIOURAL contract, not as a stock count at a wall-clock instant.
    -- Counting stock after N dashes was flaky: the dashes have to be spaced by the real
    -- 0.6s cooldown, and under Studio load those waits stretch far enough for a stock to
    -- regenerate mid-test. What actually matters to a player is this: you get a burst of
    -- clean dodges, and sustained dodging degrades you to fatigued.
    local maxStock = Config.Movement.Dodge.MaxStock
    assert(MS.getDodgeStock(player) == maxStock, "should start at full stock")

    local cleans, sawFatigued, results = 0, false, {}
    for _ = 1, 12 do
        if SM then SM.set(player, 100) end -- isolate the economy from the stamina gate
        local r = tostring(MS.dash(player, "forward"))
        table.insert(results, r)
        if r == "clean" then cleans += 1
        elseif r == "fatigued" then sawFatigued = true; break end
        task.wait(Config.Movement.Dash.Cooldown + 0.05)
    end

    local trace = table.concat(results, ", ")
    assert(cleans >= maxStock,
        string.format("expected at least %d clean dodges before fatiguing, got %d (%s)", maxStock, cleans, trace))
    assert(sawFatigued,
        "sustained dodging must degrade to fatigued rather than refusing outright (" .. trace .. ")")
end)

test("S6b_EveryDodgeTierStillGrantsIframes", function()
    -- The design point of "fatigued": out of stock you still GET a dodge, it is just worse.
    -- A refused input with no feedback is what made the old dash feel broken.
    local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
    hum.Health = hum.MaxHealth
    if SM then SM.set(player, 100) end
    task.wait(Config.Movement.Dash.Cooldown + 0.05)
    local r = MS.dash(player, "forward")
    assert(r == "fatigued" or r == "clean", "dash should have gone through, got " .. tostring(r))
    assert(CM.hasIframes(player), "any dodge tier must grant i-frames (tier was " .. tostring(r) .. ")")
    CM.applyDamage(hum, 15, player, "Player")
    assert(hum.Health == hum.MaxHealth, "a dodge must block damage while its i-frames run")
    CM.grantIframes(player, -1)
    hum.Health = hum.MaxHealth
end)

test("S7_DodgeStockRegenerates", function()
    task.wait(Config.Movement.Dodge.RegenTime + 0.2)
    assert(MS.getDodgeStock(player) >= 1, "at least one stock should have regenerated")
end)

test("S8_FlowIsExposed", function()
    local flow = MS.getFlow(player)
    assert(type(flow) == "number" and flow >= 0 and flow <= 1,
        "getFlow must return 0..1 for the combat revamp to consume, got " .. tostring(flow))
end)

test("S8b_FlowReadsReplicatedStateNotAClientAttribute", function()
    -- The bug: MovementClient publishes Flow as a CHARACTER ATTRIBUTE, and attributes set on a
    -- client never replicate -- so server-side getFlow read nil and returned 0 for every
    -- player, forever. It has to come from something that actually crosses the wire.
    local char = player.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    assert(hum and hrp, "no character")

    -- The premise, asserted rather than assumed: the attribute genuinely is invisible up here.
    assert(char:GetAttribute("Flow") == nil,
        "the client-set Flow attribute should not be visible server-side -- if it is, this fix's premise changed")

    -- MoveDirection is the obvious-looking source and it is NOT usable: the engine normalises
    -- it, so it reads 1.0 for any non-zero move regardless of magnitude. Pin that down, because
    -- it is exactly the trap this test exists to stop someone walking back into.
    hum:Move(Vector3.new(0, 0, -0.25), false)
    task.wait(0.15)
    local md = hum.MoveDirection.Magnitude
    hum:Move(Vector3.zero, false)
    assert(md < 0.01 or md > 0.99,
        string.format("MoveDirection is normalised (0 or 1), never fractional -- got %.4f, so the premise changed", md))

    -- getFlow reads velocity, which does replicate and does carry magnitude.
    local restingFlow = MS.getFlow(player)
    assert(type(restingFlow) == "number" and restingFlow >= 0 and restingFlow <= 1,
        "getFlow must stay in 0..1, got " .. tostring(restingFlow))

    -- Asserted against the live velocity rather than by driving one: the character is
    -- client-owned, so a server-side write to AssemblyLinearVelocity is overwritten by the next
    -- replication tick and the test would be a coin flip. Reading both and comparing proves the
    -- wiring deterministically.
    local v = hrp.AssemblyLinearVelocity
    local expected = math.clamp(Vector3.new(v.X, 0, v.Z).Magnitude / math.max(1, hum.WalkSpeed), 0, 1)
    assert(math.abs(MS.getFlow(player) - expected) < 0.05,
        string.format("getFlow must track the replicated root velocity (%.4f vs %.4f)",
            MS.getFlow(player), expected))
end)

print(string.format("[MV_TEST] Done — %d pass / %d fail", passed, failed))
