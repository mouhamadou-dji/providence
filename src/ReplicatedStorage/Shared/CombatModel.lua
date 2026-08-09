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
     hitNumber is 1..chainMax and indexes the animation array directly. ]]
function CombatModel.advanceChain(chain, now, cfg)
	local chainMax = cfg.ChainMax or 4
	local count
	if chain and now <= (chain.windowUntil or 0) then
		count = math.min((chain.count or 0) + 1, chainMax)
	else
		count = 1
	end
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
