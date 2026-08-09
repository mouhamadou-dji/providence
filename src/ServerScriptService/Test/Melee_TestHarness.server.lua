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

test("T10_ChainAdvancesAndCaps", function()
	local c, n, fin = Model.newChain(), nil, nil
	for expected = 1, MCFG.ChainMax do
		c, n, fin = Model.advanceChain(c, expected * 0.1, MCFG)
		assert(n == expected, ("hit %d expected, got %s"):format(expected, tostring(n)))
		assert(fin == (expected == MCFG.ChainMax), "finisher flag wrong at hit " .. expected)
	end
	-- Past the cap it clamps rather than overflowing the animation array.
	c, n = Model.advanceChain(c, MCFG.ChainMax * 0.1 + 0.1, MCFG)
	assert(n == MCFG.ChainMax, "chain must clamp at ChainMax, got " .. tostring(n))
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
	assert(MCFG.ParryWhiffCooldown > MCFG.ParryCooldown,
		"whiffing must cost more than landing, or mashing is free")
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
