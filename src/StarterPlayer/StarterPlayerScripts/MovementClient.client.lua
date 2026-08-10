--[[
	MovementClient -- the frame driver for Providence's movement (revamp pass 1, 2026-08-04).

	Owns Instances and input; owns NO maths. All the momentum feel lives in the pure
	ReplicatedStorage.Shared.MovementModel so it can be unit-tested at fixed dt.

	THE ONE RULE: this script never writes Humanoid.WalkSpeed. WalkSpeed is the authorised
	ceiling owned by CombatCore.setSpeed (health x injury x rage x caste), by
	SanityEffectsClient's cliff-pull, and by ModMenuClient's /speed. We express momentum as
	the MAGNITUDE of the move vector instead -- Humanoid:Move(v) travels at
	WalkSpeed * v.Magnitude -- so all of those keep composing and nothing fights anything.

	WHY WE DON'T DISABLE THE DEFAULT CONTROLS: PlayerModule's ControlModule binds at
	RenderPriority.Input (100) and calls humanoid:Move(inputVector, true) every frame. Rather
	than tearing that out (which would cost us mobile and gamepad support), we read its
	GetMoveVector() for input and re-issue our own Move at RenderPriority.Character (300).
	Last Move before the physics step wins, so ours does.

	CLIENT OWNS FEEL, SERVER OWNS TRUTH. Dash motion, animation state and the momentum curve
	are all local and instant. Stamina, dodge stock, i-frames and the displacement guard are
	ServerScriptService.Managers.MovementSystem's, and it can deny anything after the fact.

	PHYSICS GOES THROUGH THE VELOCITY STACK (movement rehaul phase 1, 2026-08-05). This
	script no longer owns LinearVelocity instances: dash and slide are CONTRIBUTIONS pushed
	through _G.VelocityClient, which sums every force on the character (dash, slide,
	knockback, whatever else registers) into the one VM_Velocity constraint per character.
	A knockback landing mid-dash is not a special case anywhere -- it is vector addition,
	and whichever force is bigger dominates. This script keeps everything else it always
	owned: input, the state machine, tokens, cooldowns, the momentum model, the server
	remotes, and the handback maths.

	KEYBINDS (2026-08-07 rebind, restoring the pre-teardown scheme): sprint is DOUBLE-TAP W,
	held. Ctrl is one context-sensitive key: moving faster than
	Config.Movement.Slide.SlideOverCrouchSpeed it slides, otherwise it crouches, and a slide
	that decays to a stop with Ctrl still down settles into the crouch. Shift and C are
	unbound. Crouch moved here from InputHandler so one script can arbitrate the press; its
	round-trip prediction came along, but expressed through the move-vector magnitude (THE
	ONE RULE above -- never WalkSpeed), so a wounded or raging character predicts against
	their real ceiling instead of the old hardcoded 16.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UIS               = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Model  = require(Shared:WaitForChild("MovementModel"))

local MCFG    = Config.Movement
local MODEL   = MCFG.Model
local DASHCFG = MCFG.Dash
local SLIDECFG = MCFG.Slide or {}
local SURFACES = MCFG.SurfaceProfiles or {}
local INJURIES = MCFG.InjuryProfiles or {}
local SANITY   = MCFG.Sanity or {}
local RAGECFG  = MCFG.Rage or {}

-- ── Remotes ───────────────────────────────────────────────────────────────
local remotes       = ReplicatedStorage:WaitForChild("RemoteEvents", 10)
local RE_Sprint     = remotes:WaitForChild("RequestSprint", 10)
local RE_SprintEnd  = remotes:WaitForChild("RequestSprintEnd", 10)
local RE_Crouch     = remotes:WaitForChild("RequestCrouch", 10)
local RE_Dash       = remotes:WaitForChild("RequestDash", 10)
local RE_Slide      = remotes:WaitForChild("RequestSlide", 10)
local RE_SlideEnd   = remotes:WaitForChild("RequestSlideEnd", 10)
local RE_DodgeResult = remotes:WaitForChild("OnDodgeResult", 10)
local RE_MovState   = remotes:WaitForChild("UpdateMovementState", 10)
local RE_Sanity     = remotes:WaitForChild("UpdateSanityEffects", 10)
local RE_Rage       = remotes:WaitForChild("RageStateChanged", 10)

-- ── Character refs ───────────────────────────────────────────────────────
local character, hum, hrp
local state = Model.newState()

-- ── Mirrored world state (never inferred -- the server is authoritative for all of it) ──
local isCrouching  = false
local isRaging     = false
local sanityTiers  = {}

-- ── Local action state ─────────────────────────────────────────────────
local sprintHeld    = false
local sprintActive  = false
local isDashing     = false
local dashToken     = 0
local dashCooldownUntil = 0

local isSliding      = false
local slideVec       = Vector3.zero
local slideCooldownUntil = 0

local ctrlHeld      = false
-- CROUCH/SLIDE IS BOUND TO BOTH Ctrl AND C (2026-08-09, dev's call). Tracked as two
-- independent physical keys so holding both and releasing only one does not cancel the
-- action -- onCtrlDown/onCtrlUp (below) only fire on the true 0->1 / 1->0 transition of
-- "is EITHER key down", not on every individual keystroke.
local ctrlKeyDown  = false
local cKeyDown     = false
local ctrlCrouching = false -- an on-toggle we fired is outstanding; pairs every press with a release fire
local crouchPredict = false -- optimistic half-speed between our RequestCrouch and the server's Crouch confirm
local wantSlopeSlide = false -- crouch->slope-slide conversion pending the server's CrouchEnd echo

-- The velocity stack. Dash and slide push their velocity through here as contributions
-- ("dash" / "slide" ids) instead of owning constraints; VelocityClient owns the single
-- VM_Velocity per character and sums every force acting on it. Late-bound with a nil-guard
-- (same as _G.CameraController above) so load order between StarterPlayerScripts never
-- matters; warn once rather than silently losing every impulse if it is genuinely missing.
local warnedNoVC = false
local function vc()
	local v = _G.VelocityClient
	if not v and not warnedNoVC then
		warnedNoVC = true
		warn("[MovementClient] _G.VelocityClient missing -- dash/slide impulses cannot apply")
	end
	return v
end

-- Shiftlock is CameraClient's (it owns framing, and shiftlock is framing + facing). We only
-- need to KNOW about it: while the body is locked to the camera we must not set
-- AutoRotate = false, because RotationType.CameraRelative drives the facing through exactly
-- that flag -- turning it off mid-dash would unlock the body and swing the shoulder offset
-- for the duration of the move.
local function shiftlocked()
	local cc = _G.CameraController
	return cc ~= nil and cc.isShiftlocked ~= nil and cc.isShiftlocked() == true
end

-- Only touch AutoRotate when we are the ones who own the facing. Paired calls, so a dash that
-- starts unlocked and ends locked (or vice versa) cannot leave AutoRotate stuck off.
local function setOwnFacing(owned)
	if not hum then return end
	if owned and shiftlocked() then return end -- the camera owns it; leave AutoRotate alone
	hum.AutoRotate = not owned
end

-- Horizontal speed the character is ACTUALLY travelling at, in studs/s. Physical truth rather
-- than the model's own walkPower, so it stays correct coming out of a slide, off a boat deck,
-- or during a knockback -- and because AssemblyLinearVelocity replicates, MovementSystem can
-- recompute the identical number server-side for the dash displacement guard.
local function flatSpeed()
	if not hrp then return 0 end
	local v = hrp.AssemblyLinearVelocity
	return Vector3.new(v.X, 0, v.Z).Magnitude
end

-- The dash momentum curve. Exponent > 1 keeps the low end genuinely short: walk is already
-- 62% of sprint speed, so a straight lerp would put a walking dash most of the way to a
-- sprinting one. See the table in Config.Movement.Dash.
local function dashSpeedFor(speedNow)
	local minS  = DASHCFG.MinSpeed or 32
	local maxS  = DASHCFG.MaxSpeed or 73
	local top   = math.max(1, MCFG.SprintSpeed or 26)
	local frac  = math.clamp(speedNow / top, 0, 1) ^ (DASHCFG.MomentumCurve or 1.5)
	return minS + (maxS - minS) * frac
end

-- ── PlayerModule controls (kept alive so mobile/gamepad input still reaches us) ───────
local controls
task.spawn(function()
	local ok, result = pcall(function()
		local pm = player:WaitForChild("PlayerScripts", 10):WaitForChild("PlayerModule", 10)
		return require(pm):GetControls()
	end)
	if ok then controls = result else warn("[MovementClient] PlayerModule controls unavailable: " .. tostring(result)) end
end)

-- Raw input direction, camera-relative -> flat world unit vector (or nil for no input).
-- ControlModule's GetMoveVector() is camera-relative (it is handed to Move with
-- relativeToCamera=true), so it has to go through the camera CFrame before we can use it
-- as a world direction.
local function readInputDir()
	local v
	if controls then
		local ok, mv = pcall(function() return controls:GetMoveVector() end)
		if ok then v = mv end
	end
	if not v or v.Magnitude < 0.01 then return nil end
	local camera = workspace.CurrentCamera
	if not camera then return nil end
	return Model.flatUnit(camera.CFrame:VectorToWorldSpace(v))
end

-- ── The Providence layer: everything that reshapes the momentum curve ────────────────
-- Each source contributes multipliers, and they compose. Nothing here special-cases the
-- model itself -- that stays generic and testable.
local driftClock = 0

local function buildContext(dt, grounded)
	-- accelMult is deliberately absent: acceleration is instant (Config.Movement.Model
	-- .GroundAccelTime = 0), so there is no ramp for it to modulate. Anything that wants to
	-- slow the player does it through maxPower instead.
	local maxPower, decelMult, turnMult, bleedMult = 1, 1, 1, 1

	-- Terrain friction. Mud drags, ice slides, water wades.
	if grounded and hum then
		local surf = SURFACES[hum.FloorMaterial]
		if surf then
			maxPower  = maxPower  * (surf.maxPowerMult or 1)
			decelMult = decelMult * (surf.decelMult or 1)
			turnMult  = turnMult  * (surf.turnMult  or 1)
		end
	end

	-- Injuries reshape the curve, not just the ceiling. The flat speed penalty already
	-- landed on WalkSpeed via InjuryManager.getSpeedMultiplier; this is the handling loss
	-- on top -- a wounded character skids and cannot corner. Note it does NOT touch the
	-- snappy start: instant response is a control-feel promise, not a fitness stat.
	if character then
		for injuryId, profile in pairs(INJURIES) do
			if character:GetAttribute("Injury_" .. injuryId) == true then
				maxPower  = maxPower  * (profile.maxPowerMult or 1)
				decelMult = decelMult * (profile.decelMult or 1)
				turnMult  = turnMult  * (profile.turnMult  or 1)
				bleedMult = bleedMult * (profile.turnBleedMult or 1)
			end
		end
	end

	-- Rage: all commitment, no control. You cannot brake and you cannot corner.
	if isRaging then
		decelMult = decelMult * (RAGECFG.DecelMult or 1)
		turnMult  = turnMult  * (RAGECFG.TurnMult  or 1)
	end

	-- Sanity destabilises control: a slow wander is injected into the input direction, so
	-- the character stops going quite where you asked. Deliberately slow (sub-1Hz) -- fast
	-- noise reads as a bug, slow drift reads as losing your grip.
	local driftRad = 0
	local driftDeg = 0
	if sanityTiers.cliffPull then driftDeg = SANITY.DriftDegAtCliff or 0
	elseif sanityTiers.shadow then driftDeg = SANITY.DriftDegAtShadow or 0 end
	if driftDeg > 0 then
		driftClock = driftClock + dt * (SANITY.DriftFrequency or 0.35) * 2 * math.pi
		driftRad = math.rad(driftDeg) * math.sin(driftClock)
		bleedMult = bleedMult * (SANITY.TurnBleedMult or 1)
	end

	return {
		config        = MODEL,
		grounded      = grounded,
		-- The authorised ceiling, straight off the Humanoid. The model needs it in real
		-- studs/s to know whether you are moving fast enough for momentum to exist, and to
		-- rescale walkPower when sprint raises or drops the ceiling.
		ceilingSpeed  = hum and hum.WalkSpeed or MCFG.BaseWalkSpeed,
		baseSpeed     = MCFG.BaseWalkSpeed,
		maxPower      = maxPower,
		decelMult     = decelMult,
		turnMult      = turnMult,
		turnBleedMult = bleedMult,
		driftRad      = driftRad,
	}
end

-- The constraint knowledge that used to live here (Plane vs Vector mode -- Vector pins Y
-- and cancels gravity, which made the dash hover and broke slides on slopes -- and the
-- finite MaxForce that stops the dash-into-wall fling) moved into
-- ReplicatedStorage.Shared.VelocityRuntime with the instances themselves. Dash and slide
-- are now just contributions; see the pushes in startDash/startSlide below.

-- Slope under the character: the angle off vertical, and the horizontal downhill heading.
-- Downhill is world-down projected onto the surface plane -- the direction a ball would roll.
-- Slope under the character, AVERAGED over several samples (2026-08-09). A single ray from
-- the root centre kept missing on bumpy ground and reporting flat, which is why slides died
-- on real hills. Sampling fore/aft along the direction of travel and averaging the surface
-- normals both fills those gaps and smooths out individual bumps, so the downhill reading
-- reflects the hill rather than the pebble currently under you.
local function readSlope(travelDir)
	if not hrp or not character then return 0, nil end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {character}

	local len    = SLIDECFG.RayLength or 8
	local spread = SLIDECFG.RaySpread or 2
	local origins = { hrp.Position }
	local along = travelDir and Model.flatUnit(travelDir)
	if along then
		table.insert(origins, hrp.Position + along * spread)
		table.insert(origins, hrp.Position - along * spread)
	end

	local sum, hits = Vector3.zero, 0
	for _, origin in ipairs(origins) do
		local hit = workspace:Raycast(origin, Vector3.new(0, -len, 0), params)
		if hit then
			sum += hit.Normal
			hits += 1
		end
	end
	if hits == 0 then return 0, nil end

	local normal = (sum.Magnitude > 1e-4) and sum.Unit or Vector3.yAxis
	local angle = math.deg(math.acos(math.clamp(normal:Dot(Vector3.yAxis), -1, 1)))
	local down = Vector3.new(0, -1, 0)
	local downhill = Model.flatUnit(down - normal * down:Dot(normal))
	return angle, downhill
end

-- ── Crouch (moved here from InputHandler, 2026-08-07) ────────────────────────
-- Optimistic, like the dash: fire, predict, and let the server's Crouch/CrouchEnd mirror
-- settle it. The toggle fires stay PAIRED (every on-press fire gets a release fire) so the
-- server's toggle parity can never wedge, exactly the contract InputHandler kept.
-- Sits above the slide block because updateSlide chains into requestCrouchOn when a slide
-- decays out under a held Ctrl.
local function requestCrouchOn()
	if ctrlCrouching or isCrouching then return end
	ctrlCrouching = true
	crouchPredict = true
	if RE_Crouch then RE_Crouch:FireServer() end
	-- The grounded-state nudge InputHandler always did: this client owns its own physics,
	-- so kicking the Humanoid out of a planted state has to happen here to read as instant.
	if hum and hum.FloorMaterial ~= Enum.Material.Air then
		hum:ChangeState(Enum.HumanoidStateType.Running)
	end
	-- A rejected crouch never echoes "Crouch" back; drop the prediction rather than
	-- walking at half speed forever.
	task.delay(0.6, function()
		if not isCrouching then crouchPredict = false end
	end)
end

local function requestCrouchOff()
	if not ctrlCrouching then return end
	ctrlCrouching = false
	crouchPredict = false
	if RE_Crouch then RE_Crouch:FireServer() end
end

-- Grace on the floor check. Now that gravity applies during a slide (Plane, not Vector) the
-- character genuinely leaves the ground for a frame or two over every bump and crest -- ending
-- on the FIRST Air frame would make a slide down real terrain stutter out almost immediately.
-- A ledge still ends it, it just has to be a ledge rather than a pebble.
local slideAirTime = 0
-- Duration clock (2026-08-08 pt2). Only advances while the slide is NOT gaining speed, so
-- a hill that keeps accelerating you never ages the slide out -- it ends when the hill does.
local slideAge      = 0
local slidePrevSpeed = 0
-- Where the aim pointed last frame. Steering is the FRAME-TO-FRAME DELTA of this, so a
-- slide holds its entry heading until you actually turn. nil = first frame, nothing to
-- compare against yet.
local slideAimPrev  = nil

local function endSlide(preserveMomentum)
	if not isSliding then return end
	isSliding = false
	slideCooldownUntil = tick() + (SLIDECFG.Cooldown or 0.6)
	local v = vc()
	if v then v.cancel("slide") end
	setOwnFacing(false)

	-- HANDBACK, same contract as the dash: seed the movement model from the slide's real
	-- speed so you flow straight into a run instead of dead-stopping. currentDir is set too,
	-- otherwise the model would try to bleed the "turn" from your old heading to this one.
	local speed = slideVec.Magnitude
	local dir = Model.flatUnit(slideVec)
	if preserveMomentum and dir and hrp then
		local ceiling = math.max(1, hum and hum.WalkSpeed or MCFG.BaseWalkSpeed)
		state.currentDir = dir
		state.walkPower = math.clamp(speed / ceiling, 0, 1)
		-- Leaving the ground mid-slide (a ledge) must carry the horizontal velocity into the
		-- fall, or you stop dead in mid-air -- the old system's "slide off a cliff" bug.
		hrp.AssemblyLinearVelocity = Vector3.new(slideVec.X, hrp.AssemblyLinearVelocity.Y, slideVec.Z)
	end
	slideVec = Vector3.zero
	if RE_SlideEnd then RE_SlideEnd:FireServer() end
end

local function startSlide()
	if not hum or not hrp or isSliding or isDashing or isCrouching then return end
	if hum.FloorMaterial == Enum.Material.Air then return end
	if tick() < slideCooldownUntil then return end

	local vel = hrp.AssemblyLinearVelocity
	local flat = Vector3.new(vel.X, 0, vel.Z)
	local speed = flat.Magnitude

	-- SLOPE ENTRY (2026-08-08, deepwoken-style): a slide-worthy incline under you counts as
	-- momentum -- Ctrl slides you down it even from a standstill. Seeded straight downhill
	-- at SlopeEntrySpeed with NO EntryImpulse (the hill provides; updateSlide's slope-accel
	-- branch takes it from there). MaxSlopeAngle still means fall, not slide.
	local slopeAngle, slopeDownhill = readSlope()
	local slowSlopeEntry = slopeDownhill ~= nil
		and slopeAngle >= (SLIDECFG.SlideSlopeAngle or 35)
		and slopeAngle <  (SLIDECFG.MaxSlopeAngle or 60)
		and speed < (SLIDECFG.MinSpeedToSlide or 12)

	-- You have to already be moving to slide -- it converts momentum, it does not create it.
	-- (A qualifying slope IS stored momentum -- see above.)
	if not slowSlopeEntry and speed < (SLIDECFG.MinSpeedToSlide or 12) then return end

	local dir
	if slowSlopeEntry then
		dir = slopeDownhill
	else
		dir = Model.flatUnit(flat) or Model.flatUnit(hrp.CFrame.LookVector)
	end
	if not dir then return end

	local v = vc()
	if not v then return end

	isSliding = true
	slideAirTime = 0
	slideAge = 0
	slidePrevSpeed = 0 -- 0 so the first frame always reads as "accelerating" (entry burst)
	-- Seed the steering reference from the aim at entry, so the very first frame measures a
	-- delta of zero and the slide launches exactly along `dir` instead of snapping.
	slideAimPrev = (hrp and Model.flatUnit(hrp.CFrame.LookVector)) or nil
	setOwnFacing(true)
	-- INSTANT entry: velocity is set outright, never ramped into. No duration -- a slide
	-- ends when its own physics says so (speed floor, slope, ledge), so the contribution
	-- lives until endSlide cancels it and is re-steered every frame by updateSlide.
	-- Entry clamps at MaxEntrySpeed, not MaxSpeed (2026-08-08): the dash-cancel chain was
	-- entering at the dash's ~73 and riding the 60 physics cap. MaxSpeed stays the downhill
	-- ceiling -- hills are the point -- a slide just may not START that fast.
	if slowSlopeEntry then
		slideVec = dir * math.max(speed, SLIDECFG.SlopeEntrySpeed or 14)
	else
		slideVec = dir * math.min(
			(SLIDECFG.MaxEntrySpeed or SLIDECFG.MaxSpeed or 60),
			speed + (SLIDECFG.EntryImpulse or 10))
	end
	v.push({ id = "slide", planar = slideVec, duration = nil, decay = "none", suppressInput = true })
	if RE_Slide then RE_Slide:FireServer() end
end

local function updateSlide(dt)
	if not vc() or not hrp or not hum then endSlide(false); return end

	if hum.FloorMaterial == Enum.Material.Air then
		slideAirTime = slideAirTime + dt
		-- Left the ground for real (slid off a ledge): end, but carry the momentum into the fall.
		if slideAirTime > (SLIDECFG.AirGrace or 0.15) then endSlide(true); return end
	else
		slideAirTime = 0
	end

	-- Sampled along the direction of travel, so the reading describes the hill you are
	-- actually sliding down rather than the single point under the root.
	local angle, downhill = readSlope(slideVec)
	-- Too steep to be a slide any more -- hand it to gravity as a fall, keeping speed.
	if angle >= (SLIDECFG.MaxSlopeAngle or 60) then endSlide(true); return end

	local onDownhill = false -- set by the grounded branch; read by friction and the clock

	if slideAirTime > 0 then
		-- Inside the grace window: no ground under you, so neither the slope nor friction can
		-- act. Coast at the speed you had. Bleeding here would make every bump cost you speed.
	else
		-- DOWNHILL FEEDS THE SLIDE. sin(angle) means the steeper it is the harder it pulls,
		-- so a real hill carries you a long way -- that is the whole appeal of the mechanic.
		-- Only the component heading downhill accelerates; sliding UP a slope still decays.
		local downhillAligned = 0
		if angle > (SLIDECFG.MinSlopeToSlide or 8) and downhill then
			downhillAligned = math.max(0, (Model.flatUnit(slideVec) or downhill):Dot(downhill))
			local accel = (SLIDECFG.SlopeAccelFactor or 60) * math.sin(math.rad(angle)) * downhillAligned * dt
			slideVec = slideVec + downhill * accel
		end
		-- "Genuinely heading down a hill": drives both the friction choice below and whether
		-- the duration clock is allowed to run at all.
		onDownhill = downhillAligned >= (SLIDECFG.DownhillNoDragDot or 0.5)

		-- FRICTION ALWAYS -- it is not the `else` of the slope branch. It used to be, which meant
		-- anything steeper than MinSlopeToSlide had literally zero drag and simply accelerated to
		-- MaxSpeed and held there: a measured slide down a gentle 11 degree hill ran 90 studs.
		-- (The old code had the same shape, but the slide self-terminated on the first airborne
		-- frame so it never got the chance to show.) Letting the two compete is both physically
		-- right and legible: below roughly 35 degrees friction wins and the hill merely EXTENDS
		-- the slide, above it gravity wins and the hill genuinely accelerates you.
		--
		-- EXCESS DRAG (2026-08-08): speed above ExcessRefSpeed bleeds extra, so a dash-fed
		-- slide converges toward a sprint slide's distance instead of squaring away from it
		-- (distance grows with speed^2 under constant friction). Exempt while meaningfully
		-- downhill-aligned -- hills are allowed to build to MaxSpeed; a dash-stuffed FLAT
		-- slide is not. See the Config.Movement.Slide comment block for the curve.
		local dir = Model.flatUnit(slideVec)
		local speed = slideVec.Magnitude
		local decel = SLIDECFG.FlatFriction or 34
		if onDownhill then
			-- On a hill the surface barely holds you: bleed SlopeFriction instead of the flat
			-- figure. With FlatFriction the slope only won above ~34.5 degrees, so every
			-- ordinary hill net-decelerated and the whole mechanic read as broken.
			decel = SLIDECFG.SlopeFriction or 8
		else
			decel += math.max(0, speed - (SLIDECFG.ExcessRefSpeed or 36)) * (SLIDECFG.ExcessDrag or 3)
		end
		speed = math.max(0, speed - decel * dt)
		slideVec = dir and dir * speed or Vector3.zero
	end

	-- STEERING BY TURN DELTA (2026-08-09, dev: "the default direction remains the initial
	-- direction of the slide -- only if you turn within that moment does the direction
	-- change"). The slide KEEPS the heading it entered with. Each frame we measure how far
	-- the aim has rotated SINCE THE LAST FRAME and apply that same rotation to the slide.
	-- Turn nothing and the slide holds its line forever; turn the camera and it carves by
	-- exactly what you turned, rate-limited to SteerRateDeg per second.
	--
	-- This is why it is a delta and not a target: steering TOWARD the facing (the previous
	-- implementation) meant any standing offset between body and slide dragged the heading
	-- around on its own, so the slide never held the line you entered on.
	local dir = Model.flatUnit(slideVec)
	local aimNow = (hrp and Model.flatUnit(hrp.CFrame.LookVector)) or readInputDir()
	if dir and aimNow then
		if slideAimPrev then
			local turned = Model.angleBetweenDeg(slideAimPrev, aimNow)
			if turned > 0.01 then
				local maxStep = (SLIDECFG.SteerRateDeg or 110) * dt
				local step = math.min(turned, maxStep)
				local sign = (slideAimPrev:Cross(aimNow).Y >= 0) and 1 or -1
				local steered = Model.flatUnit(
					CFrame.fromAxisAngle(Vector3.yAxis, math.rad(step) * sign) * dir)
				if steered then slideVec = steered * slideVec.Magnitude end
			end
		end
		slideAimPrev = aimNow
	end

	-- slideVec stays flat by construction; the constraint never touches Y, so gravity keeps
	-- the character pinned to the slope it is sliding down.
	slideVec = Vector3.new(slideVec.X, 0, slideVec.Z)
	if slideVec.Magnitude > (SLIDECFG.MaxSpeed or 60) then
		slideVec = slideVec.Unit * (SLIDECFG.MaxSpeed or 60)
	end
	-- Re-steer the live contribution rather than re-pushing: update keeps the same record,
	-- so the slide stays ONE contribution being aimed, not a stream of replacements.
	vc().update("slide", slideVec)

	-- DURATION. The clock only runs while you are not gaining speed: accelerating (the
	-- entry burst, or a hill feeding you) pauses it, so a downhill run lasts as long as the
	-- hill and a flat slide gets MaxDuration and no more. AccelPauseRate is a small positive
	-- threshold rather than zero so per-frame physics jitter cannot stall the timer forever.
	-- Being on a hill pauses it too, not just actively gaining: a long shallow descent can
	-- sit at terminal speed (slope feed == friction) without technically accelerating, and
	-- timing out halfway down a hill is exactly the "slide won't keep going" complaint.
	local nowSpeed = slideVec.Magnitude
	local gaining = (nowSpeed - slidePrevSpeed) > (SLIDECFG.AccelPauseRate or 1) * dt
	slidePrevSpeed = nowSpeed
	if not gaining and not onDownhill then slideAge += dt end
	-- Timing out does NOT chain into the crouch the way sliding to a stop does: you are still
	-- moving here, and dropping a moving player into a crouch reads as a snag. The handback
	-- flows the remaining speed into a run instead; Ctrl can be tapped again to re-slide.
	if slideAge >= (SLIDECFG.MaxDuration or 1.0) then endSlide(true); return end

	if slideVec.Magnitude < (SLIDECFG.MinSlideSpeed or 10) then
		endSlide(true)
		-- Slid to a stop with Ctrl still down: settle into the crouch. This is the half of
		-- the one-key contract where the slide BECOMES the crouch; the ledge and steep-slope
		-- exits above deliberately don't -- both leave the ground, and crouching there would
		-- read as a snag. (Chained after endSlide so the handback maths stays untouched.)
		if ctrlHeld then requestCrouchOn() end
	end
end

-- Dash direction (2026-08-07): the direction you are STEERING -- the camera-relative
-- input vector -- not a WASD snap to the four body axes. W+A dashes diagonally
-- forward-left; no input dashes the way you face (a standing dodge). The server and the
-- dodge-anim payload still speak 4-way tokens (VALID_DIRS), so the token is DERIVED from
-- the chosen direction against the facing, same sign convention as moveAngleDeg below.
local function dashDirAndToken()
	local facing = hrp and Model.flatUnit(hrp.CFrame.LookVector) or nil
	local dir = readInputDir() or facing
	if not dir then return nil, "forward" end
	local token = "forward"
	if facing then
		local deg = Model.angleBetweenDeg(facing, dir)
		if deg >= 135 then
			token = "back"
		elseif deg > 45 then
			token = (facing:Cross(dir).Y >= 0) and "left" or "right"
		end
	end
	return dir, token
end

-- Speed this dash was actually launched at, so the handback can be expressed against it.
local dashLaunchSpeed = 0
local dashDir = nil
-- The live dash velocity, re-aimed every frame by updateDash. Kept as a vector (not just a
-- direction) so the steering can rotate it without touching its magnitude -- turning a dash
-- must never make it faster or slower, only point somewhere else.
local dashVec = Vector3.zero
-- Where the aim pointed last frame, for the same frame-to-frame delta the slide uses.
local dashAimPrev = nil

--[[ STEERABLE DASH (2026-08-10) -- the same delta-turn flow the slide uses.

     The dash keeps the heading it launched with and rotates by exactly however much you turn
     the aim this frame, capped at Dash.SteerRateDeg. Turn nothing and it holds its line; turn
     the camera and it carves with you.

     A DELTA, not a target, for the same reason the slide is: steering TOWARD the facing would
     let any standing offset between body and dash drag the heading around on its own, so the
     dash would never hold the line you launched on.

     Only the DIRECTION changes -- the magnitude is preserved, so steering can never make a
     dash longer or shorter than the one you paid for, and the server's displacement guard
     (which budgets from the launch speed) stays valid. ]]
local function updateDash(dt)
	local v = vc()
	if not v or not hrp then return end
	local dir = Model.flatUnit(dashVec)
	local aimNow = Model.flatUnit(hrp.CFrame.LookVector)
	if dir and aimNow then
		if dashAimPrev then
			local turned = Model.angleBetweenDeg(dashAimPrev, aimNow)
			if turned > 0.01 then
				local maxStep = (DASHCFG.SteerRateDeg or 1100) * dt
				local step = math.min(turned, maxStep)
				local sign = (dashAimPrev:Cross(aimNow).Y >= 0) and 1 or -1
				local steered = Model.flatUnit(
					CFrame.fromAxisAngle(Vector3.yAxis, math.rad(step) * sign) * dir)
				if steered then
					dashVec = steered * dashVec.Magnitude
					-- The handback on exit reads dashDir, so it has to follow the steering --
					-- otherwise an air dash would fling you along the direction you STARTED in
					-- after visibly travelling somewhere else.
					dashDir = steered
				end
			end
		end
		dashAimPrev = aimNow
	end
	-- Re-aim the LIVE contribution rather than pushing a new one: update keeps the same
	-- record, so the dash stays one contribution being steered instead of a stream of
	-- replacements, and its duration keeps counting from the original launch.
	v.update("dash", dashVec)
end

local function endDash(myToken, inheritPower)
	if myToken ~= dashToken then return end -- a newer dash already took over
	isDashing = false
	-- cancel is exact and idempotent: on a natural end the contribution expires this same
	-- instant anyway (same Duration), and on a denial/feint this is what cuts it short.
	local v = vc()
	if v then v.cancel("dash") end
	setOwnFacing(false)
	if inheritPower then
		-- HANDBACK. Do NOT dump momentum to zero on exit -- carrying a fraction of the dash's
		-- own speed into movement momentum is what makes a dash flow into a run instead of
		-- dead-stopping, which was the single biggest reason the old dash read as bolted on.
		--
		-- Against THIS dash's speed, not a constant. Billing it against a fixed 80 studs/s meant
		-- 0.4 * 80 = 32, comfortably above any walk ceiling, so every dash -- including one from
		-- a dead stop -- ended clamped at walkPower 1. The knob only ever bit in its bottom
		-- fifth, and a standing dodge dumped you into a full run.
		local ceiling = (hum and hum.WalkSpeed or MCFG.BaseWalkSpeed)
		local carried = dashLaunchSpeed * (DASHCFG.MomentumCarry or 0.25)
		state.walkPower = math.clamp(math.max(state.walkPower, carried / math.max(1, ceiling)), 0, 1)

		-- Airborne, walkPower alone cannot move you (the Humanoid barely steers in the air), so
		-- an air dash needs its horizontal velocity handed back to the assembly directly --
		-- exactly the handback endSlide already does when it slides off a ledge.
		if hrp and dashDir and hum and hum.FloorMaterial == Enum.Material.Air then
			hrp.AssemblyLinearVelocity = Vector3.new(
				dashDir.X * carried, hrp.AssemblyLinearVelocity.Y, dashDir.Z * carried)
		end
	end
	dashDir = nil
end

local function startDash()
	if not hum or not hrp or isDashing then return end
	if isCrouching then return end
	-- GROUND ONLY (2026-08-09, dev's call): no air dashing. Refused here for instant local
	-- feedback and again in MovementSystem.processDash, which owns the authoritative answer.
	if hum.FloorMaterial == Enum.Material.Air then return end
	if tick() < dashCooldownUntil then return end -- predicted; server re-checks authoritatively
	-- DASH CANCELS SLIDE. Dash sits above slide in the priority chain, and cancelling into
	-- one is a deliberate bit of tech. Momentum is preserved through the handback, so the
	-- dash launches from the slide's speed rather than from a standstill. (The mirror --
	-- slide cancels dash -- lives in onCtrlDown.)
	if isSliding then endSlide(true) end

	local dir, token = dashDirAndToken()
	if not dir then return end

	local v = vc()
	if not v then return end

	local grounded = hum.FloorMaterial ~= Enum.Material.Air
	-- MOMENTUM-SCALED. A dash from a standstill is a dodge step (~7 studs); a dash out of a
	-- sprint is a committed lunge (~16). It used to be 17.6 studs either way, which is why a
	-- standing dodge read as a launch.
	local speed = dashSpeedFor(flatSpeed()) * (grounded and 1 or (DASHCFG.AirForceMult or 0.7))

	-- The RUSTY WINDOW (a dash inside Cooldown + RustyWindow fired at reduced distance) was
	-- removed 2026-08-10 -- dev: "no more half dashes." Every dash that fires is now a full
	-- dash; the flat 1.0s cooldown is the whole gate.
	dashCooldownUntil = tick() + (DASHCFG.Cooldown or 1.0)
	isDashing = true
	dashToken += 1
	dashLaunchSpeed = speed
	dashDir = dir
	dashVec = dir * speed
	-- Seed the steering reference from the aim at launch, so the first frame measures a delta
	-- of zero and the dash leaves exactly along `dir` instead of snapping.
	dashAimPrev = Model.flatUnit(hrp.CFrame.LookVector)
	local myToken = dashToken

	-- The character faces where it dashes and stops auto-rotating toward MoveDirection, which
	-- we are about to zero for the duration -- unless the camera owns the facing (shiftlock),
	-- in which case a dodge is a strafe and the body should keep facing where you are looking.
	setOwnFacing(true)
	state.currentDir = dir
	-- Framerate-independent by construction, same as it always was: a TIMED contribution, so
	-- distance is speed * Duration regardless of how many frames elapse inside the window.
	-- Fixed id: a dash cannot start while one is running, so "dash" can never collide.
	v.push({ id = "dash", planar = dir * speed, duration = DASHCFG.Duration or 0.25, decay = "none", suppressInput = true })

	-- Fire AFTER starting locally: the client owns feel, so the dash must not wait a round
	-- trip. The server validates and can still deny it (see OnDodgeResult below).
	--
	-- `speed` is sent so the displacement guard budgets for the dash we ACTUALLY did. The
	-- server does not take it on faith: it clamps the claim between what its own replicated
	-- velocity reading justifies and the configured ceiling, so a liar gains at most the
	-- legitimate maximum while an honest client is never snapped back over stale velocity.
	if RE_Dash then RE_Dash:FireServer(token, grounded, speed) end

	task.delay(DASHCFG.Duration or 0.25, function() endDash(myToken, true) end)
end

-- Server verdict. "denied" means stamina/cooldown/blocked -- cut the predicted dash short
-- rather than letting a move play out that never actually happened.
if RE_DodgeResult then
	RE_DodgeResult.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then return end
		if payload.result == "denied" then
			endDash(dashToken, false)
			dashCooldownUntil = payload.retryAfter and (tick() + payload.retryAfter) or dashCooldownUntil
		end
		if character then
			-- Read by MovementController to pick clean vs fatigued dodge clips later.
			character:SetAttribute("LastDodgeResult", payload.result)
		end
	end)
end

-- ── Server-mirrored state ──────────────────────────────────────────────────
if RE_MovState then
	RE_MovState.OnClientEvent:Connect(function(msgState)
		if     msgState == "Crouch"     then isCrouching = true; crouchPredict = false -- confirmed; the real ceiling takes over
		elseif msgState == "CrouchEnd"  then
			isCrouching = false
			-- The crouch->slope-slide conversion completes HERE (armed by the frame loop):
			-- the slide had to wait out this echo, because both the client guard and the
			-- server's processSlide refuse slides while crouched.
			if wantSlopeSlide then
				wantSlopeSlide = false
				if ctrlHeld and not isSliding then startSlide() end
			end
		elseif msgState == "Sprint"     then sprintActive = true
		elseif msgState == "SprintEnd"  then sprintActive = false
		end
	end)
end

-- A second listener on the same remote SanityEffectsClient uses. Multiple :Connect calls on
-- one RemoteEvent are independent, so this does not disturb its cliff-pull at all.
if RE_Sanity then
	RE_Sanity.OnClientEvent:Connect(function(data)
		if type(data) == "table" and type(data.tiers) == "table" then sanityTiers = data.tiers end
	end)
end

if RE_Rage then
	RE_Rage.OnClientEvent:Connect(function(data)
		isRaging = type(data) == "table" and data.active == true or false
	end)
end

-- The Ctrl arbitration: one key, read against real speed. Above SlideOverCrouchSpeed the
-- press means slide; at or below it -- or when the slide declines (cooldown, airborne,
-- mid-dash, no VelocityClient) -- it means crouch, so the press is never simply eaten.
local function onCtrlDown()
	ctrlHeld = true
	if isSliding then return end
	local threshold = SLIDECFG.SlideOverCrouchSpeed or ((MCFG.BaseWalkSpeed or 16) + 1)
	-- A slide-worthy incline counts as speed (2026-08-08): Ctrl on it means slide even from
	-- a standstill -- startSlide seeds the entry downhill.
	local slopeAngle = readSlope()
	local onSlideSlope = slopeAngle >= (SLIDECFG.SlideSlopeAngle or 35)
		and slopeAngle < (SLIDECFG.MaxSlopeAngle or 60)
	-- SLIDE ALWAYS CANCELS DASH (2026-08-09, dev: "sliding after dashing overrides / cancels
	-- your dash for a slide"). Unconditional -- a dash IS speed by definition, so it never
	-- has to satisfy the speed or slope test first. endDash hands the momentum back, then
	-- startSlide converts it; without this the dash's own isDashing guard silently refused
	-- the slide and the press fell through to a crouch.
	if isDashing then
		endDash(dashToken, true)
		startSlide()
		if isSliding then return end
	end
	if flatSpeed() > threshold or onSlideSlope then
		startSlide()
		if isSliding then return end
	end
	requestCrouchOn()
end

local function onCtrlUp()
	ctrlHeld = false
	wantSlopeSlide = false -- releasing Ctrl abandons any pending crouch->slide conversion
	if isSliding then
		endSlide(true) -- stand out of the slide, momentum handed back into the run
		return
	end
	requestCrouchOff()
end

-- ── Input ────────────────────────────────────────────────────────────────
-- DOUBLE-TAP W SPRINT. Two W presses inside the window ARM it (sprintHeld); holding W
-- keeps it armed, and the frame loop below still owns whether sprint actually engages
-- (forward-dot, crouch, grounded) and the server whether it is granted. Releasing W and
-- re-pressing inside the window re-arms without a fresh double-tap -- deliberate, so
-- sprint survives quick steering releases.
local lastWDown = 0

UIS.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode == Enum.KeyCode.Q then
		startDash()
	elseif input.KeyCode == Enum.KeyCode.W then
		local now = tick()
		if now - lastWDown <= (MCFG.Sprint.DoubleTapWindow or 0.3) then
			sprintHeld = true
		end
		lastWDown = now
	elseif input.KeyCode == Enum.KeyCode.LeftControl or input.KeyCode == Enum.KeyCode.RightControl
		or input.KeyCode == Enum.KeyCode.C then
		local wasDown = ctrlKeyDown or cKeyDown
		if input.KeyCode == Enum.KeyCode.C then cKeyDown = true else ctrlKeyDown = true end
		if not wasDown then onCtrlDown() end -- only the first of the two keys triggers it
	end
end)

UIS.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.W then
		sprintHeld = false
		if sprintActive and RE_SprintEnd then RE_SprintEnd:FireServer() end
		sprintActive = false
	elseif input.KeyCode == Enum.KeyCode.LeftControl or input.KeyCode == Enum.KeyCode.RightControl
		or input.KeyCode == Enum.KeyCode.C then
		if input.KeyCode == Enum.KeyCode.C then cKeyDown = false else ctrlKeyDown = false end
		if not (ctrlKeyDown or cKeyDown) then onCtrlUp() end -- only once BOTH are up
	end
end)

-- ── Animation / cross-system state ───────────────────────────────────────────
-- Where the body is travelling RELATIVE TO WHERE IT FACES, in degrees: 0 = straight ahead,
-- +90 = travelling right of facing, 180 = backwards. Outside shiftlock this is ~0 almost
-- always (AutoRotate turns the body to face its movement), which is exactly what makes it the
-- right signal: under shiftlock the body is locked to the camera and A/D/S become genuine
-- strafes and backpedals, and this is what MovementController picks its clip from.
local function moveAngleDeg()
	if not hrp then return 0 end
	local facing = Model.flatUnit(hrp.CFrame.LookVector)
	local moving = Model.flatUnit(state.currentDir)
	if not facing or not moving or state.walkPower <= (MODEL.RestThreshold or 0.05) then return 0 end
	local deg  = Model.angleBetweenDeg(facing, moving)
	local sign = (facing:Cross(moving).Y >= 0) and -1 or 1 -- +Y cross means counter-clockwise, i.e. left
	return deg * sign
end

local lastMoveState = nil
local function publishState(grounded)
	if not character then return end
	local s
	if isDashing                     then s = "Dashing"
	elseif isSliding                 then s = "Sliding"
	elseif not grounded              then s = "Airborne"
	elseif isCrouching               then s = state.walkPower > 0.05 and "CrouchWalking" or "Crouching"
	elseif sprintActive and state.walkPower > 0.5 then s = "Sprinting"
	elseif state.walkPower > 0.05    then s = "Walking"
	else                                  s = "Idle" end
	if s ~= lastMoveState then
		lastMoveState = s
		character:SetAttribute("MoveState", s)
	end
	-- walkPower IS the Flow value. Published every frame so the combat revamp (and any HUD
	-- meter that lands later) has something to read without reaching into this script.
	-- LOCAL ONLY: attributes set on a client never replicate. The server recovers Flow from the
	-- root's replicated velocity instead (MovementSystem.getFlow). It cannot use
	-- Humanoid.MoveDirection for it -- the engine normalises that, so it reads 1.0 for any
	-- non-zero move no matter what magnitude we pass here.
	character:SetAttribute("Flow", state.walkPower)
	-- Wired now, clips later: MovementController reads this to choose strafe/backpedal
	-- animations, and today every one of those slots points at the forward clip.
	character:SetAttribute("MoveAngle", moveAngleDeg())
end

-- ── The frame loop ───────────────────────────────────────────────────────
-- Character priority (300) runs AFTER ControlModule's own Move at Input priority (100), so
-- our Move is the one the physics step reads. Also after Camera (200), which matters
-- because input is camera-relative and we want this frame's camera, not last frame's.
RunService:BindToRenderStep("MovementClientStep", Enum.RenderPriority.Character.Value, function(dt)
	if not hum or not hrp or hum.Health <= 0 then return end

	-- Pitfall #1 from the movement research: without this, clipping a wall or a slope at
	-- speed lets the solver spin the assembly and the character flings. One line, every
	-- frame, regardless of state.
	hrp.AssemblyAngularVelocity = Vector3.zero

	local grounded = hum.FloorMaterial ~= Enum.Material.Air

	-- ── STATE CHAIN ─────────────────────────────────────────────────────────
	--   1. dash   -- the "dash" contribution drives, the momentum model suspended
	--   2. slide  -- the "slide" contribution drives (re-steered by updateSlide)
	--   3. movement model
	-- This chain now sequences the MODEL AND ANIMATION STATE only -- the physics no longer
	-- needs it. All actual velocity goes through VelocityClient's single constraint, where
	-- dash, slide and anything the server pushes (knockback) vector-sum; both impulse
	-- contributions carry suppressInput, so VelocityClient zeroes the Humanoid's own Move a
	-- priority slot after ours (the Move(zero) here is belt-and-braces for a missing
	-- VelocityClient). Both actions still hand momentum back to the model on exit rather
	-- than dead-stopping.
	if isDashing then
		updateDash(dt) -- re-aim the live dash by however much you turned this frame
		hum:Move(Vector3.zero, false)
		publishState(grounded)
		return
	end

	if isSliding then
		updateSlide(dt)
		hum:Move(Vector3.zero, false)
		publishState(grounded)
		return
	end

	local targetDir = readInputDir()
	state = Model.step(state, dt, targetDir, buildContext(dt, grounded))

	-- Sprint gating, client side. The server owns whether sprint is GRANTED (stamina, combat
	-- locks); this only decides when it is worth asking. MinForwardDot stops you sprinting
	-- sideways or backwards. There is deliberately no momentum prerequisite: with instant
	-- acceleration you are at full walk on the first frame anyway, so gating on walkPower
	-- would have been dead config that reads as live.
	if sprintHeld and not sprintActive and not isCrouching and grounded and targetDir then
		local facing = Model.flatUnit(hrp.CFrame.LookVector)
		if facing == nil or facing:Dot(targetDir) >= (MCFG.Sprint.MinForwardDot or 0.3) then
			sprintActive = true -- optimistic; server confirms or silently drops it
			if RE_Sprint then RE_Sprint:FireServer() end
		end
	end
	-- Releasing the direction (or turning away) drops sprint without needing a key-up.
	if sprintActive and (not targetDir or isCrouching) then
		sprintActive = false
		if RE_SprintEnd then RE_SprintEnd:FireServer() end
	end

	-- CROUCH -> SLOPE SLIDE conversion (2026-08-08, deepwoken-style): crouch-walking onto a
	-- slide-worthy incline converts into the downhill slide. It cannot startSlide directly
	-- -- the client guard and the server both refuse slides while crouched -- so this fires
	-- the uncrouch and arms wantSlopeSlide; the CrouchEnd echo handler finishes the job one
	-- round-trip later. Raycasts only while actually crouched with Ctrl down.
	if isCrouching and ctrlHeld and not wantSlopeSlide and grounded then
		local slopeAngle = readSlope()
		if slopeAngle >= (SLIDECFG.SlideSlopeAngle or 35) and slopeAngle < (SLIDECFG.MaxSlopeAngle or 60) then
			wantSlopeSlide = true
			requestCrouchOff()
		end
	end

	local mv = Model.moveVector(state)
	-- Crouch round-trip prediction: until the server's Crouch confirm halves the WalkSpeed
	-- ceiling for real, scale the move MAGNITUDE by the same multiplier. Predicting through
	-- the vector instead of WalkSpeed (THE ONE RULE) keeps it composing -- a wounded or
	-- raging character predicts against their real ceiling, not a hardcoded 16.
	if crouchPredict and not isCrouching then
		mv = mv * ((MCFG.SpeedMult and MCFG.SpeedMult.Crouch) or 0.5)
	end
	hum:Move(mv, false)
	publishState(grounded)
end)

-- ── Character lifecycle ───────────────────────────────────────────────────
local function acquire(char)
	character = char
	hum = char:WaitForChild("Humanoid", 10)
	hrp = char:WaitForChild("HumanoidRootPart", 10)

	state = Model.newState()
	isCrouching, sprintHeld, sprintActive = false, false, false
	isDashing = false
	dashToken += 1 -- invalidates any in-flight endDash from the previous character
	dashCooldownUntil = 0
	dashLaunchSpeed, dashDir = 0, nil
	dashVec, dashAimPrev = Vector3.zero, nil
	isSliding = false
	slideVec = Vector3.zero
	slideAirTime = 0
	slideAge, slidePrevSpeed, slideAimPrev = 0, 0, nil
	slideCooldownUntil = 0
	ctrlHeld, ctrlCrouching, crouchPredict, wantSlopeSlide = false, false, false, false
	ctrlKeyDown, cKeyDown = false, false
	isRaging = false
	sanityTiers = {}
	lastMoveState = nil

	if hum then hum.AutoRotate = true end
	-- No constraints to ensure any more -- VelocityClient attaches the character's single
	-- VM_Velocity in its own acquire, and clears every contribution on death itself.

	hum.Died:Connect(function()
		dashToken += 1
		isDashing = false
		isSliding = false
	end)
end

if player.Character then acquire(player.Character) end
player.CharacterAdded:Connect(acquire)

print(string.format(
	"[MovementClient] Loaded -- WxW sprint / Q dash (%.1f-%.1f studs) / Ctrl or C slide-or-crouch, WalkSpeed untouched",
	(DASHCFG.MinSpeed or 32) * (DASHCFG.Duration or 0.22),
	(DASHCFG.MaxSpeed or 73) * (DASHCFG.Duration or 0.22)))
