--[[
	MovementModel -- the momentum maths for Providence's movement, and nothing else.

	PURE BY CONSTRUCTION. This module touches no Instances, no services, no globals and no
	clock. Everything it needs arrives as arguments; everything it produces is returned. That
	is deliberate, for two reasons:

	  1. Framerate independence becomes PROVABLE instead of eyeballed. Movement_TestHarness
	     steps this model 1000x at dt=1/240 and 125x at dt=1/30 and asserts the two cover the
	     same ground. You cannot write that test against a module that reads RunService.
	  2. Tuning is separable from wiring. MovementClient owns Instances; this owns feel.

	WHERE THE WEIGHT LIVES (the tuning principle): snappy and weighty are not opposites --
	they just belong at different speeds. Walk/run is INSTANT in every respect: instant to
	start, instant to stop, free to turn and strafe. Momentum appears only above
	MomentumSpeedThreshold and only while sprinting -- a sprint winds up over SprintRampTime,
	carries forward over SprintDecelTime, and bleeds speed if you corner harder than
	SharpTurnAngle. Nothing ramps at the START of anything.

	THE CENTRAL IDEA -- `walkPower` (0..1) is momentum, and it is applied as the MAGNITUDE of
	the Humanoid move vector, never as WalkSpeed. Humanoid:Move(v) travels at
	WalkSpeed * v.Magnitude, so WalkSpeed stays free for the existing authority stack
	(CombatCore.setSpeed's health/injury/rage/caste product, SanityEffectsClient's cliff-pull,
	ModMenuClient's /speed) and this layer never fights it. walkPower is also the Flow value
	the combat revamp will read.

	Carry-through falls out of this for free: because the CALLER owns the Move call, releasing
	W does not zero MoveDirection. We keep feeding `currentDir` with a decaying walkPower, so
	the character skids to a stop on its own. The deleted MovementFeelClient needed a
	LinearVelocity constraint to fake that; this needs no physics at all.

	USAGE
		local state = MovementModel.newState()
		state = MovementModel.step(state, dt, targetDir, ctx)
		humanoid:Move(state.currentDir * state.walkPower, false)

	ctx fields (all optional):
		ceilingSpeed                     -- Humanoid.WalkSpeed, i.e. the authorised top speed.
		                                    REQUIRED for sprint ramping and the momentum
		                                    threshold to mean anything in real studs/s.
		baseSpeed                        -- the walk ceiling; above it counts as sprinting
		maxPower                         -- ceiling on walkPower (0..1). How a surface or
		                                    condition slows you, since accel is instant.
		decelMult, turnMult              -- surface / injury / rage modulation
		turnBleedMult                    -- how punishing sharp sprint turns are
		grounded                         -- false switches to the aerial curve + power clamp
		driftRad                         -- sanity: rotate targetDir by this many radians
]]

local MovementModel = {}

-- Defaults are only a fallback for a caller that forgets to pass config (and for the
-- harness). ReplicatedStorage.Shared.Config.Movement.Model is the real source of truth.
local DEFAULTS = {
	-- There is deliberately no ground-acceleration key: ground response is instant, always.
	GroundDecelTime = 0.06,  -- near-instant stop at walk/run -- this is snappiness
	AirDecelTime    = 1.00,  -- barely bleeds airborne; you keep what you jumped with
	SprintRampTime  = 0.35,  -- the ONLY wind-up in the model
	SprintDecelTime = 0.25,  -- carrying a sprint forward after you let go
	BaseSpeed       = 16,
	MomentumSpeedThreshold = 20, -- below this speed there is no momentum at all
	SharpTurnAngle  = 100,   -- degrees; gentler turns at speed are free
	TurnMomentumLoss = 0.15, -- fraction of momentum a full 180 at speed costs
	TurnSmoothness  = 16,
	LightTurnMult   = 4.0,   -- heading resolves ~4x faster below the momentum threshold
	AerialTurnMult  = 0.35,
	MinAirPower     = 0.55,  -- steering every jump keeps, even one from a standstill
	SnapThreshold   = 0.02,
	RestThreshold   = 0.05,
}

local FLAT = Vector3.new(1, 0, 1)

function MovementModel.newState()
	return {
		walkPower      = 0,
		-- The average power across the last frame -- what moveVector() actually applies. See
		-- the note where it is computed in step().
		appliedPower   = 0,
		currentDir     = Vector3.new(0, 0, -1),
		grounded       = true,
		-- Snapshot of walkPower at the moment we left the ground. While airborne walkPower is
		-- clamped to it, so a jump preserves momentum but cannot GAIN any -- no air strafing
		-- your way to top speed, which is the whole "committed jump" feel.
		lockedAirPower = 0,
		-- Seconds still owed to a forced full-deceleration triggered by a hard turn at speed.
		forcedDecel    = 0,
	}
end

-- Flattens to the XZ plane and normalises. Returns nil for a vector with no horizontal
-- component, so callers can distinguish "no input" from "input pointing straight down".
local function flatUnit(v)
	if not v then return nil end
	local flat = v * FLAT
	if flat.Magnitude < 1e-4 then return nil end
	return flat.Unit
end
MovementModel.flatUnit = flatUnit

-- Signed-magnitude angle between two flat unit vectors, in degrees. Clamped before acos
-- because floating point drift can push the dot fractionally outside [-1, 1] and make
-- math.acos return NaN -- which then silently poisons walkPower for the rest of the session.
local function angleBetweenDeg(a, b)
	local dot = math.clamp(a:Dot(b), -1, 1)
	return math.deg(math.acos(dot))
end
MovementModel.angleBetweenDeg = angleBetweenDeg

--[[
	step(state, dt, targetDir, ctx) -> newState

	`targetDir` is a world-space flat direction (unit) or nil for "no input".
	The returned table is a NEW table -- callers should reassign, not mutate in place.
]]
function MovementModel.step(state, dt, targetDir, ctx)
	ctx = ctx or {}
	local cfg = ctx.config or DEFAULTS
	local function c(key) return cfg[key] ~= nil and cfg[key] or DEFAULTS[key] end

	-- Guard the frame delta. A tab-out or a hitch can hand us a dt of several seconds, which
	-- would blow through an entire accel curve in one frame and teleport walkPower to its
	-- extreme. Cap at ~10fps worth: below that the sim is wrong anyway, and clamping is far
	-- less wrong than integrating a 3-second step.
	dt = math.clamp(dt or 0, 0, 0.1)

	local grounded  = ctx.grounded ~= false
	local decelMult = ctx.decelMult or 1
	local turnMult  = ctx.turnMult  or 1
	local bleedMult = ctx.turnBleedMult or 1

	local walkPower  = state.walkPower
	local currentDir = state.currentDir
	local lockedAirPower = state.lockedAirPower or 0

	-- Ground/air transitions. Landing releases the clamp; taking off snapshots it.
	--
	-- The snapshot has a FLOOR. Taken literally (`lockedAirPower = walkPower`) a jump from a
	-- standstill locked you at zero, and since the clamp below is a hard min() you then had no
	-- air control whatsoever for the entire jump -- press W mid-air and nothing happened. The
	-- committed-jump idea is "you cannot GAIN momentum in the air", not "a standing jump is
	-- dead", and MinAirPower is the difference between the two: a sprinting takeoff is still
	-- clamped to its own takeoff power, so you can never air-strafe your way up to speed.
	if grounded and not state.grounded then
		lockedAirPower = 0
	elseif not grounded and state.grounded then
		lockedAirPower = math.max(walkPower, c("MinAirPower"))
	end

	-- Sanity drift: rotate the requested direction slightly. Applied to the INPUT rather than
	-- the output so the character still moves coherently -- it just isn't going quite where
	-- you asked. Rotating the output instead reads as a camera bug, not as losing your grip.
	if targetDir and ctx.driftRad and ctx.driftRad ~= 0 then
		targetDir = (CFrame.Angles(0, ctx.driftRad, 0) * targetDir)
	end

	local hasInput = targetDir ~= nil
	local powerAtEntry = walkPower
	local maxPower = math.clamp(ctx.maxPower or 1, 0, 1)

	-- ── Speed bookkeeping ────────────────────────────────────────────────────────
	-- walkPower is a FRACTION of the currently authorised ceiling (Humanoid.WalkSpeed), so
	-- when the ceiling itself moves -- sprint on/off, crouch, an injury multiplier -- holding
	-- the same fraction would silently teleport your real speed. Rescaling to preserve
	-- absolute studs/s is also exactly what lets sprint RAMP up from run speed instead of
	-- snapping to 26 the instant the server raises the ceiling.
	local ceiling     = math.max(0.01, ctx.ceilingSpeed or c("BaseSpeed"))
	local baseSpeed   = ctx.baseSpeed or c("BaseSpeed")
	local lastCeiling = state.lastCeiling or ceiling
	if math.abs(ceiling - lastCeiling) > 0.01 then
		walkPower = math.clamp(walkPower * lastCeiling / ceiling, 0, 1)
	end

	-- THE SNAPPINESS RULE, in two booleans:
	--   heavy     -- moving fast enough for momentum to exist at all. Below this, movement is
	--                pure snap: instant to start, instant to stop, turns cost nothing.
	--   sprinting -- the ceiling has been raised above a walk, so the wind-up ramp applies.
	-- Weight lives in these two and nowhere else.
	local speedNow  = walkPower * ceiling
	local heavy     = speedNow > c("MomentumSpeedThreshold")
	local sprinting = ceiling > baseSpeed + 0.01

	-- ── 0. At-rest heading snap ────────────────────────────────────────────────
	-- Standing still means there is no momentum to redirect, so the heading takes the input
	-- instantly instead of lerping toward it. Without this, setting off while the stale
	-- currentDir still points the old way leaves the alignment gate at zero and the character
	-- refuses to move for several frames -- the exact opposite of snappy. Done before
	-- dirAtEntry is captured, so the turn bleed never charges for this free pivot.
	if hasInput and walkPower <= c("RestThreshold") then
		currentDir = targetDir
	end


	-- ── 1. Alignment ─────────────────────────────────────────────────────────────
	-- How aligned the input is with where the momentum is actually going -- measured against
	-- currentDir, not the character's facing, because redirecting MOMENTUM is the thing that
	-- should cost you. Only charged for while sprinting; see the bleed in step 4.
	local alignment, angleToTarget = 1, 0
	if hasInput then
		alignment = math.clamp(currentDir:Dot(targetDir), -1, 1)
		angleToTarget = angleBetweenDeg(currentDir, targetDir)
	end

	-- ── 2. Accelerate / decelerate ───────────────────────────────────────────────
	-- Ground acceleration does not exist -- there is no knob for it, deliberately. An accel
	-- ramp is input latency by another name, and combat cannot afford it. The ONLY wind-up
	-- in the whole model is the sprint ramp below.
	--
	-- Deceleration is split by speed: at walk/run you stop essentially on the frame you let
	-- go (GroundDecelTime is tiny), while above the momentum threshold you carry your sprint
	-- forward over SprintDecelTime. Snappy where it matters, weighty where it belongs.
	-- Sticky: once a coast STARTS from sprint speed it finishes on the sprint curve. Without
	-- this the decay crosses back under MomentumSpeedThreshold almost immediately and the
	-- rest of the stop snaps at walk speed, so releasing a sprint carried for ~50ms instead
	-- of the intended quarter second. Cleared the moment you steer again or come to rest.
	local coastHeavy = state.coastHeavy or false
	if hasInput or walkPower <= 0 then
		coastHeavy = false
	elseif heavy then
		coastHeavy = true
	end

	local decelTime = (heavy or coastHeavy) and c("SprintDecelTime")
		or (grounded and c("GroundDecelTime") or c("AirDecelTime"))
	decelTime = math.max(0.0001, decelTime / math.max(0.01, decelMult))

	-- Set only when the decel ramp runs out PART-WAY through a frame -- see the else branch.
	local appliedOverride = nil

	if hasInput then
		-- The gate: you cannot push forward while your momentum is going sideways. Squared,
		-- because a linear gate leaves enough partial alignment mid-turn to hide the bleed.
		local gate = math.max(0, alignment)
		gate = gate * gate
		local target = gate * maxPower

		if sprinting and walkPower < target then
			-- SPRINT WIND-UP: the one and only ramp. Walking never reaches this branch.
			-- The rate covers the RUN-TO-SPRINT span rather than the whole 0..1 range, so
			-- SprintRampTime means what it says -- 0.35s from run speed to full sprint --
			-- no matter what SprintSpeed is tuned to. Spanning 0..1 instead made the real
			-- wind-up 0.13s, because a sprint only ever covers the top third of walkPower.
			local span = math.max(0.05, 1 - (baseSpeed / ceiling))
			walkPower = math.min(target, walkPower + dt * span / math.max(0.0001, c("SprintRampTime")))
		else
			-- INSTANT. math.max, so this can only ever ADD speed -- shedding it is the bleed's
			-- and decel's job, never the gate's.
			walkPower = math.max(walkPower, target)
		end
	else
		-- The ramp can finish INSIDE a single frame: GroundDecelTime is 0.06s, which is shorter
		-- than one step at 30fps. When that happens the endpoint-average below
		-- ((p0 + 0) / 2) bills the whole frame for a ramp that only occupied part of it, and the
		-- error is framerate-dependent -- it was making the 30fps skid come out 4.8% longer than
		-- the 240fps one. Integrate the partial ramp exactly instead: the area under it is
		-- (p0/2) * remaining, so the frame AVERAGE is that divided by dt.
		local p0 = walkPower
		local remaining = p0 * decelTime -- seconds until it would reach zero
		if dt >= remaining then
			appliedOverride = (p0 * 0.5) * (remaining / dt)
			walkPower = 0
		else
			walkPower = p0 - dt / decelTime
		end
	end

	-- ── 3. Turn currentDir toward the input ──────────────────────────────────────
	-- With no input currentDir is HELD, not zeroed -- that's what makes a coast continue the
	-- way you were already travelling instead of collapsing toward the origin.
	--
	-- This ROTATES by a capped angle rather than Vector3:Lerp-ing between headings, because
	-- lerp degenerates at exactly 180 degrees: interpolating between two opposite unit
	-- vectors just shortens the vector along the same axis, and re-normalising hands back the
	-- ORIGINAL heading. The character could never turn around by pressing straight back, and
	-- because the heading never swept, the turn bleed never charged for the hardest turn in
	-- the game. Rotating by angle also makes `turnedDeg` below exact instead of inferred.
	--
	-- The sweep RATE is gated on `heavy` for the same reason the bleed below is: weight is
	-- supposed to live at sprint and nowhere else. TurnSmoothness alone applied an identical
	-- ~0.18s sweep to a 90 degree turn at walking pace, so walk turns were free in SPEED but
	-- not in HEADING -- pressing S mid-run carved a full-speed U-turn instead of reversing,
	-- which is most of what read as "the movement is mushy". Below the momentum threshold the
	-- heading now resolves in ~0.07s. Still 1-exp(-k*dt), so this stays framerate-independent.
	local turnedDeg = 0
	if hasInput and angleToTarget > 0.01 then
		local smoothness = c("TurnSmoothness") * turnMult
		if not heavy then smoothness = smoothness * c("LightTurnMult") end
		if not grounded then smoothness = smoothness * c("AerialTurnMult") end
		-- Exponential rather than (dt * smoothness): framerate-independent, and it cannot
		-- overshoot on a long frame the way a raw dt*k step does.
		local alpha = 1 - math.exp(-smoothness * dt)
		turnedDeg = math.min(angleToTarget, angleToTarget * alpha)
		-- Which way round: +Y cross means the target is counter-clockwise from here. At a
		-- perfect 180 the cross is zero and either way is equally correct, so pick one and be
		-- consistent rather than stalling.
		local sign = (currentDir:Cross(targetDir).Y >= 0) and 1 or -1
		currentDir = flatUnit(CFrame.Angles(0, math.rad(turnedDeg) * sign, 0) * currentDir) or targetDir
	end

	-- ── 4. Turn bleed -- ONLY at speed, and only for genuinely sharp turns ─────────────
	-- Walking turns cost nothing whatsoever: that is the snappiness, and strafing or
	-- reversing at walk speed has to stay free. Above MomentumSpeedThreshold, a turn sharper
	-- than SharpTurnAngle bleeds momentum -- which is what stops a sprinting character
	-- cornering on a coin.
	--
	-- Charged on the angle actually SWEPT this frame, not the angle remaining to the target.
	-- The remaining angle stays roughly constant per frame while a turn is in progress, so
	-- charging on it made a 240fps client pay four times what a 60fps client paid for the
	-- identical turn. Sweep is the only framerate-honest measure.
	if hasInput and heavy and walkPower > 0.01 and angleToTarget >= c("SharpTurnAngle") and turnedDeg > 0.01 then
		local bleed = (turnedDeg / 180) * c("TurnMomentumLoss") * bleedMult
		walkPower = walkPower - math.min(bleed, 1) * walkPower
	end

	walkPower = math.clamp(walkPower, 0, maxPower)
	if not grounded then
		-- Committed jump: never exceed the momentum you took off with.
		walkPower = math.min(walkPower, lockedAirPower)
	end
	if walkPower < c("SnapThreshold") and not hasInput then
		walkPower = 0
	end

	return {
		walkPower      = walkPower,
		-- The power to ACTUALLY apply for this frame: the average across it, not the endpoint.
		-- Humanoid:Move holds one magnitude for the whole frame, so using the endpoint makes a
		-- 30fps client cover visibly different ground to a 240fps one across any short ramp
		-- (the skid was ~13% longer at 30fps before this). Averaging integrates a linear ramp
		-- exactly, which is what every ramp in this model is.
		appliedPower   = appliedOverride or (powerAtEntry + walkPower) * 0.5,
		currentDir     = currentDir,
		grounded       = grounded,
		lockedAirPower = lockedAirPower,
		coastHeavy     = coastHeavy,
		lastCeiling    = ceiling,
		speed          = walkPower * ceiling, -- studs/s, for callers that want real units
	}
end

-- Convenience for the caller: the vector to hand straight to Humanoid:Move().
function MovementModel.moveVector(state)
	return state.currentDir * (state.appliedPower or state.walkPower)
end

return MovementModel
