--[[
	CombatModel -- the pure maths behind level-based melee (2026-08-09).

	No Instances, no globals, no os.clock(). Every function is a pure function of its
	arguments, so the harness can drive a whole exchange at fixed timestamps and assert the
	outcome exactly -- the same contract MovementModel and VelocityModel keep, and the reason
	those two have real tests while the old combat stack never did.

	THE CENTRAL RULE: a defence only works if its LEVEL MATCHES the incoming attack's.
	Attacking from a crouch or a slide is a LOW attack; anything else is HIGH. Guarding and
	parrying carry a level the same way, taken from the same stance. Guard high against a low
	sweep and it hits you.

	Time is passed IN as `now` rather than read, so nothing here can disagree with the caller
	about what time it is. The server passes os.clock(); tests pass whatever they like.
]]

local CombatModel = {}

CombatModel.Level = {
	High = "High",
	Low  = "Low",
}

-- The stances that make an attack (or a defence) LOW. These are MoveState values on the
-- client and derived server-side from the crouch/slide getters -- either way the vocabulary
-- is the same so the two sides cannot drift.
local LOW_STATES = {
	Crouching     = true,
	CrouchWalking = true,
	Sliding       = true,
}

--[[ Level from a movement state string. Anything unrecognised (including nil) is High:
     failing to High is the safe default, because a mistaken High attack is merely blockable
     by a High guard, whereas defaulting to Low would let a bug produce unblockable-looking
     hits against anyone standing. ]]
function CombatModel.levelFromState(moveState)
	return LOW_STATES[moveState] and CombatModel.Level.Low or CombatModel.Level.High
end

function CombatModel.isLowState(moveState)
	return LOW_STATES[moveState] == true
end

-- The whole defensive contract in one line.
function CombatModel.levelsMatch(attackLevel, defenceLevel)
	return attackLevel == defenceLevel
end

-- ── Chain state ────────────────────────────────────────────────────────────
-- A swing advances the chain if it lands inside the reset window, otherwise it starts over
-- at 1. Returned, never mutated in place, so a rejected swing cannot corrupt the state.

function CombatModel.newChain()
	return { count = 0, windowUntil = 0 }
end

--[[ Advance the chain for a swing at `now`. Returns (newChain, hitNumber, isFinisher).
     hitNumber is 1..chainMax and indexes the animation array directly.

     WRAPS after the finisher (fixed 2026-08-09). This used to clamp with math.min, so once
     you reached the last hit every further swing repeated the finisher forever -- spamming
     attack never returned to hit 1. A chain that has been completed starts over. ]]
function CombatModel.advanceChain(chain, now, cfg)
	local chainMax = cfg.ChainMax or 4
	-- Only a swing inside the reset window continues anything; outside it the previous
	-- count is irrelevant and we are starting fresh either way.
	local prev = (chain and now <= (chain.windowUntil or 0)) and (chain.count or 0) or 0
	local count = (prev >= chainMax) and 1 or (prev + 1)
	-- The window is refreshed from THIS swing, so the reset clock measures the gap between
	-- swings rather than the age of the chain.
	local newChain = { count = count, windowUntil = now + (cfg.ChainResetTime or 2) }
	return newChain, count, count >= chainMax
end

-- The finisher hits harder. Everything else uses the base figure.
function CombatModel.knockbackFor(isFinisher, cfg)
	if isFinisher then return cfg.KnockbackFinisher or 45 end
	return cfg.Knockback or 20
end

-- ── Attack kind ────────────────────────────────────────────────────────────
CombatModel.Kind = {
	Chain  = "Chain",
	Lunge  = "Lunge",
	Aerial = "Aerial",
	UpTilt = "UpTilt",
}

--[[ Which attack a swing becomes, from the attacker's situation.

     ctx = { airborne = bool, sprinting = bool, uncrouchedAt = number?, now = number }

     PRECEDENCE: Aerial > UpTilt > Lunge > Chain.
       * Airborne wins outright -- you cannot meaningfully lunge or rise off the ground.
       * UpTilt beats Lunge because it is a deliberate timed input (a 0.4s window after
         releasing crouch) while sprinting is merely the state you happened to be in;
         a deliberate input should never be swallowed by an ambient one.

     Only Chain touches the combo counter. The three contextual attacks sit outside it
     entirely, the same way the old stack's running M1 never touched chainCount. ]]
function CombatModel.attackKind(ctx, cfg)
	if not ctx then return CombatModel.Kind.Chain end
	if ctx.airborne then return CombatModel.Kind.Aerial end
	local ut = cfg and cfg.UpTilt
	if ut and ctx.uncrouchedAt and ctx.now then
		local since = ctx.now - ctx.uncrouchedAt
		if since >= 0 and since < (ut.Window or 0.4) then
			return CombatModel.Kind.UpTilt
		end
	end
	if ctx.sprinting then return CombatModel.Kind.Lunge end
	return CombatModel.Kind.Chain
end

-- Per-kind tuning, falling back to the base melee numbers so a missing block degrades to a
-- normal swing rather than erroring.
function CombatModel.profileFor(kind, cfg)
	local sub = cfg[kind] -- cfg.Lunge / cfg.Aerial / cfg.UpTilt
	if kind == CombatModel.Kind.Chain or not sub then
		return { damage = cfg.Damage or 10, knockback = cfg.Knockback or 20, vertical = 0 }
	end
	return {
		damage    = sub.Damage or cfg.Damage or 10,
		knockback = sub.Knockback or cfg.Knockback or 20,
		-- Up is positive, down negative. Aerial slams the victim into the floor; up-tilt
		-- launches them off it.
		vertical  = sub.UpForce or (sub.DownForce and -sub.DownForce) or 0,
	}
end

-- ── Timing windows ─────────────────────────────────────────────────────────

--[[ Is a parry started at `startedAt` still live at `now`? Pure comparison so the harness can
     prove the boundary is exclusive at both ends rather than trusting a live test. ]]
function CombatModel.parryActive(startedAt, now, cfg)
	if not startedAt then return false end
	local elapsed = now - startedAt
	return elapsed >= 0 and elapsed < (cfg.ParryWindow or 0.2)
end

--[[ RESOLUTION -- the one place the defensive outcome is decided.

     `defence` is the victim's state at the moment of resolution:
        { guarding = bool, guardLevel = Level, parryStartedAt = number?, parryLevel = Level? }

     Order is parry, then guard, then hit. Parry outranks guard because a player holding
     guard who then taps parry has clearly asked for the parry, and because parry is the
     harder, riskier read -- it should never be swallowed by the safer option.

     Returns "Parried" | "Blocked" | "Hit". A wrong-level defence returns "Hit", which is
     the entire point of the mechanic. ]]
function CombatModel.resolve(attackLevel, defence, now, cfg)
	if defence then
		if CombatModel.parryActive(defence.parryStartedAt, now, cfg)
			and CombatModel.levelsMatch(attackLevel, defence.parryLevel) then
			return "Parried"
		end
		if defence.guarding and CombatModel.levelsMatch(attackLevel, defence.guardLevel) then
			return "Blocked"
		end
	end
	return "Hit"
end

--[[ Would waiting out the reaction grace change anything? Used to decide whether a hit can be
     resolved immediately or must be deferred.

     Only a "Hit" is worth deferring: a parry or block is already the best outcome available
     to the defender, so waiting could only take it away. Deferring solely on Hit is also what
     keeps the grace from adding latency to the cases that already resolved. ]]
function CombatModel.shouldDefer(outcome)
	return outcome == "Hit"
end

return CombatModel
