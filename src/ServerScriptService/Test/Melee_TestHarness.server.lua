-- Melee_TestHarness — level-based combat tests (2026-08-09)
--
-- The headline tests are the PURE ones: because ReplicatedStorage.Shared.CombatModel is a
-- pure function of (state, now, cfg), the whole level-matching contract and the parry window
-- boundary can be proved at exact timestamps with no rig, no waiting, and no flakiness. The
-- old combat stack had no tests at all, and its config comments record four separate rounds
-- of blind retuning as a result.
--
-- Live tests lean on decisions rather than physics wherever possible — the server cannot
-- assert a client-owned character's motion, but it can assert what IT decided.
--
-- Registers the `meleetest` mod command (level|chain|parry|guard|swing|box). Registered HERE,
-- not in ModManager, so the command physically does not exist on a live server.
local Players    = game:GetService("Players")
local RunService = game:GetService("RunService")
local RepStorage = game:GetService("ReplicatedStorage")
if not RunService:IsStudio() then return end

local Model  = require(RepStorage.Shared.CombatModel)
local Config = require(RepStorage.Shared.Config)
local MCFG   = Config.Melee
local Level  = Model.Level

local passed, failed = 0, 0
local function test(name, fn)
	local ok, err = pcall(fn)
	if ok then print("[MELEE_TEST] PASS: " .. name); passed += 1
	else warn("[MELEE_TEST] FAIL: " .. name .. " — " .. tostring(err)); failed += 1 end
end

local function waitFor(name, timeout)
	local t = os.clock() + (timeout or 10)
	while not _G[name] do
		if os.clock() > t then return nil end
		task.wait(0.05)
	end
	return _G[name]
end

print("[MELEE_TEST] Starting melee tests")

-- ── Pure: levels ───────────────────────────────────────────────────────────

test("T1_CrouchAndSlideAreLow", function()
	assert(Model.levelFromState("Crouching") == Level.Low, "Crouching must be Low")
	assert(Model.levelFromState("CrouchWalking") == Level.Low, "CrouchWalking must be Low")
	assert(Model.levelFromState("Sliding") == Level.Low, "Sliding must be Low")
end)

test("T2_EverythingElseIsHigh", function()
	for _, s in ipairs({ "Idle", "Walking", "Sprinting", "Airborne", "Dashing" }) do
		assert(Model.levelFromState(s) == Level.High, s .. " must be High")
	end
	-- Unknown and nil must fail to High: a mistaken High attack is merely blockable by a High
	-- guard, whereas defaulting to Low would make bugs look like unblockable hits.
	assert(Model.levelFromState(nil) == Level.High, "nil must default High")
	assert(Model.levelFromState("Nonsense") == Level.High, "unknown must default High")
end)

test("T3_MatchingIsTheWholeContract", function()
	assert(Model.levelsMatch(Level.High, Level.High), "High vs High must match")
	assert(Model.levelsMatch(Level.Low, Level.Low), "Low vs Low must match")
	assert(not Model.levelsMatch(Level.High, Level.Low), "High vs Low must NOT match")
	assert(not Model.levelsMatch(Level.Low, Level.High), "Low vs High must NOT match")
end)

-- ── Pure: resolution ───────────────────────────────────────────────────────

test("T4_GuardOnlyWorksAtMatchingLevel", function()
	local right = { guarding = true, guardLevel = Level.High }
	local wrong = { guarding = true, guardLevel = Level.Low }
	assert(Model.resolve(Level.High, right, 0, MCFG) == "Blocked", "matched guard must block")
	assert(Model.resolve(Level.High, wrong, 0, MCFG) == "Hit", "mismatched guard must NOT block")
end)

test("T5_ParryOnlyWorksAtMatchingLevel", function()
	local right = { parryStartedAt = 0, parryLevel = Level.Low }
	local wrong = { parryStartedAt = 0, parryLevel = Level.High }
	assert(Model.resolve(Level.Low, right, 0.05, MCFG) == "Parried", "matched parry must parry")
	assert(Model.resolve(Level.Low, wrong, 0.05, MCFG) == "Hit", "mismatched parry must NOT parry")
end)

test("T6_ParryOutranksGuard", function()
	-- Holding guard and then tapping parry is an explicit ask for the parry: the harder,
	-- riskier read must never be swallowed by the safer option sitting underneath it.
	local both = {
		guarding = true, guardLevel = Level.High,
		parryStartedAt = 0, parryLevel = Level.High,
	}
	assert(Model.resolve(Level.High, both, 0.05, MCFG) == "Parried", "parry must beat guard")
end)

test("T7_ParryWindowBoundaries", function()
	local w = MCFG.ParryWindow
	local d = { parryStartedAt = 100, parryLevel = Level.High }
	assert(Model.resolve(Level.High, d, 100, MCFG) == "Parried", "t=0 must be inside")
	assert(Model.resolve(Level.High, d, 100 + w * 0.99, MCFG) == "Parried", "just inside must parry")
	-- Exclusive at the far end: exactly at the window length the parry is already over.
	assert(Model.resolve(Level.High, d, 100 + w, MCFG) == "Hit", "exactly at the end must be expired")
	assert(Model.resolve(Level.High, d, 100 + w + 1, MCFG) == "Hit", "past the end must be expired")
end)

test("T8b_NilVictimResolvesWithoutThrowing", function()
	-- REGRESSION (2026-08-09). victimPlayer is nil for every NPC, wolf, shroom and the
	-- CombatDummy. The hit payload used to dereference victimPlayer.Name unguarded, which
	-- threw inside the swing coroutine -- so the speed/state restore never ran and the
	-- attacker was left stuck at attack walk-speed until their next swing. Anyone testing
	-- against the dummy hit this on every single swing.
	local ok, err = pcall(function()
		return Model.resolve(Level.High, nil, 0, MCFG)
	end)
	assert(ok, "resolving against a nil defence must not throw: " .. tostring(err))
	assert(Model.resolve(Level.High, nil, 0, MCFG) == "Hit", "an NPC with no defence is hit")
end)

test("T8_NoDefenceIsAHit", function()
	assert(Model.resolve(Level.High, nil, 0, MCFG) == "Hit", "nil defence must be a hit")
	assert(Model.resolve(Level.High, {}, 0, MCFG) == "Hit", "empty defence must be a hit")
end)

test("T9_OnlyHitsAreDeferred", function()
	-- The grace window may only ever help the defender, so a result that already favours them
	-- must resolve immediately rather than being re-rolled.
	assert(Model.shouldDefer("Hit"), "a hit must be deferred for the reaction grace")
	assert(not Model.shouldDefer("Blocked"), "a block must not be deferred")
	assert(not Model.shouldDefer("Parried"), "a parry must not be deferred")
end)

-- ── Pure: chain ────────────────────────────────────────────────────────────

test("T10_ChainAdvancesThenWrapsToOne", function()
	local c, n, fin = Model.newChain(), nil, nil
	for expected = 1, MCFG.ChainMax do
		c, n, fin = Model.advanceChain(c, expected * 0.1, MCFG)
		assert(n == expected, ("hit %d expected, got %s"):format(expected, tostring(n)))
		assert(fin == (expected == MCFG.ChainMax), "finisher flag wrong at hit " .. expected)
	end
	-- REGRESSION (2026-08-09). This used to clamp with math.min, so once you reached the
	-- finisher every further swing repeated it forever and spamming attack never returned
	-- to hit 1. The chain must start over instead.
	c, n, fin = Model.advanceChain(c, MCFG.ChainMax * 0.1 + 0.1, MCFG)
	assert(n == 1, "the swing after the finisher must wrap to hit 1, got " .. tostring(n))
	assert(not fin, "the wrapped swing is hit 1, not another finisher")
	-- And it keeps counting normally from there rather than sticking at 1.
	c, n = Model.advanceChain(c, MCFG.ChainMax * 0.1 + 0.2, MCFG)
	assert(n == 2, "the chain must continue after wrapping, got " .. tostring(n))
end)

-- ── Pure: attack kind ──────────────────────────────────────────────────────

test("T10b_AttackKindPrecedence", function()
	local K = Model.Kind
	local base = { airborne = false, sprinting = false, uncrouchedAt = nil, now = 100 }
	assert(Model.attackKind(base, MCFG) == K.Chain, "plain swing is a chain hit")

	local sprint = { airborne = false, sprinting = true, now = 100 }
	assert(Model.attackKind(sprint, MCFG) == K.Lunge, "sprinting swings lunge")

	local air = { airborne = true, sprinting = true, uncrouchedAt = 100, now = 100 }
	assert(Model.attackKind(air, MCFG) == K.Aerial, "airborne outranks everything")

	-- A deliberate timed input must not be swallowed by the ambient state you happened to
	-- be in, so up-tilt beats lunge.
	local both = { airborne = false, sprinting = true, uncrouchedAt = 100, now = 100.1 }
	assert(Model.attackKind(both, MCFG) == K.UpTilt, "up-tilt outranks lunge")
end)

test("T10c_UpTiltWindowBoundaries", function()
	local K, w = Model.Kind, MCFG.UpTilt.Window
	local function at(dt) return Model.attackKind({ uncrouchedAt = 100, now = 100 + dt }, MCFG) end
	assert(at(0) == K.UpTilt, "the instant of release is inside the window")
	assert(at(w * 0.99) == K.UpTilt, "just inside must up-tilt")
	assert(at(w) == K.Chain, "exactly at the window length it has expired")
	assert(at(w + 1) == K.Chain, "past the window is a normal swing")
end)

test("T10d_ProfilesAndVerticalDirection", function()
	local K = Model.Kind
	-- Up is positive, down negative — an up-tilt launches, an aerial slams.
	assert(Model.profileFor(K.UpTilt, MCFG).vertical > 0, "up-tilt must launch upward")
	assert(Model.profileFor(K.Aerial, MCFG).vertical < 0, "aerial must drive downward")
	assert(Model.profileFor(K.Chain, MCFG).vertical == 0, "a chain hit has no vertical")
	assert(Model.profileFor(K.Lunge, MCFG).damage == MCFG.Lunge.Damage, "lunge uses its own damage")
	-- An unknown kind must degrade to the base numbers rather than erroring.
	assert(Model.profileFor("Nonsense", MCFG).damage == MCFG.Damage, "unknown kind falls back")
end)

test("T11_ChainResetsAfterTheWindow", function()
	local c, n = Model.newChain()
	c, n = Model.advanceChain(c, 0, MCFG)
	assert(n == 1, "first swing is hit 1")
	c, n = Model.advanceChain(c, 0.1, MCFG)
	assert(n == 2, "prompt second swing continues the chain")
	-- A gap longer than ChainResetTime starts over.
	c, n = Model.advanceChain(c, 0.1 + MCFG.ChainResetTime + 0.01, MCFG)
	assert(n == 1, "a swing past the reset window restarts at 1, got " .. tostring(n))
end)

test("T12_FinisherHitsHarder", function()
	local base = Model.knockbackFor(false, MCFG)
	local fin  = Model.knockbackFor(true, MCFG)
	assert(fin > base, ("finisher knockback %d must exceed base %d"):format(fin, base))
end)

-- ── Config sanity ──────────────────────────────────────────────────────────

test("T13_ConfigIsCoherent", function()
	assert(#MCFG.Anims == MCFG.ChainMax,
		("Anims has %d entries but ChainMax is %d -- a chain hit would have no clip")
			:format(#MCFG.Anims, MCFG.ChainMax))
	assert(#MCFG.HitSounds >= 1, "at least one hit sound is required")
	-- The reaction grace must stay well inside the parry window, or a parry tapped on
	-- contact would expire before the deferred re-check ever looks at it.
	assert(MCFG.ReactionGrace < MCFG.ParryWindow,
		"ReactionGrace must be shorter than ParryWindow")
	-- The windup is the entire telegraph; if it is shorter than the reaction grace the
	-- defender is being asked to react to something they cannot have seen.
	assert(MCFG.Windup > MCFG.ReactionGrace, "Windup must exceed ReactionGrace")
	-- A swing must FIT inside its own cooldown. If the next swing can start while the
	-- previous one is still running, the new swing's token silently kills the old one
	-- mid-flight -- so its committed tail simply stops existing partway through.
	local swingLen = MCFG.Windup + (MCFG.SwingPhase or 0)
	assert(MCFG.SwingCooldown >= swingLen,
		("SwingCooldown %.2f must cover the whole attack, Windup + SwingPhase (%.2f)")
			:format(MCFG.SwingCooldown, swingLen))
	-- The hitbox frame lands at the END of the windup, so the windup must be the larger
	-- share -- it is the part a defender actually reads.
	assert(MCFG.Windup > (MCFG.SwingPhase or 0),
		"the telegraph should be longer than the follow-through")
	-- The windup is a boost and the active frames are the commitment; if that inverted, the
	-- telegraph would punish you and the hit would reward you.
	-- The windup is the only phase that touches movement now; the swing phase deliberately
	-- owns no speed source at all. Assert the boost is still a boost.
	assert((MCFG.WindupSpeedMult or 1) >= 1,
		"the windup should carry you into the swing, not slow you")
	assert(MCFG.AttackSpeedMult == nil,
		"AttackSpeedMult was removed 2026-08-10 -- the swing phase must not slow you")
	assert(MCFG.ParryWhiffCooldown > MCFG.ParryCooldown,
		"whiffing must cost more than landing, or mashing is free")
	-- Every contextual attack needs a clip index that actually exists in Anims.
	for _, kind in ipairs({ "Lunge", "Aerial", "UpTilt" }) do
		local sub = MCFG[kind]
		assert(sub, "missing Config.Melee." .. kind)
		local idx = sub.AnimIndex
		assert(idx and MCFG.Anims[idx],
			("%s.AnimIndex %s has no clip in Anims"):format(kind, tostring(idx)))
	end
	-- The lunge push lasts the windup, so it must not outlive the swing it belongs to.
	assert(MCFG.Lunge.ForwardForce > 0, "a lunge must actually carry you forward")
	-- The aerial carries you forward too since 2026-08-09 pt2.
	assert(MCFG.Aerial.ForwardForce > 0, "an aerial must carry you forward as well")
	-- The grab (catch + drag an airborne victim before the slam) was built and pulled the
	-- same session -- dev's call: "doing too much." Assert it stays gone rather than
	-- reappearing silently if Config is ever merged from an older branch.
	assert(MCFG.Aerial.GrabRange == nil and MCFG.Aerial.GrabOffset == nil,
		"the aerial grab was removed 2026-08-09 pt3 -- these keys should not exist")
end)

test("T13b_DashIframeCoverage", function()
	-- Dash.Duration went 0.22 -> 0.44 -> 0.22 (doubled, then halved back). At 0.44 the 0.30s
	-- of i-frames stopped covering the whole dash, giving it a punishable tail; back at 0.22
	-- that tail is gone and a dash is invulnerable start to finish again. This asserts the
	-- numbers are what we think they are, so a later change to either one is noticed here
	-- rather than in a fight.
	local dash = Config.Movement.Dash
	local dodge = Config.Movement.Dodge
	assert(dash.Duration == 0.22, "dash duration should be back at 0.22")
	assert(dodge.IframeDuration >= dash.Duration,
		"i-frames should cover the whole dash again at this duration")
end)

test("T13c_ReactionAnimsAreCoherent", function()
	local RA = MCFG.ReactionAnims
	assert(RA, "Config.Melee.ReactionAnims is missing -- combat would have no reactions at all")
	-- The guard HOLD is the one entry whose absence is both silent and unmissable: with no pose
	-- a raised guard is invisible, and the level read this entire system is built on is a read
	-- of body language. Every other entry may legitimately be an unauthored placeholder --
	-- CombatClient skips those and falls back.
	assert(type(RA.Guard) == "string" and RA.Guard ~= "" and RA.Guard ~= "rbxassetid://0",
		"ReactionAnims.Guard must be authored -- a guard with no pose is an invisible guard")
	-- Both sets are indexed by chain hit, so a full chain must not run off the end of either.
	-- Longer than ChainMax is fine: both carry the old stack's five clips.
	for _, name in ipairs({ "Parried", "GotHit" }) do
		local list = RA[name]
		assert(type(list) == "table" and #list >= MCFG.ChainMax,
			("ReactionAnims.%s has %d clips but ChainMax is %d -- a late chain hit would have"
				.. " no reaction"):format(name, (type(list) == "table") and #list or 0, MCFG.ChainMax))
	end
end)

-- ── Live ───────────────────────────────────────────────────────────────────

local MC = waitFor("CombatSystem", 10)

test("T14_RegisteredAtTheSeam", function()
	assert(MC ~= nil, "_G.CombatSystem must be registered")
	for _, name in ipairs({
		"isActionBlocked", "isSprintLocked", "isTurnCapped", "applyStagger",
		"clearHitstun", "isBlocking", "checkBlockHit",
		"isParrying", "getParryElapsed", "cancelParry",
	}) do
		assert(type(MC[name]) == "function", "missing seam delegate: " .. name)
	end
	-- getCombatState must stay UNregistered: CombatCore owns both the store and the
	-- character-attribute mirror, and registering only the getter would let the two diverge.
	assert(MC.getCombatState == nil,
		"getCombatState must not be registered -- CombatCore owns combat state")
	assert(MC.PlayerSwung and type(MC.PlayerSwung.Connect) == "function",
		"PlayerSwung must expose Connect -- WolfManager's read-parry polls for it")
end)

test("T15_DamageFunnelNotHijacked", function()
	-- Registering applyDamage would replace CombatCore's entire funnel body, silently
	-- discarding godmode, meditation immunity, the i-frame gate, damage history and the
	-- combat tag. This asserts we never start doing that by accident.
	assert(MC.applyDamage == nil,
		"MeleeCombat must NOT register applyDamage -- it would replace CombatCore's gates")
end)

test("T16_CombatManagerUntouched", function()
	local cc = _G.CombatCore
	assert(_G.CombatManager ~= nil, "_G.CombatManager must still exist")
	assert(cc == nil or _G.CombatManager == cc,
		"_G.CombatManager must still point at CombatCore -- 14 systems depend on it")
end)

-- ── Mod command ────────────────────────────────────────────────────────────
task.spawn(function()
	local MM = waitFor("ModManager", 15)
	if not MM or not MM.registerCommand then return end
	MM.registerCommand("meleetest", function(player, args)
		local sub = (args and args[1] or "level"):lower()
		if sub == "level" then
			return "level: " .. tostring(MC and MC.getLevel and MC.getLevel(player))
		elseif sub == "chain" then
			return "chain: " .. tostring(MC and MC.getChain and MC.getChain(player))
		elseif sub == "swing" then
			if MC and MC.swing then MC.swing(player) end
			return "swung"
		elseif sub == "parry" then
			if MC and MC.parry then MC.parry(player) end
			return "parry window opened"
		elseif sub == "guard" then
			if MC and MC.isBlocking and MC.isBlocking(player) then
				MC.guardEnd(player); return "guard released"
			end
			if MC and MC.guard then MC.guard(player) end
			return "guarding"
		elseif sub == "box" then
			_G.DEBUG_HITBOXES_ON = not _G.DEBUG_HITBOXES_ON
			return "hitbox visualiser: " .. tostring(_G.DEBUG_HITBOXES_ON)
		end
		return "usage: meleetest level|chain|swing|parry|guard|box"
	end)
	print("[MELEE_TEST] `meleetest` command registered (Studio only)")
end)

print(("[MELEE_TEST] Done — %d passed, %d failed"):format(passed, failed))
