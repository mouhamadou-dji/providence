--[[
	VelocityModel -- the contribution-summing maths for Providence's velocity stack, and
	nothing else. Movement rehaul phase 1 (2026-08-05).

	THE IDEA: everything that wants to shove a character -- dash, slide, knockback, a mob's
	sweep, a launch, wind -- registers a CONTRIBUTION instead of owning its own constraint.
	One processor sums them all into a single answer every frame, and exactly one
	LinearVelocity per character applies it (VelocityRuntime owns that instance). Two shoves
	in the same direction stack; two opposing shoves cancel; a dash during a knockback is not
	a special case, it is just vector addition -- whichever force is bigger dominates.

	PURE BY CONSTRUCTION, same contract as MovementModel: no Instances, no services, no
	globals and no clock. `now` arrives as an argument everywhere; config arrives via
	ctx.config. That is what lets VM_TestHarness step this at dt=1/240 and dt=1/30 and assert
	the two cover the same ground -- you cannot write that test against a module that reads
	RunService itself.

	A CONTRIBUTION (the spec table handed to add):
		id            string?  -- stable handle for update/remove. Omitted -> auto "vm_<n>".
		                         Re-adding an EXISTING id replaces that contribution, so a
		                         caller that wants stacking uses fresh ids (applyKnockback
		                         does), and a caller that wants refresh reuses one ("dash").
		planar        Vector3  -- flat world velocity this contribution wants, studs/s.
		                         Y is stripped on add: vertical travel is not a sustained
		                         constraint in this system (see `vertical`).
		vertical      number?  -- ONE-SHOT vertical impulse, studs/s, consumed exactly once
		                         by the first resolve after it lands. The runtime applies it
		                         to AssemblyLinearVelocity and gravity does the rest --
		                         Plane-mode constraints cannot express Y, deliberately (a
		                         Vector-mode constraint pins Y and cancels gravity, the
		                         documented dash-hover / slide-on-slope bug).
		duration      number?  -- seconds. Clamped to MaxDuration. nil = no expiry, lives
		                         until remove()d -- for continuously-steered contributions
		                         (slide). Boundary layers (the VelocityPush remote) must NOT
		                         forward nil durations; that policy lives there, not here.
		decay         string?  -- "none" (constant until cut, default) | "linear" (fades to
		                         zero across duration). "linear" with no duration is
		                         meaningless and coerced to "none".
		maxForce      number?  -- authority budget for the constraint while this contribution
		                         is active. Defaults to MaxForce. Composes by MAX, not sum --
		                         see resolve.
		suppressInput boolean? -- default true: while this contribution is active the
		                         character's own movement input is zeroed (the runtime issues
		                         Humanoid:Move(zero)). false = the push BLENDS with walking
		                         (wind, currents).

	USAGE
		local state = VelocityModel.newState()
		state, id = VelocityModel.add(state, spec, now, ctx)
		local out; out, state = VelocityModel.resolve(state, now, dt, ctx)
		-- out = { planar=Vector3, maxForce=n, verticalImpulse=n, suppressInput=bool,
		--         active=bool }

	Every function returns a NEW state -- callers reassign, never mutate. ctx.config is
	Config.Velocity; DEFAULTS below is only the fallback.
]]

local VelocityModel = {}

-- Fallback for a caller that forgets to pass config (and for the harness).
-- ReplicatedStorage.Shared.Config.Velocity is the real source of truth.
local DEFAULTS = {
	MaxForce        = 45000, -- same tuned cap as the old dash/slide constraints, same reason:
	                         -- unbounded force fights wall collisions instead of letting the
	                         -- solver resolve them (the dash-into-wall fling/spin bug)
	MaxSpeed        = 200,   -- clamp on any single planar and on the resolved sum -- a
	                         -- config-typo guard, not a gameplay number
	MaxDuration     = 5,     -- clamp on any single contribution's finite duration
	DefaultDuration = 0.25,  -- what boundary layers substitute for a missing duration
}

local FLAT = Vector3.new(1, 0, 1)

local function c(cfg, key)
	local v = cfg and cfg[key]
	if v ~= nil then return v end
	return DEFAULTS[key]
end

function VelocityModel.newState()
	return {
		contributions = {}, -- array of records, insertion-ordered
		nextId        = 1,
	}
end

-- How many contributions are live (expired ones are only pruned by resolve, so pass `now`
-- to count what is genuinely active rather than what is merely still in the array).
function VelocityModel.count(state, now)
	local n = 0
	for _, rec in ipairs(state.contributions) do
		if rec.expiresAt == nil or now == nil or now < rec.expiresAt then n += 1 end
	end
	return n
end

-- Instantaneous decay multiplier for a record at time t. Exported for the harness.
function VelocityModel.decayFactor(rec, t)
	if rec.decay ~= "linear" or not rec.expiresAt then return 1 end
	local remaining = (rec.expiresAt - t) / rec.duration
	return math.clamp(remaining, 0, 1)
end

-- nil for anything that is not a finite Vector3 -- callers refuse rather than coerce, so a
-- junk planar can never silently become "no push" and mask its own bug.
local function flatten(v)
	if typeof(v) ~= "Vector3" then return nil end
	local flat = v * FLAT
	if flat ~= flat then return nil end -- NaN components: refuse, don't poison the sum
	return flat
end

local function clampMagnitude(v, maxMag)
	local m = v.Magnitude
	if m > maxMag and m > 0 then return v * (maxMag / m) end
	return v
end

--[[
	add(state, spec, now, ctx) -> newState, id

	Validates and clamps the spec, stamps startedAt/expiresAt from `now`, and appends it.
	An id that already exists REPLACES the old record (same array slot, so ordering is
	stable). Invalid planar -> the add is refused and the original state comes back with a
	nil id, so a caller can tell nothing happened.
]]
function VelocityModel.add(state, spec, now, ctx)
	local cfg = ctx and ctx.config
	if type(spec) ~= "table" then return state, nil end

	local planar = flatten(spec.planar)
	if not planar then return state, nil end
	planar = clampMagnitude(planar, c(cfg, "MaxSpeed"))

	local duration = tonumber(spec.duration)
	if duration then duration = math.clamp(duration, 0, c(cfg, "MaxDuration")) end

	local decay = spec.decay
	if decay ~= "linear" or not duration then decay = "none" end

	local id = spec.id
	local nextId = state.nextId
	if type(id) ~= "string" or id == "" then
		id = "vm_" .. nextId
		nextId += 1
	end

	local rec = {
		id            = id,
		planar        = planar,
		vertical      = tonumber(spec.vertical) or 0,
		duration      = duration,
		startedAt     = now,
		expiresAt     = duration and (now + duration) or nil,
		decay         = decay,
		maxForce      = tonumber(spec.maxForce),
		suppressInput = spec.suppressInput ~= false, -- default TRUE: a force acting on you
		                                             -- interrupts your own footing unless the
		                                             -- caller explicitly says it blends
		verticalPending = (tonumber(spec.vertical) or 0) ~= 0,
	}

	local contributions = table.clone(state.contributions)
	local replaced = false
	for i, old in ipairs(contributions) do
		if old.id == id then contributions[i] = rec; replaced = true; break end
	end
	if not replaced then table.insert(contributions, rec) end

	return { contributions = contributions, nextId = nextId }, id
end

-- Retarget a live contribution's planar velocity WITHOUT resetting its clock -- this is how
-- a continuously-steered contribution (slide carving into a turn) stays one contribution
-- instead of a stream of replacements. Unknown id is a no-op.
function VelocityModel.update(state, id, planar, ctx)
	local cfg = ctx and ctx.config
	local flat = flatten(planar)
	if not flat then return state end
	local contributions = state.contributions
	for i, rec in ipairs(contributions) do
		if rec.id == id then
			local out = table.clone(contributions)
			local new = table.clone(rec)
			new.planar = clampMagnitude(flat, c(cfg, "MaxSpeed"))
			out[i] = new
			return { contributions = out, nextId = state.nextId }
		end
	end
	return state
end

function VelocityModel.remove(state, id)
	local contributions = {}
	local found = false
	for _, rec in ipairs(state.contributions) do
		if rec.id == id then found = true else table.insert(contributions, rec) end
	end
	if not found then return state end
	return { contributions = contributions, nextId = state.nextId }
end

function VelocityModel.clear(state)
	return { contributions = {}, nextId = state.nextId }
end

--[[
	resolve(state, now, dt, ctx) -> out, newState

	The processor. Prunes everything expired at `now`, then composes what is left:

	  planar   -- VECTOR SUM of every active contribution. The only rule under which two
	              opposing shoves cancel and two aligned shoves stack, which is the whole
	              point of routing every force through one place. Clamped to MaxSpeed after
	              summing (typo guard).

	              Each term is integrated over the frame the caller is about to hold it for,
	              [now, now+dt] -- decay is evaluated at the midpoint of the COVERED part of
	              that window and scaled by the covered fraction. This is the same trick as
	              MovementModel.appliedPower (the frame AVERAGE, not the endpoint): the
	              constraint holds one velocity for the whole frame, so sampling the start of
	              the frame is a left Riemann sum and a 30fps client travels measurably
	              further than a 240fps one across the same shove. Midpoint + coverage makes
	              a linear fade AND an expiry-mid-frame integrate exactly at any dt --
	              asserted by the harness. dt=0 gives the instantaneous value.

	  maxForce -- MAX across active contributions, NOT sum. MaxForce is not a velocity, it is
	              the authority budget the constraint may spend fighting collisions; summing
	              it would quietly rebuild the unbounded-force fling bug as contributions
	              stack (three knockbacks = 135k force into a wall). Max keeps the guarantee
	              "never more violent than the most violent single thing acting on you".

	  verticalImpulse -- sum of every not-yet-consumed vertical, reported ONCE; the new state
	              comes back with them marked consumed. The caller applies it to the assembly
	              directly and gravity owns what happens next.

	  suppressInput -- true if ANY active contribution wants the player's own input zeroed.

	  active   -- false when nothing is live. The runtime maps that straight onto
	              LinearVelocity.Enabled, so normal Humanoid movement resumes untouched the
	              frame the last contribution dies.
]]
function VelocityModel.resolve(state, now, dt, ctx)
	local cfg = ctx and ctx.config
	dt = math.max(0, tonumber(dt) or 0)

	local kept = {}
	local sum = Vector3.zero
	local maxForce = 0
	local verticalImpulse = 0
	local suppress = false
	local mutated = false

	for _, rec in ipairs(state.contributions) do
		if rec.expiresAt and now >= rec.expiresAt then
			mutated = true -- expired: pruned by omission
		else
			-- Fraction of the upcoming frame this contribution actually covers, and the
			-- decay evaluated at the midpoint of that covered stretch (see header).
			local cover = 1
			if rec.expiresAt and dt > 0 then
				cover = math.clamp((rec.expiresAt - now) / dt, 0, 1)
			end
			local factor = VelocityModel.decayFactor(rec, now + dt * cover * 0.5) * cover

			sum += rec.planar * factor
			maxForce = math.max(maxForce, rec.maxForce or c(cfg, "MaxForce"))
			if rec.suppressInput then suppress = true end

			if rec.verticalPending then
				verticalImpulse += rec.vertical
				local consumed = table.clone(rec)
				consumed.verticalPending = false
				rec = consumed
				mutated = true
			end
			table.insert(kept, rec)
		end
	end

	local out = {
		planar          = clampMagnitude(sum, c(cfg, "MaxSpeed")),
		maxForce        = maxForce > 0 and maxForce or c(cfg, "MaxForce"),
		verticalImpulse = verticalImpulse,
		suppressInput   = suppress,
		active          = #kept > 0,
	}
	if not mutated then return out, state end
	return out, { contributions = kept, nextId = state.nextId }
end

return VelocityModel
