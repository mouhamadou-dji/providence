-- MovementFlow_TestHarness — speed/jump composition tests (2026-08-10)
--
-- Nothing in this repo tested speed composition before. The one live WalkSpeed test
-- (Movement_TestHarness S2) exercises sprint IN ISOLATION and would pass with the
-- attack/guard clobbering bug fully present, because the bug only appears when TWO sources
-- overlap. That is the gap this fills.
--
-- Everything here is pure: MovementFlow takes state in and returns numbers, so a whole
-- interleaving can be replayed at exact values with no rig, no waiting and no flakiness.
local RunService = game:GetService("RunService")
local RepStorage = game:GetService("ReplicatedStorage")
if not RunService:IsStudio() then return end

local Flow   = require(RepStorage.Shared.MovementFlow)
local Config = require(RepStorage.Shared.Config)
local W      = Config.Movement.FlowWeights

local CFG = { BaseWalkSpeed = 16, BaseJumpPower = 50 }

local passed, failed = 0, 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then print("[FLOW_TEST] PASS: " .. name); passed += 1
	else warn("[FLOW_TEST] FAIL: " .. name .. " — " .. tostring(err)); failed += 1 end
end

local function near(a, b, tol)
	return math.abs(a - b) < (tol or 0.001)
end

local function walkOf(state)
	local w = Flow.resolve(state, CFG)
	return w
end

print("[FLOW_TEST] Starting movement flow tests")

-- ── Winner selection ───────────────────────────────────────────────────────

test("F1_EmptyLineupFallsBackToBase", function()
	-- The lineup is genuinely empty for a frame or two after every respawn. Falling back to
	-- the base is what stops a fresh character being frozen at zero.
	local s = Flow.newState()
	local walk, jump = Flow.resolve(s, CFG)
	assert(near(walk, 16), "empty lineup should walk at base, got " .. walk)
	assert(near(jump, 50), "empty lineup should jump at base, got " .. jump)
end)

test("F2_HighestWeightWins", function()
	local s = Flow.newState()
	Flow.setSetter(s, "Default", W.Default, 1)
	Flow.setSetter(s, "Crouch", W.Crouch, 0.5)
	Flow.setSetter(s, "Attack", W.Attack, 0.25)
	local walk, _, name = Flow.resolve(s, CFG)
	assert(name == "Attack", "Attack outranks Crouch, got " .. tostring(name))
	assert(near(walk, 4), "16 * 0.25 = 4, got " .. walk)
end)

test("F3_TiesGoToWhoeverRegisteredFIRST", function()
	-- Vagabond's version inserts with >=, handing ties to the NEWEST entry -- so two
	-- equal-weight systems steal the slot from each other on every refresh. Ties here are
	-- stable: the incumbent keeps it.
	local s = Flow.newState()
	Flow.setSetter(s, "First", 50, 0.5)
	Flow.setSetter(s, "Second", 50, 0.9)
	local _, _, name = Flow.resolve(s, CFG)
	assert(name == "First", "an equal-weight newcomer must not displace the incumbent, got " .. tostring(name))
end)

test("F4_RefreshDoesNotPromotePastAnEqualPeer", function()
	-- Re-registering a live source (a guard re-asserting itself) keeps its original sequence,
	-- so it cannot quietly jump ahead of an equal-weight source that was there first.
	local s = Flow.newState()
	Flow.setSetter(s, "First", 50, 0.5)
	Flow.setSetter(s, "Second", 50, 0.9)
	Flow.setSetter(s, "Second", 50, 0.8) -- refresh
	local _, _, name = Flow.resolve(s, CFG)
	assert(name == "First", "a refresh must not promote past an equal peer, got " .. tostring(name))
end)

test("F5_LowestWeightSetterIsStillRecorded", function()
	-- Vagabond silently DROPS a setter whose weight is below everything present (its insert
	-- loop has no tail append), so it never reappears when the high-priority source leaves.
	local s = Flow.newState()
	Flow.setSetter(s, "Stagger", W.Stagger, 0.3)
	Flow.setSetter(s, "Crouch", W.Crouch, 0.5) -- lower than everything currently present
	assert(Flow.hasSetter(s, "Crouch"), "the low-weight setter must still be recorded")
	Flow.clearSetter(s, "Stagger")
	local walk, _, name = Flow.resolve(s, CFG)
	assert(name == "Crouch", "it must surface once the higher one leaves, got " .. tostring(name))
	assert(near(walk, 8), "16 * 0.5 = 8, got " .. walk)
end)

-- ── Removal is exact ───────────────────────────────────────────────────────

test("F6_ClearingANonWinnerChangesNothing", function()
	local s = Flow.newState()
	Flow.setSetter(s, "Guard", W.Guard, 0.40)
	Flow.setSetter(s, "Attack", W.Attack, 0.25)
	local before = walkOf(s)
	Flow.clearSetter(s, "Guard")
	assert(near(walkOf(s), before), "clearing a loser must not move the resolved speed")
end)

test("F7_ClearingTheWinnerPromotesTheRunnerUp", function()
	local s = Flow.newState()
	Flow.setSetter(s, "Default", W.Default, 1)
	Flow.setSetter(s, "Guard", W.Guard, 0.40)
	Flow.setSetter(s, "Attack", W.Attack, 0.25)
	assert(near(walkOf(s), 4), "attack wins first")
	Flow.clearSetter(s, "Attack")
	assert(near(walkOf(s), 6.4), "guard should take over: 16 * 0.40 = 6.4, got " .. walkOf(s))
	Flow.clearSetter(s, "Guard")
	assert(near(walkOf(s), 16), "default should take over, got " .. walkOf(s))
end)

test("F8_ClearingIsIdempotentAndOrderIndependent", function()
	-- Cleanup paths can run twice, out of order, or after another source took over. None of
	-- that may corrupt the result -- this is the property the old restore-to-a-constant
	-- approach did not have.
	local s = Flow.newState()
	Flow.setSetter(s, "Default", W.Default, 1)
	Flow.setSetter(s, "Guard", W.Guard, 0.40)
	Flow.setSetter(s, "Attack", W.Attack, 0.25)
	Flow.clearSetter(s, "Attack")
	Flow.clearSetter(s, "Attack") -- again
	Flow.clearSetter(s, "Nonexistent")
	assert(near(walkOf(s), 6.4), "repeat/unknown clears must be harmless, got " .. walkOf(s))
end)

-- ── The reported bug, as a regression test ─────────────────────────────────

test("F9_REGRESSION_SwingThenGuardTapLeavesNoResidue", function()
	--[[ The exact interleaving the dev reported:
	         M1 -> windup boost
	         guard down -> guard slow
	         guard up   -> guard released
	         windup ends -> attack slow lands
	         swing ends  -> swing releases its keys
	     Under the old single-slot system the swing's restore was skipped (an unrelated state
	     flag had changed) and the player stayed at 4 studs/s forever. ]]
	local s = Flow.newState()
	Flow.setSetter(s, "Default", W.Default, 1)

	Flow.setSetter(s, "Windup", W.Windup, 1.125)          -- M1
	Flow.setSetter(s, "Guard", W.Guard, 0.40)             -- guard down
	Flow.clearSetter(s, "Guard")                          -- guard up
	Flow.setSetter(s, "Attack", W.Attack, 0.25)           -- windup ends
	assert(near(walkOf(s), 4), "mid-swing should be the attack commitment, got " .. walkOf(s))

	Flow.clearSetter(s, "Windup")                         -- swing cleanup
	Flow.clearSetter(s, "Attack")
	assert(near(walkOf(s), 16), "SPEED MUST RETURN TO BASE after the swing, got " .. walkOf(s))
end)

test("F10_REGRESSION_GuardHeldThroughAnEntireSwing", function()
	-- Guard raised mid-swing and still held when the swing ends: the swing must release only
	-- its own keys and leave the guard slow intact.
	local s = Flow.newState()
	Flow.setSetter(s, "Default", W.Default, 1)
	Flow.setSetter(s, "Windup", W.Windup, 1.125)
	Flow.setSetter(s, "Guard", W.Guard, 0.40)
	Flow.setSetter(s, "Attack", W.Attack, 0.25)
	Flow.clearSetter(s, "Windup")
	Flow.clearSetter(s, "Attack")
	assert(near(walkOf(s), 6.4), "still guarding, so guard speed: got " .. walkOf(s))
	Flow.clearSetter(s, "Guard")
	assert(near(walkOf(s), 16), "and base once the guard drops, got " .. walkOf(s))
end)

test("F11_REGRESSION_CrouchSurvivesASwing", function()
	-- Crouch is deliberately allowed during combat. A swing must not leave the player
	-- crouched-but-full-speed, which is what the old restore-to-1 did.
	local s = Flow.newState()
	Flow.setSetter(s, "Default", W.Default, 1)
	Flow.setSetter(s, "Crouch", W.Crouch, 0.5)
	Flow.setSetter(s, "Windup", W.Windup, 1.125)
	Flow.setSetter(s, "Attack", W.Attack, 0.25)
	Flow.clearSetter(s, "Windup")
	Flow.clearSetter(s, "Attack")
	assert(near(walkOf(s), 8), "should be back to crouch speed, not 16: got " .. walkOf(s))
end)

test("F12_StaggerOutranksEverythingBelowFreeze", function()
	local s = Flow.newState()
	Flow.setSetter(s, "Default", W.Default, 1)
	Flow.setSetter(s, "Sprint", W.Sprint, 1.625)
	Flow.setSetter(s, "Guard", W.Guard, 0.40)
	Flow.setSetter(s, "Stagger", W.Stagger, 0.30)
	assert(near(walkOf(s), 4.8), "stagger wins: 16 * 0.30, got " .. walkOf(s))
	Flow.clearSetter(s, "Stagger")
	assert(near(walkOf(s), 6.4), "guard resumes underneath it, got " .. walkOf(s))
end)

-- ── Modifiers and multipliers ──────────────────────────────────────────────

test("F13_TheFormula", function()
	-- (base * winnerMult + flat) * product(multipliers)
	local s = Flow.newState()
	Flow.setSetter(s, "Guard", W.Guard, 0.5)   -- 16 * 0.5 = 8
	Flow.setModifier(s, "Boots", 2)            -- + 2      = 10
	Flow.setMultiplier(s, "Health", 0.5)       -- * 0.5    = 5
	assert(near(walkOf(s), 5), "expected 5, got " .. walkOf(s))
end)

test("F14_MultipliersStackByProduct", function()
	local s = Flow.newState()
	Flow.setSetter(s, "Default", W.Default, 1)
	Flow.setMultiplier(s, "A", 1.1)
	Flow.setMultiplier(s, "B", 1.1)
	assert(near(walkOf(s), 16 * 1.21), "two +10% must give +21%, got " .. walkOf(s))
end)

test("F15_ScalarsApplyToWhicheverStateIsWinning", function()
	-- The dev's own description: "guarding I get the guard speed setter + health scaler +
	-- speedboost passive". The scalars follow the state rather than competing with it.
	local s = Flow.newState()
	Flow.setSetter(s, "Default", W.Default, 1)
	Flow.setMultiplier(s, "Injury", 0.5)
	assert(near(walkOf(s), 8), "injured and walking, got " .. walkOf(s))
	Flow.setSetter(s, "Guard", W.Guard, 0.40)
	assert(near(walkOf(s), 16 * 0.40 * 0.5), "injured AND guarding should compose, got " .. walkOf(s))
end)

test("F16_AbsoluteIgnoresBothLayers", function()
	-- A freeze must be immovable. Multiplying zero would hold, but a flat modifier would not,
	-- which is why absolute short-circuits both layers rather than relying on 0 * x.
	local s = Flow.newState()
	Flow.setSetter(s, "Freeze", W.Freeze, 0, 0, { absolute = true })
	Flow.setModifier(s, "Boots", 5)
	Flow.setMultiplier(s, "Swift", 1.5)
	local walk, jump = Flow.resolve(s, CFG)
	assert(near(walk, 0), "a frozen player must not move, got " .. walk)
	assert(near(jump, 0), "a frozen player must not jump, got " .. jump)
end)

test("F17_IgnoreListSkipsNamedScalarsOnly", function()
	local s = Flow.newState()
	Flow.setSetter(s, "Windup", W.Windup, 1, nil, { ignore = { "Injury" } })
	Flow.setMultiplier(s, "Injury", 0.5)
	Flow.setMultiplier(s, "Swift", 1.5)
	assert(near(walkOf(s), 16 * 1.5), "Injury excluded, Swift kept: got " .. walkOf(s))
end)

test("F18_NeverResolvesNegative", function()
	-- Vagabond permits negative speeds deliberately (it has a "Stop" state at -4). Nothing
	-- here wants that, and a negative WalkSpeed is a Roblox footgun.
	local s = Flow.newState()
	Flow.setSetter(s, "Default", W.Default, 1)
	Flow.setModifier(s, "Crippled", -999)
	local walk, jump = Flow.resolve(s, CFG)
	assert(walk == 0, "clamped at a standstill, got " .. walk)
	assert(jump >= 0, "jump clamped too, got " .. jump)
end)

test("F19_JumpTravelsWithTheSameWinner", function()
	local s = Flow.newState()
	Flow.setSetter(s, "Default", W.Default, 1, 1)
	Flow.setSetter(s, "Crouch", W.Crouch, 0.5, 0)  -- crouching cannot jump
	local walk, jump = Flow.resolve(s, CFG)
	assert(near(walk, 8), "walk from the crouch setter, got " .. walk)
	assert(near(jump, 0), "jump from the SAME setter, got " .. jump)
end)

-- ── Config sanity ──────────────────────────────────────────────────────────

test("F20_WeightOrderMatchesIntent", function()
	assert(W.Attack > W.Guard, "attack must outrank guard or the overlap is order-dependent")
	assert(W.Stagger > W.Attack, "a stagger must beat your own swing")
	assert(W.Freeze > W.Stagger, "freeze must beat everything")
	assert(W.Crouch > W.Sprint, "you cannot sprint out of a crouch")
	assert(W.Default == 0, "Default is the floor; nothing should register below it")
end)

print(("[FLOW_TEST] Done — %d passed, %d failed"):format(passed, failed))
