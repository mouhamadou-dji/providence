--[[
	MovementFlow -- the pure resolution behind WalkSpeed and JumpPower (2026-08-10).

	THE PROBLEM IT REPLACES. CombatCore.setSpeed stored ONE number. Guard, attack, stagger,
	crouch, sprint, the Swift talent and freeze all pushed through that single slot, so every
	caller silently destroyed the previous one's value with no record it had existed. The
	failure that finally surfaced it: swing -> tap guard -> release guard -> the swing's own
	slow lands afterwards, its restore is skipped because an unrelated state flag changed,
	and the player is left at 4 studs/s permanently with nothing scheduled to fix it.

	THE MODEL. Sources are NAMED and WEIGHTED, so removing one can never disturb another:

	  SETTERS     compete. The highest weight wins; ties go to whichever was added FIRST.
	              The winner alone supplies the base.
	  MODIFIERS   flat additive deltas applied to the winner.
	  MULTIPLIERS multiplicative, applied last.

	      final = (BaseSpeed * winner.mult + SUM modifiers) * PRODUCT multipliers

	That formula is lifted from Vagabond's Data.Character.Movement, which solved this same
	problem. Five of its behaviours are deliberately NOT reproduced -- see the notes on
	setSetter and resolve.

	PURE. No Instances, no globals, no clock reads: every function is a function of its
	arguments, so the whole resolution is testable at exact values with no rig. Same contract
	MovementModel, VelocityModel and CombatModel keep.

	State is treated as immutable-ish: mutators return the state so callers read as a
	pipeline, but they mutate in place for speed. Never share a state table between characters.
]]

local MovementFlow = {}

-- Every setter carries both stats, so a source can never win speed and lose jump. A source
-- that only cares about one passes nil for the other and inherits it from the winner's
-- default of 1 -- i.e. "no opinion" rather than "set it to zero".
local DEFAULT_WALK_MULT = 1
local DEFAULT_JUMP_MULT = 1

function MovementFlow.newState()
	return {
		setters     = {}, -- [name] = {weight, walk, jump, seq, absolute, ignore}
		modifiers   = {}, -- [name] = {walk, jump}
		multipliers = {}, -- [name] = {walk, jump}
		seq         = 0,  -- insertion counter; breaks weight ties toward the OLDEST entry
	}
end

--[[ Register or replace a named setter.

     `opts` may carry:
       absolute = true    -- modifiers and multipliers do NOT apply. This is load-bearing:
                             it is what keeps a freeze at exactly 0 and a rooted attack rooted
                             even while a speed passive is live.
       ignore   = {names} -- apply everything EXCEPT these modifiers/multipliers.

     Re-registering an existing name KEEPS ITS ORIGINAL seq, so refreshing a live source (a
     guard re-asserting itself, say) does not quietly promote it past an equal-weight source
     that was there first. ]]
function MovementFlow.setSetter(state, name, weight, walkMult, jumpMult, opts)
	local existing = state.setters[name]
	local seq
	if existing then
		seq = existing.seq
	else
		state.seq += 1
		seq = state.seq
	end
	opts = opts or {}
	state.setters[name] = {
		weight   = weight or 0,
		walk     = walkMult or DEFAULT_WALK_MULT,
		jump     = jumpMult or DEFAULT_JUMP_MULT,
		seq      = seq,
		absolute = opts.absolute == true,
		ignore   = opts.ignore,
	}
	return state
end

function MovementFlow.clearSetter(state, name)
	state.setters[name] = nil
	return state
end

function MovementFlow.hasSetter(state, name)
	return state.setters[name] ~= nil
end

-- Flat additive deltas, in studs/s. Stored as DATA and folded at resolve time -- Vagabond
-- baked them into each setter on mutation and un-baked them with -= on removal, which made
-- add/remove order significant and let a modifier's own bookkeeping fields leak into the
-- arithmetic. Folding at resolve makes removal exact by construction.
function MovementFlow.setModifier(state, name, walkAdd, jumpAdd)
	state.modifiers[name] = { walk = walkAdd or 0, jump = jumpAdd or 0 }
	return state
end

function MovementFlow.clearModifier(state, name)
	state.modifiers[name] = nil
	return state
end

-- Multiplicative, and they stack by product: two +10% sources give 1.21, not 1.20.
function MovementFlow.setMultiplier(state, name, walkMul, jumpMul)
	state.multipliers[name] = { walk = walkMul or 1, jump = jumpMul or 1 }
	return state
end

function MovementFlow.clearMultiplier(state, name)
	state.multipliers[name] = nil
	return state
end

--[[ The winning setter: highest weight, ties to the LOWEST seq (added first).

     Vagabond inserts with `>=`, which hands ties to whichever was added LAST -- so two
     equal-weight systems steal the top slot from each other on every refresh. Ties here go
     to the incumbent, which is both what the dev described and the stable answer. ]]
local function winnerOf(state)
	local best, bestName = nil, nil
	for name, s in pairs(state.setters) do
		if best == nil
			or s.weight > best.weight
			or (s.weight == best.weight and s.seq < best.seq) then
			best, bestName = s, name
		end
	end
	return best, bestName
end

MovementFlow.winnerOf = winnerOf

local function ignored(setter, name)
	local list = setter.ignore
	if not list then return false end
	for _, n in ipairs(list) do
		if n == name then return true end
	end
	return false
end

--[[ Resolve to concrete WalkSpeed / JumpPower.

     cfg = { BaseWalkSpeed = number, BaseJumpPower = number }

     Returns walkSpeed, jumpPower, winnerName, winnerWeight. With no setters at all it falls
     back to the bases -- a character with an empty lineup walks normally rather than freezing,
     which matters because the lineup is empty for a frame or two after every respawn. ]]
function MovementFlow.resolve(state, cfg)
	local baseWalk = cfg.BaseWalkSpeed or 16
	local baseJump = cfg.BaseJumpPower or 50

	local win, winName = winnerOf(state)
	if not win then
		return baseWalk, baseJump, nil, 0
	end

	local walk = baseWalk * win.walk
	local jump = baseJump * win.jump

	-- `absolute` short-circuits BOTH layers. A freeze must stay 0 no matter what buffs are
	-- live, and multiplying 0 would technically hold but adding a flat modifier would not.
	if win.absolute then
		return walk, jump, winName, win.weight
	end

	for name, m in pairs(state.modifiers) do
		if not ignored(win, name) then
			walk += m.walk
			jump += m.jump
		end
	end

	for name, m in pairs(state.multipliers) do
		if not ignored(win, name) then
			walk *= m.walk
			jump *= m.jump
		end
	end

	-- Clamped at zero: a stack of penalties must stop at standing still rather than walking
	-- backwards. Vagabond deliberately allows negatives (it has a "Stop" state at -4); nothing
	-- in Providence wants that, and a negative WalkSpeed is a Roblox footgun.
	if walk < 0 then walk = 0 end
	if jump < 0 then jump = 0 end

	return walk, jump, winName, win.weight
end

return MovementFlow
