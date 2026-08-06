local Config = {}

-- Single source of truth for owner usernames. ModManager / ChatManager / LanguageManager
-- all read this; do not re-declare a local OWNERS list in a manager (they drifted before,
-- and this table carried a "greatmlgpd1" typo for the real "greatmlgd1" while nothing read it).
Config.Owners = {"greatmlgd1", "Broke3n", "RespiraDev", "Gdjkshgdhhse", "JakxSkellington"}

-- PLACEHOLDER_GROUPID: ModGroupId
Config.ModGroupId = 0
-- PLACEHOLDER_RANKID: ModRankMinimum
Config.ModRankMinimum = 100

Config.Stamina = {
	Max = 100,
	RegenIdle    = 1.5,  -- stamina per second out of combat (was 1, bumped a bit faster)
	RegenCombat  = 0.6,  -- stamina per second in combat (was 0.4, bumped a bit faster)
	RegenTickRate = 1.0, -- unused by new SM but kept for compatibility
	HPRegenIdle   = 0.6, -- HP per second out of combat (debuffed from 1 per user request)
	HPRegenCombat = 0.2, -- HP per second in combat (debuffed from 0.4 per user request)
	CostM1 = 0, -- removed per design: M1 no longer costs stamina (polish pass, confirmed live)
	CostM2 = 18,
	CostParry = 12,
	CostParryTrait = 20,
	CostBlockPerSec = 5,
	CostDash = 6, 
	CostDodgeFist = 8,
	CostClashEnter = 15,
	CostClashWinRefund = 10,
	CostSprint = 3,
	HungerZeroDrainMult = 1.2,
	HungerZeroRegenMult = 0.5,
}

Config.Posture = {
	Max = 100,
	FillM1 = 5,
	FillAerialBonus = 3,
	FillWhiff = 15,
	FillGotParried = 20,
	FillBlock = 10,
	DrainRateNatural = 5,
	DrainRateManual = 15,
	DrainRateInCombat = 0,
	GuardBreakDuration = 3.0, 
}

Config.Parry = {
	WindowTotal = 20,       -- frames @60fps the parry stays active after activation (~0.333s -- slight buff from 18/0.3s per user request; was 24/0.4s, then 16/0.267s; press-F now fires the parry instantly and only falls into block once this window closes, so it needs to read as a tight reaction window, not a long safety net)
	PerfectWindow = 10,     -- frames @60fps that count as a Perfect (was 4 -- ~67ms was so tight almost no real parry ever landed Perfect, which is also why the Perfect-only VFX/hitstop basically never fired)
	Cooldown = 1.0,         -- was 0.6 -- makes tap-spamming F meaningfully costly instead of nearly free
	-- Raised 1.2 -> 1.5 (2026-07-21): at 1.2s a perfect parry could not fit a meaningful punish
	-- (a full 5-hit M1 chain is M1Cooldown 0.5 x 5 = 2.5s), so winning the read paid out less
	-- than it should. 1.5s is the spec's tuned window -- a 3-hit chain or a critical.
	StaggerDurationPerfect = 1.5,
	StaggerDurationLate = 0.5,
}

Config.Combat = {
	M1Damage = 15,
	M2Damage = 30,
	CriticalDamage = 45,
	FistDamageMultiplier = 0.6,
	SpeedBlock = 0.4,
	HitstunDuration = 0.3,
	KnockbackForce = 40,
	KnockbackRunningForce = 50,
	ExecuteHealthThreshold = 0.15,
	ExecuteRange = 5,
	CarryRange = 4,
	BleedOutTime = 30,
	CombatTagDuration = 60,
	SpeedM1Chain = 0.25, -- was 0.35 (polish pass: M1 chain felt too free, players moving too much)
	SpeedM2Swing = 0.10, -- was 0 (polish pass: full root felt too heavy; allow slight shuffle)
	-- {offset, sizeX, sizeY, sizeZ} — far reach = offset + sizeZ/2
	HitboxM1 = {3, 6, 5, 4},   -- reach 5 studs
	HitboxM2 = {2, 7, 5, 2.5}, -- reach 3.25 studs — noticeably shorter than M1: more power, less range
	HitboxRunningM1 = {4, 4, 4, 6},
	HitboxAerialM1 = {2, 5, 5, 4},
	HitboxCriticalNormal = {3, 4, 4, 4},
	HitboxCriticalAir = {2, 6, 6, 4},
	HitboxCriticalSweep = {2, 5, 3, 5},
	ChainResetTime = 2,     -- seconds of no M1 before the chain resets to hit 1
	LandingRecovery = 0.93, -- seconds after landing where M1/M2/dash/parry are blocked (movement still allowed) -- matches the land animation's real length (rbxassetid://89670666875141) so actions aren't available again mid-animation
	M1Startup = 32,         -- frames @60fps before the FIRST M1 hit's hitbox activates (readable telegraph -- long enough to actually see the windup and react/parry) -- bumped from 12, then 16, then 22, then 28: hitbox was still appearing too soon
	M2SwingDuration = 0.8,  -- seconds the M2 swing/root lasts
	M2Cooldown = 7.0,       -- seconds between M2 attempts -- previously only a hardcoded fallback in CombatManager, not actually in Config
	M2Startup = 36,         -- frames @60fps before M2's hitbox activates -- previously M2 had NO windup at all (hit on the same frame as input), making it nearly impossible to react to or parry. Noticeably longer than M1Startup: M2 is the slow, heavy, more-telegraphed swing. Bumped from 26, then 32: still felt too fast.
	AttackTurnSpeed = 120,  -- degrees/sec cap on character rotation while an attack is active
	-- The following were previously only hardcoded fallback defaults inside CombatManager's
	-- script (never actually read from Config)
	M1ChainMax = 5,               -- hits in a full M1 combo before it must reset
	M1EndLagDuration = 1.5,       -- seconds of M1-locked end lag after a full chain finishes
	M1EnderDamageMultiplier = 1.35, -- damage multiplier on the chain-finishing (5th) hit
	CostFeint = 4,                -- stamina cost to feint (cancel an M1 mid-chain)
	SpeedStagger = 0.3,           -- movement speed multiplier while staggered
	SpeedGuardBreak = 0,          -- movement speed multiplier while guard-broken (fully rooted)
	SpeedCarrying = 0.5,          -- movement speed multiplier while carrying a downed player
	M1Cooldown = 0.5,             -- seconds between M1 swings (the chain's own rhythm)
	CriticalCooldown = 13,        -- seconds between Critical attempts
	AerialSlamCooldown = 5,       -- seconds between Aerial M1 (DownSlam) attempts
	FeintCooldown = 2.0,          -- seconds between feints -- was 1.0, bumped to make feinting a real commitment, not a near-free option
	SprintLockDuration = 1.5,     -- seconds of no-sprint after landing OR receiving a hit (refreshed on every hit) -- stops a fight being escaped by just holding W+Shift mid-exchange
}

-- Real combat animation clip ids, shared by InputHandler (client-predicted player anims)
-- and NPCManager (server-driven NPC anims, since NPCs have no client to predict on) so
-- the two can never drift apart the way the client-side mirrored-constant bugs did before
-- (see the M1 chain-rate/endlag drift bug -- same lesson, applied to asset ids this time).
-- M2 has no dedicated clip here on purpose -- players never got one either (M2 relies
-- entirely on the weapon-trail flash + windup highlight, no character animation at all).
Config.CombatAnims = {
	M1Attack  = {"rbxassetid://93003216324892","rbxassetid://93309525871833","rbxassetid://76061547002874","rbxassetid://105606731790316","rbxassetid://86525713046817"},
	M1Parried = {"rbxassetid://78432723730245","rbxassetid://137733149049804","rbxassetid://107001549223171","rbxassetid://93112238973652","rbxassetid://77227256623114"},
	M1GotHit  = {"rbxassetid://89336533592700","rbxassetid://87274907384651","rbxassetid://106529260314645","rbxassetid://114865793084492","rbxassetid://102069296813970"},
	M1Parry   = {"rbxassetid://126386632322807"}, -- only the first parry animation is used
	Parry     = {"rbxassetid://78432723730245"},  -- only the first parry animation is used
	DownSlam       = {"rbxassetid://132272853265400"}, -- aerial M1 (DownSlam) attacker pose
	DownSlamGotHit = {"rbxassetid://71659184399828"},  -- victim reaction when slammed down by DownSlam
	GuardBroken    = {"rbxassetid://90600493268409"},  -- reaction pose on posture break
}

Config.Speed = {
	Base = 16,
	Sprint = 25,
	M1Active = 4,   -- 0.25 * Base -- kept in sync with Config.Combat.SpeedM1Chain (the actual value CombatManager reads)
	M2Swing = 1.6,  -- 0.10 * Base -- kept in sync with Config.Combat.SpeedM2Swing (the actual value CombatManager reads)
	ParryWindow = 12,
	Blocking = 6,
	BlockTalent = 16,
	Stagger = 5,
	GuardBreak = 0,
	EndLag = 16,
	Carrying = 8,
	Feint = 16,
}

-- ─── MOVEMENT ─────────────────────────────────────────────────────────────
-- Movement revamp pass 1 (2026-08-04). The old stack was torn out the same day and is
-- archived at ServerStorage._OldMovement_2026_08_04 if any old value is wanted back.
--
-- READ BEFORE TOUCHING SPEED: the movement system NEVER writes Humanoid.WalkSpeed.
-- WalkSpeed is the *authorised ceiling*, owned by the existing pipeline (CombatCore.setSpeed
-- composes health x injury x rage x caste; SanityEffectsClient's cliff-pull and
-- ModMenuClient's /speed also write it). Momentum is expressed as the MAGNITUDE of the move
-- vector instead -- Humanoid:Move(v) travels at WalkSpeed * v.Magnitude -- so every one of
-- those multipliers keeps composing untouched and there is no feedback loop.
Config.Movement = {
	BaseWalkSpeed = 16,
	SprintSpeed   = 26,  -- the ceiling sprint raises WalkSpeed to (via CombatCore.setSpeed)
	SpeedMult = {
		Normal = 1.0,
		Crouch = 0.5, -- 8 studs/s
		Sprint = 26 / 16,
	},

	-- Momentum model (ReplicatedStorage.Shared.MovementModel). All times are SECONDS, all
	-- rates are per-second: the model is dt-scaled throughout so a 30fps and a 240fps client
	-- cover identical ground (asserted in Movement_TestHarness).
	-- SNAPPY AT WALK, WEIGHTY AT SPRINT. Snappy and weighty are not opposites -- they just
	-- belong at different speeds. There is NO ground-acceleration knob here on purpose: an
	-- accel ramp is input latency wearing a different hat, and combat cannot afford it.
	-- Walk/run is instant to start, instant to stop, and free to turn or strafe. Every gram
	-- of weight lives above MomentumSpeedThreshold, i.e. in sprint.
	Model = {
		BaseSpeed       = 16,   -- ceilings above this count as sprinting

		-- Stopping. At walk/run this is near-instant (snappy); once you are over the momentum
		-- threshold, SprintDecelTime takes over and you carry the sprint forward instead.
		GroundDecelTime = 0.06,
		AirDecelTime    = 1.00, -- barely bleeds in the air; you keep what you jumped with

		-- The ONLY wind-up in the entire model. Sprint takes this long to reach top speed,
		-- and that wind-up IS the momentum you then have to manage in a fight.
		SprintRampTime  = 0.35,
		SprintDecelTime = 0.25,

		-- Momentum simply does not exist below this speed (studs/s). Walk is 16, so nothing
		-- about walking is ever weighty; sprint is 26, so the top of a sprint is.
		MomentumSpeedThreshold = 20,
		-- ...and even at speed, only genuinely sharp turns cost anything. Gentle course
		-- corrections mid-sprint stay free.
		SharpTurnAngle   = 100, -- degrees
		TurnMomentumLoss = 0.15, -- fraction of momentum a full 180 at speed costs

		TurnSmoothness  = 16,   -- facing/heading chases input fast -- visually snappy
		-- ...and BELOW the momentum threshold it is snappier still. Weight is supposed to live
		-- at sprint and nowhere else, but TurnSmoothness alone applied the same ~0.18s sweep to
		-- a 90 degree turn at walking pace, so pressing S mid-run carved a full-speed U-turn
		-- instead of reversing. At walk the heading now resolves in ~0.07s.
		LightTurnMult   = 4.0,
		AerialTurnMult  = 0.35, -- committed jumps: you cannot freely redirect mid-air

		-- The floor on airborne momentum. lockedAirPower snapshots your speed at takeoff and
		-- clamps you to it, which is the committed-jump feel -- but taken literally a jump from
		-- a STANDSTILL locked you at zero and you could not steer at all for the whole jump.
		-- This is the baseline steering every jump keeps. You still cannot air-strafe your way
		-- UP to sprint speed, which is the part that actually mattered.
		MinAirPower     = 0.55,

		-- Below this walkPower the character counts as at rest, and the heading snaps
		-- straight to the input instead of lerping -- no momentum means nothing to redirect,
		-- so setting off from a standstill is instant in any direction.
		RestThreshold   = 0.05,
		-- Below this the model snaps to 0 instead of asymptoting toward it forever.
		SnapThreshold   = 0.02,
	},

	Sprint = {
		MinForwardDot = 0.3,  -- must be roughly heading the way you're facing to sprint
		StaminaPerSec = 3,    -- scaled by TalentManager.getModifier(p, "SprintStaminaDrain")
	},

	-- DASH -- distance SCALES WITH MOMENTUM (2026-08-05 pt3). It used to be a flat
	-- 80 x 0.22 = 17.6 studs whether you were sprinting or standing still, which made a
	-- standing dodge read as a launch. Duration stays FIXED, because distance = speed x
	-- duration with no frame term is the whole reason the dash is framerate-independent.
	--
	--   speed = MinSpeed + (MaxSpeed - MinSpeed) * (flatSpeed / SprintSpeed) ^ MomentumCurve
	--
	-- standstill -> 32 x 0.22 = ~7.0 studs   (a dodge step)
	-- walking    -> 52 x 0.22 = ~11.4 studs
	-- sprinting  -> 73 x 0.22 = ~16.1 studs  (a committed lunge)
	--
	-- The exponent is what pulls walk down to ~11: a linear map would put it at ~12.6,
	-- because walk is already 62% of sprint speed.
	Dash = {
		MinSpeed      = 32,   -- from a dead stop
		MaxSpeed      = 73,   -- at full sprint
		MomentumCurve = 1.5,  -- >1 keeps the low end short; 1 would be a straight lerp
		Duration      = 0.22, -- distance = speed * Duration, constant at ANY framerate
		Cooldown      = 0.60, -- scaled by TalentManager.getModifier(p, "DashCooldownMult")
		StaminaCost   = 6,
		AirForceMult  = 0.70, -- an un-nerfed air dash launches you
		-- Handback on exit: carry this fraction of THIS DASH'S OWN speed into movement
		-- momentum, so the character flows out into a run instead of dead-stopping. Against a
		-- constant it saturated -- every dash, including a standing one, ended at walkPower 1.
		-- Scaled against the real dash speed it means the same thing at both ends of the curve.
		MomentumCarry = 0.25,
		MaxDisplacementMult = 1.5, -- server snapback guard: resolved speed * Duration * this
	},

	-- SLIDE (rebuilt 2026-08-05). Instant in, decay out -- like everything else here,
	-- nothing ramps at the START. Bound to C.
	--
	-- The whole point is the slope: downhill, gravity feeds the slide and you go FURTHER,
	-- which is the fun of it. On the flat, friction eats it and you stand back up.
	--
	-- RETUNED 2026-08-05 pt3. EntryImpulse 55 meant a slide STARTED at 71 studs/s from a
	-- walk and covered ~62 studs on flat ground before friction gave up -- a teleport, not a
	-- commitment. Now ~15 studs from a walk, ~27 from a sprint.
	Slide = {
		EntryImpulse    = 18,   -- instant burst added to your current speed on entry
		MinSpeedToSlide = 12,   -- must already be moving this fast to slide at all
		FlatFriction    = 34,   -- studs/s^2 bled on flat ground
		MinSlideSpeed   = 10,   -- below this you stand up
		-- Downhill acceleration, scaled by sin(slope). It COMPETES with FlatFriction rather than
		-- replacing it, so the crossover is where SlopeAccelFactor * sin(angle) = FlatFriction:
		-- 60 * sin(angle) = 34 -> about 35 degrees. Below that a hill extends the slide; above it
		-- the hill genuinely accelerates you toward MaxSpeed.
		SlopeAccelFactor = 60,
		MinSlopeToSlide = 8,    -- degrees; gentler than this contributes no downhill pull at all
		MaxSlopeAngle   = 60,   -- steeper than this is a fall, not a slide
		-- Now that gravity acts during a slide, real terrain lifts you off the ground for a frame
		-- or two over every bump. Ending on the first airborne frame would stutter a hill slide
		-- out almost immediately; a ledge has to actually be a ledge.
		AirGrace        = 0.15, -- seconds off the ground before the slide gives up
		SteerControl    = 0.30, -- how much you may carve mid-slide (0 = none, 1 = full)
		MaxSpeed        = 60,   -- hard cap so a long hill cannot launch you
		StaminaCost     = 8,
		Cooldown        = 0.60,
	},

	Dodge = {
		MaxStock            = 3,
		-- MUST stay comfortably longer than MaxStock x Dash.Cooldown (3 x 0.6 = 1.8s), or the
		-- economy is decorative: at 2.0s the first stock had already regenerated before you
		-- could physically spend the third, so the stock never actually emptied.
		RegenTime           = 3.5,  -- seconds per restored stock
		IframeDuration      = 0.30,
		FatiguedIframeMult  = 0.40, -- out of stock = a worse dodge, not no dodge
		FatiguedStaminaMult = 1.50,
		MaxRefundWindow     = 0.40, -- cap on the ping-compensated damage refund
		MaxRefundPerDodge   = 40,   -- so a spoofed-latency client cannot farm heals
	},

	-- Terrain friction. Missing materials fall back to no modification at all.
	--   maxPowerMult -- top speed on this surface. THIS is how a surface slows you now that
	--                   acceleration is instant; an accelMult would do nothing.
	--   decelMult    -- LOWER = longer skid (it divides into the decel TIME).
	--   turnMult     -- cornering authority / grip.
	-- Ice is the shape to read for the idea: full speed, no grip, enormous skid.
	SurfaceProfiles = {
		[Enum.Material.Mud]        = { maxPowerMult = 0.80, decelMult = 1.60, turnMult = 0.75 },
		[Enum.Material.Snow]       = { maxPowerMult = 0.90, decelMult = 0.55, turnMult = 0.55 },
		[Enum.Material.Ice]        = { maxPowerMult = 1.00, decelMult = 0.25, turnMult = 0.30 },
		[Enum.Material.Glacier]    = { maxPowerMult = 1.00, decelMult = 0.25, turnMult = 0.30 },
		[Enum.Material.Sand]       = { maxPowerMult = 0.85, decelMult = 1.40, turnMult = 0.85 },
		[Enum.Material.Water]      = { maxPowerMult = 0.70, decelMult = 1.30, turnMult = 0.70 },
		[Enum.Material.Grass]      = { maxPowerMult = 1.00, decelMult = 1.00, turnMult = 0.95 },
		[Enum.Material.LeafyGrass] = { maxPowerMult = 0.98, decelMult = 1.05, turnMult = 0.90 },
		[Enum.Material.Slate]      = { maxPowerMult = 1.00, decelMult = 0.90, turnMult = 0.90 },
	},

	-- Injuries reshape the CURVE, not just the top speed. BrokenTissue's flat speedMult
	-- still comes from InjuryManager.getSpeedMultiplier (it lands on WalkSpeed); this is the
	-- extra handling penalty layered on top -- a wounded character skids and cannot corner.
	-- A wounded character keeps the snappy start (that is a control-feel promise, not a
	-- fitness stat) but loses grip: worse cornering, longer skid, harsher turn bleed.
	InjuryProfiles = {
		BrokenTissue  = { maxPowerMult = 0.90, decelMult = 0.70, turnMult = 0.50, turnBleedMult = 2.0 },
		LostArm       = { maxPowerMult = 1.00, decelMult = 1.00, turnMult = 0.85, turnBleedMult = 1.2 },
		ConcussedMind = { maxPowerMult = 1.00, decelMult = 1.00, turnMult = 0.70, turnBleedMult = 1.4 },
	},

	-- Sanity destabilises control: at the listed tiers the character stops obeying you
	-- cleanly -- a slow drift is injected into the input direction and hard turns bleed more.
	Sanity = {
		DriftDegAtShadow = 6,   -- max drift once the `shadow` tier is active
		DriftDegAtCliff  = 14,  -- max drift once `cliffPull` is active (the deepest tier)
		DriftFrequency   = 0.35, -- Hz -- slow wander, not jitter
		TurnBleedMult    = 1.6,
	},

	-- Rage is pure commitment: dodges cost no stock, but you cannot brake or corner.
	Rage = { DecelMult = 0.35, TurnMult = 0.45, FreeDodges = true },
}

-- ─── VELOCITY (movement rehaul phase 1, 2026-08-05) ─────────────────────────
-- The contribution system: every external force on a character (dash, slide, knockback,
-- launches) registers a contribution with VelocityModel/VelocityClient, and ONE
-- LinearVelocity per character applies the vector sum. Read by VelocityModel (as
-- ctx.config), VelocityRuntime, VelocityClient and VelocityManager.
Config.Velocity = {
	-- Same tuned cap the dash/slide constraints proved out, for the same reason: unbounded
	-- force fights wall collisions instead of letting the solver resolve them (the
	-- dash-into-wall fling/spin bug). Composes by MAX across stacked contributions, never
	-- by sum -- stacking three knockbacks must not triple the violence against a wall.
	MaxForce    = 45000,
	MaxSpeed    = 200, -- clamp on any single contribution and on the resolved sum (typo guard)
	MaxDuration = 5,   -- clamp on any single finite contribution's duration
	DefaultDuration = 0.25, -- substituted when a server push omits duration

	Knockback = {
		Duration = 0.25,     -- how long a standard hit-shove drives
		Decay    = "linear", -- fades across the window rather than cutting -- reads as a
		                     -- shove, not a conveyor belt
		-- Forces deliberately NOT duplicated here: callers pass their own (Shroom 32/26,
		-- Wolf 40/20 from their config blocks) and the fallback stays
		-- Config.Combat.KnockbackForce, read at call time by VelocityManager.applyKnockback
		-- -- which takes that long-orphaned key off the orphan list instead of shadowing it.
	},
}

-- Config.MovementFeel (accel ramp, stop-slide, sprint FOV, lean-into-turns, coyote
-- time + jump buffering, camera follow lag) was deleted 2026-08-04 along with
-- StarterPlayerScripts.MovementFeelClient. Its full tuning block is preserved inside
-- the archived script at ServerStorage._OldMovement_2026_08_04.Client.MovementFeelClient.
-- Nothing reads it now; leaving it here would be dead config that reads as live.

-- ─── CAMERA ──────────────────────────────────────────────────────────────
-- Tight over-the-shoulder framing, read by StarterPlayerScripts.CameraClient.
--
-- NOTE ON SCOPE: the 2026-08-04 teardown deliberately stripped every camera EFFECT out of
-- movement (bob, dip, roll, sprint FOV, lean, follow lag). This is NOT those coming back --
-- it is framing only: how far back the camera sits, how far off-shoulder, and whether the
-- body is locked to the camera. Roblox's own camera still does the following, and nothing
-- here writes CFrame per frame, so it composes with the Sanity/Feelings/Injury/Weather
-- passes instead of fighting them. Enabled = false restores stock framing completely.
--
-- WHY SHOULDER OFFSET LIVES UNDER Shiftlock (2026-08-05 pt3): Humanoid.CameraOffset is
-- applied in HUMANOIDROOTPART space -- BaseCamera:GetSubjectPosition does
-- `bodyPart.CFrame:vectorToWorldSpace(heightOffset + humanoid.CameraOffset)`. With AutoRotate
-- on, the body faces its movement direction, so a fixed X offset SWINGS the camera around you
-- every time you turn. That was the "camera isn't set correctly" bug. Under
-- RotationType.CameraRelative the body's yaw IS the camera's yaw, so root-part X becomes
-- camera-right and the exact same property becomes correct -- which is precisely why Roblox's
-- own shiftlock uses it. So: offset while locked, dead centre while not. Never wrong in
-- either mode.
Config.Camera = {
	Enabled = true,
	DefaultDistance = 10,      -- closer than Roblox's stock 12.5
	CombatDistance  = 8,       -- tightens while CombatState is not Idle
	MinZoomDistance = 0.5,     -- the player may still zoom in to first person
	DistanceLerp    = 6,       -- how fast the distance eases between the two
	OffsetLerp      = 8,

	-- True over-the-shoulder. Default OFF: LockCenter pins the cursor to screen centre and
	-- nothing in ABYSS releases it (only EmoteWheelClient saves/restores MouseBehavior), so
	-- an always-on lock would make the mod menu, inventory, hotbar, BTools, trade and ritual
	-- UI unclickable. Alt toggles, and a manual toggle-OFF sticks.
	Shiftlock = {
		Enabled        = true,
		DefaultOn      = false,
		Key            = Enum.KeyCode.LeftAlt,
		ShoulderOffset = 2,    -- studs right of screen centre; 0 = centred behind
		CursorGui      = "ShiftlockCursor",
	},
	-- Roblox's default camera already follows with no added lag -- the follow-lag layer was
	-- deleted with the teardown and is deliberately NOT reinstated. Kept as documentation of
	-- intent rather than as a knob that secretly does nothing.
	FollowResponsiveness = 20,
}

Config.Clash = {
	InputRaceTime = 3,
	SequenceLength = 5,
	LoserStaggerDuration = 0.8,
	LoserStaminaDrain = 10,
}

Config.Hunger = {
	Max = 100,
	DrainHealingRate = 2,
	DrainPassiveRate = 0.015, -- ~100 -> 0 in ~111 minutes (was 0.12/~14min, then 0.04/~42min -- still too quick per user feedback)
	DrainCombatRate = 0,
	LowThreshold = 30, -- heal-rate taper starts below this
	MinHealMult = 0.35, -- floor heal multiplier from hunger alone bottoming out (not the both-zero case)
}

-- Drains faster than Hunger by design (user request: "water drains faster then food").
Config.Water = {
	Max = 100,
	DrainPassiveRate = 0.2, -- ~100 -> 0 in ~8 minutes
	LowThreshold = 30,
	MinHealMult = 0.35,
}

Config.DayCycle = {
	FullDayDuration = 1500,
	-- ClockTime a fresh server starts the cycle at. Was hardcoded 6.0 in WeatherManager, which
	-- is DAWN by the game's own getTimeOfDay table (Dawn 5.5-8, Morning 8-11) -- so every new
	-- server opened in half-light. 8.0 is the start of Morning proper.
	StartClockTime = 8.0,
}

Config.Currency = {
	Tiers = {"Obol", "Drachma", "Stater", "RoyalStater"},
	ConversionRate = 10,
}

Config.PDStages = {
	[0] = "Inert",
	[1] = "Awakened",
	[2] = "Scarred",
	[3] = "Burning",
	[4] = "Condemned",
	[5] = "TheAbyss",
}

Config.FightingStyles = {
	"None", "Ironwall", "Duelist", "Berserker", "Unarmed", "Spear", "Dagger"
}


Config.Combat.MobKnockbackResist = 0.85

Config.Combat.DashIFrames = 6 -- frames @ 60fps of dash invincibility, applies to ALL players

-- Dash Feint: Q pressed again during an active dash ends it early, trading remaining
-- travel distance for extra iframes -- a mix-up tool to bait a punish read for the full dash.
Config.Combat.DashFeintBonusIFrames = 4    -- frames @ 60fps, granted on TOP of any remaining dash iframes
Config.Combat.DashFeintRecovery     = 0.15 -- seconds of no-attack neutral recovery after a feint

-- Dash<->Parry cancels (design doc PART FOUR/4E, combat polish)
Config.Combat.DashToParryCancel  = true
Config.Combat.ParryToDashCancel  = true
Config.Combat.CancelWindowFrames = 4 -- frames @ 60fps (~0.067s)

Config.Bleed = {
	BloodBarMax = 100,
	BurstDamage = 30,
	BloodBarDecayRate = 3, -- per second, clots back toward 0 when not actively bleeding (~33s for a full bar)
	Tiers = {
		Light  = { drainPerSec = 1.5, duration = 4, bloodBarFill = 12 },
		Medium = { drainPerSec = 2.5, duration = 5, bloodBarFill = 22 },
		Heavy  = { drainPerSec = 4,   duration = 6, bloodBarFill = 35 },
	},
}

-- PLACEHOLDER_WEBHOOK: DiscordWebhook
Config.DiscordWebhook = "PLACEHOLDER_WEBHOOK_URL"

-- WEATHER — Module 12 expansion
Config.WeatherTransitionDuration = 5

Config.WeatherProfiles = {
	-- Clear is ABYSS's true baseline -- every other profile tweens away from this and every
	-- weather clearing tweens back to it, so THIS is where the game's default dark-medieval
	-- mood lives (retuned 2026-07-18: was a bright washed-out neutral, now a warm dark grim
	-- tone per the owner's reference image). Deliberately not a separate static Lighting
	-- override applied alongside WeatherClient's own tweening -- two systems writing the same
	-- Ambient/Brightness/Atmosphere/ColorCorrection properties is exactly the bug already hit
	-- once before (see WeatherClient's Saturation-oscillation comment) and fixed by giving
	-- ownership to a single instance/table.
	Clear = {
		Ambient = Color3.fromRGB(80, 75, 65), OutdoorAmbient = Color3.fromRGB(120, 115, 100),
		Brightness = 1.5, FogEnd = 5000, FogStart = 0, FogColor = Color3.fromRGB(180, 180, 190),
		AtmosphereDensity = 0.4, AtmosphereColor = Color3.fromRGB(190, 170, 140), AtmosphereHaze = 1.8, AtmosphereGlare = 0.3,
		ColorCorrection = { Brightness = -0.05, Contrast = 0.20, Saturation = -0.15, TintColor = Color3.fromRGB(240, 220, 200) },
	},
	Sunny = {
		Ambient = Color3.fromRGB(180, 170, 155), OutdoorAmbient = Color3.fromRGB(230, 220, 195),
		Brightness = 3, FogEnd = 8000, FogStart = 500, FogColor = Color3.fromRGB(210, 200, 180),
		AtmosphereDensity = 0.2, AtmosphereColor = Color3.fromRGB(230, 220, 200), AtmosphereHaze = 0.3, AtmosphereGlare = 0.3,
		ColorCorrection = { Brightness = 0.05, Contrast = 0.15, Saturation = 0.15, TintColor = Color3.fromRGB(255, 250, 240) },
	},
	Cloudy = {
		Ambient = Color3.fromRGB(130, 128, 125), OutdoorAmbient = Color3.fromRGB(150, 150, 155),
		Brightness = 1.2, FogEnd = 3000, FogStart = 200, FogColor = Color3.fromRGB(150, 150, 155),
		AtmosphereDensity = 0.5, AtmosphereColor = Color3.fromRGB(160, 160, 165), AtmosphereHaze = 1.5, AtmosphereGlare = 0,
		ColorCorrection = { Brightness = -0.05, Contrast = 0, Saturation = -0.15, TintColor = Color3.fromRGB(240, 240, 245) },
	},
	Foggy = {
		Ambient = Color3.fromRGB(120, 120, 125), OutdoorAmbient = Color3.fromRGB(140, 140, 145),
		Brightness = 1, FogEnd = 300, FogStart = 30, FogColor = Color3.fromRGB(160, 160, 165),
		AtmosphereDensity = 0.8, AtmosphereColor = Color3.fromRGB(170, 170, 175), AtmosphereHaze = 3, AtmosphereGlare = 0,
		ColorCorrection = { Brightness = -0.05, Contrast = -0.05, Saturation = -0.25, TintColor = Color3.fromRGB(230, 230, 240) },
	},
	Rain = {
		Ambient = Color3.fromRGB(110, 115, 125), OutdoorAmbient = Color3.fromRGB(140, 145, 155),
		Brightness = 1, FogEnd = 1500, FogStart = 100, FogColor = Color3.fromRGB(130, 135, 145),
		AtmosphereDensity = 0.6, AtmosphereColor = Color3.fromRGB(140, 145, 155), AtmosphereHaze = 2, AtmosphereGlare = 0,
		ColorCorrection = { Brightness = -0.1, Contrast = 0.05, Saturation = -0.1, TintColor = Color3.fromRGB(220, 225, 240) },
	},
	HeavyRain = {
		Ambient = Color3.fromRGB(90, 95, 105), OutdoorAmbient = Color3.fromRGB(115, 120, 130),
		Brightness = 0.8, FogEnd = 800, FogStart = 50, FogColor = Color3.fromRGB(110, 115, 125),
		AtmosphereDensity = 0.75, AtmosphereColor = Color3.fromRGB(120, 125, 135), AtmosphereHaze = 2.5, AtmosphereGlare = 0,
		ColorCorrection = { Brightness = -0.15, Contrast = 0.05, Saturation = -0.2, TintColor = Color3.fromRGB(210, 220, 240) },
	},
	Thunderstorm = {
		Ambient = Color3.fromRGB(70, 75, 90), OutdoorAmbient = Color3.fromRGB(90, 95, 110),
		Brightness = 0.6, FogEnd = 600, FogStart = 30, FogColor = Color3.fromRGB(85, 90, 105),
		AtmosphereDensity = 0.85, AtmosphereColor = Color3.fromRGB(95, 100, 115), AtmosphereHaze = 3, AtmosphereGlare = 0,
		ColorCorrection = { Brightness = -0.2, Contrast = 0.15, Saturation = -0.3, TintColor = Color3.fromRGB(200, 210, 240) },
	},
	Snow = {
		Ambient = Color3.fromRGB(140, 145, 160), OutdoorAmbient = Color3.fromRGB(180, 185, 200),
		Brightness = 1.5, FogEnd = 500, FogStart = 20, FogColor = Color3.fromRGB(220, 225, 235),
		AtmosphereDensity = 0.7, AtmosphereColor = Color3.fromRGB(230, 235, 245), AtmosphereHaze = 2, AtmosphereGlare = 0.2,
		ColorCorrection = { Brightness = 0.05, Contrast = -0.1, Saturation = -0.4, TintColor = Color3.fromRGB(240, 245, 255) },
	},
	Hail = {
		Ambient = Color3.fromRGB(100, 110, 125), OutdoorAmbient = Color3.fromRGB(130, 140, 155),
		Brightness = 1, FogEnd = 700, FogStart = 40, FogColor = Color3.fromRGB(160, 170, 185),
		AtmosphereDensity = 0.75, AtmosphereColor = Color3.fromRGB(150, 160, 175), AtmosphereHaze = 2.5, AtmosphereGlare = 0,
		ColorCorrection = { Brightness = -0.1, Contrast = 0.1, Saturation = -0.3, TintColor = Color3.fromRGB(220, 230, 245) },
	},
	Sandstorm = {
		Ambient = Color3.fromRGB(170, 130, 80), OutdoorAmbient = Color3.fromRGB(200, 155, 100),
		Brightness = 1.2, FogEnd = 200, FogStart = 20, FogColor = Color3.fromRGB(190, 145, 90),
		AtmosphereDensity = 0.9, AtmosphereColor = Color3.fromRGB(210, 165, 105), AtmosphereHaze = 4, AtmosphereGlare = 0.4,
		ColorCorrection = { Brightness = 0, Contrast = 0.1, Saturation = 0.2, TintColor = Color3.fromRGB(240, 200, 140) },
	},
	BloodRain = {
		Ambient = Color3.fromRGB(120, 40, 40), OutdoorAmbient = Color3.fromRGB(150, 55, 55),
		Brightness = 0.8, FogEnd = 900, FogStart = 60, FogColor = Color3.fromRGB(140, 40, 40),
		AtmosphereDensity = 0.7, AtmosphereColor = Color3.fromRGB(160, 50, 50), AtmosphereHaze = 2.5, AtmosphereGlare = 0,
		ColorCorrection = { Brightness = -0.1, Contrast = 0.2, Saturation = 0.5, TintColor = Color3.fromRGB(255, 180, 180) },
	},
	RedMist = {
		Ambient = Color3.fromRGB(100, 35, 35), OutdoorAmbient = Color3.fromRGB(130, 45, 45),
		Brightness = 0.9, FogEnd = 250, FogStart = 20, FogColor = Color3.fromRGB(150, 40, 40),
		AtmosphereDensity = 0.9, AtmosphereColor = Color3.fromRGB(170, 50, 50), AtmosphereHaze = 4, AtmosphereGlare = 0,
		ColorCorrection = { Brightness = -0.15, Contrast = 0.15, Saturation = 0.4, TintColor = Color3.fromRGB(255, 170, 170) },
	},
	RedSky = {
		Ambient = Color3.fromRGB(80, 25, 25), OutdoorAmbient = Color3.fromRGB(120, 35, 35),
		Brightness = 0.7, FogEnd = 1500, FogStart = 100, FogColor = Color3.fromRGB(100, 30, 30),
		AtmosphereDensity = 0.6, AtmosphereColor = Color3.fromRGB(180, 40, 40), AtmosphereHaze = 2, AtmosphereGlare = 0.3,
		ColorCorrection = { Brightness = -0.15, Contrast = 0.3, Saturation = 0.6, TintColor = Color3.fromRGB(255, 150, 150) },
	},
}
-- Aliases for pre-existing live weather names (the game already used "Fog"/"Storm"/
-- "Earthquake" before this expansion) -- point them at the matching new profile so
-- old mod-menu commands / saved calls still resolve.
Config.WeatherProfiles.Fog         = Config.WeatherProfiles.Foggy
Config.WeatherProfiles.Storm       = Config.WeatherProfiles.Thunderstorm
Config.WeatherProfiles.Earthquake  = Config.WeatherProfiles.Cloudy

-- Weather types that may occur naturally, with roll weight. BloodRain/RedMist/RedSky are
-- deliberately absent here -- mod-only / Eclipse-only, enforced by NaturalWeatherRotation
-- being the sole source the natural-cycle roll picks from.
Config.NaturalWeatherRotation = {
	{ weather = "Clear",        weight = 30 },
	{ weather = "Sunny",        weight = 20 },
	{ weather = "Cloudy",       weight = 25 },
	{ weather = "Foggy",        weight = 10 },
	{ weather = "Rain",         weight = 15 },
	{ weather = "HeavyRain",    weight = 8 },
	{ weather = "Thunderstorm", weight = 5 },
	{ weather = "Snow",         weight = 6 },
	{ weather = "Hail",         weight = 3 },
	{ weather = "Sandstorm",    weight = 2 },
}
Config.ModOnlyWeathers = { BloodRain = true, RedMist = true, RedSky = true }
Config.NaturalWeatherIntervalMin = 240 -- 4 min
Config.NaturalWeatherIntervalMax = 480 -- 8 min

-- Tuned for a 30x30 stud emission area (see WeatherClient's particleAnchor) -- emitRate
-- is picked so steady-state particle count (emitRate * lifetime) actually reads as
-- visible weather in that area, not a sparse sprinkle.
Config.WeatherParticles = {
	Rain         = { emitRate = 350, color = Color3.fromRGB(180, 200, 220), speed = 110, lifetime = 0.45, size = 0.13 },
	HeavyRain    = { emitRate = 550, color = Color3.fromRGB(170, 190, 220), speed = 140, lifetime = 0.5,  size = 0.16 },
	Thunderstorm = { emitRate = 650, color = Color3.fromRGB(160, 180, 210), speed = 150, lifetime = 0.5,  size = 0.16 },
	Snow         = { emitRate = 220, color = Color3.fromRGB(255, 255, 255), speed = 12,  lifetime = 4,    size = 0.35 },
	Hail         = { emitRate = 300, color = Color3.fromRGB(220, 230, 240), speed = 65,  lifetime = 0.8,  size = 0.22 },
	Sandstorm    = { emitRate = 450, color = Color3.fromRGB(205, 165, 105), speed = 55,  lifetime = 1.5,  size = 0.4 },
	BloodRain    = { emitRate = 300, color = Color3.fromRGB(150, 20, 20),   speed = 110, lifetime = 0.45, size = 0.1 },
	RedMist      = { emitRate = 100, color = Color3.fromRGB(160, 30, 30),   speed = 5,   lifetime = 4,    size = 0.4 },
}
Config.WeatherParticles.Storm = Config.WeatherParticles.Thunderstorm

-- Real sound instance names under ReplicatedStorage._Sounds.Weather / .Frost (see
-- WeatherClient); nil means silent for that weather.
Config.WeatherAmbientSounds = {
	Clear = nil, Sunny = nil,
	Cloudy = "Wind",
	Foggy = "Wind",
	Rain = "Rain_Light",
	HeavyRain = "Rain_Heavy",
	Thunderstorm = "Rain_Heavy",
	Snow = "Snow_Wind",
	Hail = "Hail_Impact",
	Sandstorm = "Sandstorm_Wind",
	BloodRain = "BloodRain_Ambient",
	RedMist = nil,
	RedSky = "Eclipse_Hum",
}
Config.WeatherAmbientSounds.Fog        = Config.WeatherAmbientSounds.Foggy
Config.WeatherAmbientSounds.Storm      = Config.WeatherAmbientSounds.Thunderstorm
Config.WeatherAmbientSounds.Earthquake = Config.WeatherAmbientSounds.Cloudy

Config.Frost = {
	StackApplyInterval = 3,
	MaxStacks = 10,
	DamagePerStackPerSecond = 0.3,
	DecayInterval = 5, -- 1 stack per this many seconds when out of cold weather
	LightningClearRadius = 30,
	FireProximityRadius = 15,
	FireProximityInterval = 2,
	IndoorRaycastHeight = 50,
	WarnLowStacks = 3,
	WarnHighStacks = 6,
	ClothingProtection = {
		None = 1.0,
		LightCloth = 0.7,
		Fur = 0.3,
		HeavyFur = 0.1,
	},
}

Config.Sandstorm = {
	BlurBase = 8,
	BlurMitigated = 2,
	Mitigation = {
		None = 1.0,
		LightCloth = 0.5,
		Mask = 0.2,
		FullFaceCloth = 0.1,
	},
}

Config.Lightning = {
	IntervalMin = 8,
	IntervalMax = 25,
	WarningLeadTime = 1,
	StrikeRadius = 500,
	SpeedOfSound = 340,
	FrostClearRadius = 30,
	DirectHitRadius = 10,
	DirectHitDamage = 35,
	AuraDuration = 1.5,
	AuraTemplateName = "Thunder Aura Blue",
}

-- Sky cloud layer (Terrain.Clouds) per weather -- Cover/Density match Roblox's native
-- Clouds instance properties. Clear/Sunny get a light scattering; storms get heavy,
-- dark cover.
Config.WeatherClouds = {
	Clear        = { Cover = 0.35, Density = 0.5,  Color = Color3.fromRGB(255, 255, 255) },
	Sunny        = { Cover = 0.15, Density = 0.4,  Color = Color3.fromRGB(255, 255, 255) },
	Cloudy       = { Cover = 0.85, Density = 0.7,  Color = Color3.fromRGB(210, 210, 215) },
	Foggy        = { Cover = 0.6,  Density = 0.3,  Color = Color3.fromRGB(220, 220, 225) },
	Rain         = { Cover = 0.75, Density = 0.6,  Color = Color3.fromRGB(160, 165, 175) },
	HeavyRain    = { Cover = 0.85, Density = 0.75, Color = Color3.fromRGB(120, 125, 135) },
	Thunderstorm = { Cover = 0.95, Density = 0.85, Color = Color3.fromRGB(70, 75, 85) },
	Snow         = { Cover = 0.8,  Density = 0.6,  Color = Color3.fromRGB(230, 232, 240) },
	Hail         = { Cover = 0.85, Density = 0.7,  Color = Color3.fromRGB(180, 185, 195) },
	Sandstorm    = { Cover = 0.5,  Density = 0.4,  Color = Color3.fromRGB(210, 180, 140) },
	BloodRain    = { Cover = 0.7,  Density = 0.6,  Color = Color3.fromRGB(140, 60, 60) },
	RedMist      = { Cover = 0.4,  Density = 0.3,  Color = Color3.fromRGB(150, 70, 70) },
	RedSky       = { Cover = 0.6,  Density = 0.5,  Color = Color3.fromRGB(160, 60, 60) },
}
Config.WeatherClouds.Fog        = Config.WeatherClouds.Foggy
Config.WeatherClouds.Storm      = Config.WeatherClouds.Thunderstorm
Config.WeatherClouds.Earthquake = Config.WeatherClouds.Cloudy

-- TIME OF DAY -- weather profiles above define an absolute "clear noon" baseline; these
-- act as multipliers/tints blended continuously across the day so the same weather type
-- actually looks different at dawn vs. midnight instead of always rendering identically
-- regardless of clock time. WeatherClient blends between adjacent checkpoints by
-- ClockTime so there are no hard jumps at the boundaries.
Config.TimeOfDayProfiles = {
	-- DeepNight/Night pushed moodier/more desaturated with a bigger, richer bloom (moon
	-- glow) and extra contrast -- aiming for that Sekiro moonlit-susuki-field look: deep
	-- cool blue-black sky, big luminous moon, high-contrast silhouettes.
	-- SunRaysIntensity values are ~3x the old ones -- empirically verified in Studio that
	-- Roblox's SunRaysEffect is barely visible below ~0.5 and only reads as real dramatic
	-- god-rays around 0.8-1.0. MoonGlowIntensity drives a separate custom moon-glow effect
	-- (SunRaysEffect is hardcoded to the Sun's direction only -- confirmed via
	-- Lighting:GetSunDirection()/GetMoonDirection() returning different vectors -- so it
	-- physically cannot pick up the Moon at night; the moon needs its own effect).
	DeepNight = {
		BrightnessMult = 0.11, AmbientTint = Color3.fromRGB(130, 145, 205),
		ColorCorrectionTint = Color3.fromRGB(165, 185, 235), FogColorTint = Color3.fromRGB(120, 135, 185),
		CloudColorTint = Color3.fromRGB(115, 130, 185),
		SunRaysIntensity = 0, MoonGlowIntensity = 0.85, BloomIntensity = 1.45, BloomSize = 34,
		CCBrightnessDelta = -0.1, CCContrastDelta = 0.1, CCSaturationDelta = -0.18,
	},
	Dawn = {
		BrightnessMult = 0.55, AmbientTint = Color3.fromRGB(255, 200, 160),
		ColorCorrectionTint = Color3.fromRGB(255, 215, 180), FogColorTint = Color3.fromRGB(255, 200, 175),
		CloudColorTint = Color3.fromRGB(255, 190, 150),
		SunRaysIntensity = 0.8, MoonGlowIntensity = 0, BloomIntensity = 1.2, BloomSize = 26,
		CCBrightnessDelta = 0.02, CCContrastDelta = 0.03, CCSaturationDelta = 0.05,
	},
	Morning = {
		BrightnessMult = 0.85, AmbientTint = Color3.fromRGB(255, 240, 220),
		ColorCorrectionTint = Color3.fromRGB(255, 248, 235), FogColorTint = Color3.fromRGB(235, 235, 230),
		CloudColorTint = Color3.fromRGB(255, 245, 230),
		SunRaysIntensity = 0.45, MoonGlowIntensity = 0, BloomIntensity = 1.0, BloomSize = 22,
		CCBrightnessDelta = 0, CCContrastDelta = 0, CCSaturationDelta = 0,
	},
	Midday = {
		BrightnessMult = 1.0, AmbientTint = Color3.fromRGB(255, 255, 255),
		ColorCorrectionTint = Color3.fromRGB(255, 255, 255), FogColorTint = Color3.fromRGB(255, 255, 255),
		CloudColorTint = Color3.fromRGB(255, 255, 255),
		SunRaysIntensity = 0.25, MoonGlowIntensity = 0, BloomIntensity = 0.85, BloomSize = 20,
		CCBrightnessDelta = 0, CCContrastDelta = 0, CCSaturationDelta = 0,
	},
	Afternoon = {
		BrightnessMult = 0.9, AmbientTint = Color3.fromRGB(255, 245, 225),
		ColorCorrectionTint = Color3.fromRGB(255, 248, 230), FogColorTint = Color3.fromRGB(245, 235, 220),
		CloudColorTint = Color3.fromRGB(255, 240, 220),
		SunRaysIntensity = 0.3, MoonGlowIntensity = 0, BloomIntensity = 0.9, BloomSize = 22,
		CCBrightnessDelta = 0, CCContrastDelta = 0, CCSaturationDelta = 0,
	},
	Dusk = {
		BrightnessMult = 0.5, AmbientTint = Color3.fromRGB(255, 175, 130),
		ColorCorrectionTint = Color3.fromRGB(255, 190, 150), FogColorTint = Color3.fromRGB(255, 170, 140),
		CloudColorTint = Color3.fromRGB(255, 165, 120),
		SunRaysIntensity = 0.9, MoonGlowIntensity = 0, BloomIntensity = 1.25, BloomSize = 28,
		CCBrightnessDelta = 0.03, CCContrastDelta = 0.05, CCSaturationDelta = 0.1,
	},
	Night = {
		BrightnessMult = 0.2, AmbientTint = Color3.fromRGB(150, 165, 220),
		ColorCorrectionTint = Color3.fromRGB(175, 195, 235), FogColorTint = Color3.fromRGB(135, 150, 195),
		CloudColorTint = Color3.fromRGB(140, 155, 205),
		SunRaysIntensity = 0, MoonGlowIntensity = 0.85, BloomIntensity = 1.35, BloomSize = 32,
		CCBrightnessDelta = -0.07, CCContrastDelta = 0.08, CCSaturationDelta = -0.14,
	},
}

-- Ordered checkpoints (ClockTime -> profile name) that WeatherClient interpolates
-- between. Matches WeatherManager.getTimeOfDay()'s boundaries.
Config.TimeOfDayCheckpoints = {
	{ t = 2,    name = "DeepNight" },
	{ t = 5.5,  name = "Dawn" },
	{ t = 8,    name = "Morning" },
	{ t = 11,   name = "Midday" },
	{ t = 14,   name = "Afternoon" },
	{ t = 17,   name = "Dusk" },
	{ t = 20,   name = "Night" },
}

-- Per-weather multipliers on top of the time-of-day base -- e.g. Sunny cranks sun rays
-- for a strong god-ray look, storms/fog crush them down since there's no direct light
-- to catch, fog/snow get extra soft bloom for that diffuse hazy look. MoonGlowMult is the
-- night-time equivalent of SunRaysMult -- clouds/fog/storms should dim or hide the moon
-- the same way they'd block sun rays. ShadowSoftness: crisp/hard shadows in direct light
-- (Clear/Sunny), soft/diffuse when light is scattered (Foggy/Cloudy/Snow/storms).
Config.WeatherSkyMods = {
	Clear        = { SunRaysMult = 1.3, BloomMult = 1.0,  MoonGlowMult = 1.2, ShadowSoftness = 0.15 },
	Sunny        = { SunRaysMult = 1.8, BloomMult = 1.1,  MoonGlowMult = 1.2, ShadowSoftness = 0.1 },
	Cloudy       = { SunRaysMult = 0.4, BloomMult = 0.9,  MoonGlowMult = 0.5, ShadowSoftness = 0.4 },
	Foggy        = { SunRaysMult = 0.15, BloomMult = 1.3, MoonGlowMult = 0.2, ShadowSoftness = 0.6 },
	Rain         = { SunRaysMult = 0.2, BloomMult = 0.85, MoonGlowMult = 0.3, ShadowSoftness = 0.45 },
	HeavyRain    = { SunRaysMult = 0.1, BloomMult = 0.8,  MoonGlowMult = 0.15, ShadowSoftness = 0.55 },
	Thunderstorm = { SunRaysMult = 0.05, BloomMult = 0.75, MoonGlowMult = 0.05, ShadowSoftness = 0.6 },
	Snow         = { SunRaysMult = 0.6, BloomMult = 1.25, MoonGlowMult = 0.7, ShadowSoftness = 0.35 },
	Hail         = { SunRaysMult = 0.3, BloomMult = 0.9,  MoonGlowMult = 0.35, ShadowSoftness = 0.45 },
	Sandstorm    = { SunRaysMult = 0.5, BloomMult = 1.15, MoonGlowMult = 0.4, ShadowSoftness = 0.5 },
	BloodRain    = { SunRaysMult = 0.1, BloomMult = 1.0,  MoonGlowMult = 0.3, ShadowSoftness = 0.4 },
	RedMist      = { SunRaysMult = 0.1, BloomMult = 1.1,  MoonGlowMult = 0.25, ShadowSoftness = 0.5 },
	RedSky       = { SunRaysMult = 0.7, BloomMult = 1.3,  MoonGlowMult = 0.6, ShadowSoftness = 0.3 },
}
Config.WeatherSkyMods.Fog        = Config.WeatherSkyMods.Foggy
Config.WeatherSkyMods.Storm      = Config.WeatherSkyMods.Thunderstorm
Config.WeatherSkyMods.Earthquake = Config.WeatherSkyMods.Cloudy

-- DEPTH OF FIELD -- kept deliberately subtle: NearIntensity stays 0 (never blur anything
-- close, which is where combat actually happens) and InFocusRadius is generous, so only
-- distant background scenery gets a gentle cinematic softening.
Config.DepthOfField = {
	FocusDistance = 40,
	InFocusRadius = 60,
	NearIntensity = 0,
	BaseFarIntensity = 0.12,
}
Config.WeatherDOFMult = {
	Clear = 0.8, Sunny = 0.7, Cloudy = 1.0, Foggy = 1.4, Rain = 1.1, HeavyRain = 1.3,
	Thunderstorm = 1.3, Snow = 1.1, Hail = 1.1, Sandstorm = 1.2, BloodRain = 1.1,
	RedMist = 1.3, RedSky = 1.1,
}
Config.WeatherDOFMult.Fog        = Config.WeatherDOFMult.Foggy
Config.WeatherDOFMult.Storm      = Config.WeatherDOFMult.Thunderstorm
Config.WeatherDOFMult.Earthquake = Config.WeatherDOFMult.Cloudy

-- MOON GLOW -- SunRaysEffect only ever follows the Sun's direction (Lighting:GetSunDirection()
-- vs GetMoonDirection() are different vectors, confirmed in Studio), so it physically can't
-- light up at night. This drives a separate screen-space glow tracking the real moon
-- position (Lighting:GetMoonDirection()) instead -- see WeatherClient's moon-glow section.
Config.MoonGlow = {
	Color = Color3.fromRGB(210, 220, 245),
	BaseSize = 260, -- pixels, outer halo diameter at full intensity
}

-- SHADOWS -- GlobalShadows should always stay on; only softness is tuned per weather
-- (see Config.WeatherSkyMods[weather].ShadowSoftness above).
Config.Shadows = {
	GlobalShadowsEnabled = true,
}

-- WIND -- a light drift of leaves/dust across view for ambiance. Snow/Sandstorm already
-- have their own dense precipitation carrying that feel, so they skip separate debris.
Config.WeatherWind = {
	Clear        = { DebrisRate = 3,  Color = Color3.fromRGB(200, 190, 150) },
	Sunny        = { DebrisRate = 2,  Color = Color3.fromRGB(210, 200, 160) },
	Cloudy       = { DebrisRate = 10, Color = Color3.fromRGB(180, 175, 150) },
	Foggy        = { DebrisRate = 4,  Color = Color3.fromRGB(190, 190, 190) },
	Rain         = { DebrisRate = 6,  Color = Color3.fromRGB(150, 140, 110) },
	HeavyRain    = { DebrisRate = 12, Color = Color3.fromRGB(140, 130, 100) },
	Thunderstorm = { DebrisRate = 16, Color = Color3.fromRGB(130, 120, 95) },
	Snow         = { DebrisRate = 0,  Color = Color3.fromRGB(255, 255, 255) },
	Hail         = { DebrisRate = 8,  Color = Color3.fromRGB(150, 145, 140) },
	Sandstorm    = { DebrisRate = 0,  Color = Color3.fromRGB(210, 180, 140) },
	BloodRain    = { DebrisRate = 6,  Color = Color3.fromRGB(120, 60, 60) },
	RedMist      = { DebrisRate = 3,  Color = Color3.fromRGB(130, 70, 70) },
	RedSky       = { DebrisRate = 5,  Color = Color3.fromRGB(140, 70, 70) },
}
Config.WeatherWind.Fog        = Config.WeatherWind.Foggy
Config.WeatherWind.Storm      = Config.WeatherWind.Thunderstorm
Config.WeatherWind.Earthquake = Config.WeatherWind.Cloudy

-- QTE SYSTEM -- shared foundation for meditation, pushups, interactables, and mod-triggered
-- QTEs. Server (QTEManager) picks/generates content and owns the deadline; client (QTEClient)
-- renders the matching UI for `type` and reports a result before the deadline.
Config.QTETiers = {
	Tier1 = { name = "Basic Focus", type = "SequenceInput", pool = {"W","A","S","D","Space"}, length = 4, timePerInput = 1.0 },
	Tier2 = { name = "Focused Mind", type = "SequenceInput", pool = {"W","A","S","D","Space","1","2","3","4","5"}, length = 6, timePerInput = 0.8 },
	Tier3 = { name = "Master Focus", type = "MonkeyType", wordPool = {"parry","focus","blade","steel","iron","flame","wind","abyss","eclipse","shadow"}, wordCount = 4, timeTotal = 12 },
	Tier4 = { name = "Perfect Timing", type = "GreenBar", barSpeed = 2, greenZoneWidth = 0.15, attempts = 3 },
	Tier5 = { name = "Absolute Precision", type = "CircleClose", circleDuration = 1.0, toleranceWindow = 0.1 },
	-- Mining (design doc PART TWO): a new QTE type, not a numbered tier -- rarity-tuned via
	-- Config.MiningRarityTuning at the moment mining starts (MiningManager builds a fresh
	-- per-attempt tierCfg table from the node's OreRarity rather than a single fixed entry
	-- here, since click count/tolerance/speed all vary by rarity).
	MiningQTE = { name = "Mining Rhythm", type = "ReactiveClick", countdownSpeed = 1.0, toleranceMs = 400, clickCount = 3 },
}

Config.MiningRarityTuning = {
	Common    = { countdownSpeed = 1.0, toleranceMs = 400, clickCount = 3 },
	Uncommon  = { countdownSpeed = 1.3, toleranceMs = 300, clickCount = 4 },
	Rare      = { countdownSpeed = 1.6, toleranceMs = 200, clickCount = 5 },
	Legendary = { countdownSpeed = 2.0, toleranceMs = 120, clickCount = 6 },
}
-- Endurance modifier: +5ms tolerance per point of Endurance (design doc: "each 10
-- Endurance adds +50ms", i.e. 5ms/point) -- applied by MiningManager at attempt-start.
Config.MiningEndurance = { TolerancePerPoint = 5 }

Config.LootPools = {
	common_forest = {
		{ item = "wood", weight = 40, count = "1-3" },
		{ item = "berries", weight = 30, count = "1-2" },
		{ item = "rope", weight = 20, count = "1" },
		{ item = "iron_ore", weight = 10, count = "1" },
	},
	massalia_barrel = {
		{ item = "bread", weight = 50, count = "1" },
		{ item = "wine", weight = 30, count = "1" },
		{ item = "coin_obol", weight = 20, count = "5-15" },
	},
}

Config.OreNodes = {
	Iron   = { rarity = "Common",    quantity = "1-3" },
	Copper = { rarity = "Common",    quantity = "1-3" },
	Silver = { rarity = "Uncommon",  quantity = "1-2" },
	Gold   = { rarity = "Rare",      quantity = "1-2" },
	Rare_Bloodstone = { rarity = "Legendary", quantity = "1" },
}

Config.SmeltingRecipes = {
	Iron_Ore = { output = "Iron_Ingot", count = 1, timeSeconds = 15 },
	Copper_Ore = { output = "Copper_Ingot", count = 1, timeSeconds = 10 },
	Silver_Ore = { output = "Silver_Ingot", count = 1, timeSeconds = 25 },
	Gold_Ore = { output = "Gold_Ingot", count = 1, timeSeconds = 40 },
	Rare_Bloodstone_Ore = { output = "Bloodstone_Ingot", count = 1, timeSeconds = 60 },
}

Config.TailoringShapes = {
	Circle = { points = {Vector2.new(0.5,0.15),Vector2.new(0.78,0.28),Vector2.new(0.85,0.5),Vector2.new(0.78,0.72),Vector2.new(0.5,0.85),Vector2.new(0.22,0.72),Vector2.new(0.15,0.5),Vector2.new(0.22,0.28),Vector2.new(0.5,0.15)}, tolerance = 15 },
	Square = { points = {Vector2.new(0.2,0.2),Vector2.new(0.8,0.2),Vector2.new(0.8,0.8),Vector2.new(0.2,0.8),Vector2.new(0.2,0.2)}, tolerance = 12 },
	Curve  = { points = {Vector2.new(0.15,0.5),Vector2.new(0.3,0.2),Vector2.new(0.5,0.5),Vector2.new(0.7,0.8),Vector2.new(0.85,0.5)}, tolerance = 10 },
	Star   = { points = {Vector2.new(0.5,0.1),Vector2.new(0.61,0.38),Vector2.new(0.91,0.38),Vector2.new(0.67,0.57),Vector2.new(0.76,0.86),Vector2.new(0.5,0.68),Vector2.new(0.24,0.86),Vector2.new(0.33,0.57),Vector2.new(0.09,0.38),Vector2.new(0.39,0.38),Vector2.new(0.5,0.1)}, tolerance = 8 },
}

Config.TailoringRecipes = {
	Cloth_Shirt = { materials = {{item="linen",count=3}}, shape = "Curve", output = "cloth_shirt" },
	Cloth_Pants = { materials = {{item="linen",count=4}}, shape = "Square", output = "cloth_pants" },
	Fur_Cloak   = { materials = {{item="linen",count=2},{item="fur",count=2}}, shape = "Star", output = "fur_cloak" },
}

Config.SmithingRecipes = {
	Iron_Longsword = { materials = {{item="Iron_Ingot",count=3}}, qteCount = 5, output = "iron_longsword", qualityTier = "Iron" },
	Steel_Shortsword = { materials = {{item="Iron_Ingot",count=2}}, qteCount = 4, output = "steel_shortsword", qualityTier = "Steel" },
	Masterwork_Longsword = { materials = {{item="Iron_Ingot",count=5},{item="Silver_Ingot",count=1}}, qteCount = 8, output = "masterwork_longsword", qualityTier = "Masterwork" },
	Iron_Axe = { materials = {{item="Iron_Ingot",count=4}}, qteCount = 6, output = "iron_axe", qualityTier = "Iron" },
}
-- Quality tier ladder for the fail-degrades-quality rule -- shared with the existing
-- Enums.WeaponQuality ordering (Iron < Steel < Masterwork < Legendary < Divine).
Config.QualityTierOrder = {"Iron","Steel","Masterwork","Legendary","Divine"}

Config.FarmingRecipes = {
	Wheat_Seed  = { growthSeconds = 600,  harvestOutput = { item = "wheat",  count = "2-4" } },
	Turnip_Seed = { growthSeconds = 480,  harvestOutput = { item = "turnip", count = "1-3" } },
	Herb_Seed   = { growthSeconds = 300,  harvestOutput = { item = "herb",   count = "1-2" } },
	Grape_Seed  = { growthSeconds = 1800, harvestOutput = { item = "grapes", count = "3-6" } },
}
Config.FarmingGrowthCheckInterval = 10

-- EMOTE WHEEL -- 3 pages of 4 slots. anim left as "" (placeholder convention, same as
-- PLACEHOLDER_SOUND elsewhere: empty/rbxassetid://0 = skip silently) until real clips are
-- authored. special=true marks the two progression emotes (meditate/pushups), which
-- EmoteManager routes to MeditationManager/PushupsManager instead of a plain one-shot anim.
Config.EmoteWheel = {
	Page1 = {
		{ id = "wave",  anim = "", special = false },
		{ id = "bow",   anim = "", special = false },
		{ id = "sit",   anim = "", special = false },
		{ id = "point", anim = "", special = false },
	},
	Page2 = {
		{ id = "meditate", anim = "", special = true },
		{ id = "pushups",  anim = "", special = true },
		{ id = "sleep",    anim = "", special = false },
		{ id = "prayer",   anim = "", special = false },
	},
	Page3 = {
		{ id = "laugh", anim = "", special = false },
		{ id = "cry",   anim = "", special = false },
		{ id = "shrug", anim = "", special = false },
		{ id = "clap",  anim = "", special = false },
	},
}

Config.Meditation = {
	EarlyStageDuration    = 180, -- 3 minutes
	EarlyStageQTEInterval = 30,
	DeepStageQTEInterval  = 60,
	QTETier               = "Tier2",
	Milestones            = {10, 25, 50},
}

Config.Pushups = {
	QTEInterval             = 20,
	QTETier                 = "Tier1",
	HungerDrainMultiplier   = 3,
	StaminaDrainPerCycle    = 5,
	Milestones              = {10, 25, 50},
}

-- SPIRITS -- ambient faction orbs, only visible to players with the AwakenedEyes talent.
Config.SpiritFactions = {
	Flame  = { color = Color3.fromRGB(255, 100, 40),  size = 1.5 },
	Wind   = { color = Color3.fromRGB(180, 220, 255), size = 1.5 },
	Water  = { color = Color3.fromRGB(60, 130, 200),  size = 1.5 },
	Earth  = { color = Color3.fromRGB(120, 90, 50),   size = 1.5 },
	Shadow = { color = Color3.fromRGB(50, 20, 60),    size = 1.5 },
	Blood  = { color = Color3.fromRGB(140, 20, 30),   size = 1.5 },
}

-- NPC / AI SYSTEM
Config.NPC = {
	DecisionInterval    = 0.2,
	SightCheckInterval  = 0.3,
	SightConeAngle      = 60,   -- degrees, half-angle each side of forward
	DefaultSightRange   = 40,
	DefaultLeashRange   = 60,
	DefaultMaxHealth    = 100,
	WalkSpeed           = 16,
	MeleeRange          = 6,    -- attack once within this distance
	ApproachTriggerDist = 6,    -- move toward target when farther than this
	LowHPThreshold      = 0.30,
	RetreatChance       = 0.40, -- chance per decision tick to retreat while low HP
	PlayerLedFollowDist = 10,
	ActionWeights       = { M1 = 0.60, M2 = 0.20, Parry = 0.15, Dash = 0.05 },
	M1Cooldown          = 0.6,
	M2Cooldown           = 2.5,
	DashCooldown        = 3,
	ParryWindow         = 20 / 60, -- matches Config.Parry.WindowTotal
	ParryPerfectWindow  = 10 / 60,
	ParryCooldown       = 1.0,
	ExecuteRange        = 5,
	RagdollDespawnDelay = 30,
	SpeechBubbleRange   = 30,
	IdlePhraseIntervalMin = 15,
	IdlePhraseIntervalMax = 40,
}

-- CUSTOM MOD BTOOLS
Config.BTools = {
	DefaultInteractableCooldown = 60,
	DefaultRespawnDelay         = 60,
}

-- LIGHT SOURCES
Config.LightSources = {
	Torch    = { range = 20, brightness = 2,   color = Color3.fromRGB(255, 178, 76),  frostClearRate = 1, hasFire = true,  fireSize = 5 },
	Campfire = { range = 30, brightness = 3,   color = Color3.fromRGB(255, 160, 60),  frostClearRate = 2, hasFire = true,  fireSize = 12 },
	Lantern  = { range = 16, brightness = 1.5, color = Color3.fromRGB(255, 210, 140), frostClearRate = 1, hasFire = false, fireSize = 0 },
	Brazier  = { range = 35, brightness = 3.5, color = Color3.fromRGB(255, 150, 50),  frostClearRate = 3, hasFire = true,  fireSize = 15 },
}
Config.LightSourceFrostCheckInterval = 2

-- INJURIES -- permanent conditions applied by lore team or specific items (dissection
-- knife, etc). Persist across respawn, reset on PDE wipe. See InjuryManager.
Config.Injuries = {
	LostArm = {
		name = "Lost Arm",
		effect = "Damage output reduced by 50%. M1/M2 have reduced range and visual is missing arm.",
		visual = "hide_right_arm", -- server sets Transparency 1 on the affected arm (side-aware)
		damageMult = 0.5,
		hitboxShrink = 0.7, -- M1/M2 hitbox size multiplier
	},
	Insanity = {
		name = "Insanity",
		effect = "Hallucinations: fake player figures appear briefly, other player faces flicker/vanish, chat text occasionally distorts.",
	},
	HalfBlind = {
		name = "Half Blind",
		effect = "Half the screen is blocked by darkness (left or right eye).",
	},
	FullBlind = {
		name = "Full Blindness",
		effect = "Entire vision is black. Only spatial awareness talents help.",
	},
	BadVision = {
		name = "Bad Vision",
		effect = "Peripheral blur increases gradually until healed.",
	},
	BrokenTissue = {
		name = "Broken Tissue",
		effect = "Damage output reduced by 25%. Movement speed reduced by 15%.",
		damageMult = 0.75,
		speedMult = 0.85,
	},
	ConcussedMind = {
		name = "Concussed",
		effect = "Stamina regen halved. Camera occasionally jerks slightly.",
		staminaRegenMult = 0.5,
	},
	DeafEar = {
		name = "Deaf Ear",
		effect = "3D positional sounds reduced in one direction.",
	},
}
-- Which injury types accept a Left/Right side param
Config.InjurySideTypes = { LostArm = true, HalfBlind = true, DeafEar = true }
-- Which injury types accept a 0-100 severity param
Config.InjurySeverityTypes = { Insanity = true, BadVision = true }

Config.BadVisionRamp = {
	InitialSeverity = 10,
	IncreasePerMinute = 2,
	MaxSeverity = 100,
}

Config.InsanityHallucinations = {
	FakePlayerFigure = {
		chance = 0.05, -- per-minute chance at severity 100 (scaled linearly by severity/100)
		description = "A shadowy figure of another player appears briefly in the distance, then vanishes.",
	},
	FaceVanish = {
		chance = 0.08,
		description = "Another player's face briefly vanishes (becomes blank) for 1 second.",
	},
	ChatDistortion = {
		chance = 0.10,
		description = "Chat text appears distorted for a moment.",
	},
}

-- DNA / LORE CLANS -- hidden bloodline attribute, mod-assigned only. See DNAManager.
-- buff shapes: {stat="Strength/Endurance/Agility/Perception", amount=N} (additive to the
-- named stat), {stat="M1Damage/M2Damage", multiplier=N} (multiplies final damage), or
-- {stat="ParryWindow", frames=N} (additive frames on the Perfect-parry sub-window).
Config.LoreClans = {
	Verkanos = {
		name = "House Verkanos",
		buffs = {
			{ stat = "Strength", amount = 3 },
			{ stat = "M1Damage", multiplier = 1.05 },
		},
		loreNotes = "An old warrior line. Their DNA carries strength.",
	},
	Aeliana = {
		name = "House Aeliana",
		buffs = {
			{ stat = "Agility", amount = 5 },
			{ stat = "StaminaMax", amount = 10 },
		},
		loreNotes = "A fast, elusive bloodline.",
	},
	Corvid = {
		name = "House Corvid",
		buffs = {
			{ stat = "ParryWindow", frames = 1 },
			{ stat = "Perception", amount = 10 },
		},
		loreNotes = "A cunning line. Their eyes see faster.",
	},
}

-- ================================================================================
-- CASTES -- the six hereditary castes of the Celtic Crun. Stored in characterData.DNA.Caste
-- alongside the existing Clan/Purity, so it persists across PDE wipes exactly like the rest
-- of DNA does (IdentityManager.resetForWipe never touches the DNA table). Caste is NOT shown
-- in the journal -- it is only learned by interacting with a Revealer NPC (see Config.Reveal).
-- Every buff's `baseAmount` is the value AT PURITY 100; CasteManager scales it down linearly
-- by the player's Purity (see Config.PurityScaling). See CasteManager.
-- ================================================================================
Config.Castes = {
	Celtae = {
		name = "Celtae",
		rank = 1, -- highest
		description = "The noblest and highest-crowned. The King is always Celtae.",
		buffs = {
			{ type = "FactionRepBonus", faction = "AllGaulish", baseAmount = 10 },
			{ type = "StartingCurrency", baseAmount = 250 }, -- Obol, granted once ever
		},
		loreFlag = "AssassinationTarget", -- lore team may flag them for plots
		loreNotes = "Nobility. A target on their back as much as a crown on their head.",
	},
	Aedui = {
		name = "Aedui",
		rank = 2,
		description = "Noble diplomats and inter-caste communicators. Once rich chieftains.",
		buffs = {
			{ type = "MerchantPriceReduction", baseAmount = 0.10 }, -- 10% cheaper at merchants
			{ type = "AllyBondSpeedup", baseAmount = 250 },        -- seconds off Config.Ally.RequiredProximitySeconds
			{ type = "FactionRepBonus", faction = "Greek", baseAmount = 15 },
		},
		loreNotes = "The tongue that speaks between castes and to outsiders.",
	},
	Aquitani = {
		name = "Aquitani",
		rank = 3,
		description = "Librarians and druids. Scholars and students, given leeway in the wars.",
		buffs = {
			{ type = "MeditationProgressBonus", baseAmount = 0.25 },
			{ type = "ReadingProgressBonus", baseAmount = 0.30 },
			{ type = "SanityResistance", baseAmount = 0.15 }, -- sanity RISES 15% slower
		},
		loreNotes = "The keepers of knowledge. Their minds are disciplined against the dark.",
	},
	Belgae = {
		name = "Belgae",
		rank = 2, -- warrior nobility, high status
		description = "The warrior caste. Fiercest and strongest. ~75% are warrior nobles.",
		buffs = {
			{ type = "DamageBonus", baseAmount = 0.08 },
			{ type = "MaxPostureBonus", baseAmount = 10 },
			{ type = "NonCombatProgressPenalty", baseAmount = 0.10 },
		},
		loreNotes = "Born for war. Ill-suited to the quiet work of scholars.",
	},
	Sequani = {
		name = "Sequani",
		rank = 5,
		description = "Fighters, but not fierce enough. Respected, but forced toward the bottom.",
		buffs = {
			{ type = "DamageBonus", baseAmount = 0.04 },
			{ type = "MaxStaminaBonus", baseAmount = 5 },
			{ type = "StaminaRegenBonus", baseAmount = 0.10 },
		},
		loreNotes = "Good enough to fight, never good enough to be honoured.",
	},
	Parisii = {
		name = "Parisii",
		rank = 6, -- lowest, but largest
		description = "The largest and least important caste. Most citizens are Parisii.",
		buffs = {
			{ type = "HungerThirstEfficiency", baseAmount = 0.20 }, -- drains 20% slower
			{ type = "MassaliaMovementBonus", baseAmount = 0.10 },
		},
		loreNotes = "The many. The overlooked. A blank slate on which any story is written.",
	},
}

-- Purity (0-100) scales every caste buff linearly: effective = baseAmount * (Purity/100).
-- MinimumFloors raises that multiplier's floor for buff types that should still do something
-- (or apply in full) on a diluted bloodline -- you are born noble or you are not, so the
-- Celtae birth purse is flat at 1.0 regardless of purity.
Config.PurityScaling = {
	Enabled = true,
	MinimumFloors = {
		StartingCurrency = 1.0,
		FactionRepBonus  = 0.5,
		-- everything else scales fully from 0
	},
}

-- Which Gaulish reputation tracks "AllGaulish" fans out to (Config.Reputation keys as used by
-- DataManager's Reputation table).
Config.CasteFactionGroups = {
	AllGaulish = { "Gauls" },
	Greek      = { "Greeks" },
}

-- ================================================================================
-- NPC STAT REVELATION -- any NPC can be flagged IsRevealer via the mod panel, turning it into
-- a service players seek out in the world (you cannot freely read your own caste). See
-- RevealManager.
-- ================================================================================
Config.Reveal = {
	Types = { "Caste", "Purity", "Clan", "Stats", "FullDNA", "Sanity", "Everything" },
	PromptRange = 10,
	PromptLabel = "Speak",
	RevealSound = "rbxassetid://0", -- PLACEHOLDER_SOUND: reveal_chime
	-- Which KnownAboutSelf flags each RevealType sets.
	Grants = {
		Caste      = { "Caste" },
		Purity     = { "Purity" },
		Clan       = { "Clan" },
		Stats      = { "Stats" },
		FullDNA    = { "Caste", "Purity", "Clan" },
		Sanity     = { "Sanity" },
		Everything = { "Caste", "Purity", "Clan", "Stats", "Sanity" },
	},
}

-- ================================================================================
-- THE KING -- a TITLE, not a caste (stored in characterData.Titles). Always held by a Celtae.
-- ================================================================================
Config.KingTitle = {
	RequiresCaste = "Celtae",
	OnlyOneKing   = true,
	Perks = {
		{ type = "FactionRepBonus", faction = "AllGaulish", amount = 30 },
		{ type = "CurrencyIncomeBonus", amount = 0.15 },
		{ type = "CommandAuthority", value = true },
		{ type = "CrownVisual", value = true },
	},
	CrownAssetId    = 0,             -- PLACEHOLDER_ASSET: CrownModel (worn above the King's head)
	CoronationSound = "rbxassetid://0", -- PLACEHOLDER_SOUND: coronation_horn
	DecreeCooldown  = 300,           -- /decree rate limit, seconds
}

-- Titles the mod panel can grant. King is validated against Config.KingTitle.RequiresCaste.
Config.GrantableTitles = { "King", "Chieftain", "Druid", "Champion", "Outcast" }

-- RITUALS
Config.Ritual = {
	CircleRadius = 10,
	PlaceItemRange = 5,
	AutoDespawnMinutes = 30,
	OwnerDisconnectGraceMinutes = 5,
}

-- POTIONS / HEALING
Config.Potions = {
	MinorHealthPotion = {
		name = "Minor Health Draught", healAmount = 30, healOverTime = false,
		stackable = true, maxStack = 5, useTime = 2,
		useAnimation = "rbxassetid://0", useSound = "rbxassetid://0", -- PLACEHOLDER_ANIMATION / PLACEHOLDER_SOUND: potion_use / potion_drink
		effects = {"heal_hp"},
	},
	MajorHealthPotion = {
		name = "Major Health Draught", healAmount = 75, healOverTime = false,
		stackable = true, maxStack = 3, useTime = 2.5,
		useAnimation = "rbxassetid://0", useSound = "rbxassetid://0",
		effects = {"heal_hp"},
	},
	StaminaPotion = {
		name = "Vigour Elixir", healAmount = 50,
		stackable = true, maxStack = 5, useTime = 1.5,
		useAnimation = "rbxassetid://0", useSound = "rbxassetid://0",
		effects = {"restore_stamina"},
	},
	Bandage = {
		name = "Linen Bandage",
		stackable = true, maxStack = 10, useTime = 3,
		useAnimation = "rbxassetid://0", useSound = "rbxassetid://0",
		effects = {"clear_bleed", "reduce_bloodbar_50"},
	},
	HealingSalve = {
		name = "Herbal Salve", healAmount = 20, healOverTime = true, overTimeDuration = 10,
		stackable = true, maxStack = 3, useTime = 2,
		useAnimation = "rbxassetid://0", useSound = "rbxassetid://0",
		effects = {"heal_hp_over_time"},
	},
	ClarityElixir = {
		name = "Elixir of Clarity",
		stackable = false, useTime = 5,
		useAnimation = "rbxassetid://0", useSound = "rbxassetid://0",
		effects = {"clear_insanity"},
	},
	RestorationDraught = {
		name = "Restoration Draught",
		stackable = false, useTime = 8,
		useAnimation = "rbxassetid://0", useSound = "rbxassetid://0",
		effects = {"clear_all_injuries"},
	},
	CalmingTea = {
		name = "Calming Tea", stackable = true, maxStack = 5, useTime = 3,
		useAnimation = "rbxassetid://0", useSound = "rbxassetid://0",
		effects = {"reduce_sanity_tea"},
	},
}

-- Effect functions keyed by the strings potions list in their `effects` table. Server-only
-- (reference _G managers) -- never invoked from a client context, even though Config itself
-- is a shared module required by both sides.
Config.PotionEffects = {
	heal_hp = function(player, potion)
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum then hum.Health = math.min(hum.Health + potion.healAmount, hum.MaxHealth) end
	end,
	heal_hp_over_time = function(player, potion)
		local ticks = potion.overTimeDuration
		local perTick = potion.healAmount / ticks
		for i = 1, ticks do
			task.delay(i, function()
				local char = player.Character
				local hum = char and char:FindFirstChildOfClass("Humanoid")
				if hum then hum.Health = math.min(hum.Health + perTick, hum.MaxHealth) end
			end)
		end
	end,
	restore_stamina = function(player, potion)
		local sm = _G.StaminaManager
		if sm then sm.refund(player, potion.healAmount) end
	end,
	clear_bleed = function(player, potion)
		local bm = _G.BleedManager
		if bm then bm.ClearBleeds(player) end
	end,
	reduce_bloodbar_50 = function(player, potion)
		local bm = _G.BleedManager
		if bm then bm.ReduceBloodBar(player, 50) end
	end,
	clear_insanity = function(player, potion)
		local im = _G.InjuryManager
		if im then im.removeInjury(player, "Insanity") end
	end,
	clear_all_injuries = function(player, potion)
		local im = _G.InjuryManager
		if im then im.clearAllInjuries(player) end
	end,
	reduce_sanity_tea = function(player, potion)
		local sm = _G.SanityManager
		if sm then sm.adjustSanity(player, -Config.SanityRecovery.DrinkCalmingTea, "DrinkCalmingTea") end
	end,
}

-- SANITY -- hidden per-player meter (0 healthy .. 100 broken). See SanityManager.
-- Never shown in HUD/journal by default; only lore team (mod panel) or a rare talent
-- (BloodInsight/AwakenedEyes) can reveal it.
Config.Sanity = {
	WitnessDeath           = 10, -- see any player die within WitnessRadius
	WitnessGripDeath       = 15, -- see a grip/execution kill within WitnessRadius
	KillPlayer             = 20, -- personally kill another player
	KillAlly               = 60, -- personally kill someone you're allied with
	WitnessAllyDeath       = 40, -- see an ally die within AllyWitnessRadius (fires AFTER the rage bypass)
	LoseArm                = 25, -- LostArm injury applied
	LoseEye                = 15, -- HalfBlind injury applied
	GoFullBlind            = 30, -- FullBlind injury applied
	NearRitualFailure      = 10, -- within RitualFailureRadius when a ritual fails
	SpiritHostileEncounter = 5,  -- Rep < -50 spirit nearby for 30s

	WitnessRadius        = 30,
	AllyWitnessRadius     = 60,
	RitualFailureRadius  = 20,
	WitnessCheckInterval = 0.5,

	-- Hallucination tier thresholds (enter at value, exit at value-Hysteresis)
	ScratchThreshold           = 50,
	FaceScribbleThreshold      = 60,
	ShadowFiguresThreshold     = 70,
	ShadowFiguresStunThreshold = 80,
	CliffPullThreshold         = 90,
	Hysteresis                 = 5,

	RageEligibilityThreshold = 90, -- must be 90+ to enter rage (raised from 80 -- rage should be rare)
}

Config.SanityRecovery = {
	-- No passive/automatic recovery — sanity only ever decreases through these explicit actions
	Sleep         = 5, -- per real minute of sleeping emote
	Meditate      = 3, -- per real minute, early stage
	MeditateDeep  = 8, -- per real minute, deep meditation
	DrinkCalmingTea = 15, -- one-shot, CalmingTea potion
	NearAlly      = 0.5, -- per real minute within Config.Ally.NearAllyRange of an introduced/allied companion
	LoreTeamAction = 0, -- variable — lore team sets any value via mod panel
}

-- RAGE MODE -- berserker state entered at HPThreshold+SanityThreshold, or bypassed entirely
-- on ally death (see Config.Ally). See RageManager.
Config.Rage = {
	HPThreshold     = 0.10, -- must be at/below this HP fraction (tightened from 0.15 -- harder to proc)
	SanityThreshold = 90,   -- must have sanity 90+ (bypassed on ally death); real gate is Config.Sanity.RageEligibilityThreshold
	CheckInterval   = 0.5,

	Duration                 = 90,
	DamageBoost              = 1.45, -- +45% damage
	StaggerImmune            = true,
	KnockbackImmuneDuration  = 30,   -- no knockback for the first 30s of rage

	ExhaustionDuration          = 120,
	ExhaustionDamagePenalty     = 0.80, -- -20% damage
	ExhaustionRegenMultiplier   = 0.5,  -- 50% slower stamina/HP regen
	ExhaustionSpeedMultiplier   = 0.85, -- -15% movement speed

	LoreDebuffRequired = true, -- lore team must assign an exit debuff via mod panel before/at exit
}

-- FEELINGS -- short-lived emotional states with visual/audio effects. See FeelingsManager.
Config.Feelings = {
	Anxiety = {
		duration = 5,
		screenFlash = { color = Color3.fromRGB(180, 20, 20), interval = 0.5 },
		screenShake = { intensity = 0.3, frequency = 8 },
		sound = "PLACEHOLDER_SOUND: feeling_anxiety_heartbeat",
	},
	Fear = {
		duration = 5,
		screenFlash = { color = Color3.fromRGB(30, 30, 50), interval = 0.8 },
		peripheralDarken = true,
		sound = "PLACEHOLDER_SOUND: feeling_fear_breath",
	},
	Rage = {
		-- Short spike of anger — distinct from Rage MODE (Config.Rage), does not conflict with it
		duration = 5,
		screenFlash = { color = Color3.fromRGB(200, 20, 20), interval = 0.3 },
		screenShake = { intensity = 0.5, frequency = 10 },
		sound = "PLACEHOLDER_SOUND: feeling_rage_pulse",
	},
	Paranoia = {
		duration = 8,
		cameraSubtleTurns = true,
		soundOccasional = "PLACEHOLDER_SOUND: feeling_paranoia_whisper",
	},
	Soothing = {
		duration = 10,
		peripheralGlow = { color = Color3.fromRGB(255, 240, 200), intensity = 0.2 },
		sound = "PLACEHOLDER_SOUND: feeling_soothing_hum",
		sanityDrain = 2,
	},
	FadeIn  = 0.3,
	FadeOut = 0.5,
}

Config.FeelingTriggers = {
	OnWitnessDeath        = "Anxiety",
	OnWitnessGripDeath    = "Fear",
	OnKillWithNoTalent    = "Anxiety", -- if attacker lacks ColdBlood
	OnAllyDeath           = "Rage",    -- fires just before rage MODE triggers
	OnShadowFigureAttack  = "Paranoia",
	OnCliffPullActive     = "Fear",
	OnNearAlly            = "Soothing",
}

-- MOB REGISTRY -- the curated list the mod panel's "Spawn Mob" dropdown offers.
-- `template` is the literal Model name ModManager.spawnMob clones out of Workspace/ReplicatedStorage.
-- `manager` (optional) routes the spawn through a real AI manager instead of a bare clone --
-- without it you get a dumb statue with no behaviour, which is what spawnMob did for everything.
-- Only rigs verified live to have a Humanoid + HumanoidRootPart are listed here.
Config.Mobs = {
	{ name = "Shroom",       template = "SporeGooberChild", manager = "ShroomManager", note = "4-legged spore mob, full AI" },
	{ name = "Lesser Wolf",  template = "LesserWolf",       manager = "WolfManager",   note = "quadruped predator, full AI" },
	{ name = "Skinwalker",   template = "SkinWalker",       note = "tall, 15 parts" },
	{ name = "Wendigo",      template = "Wendigo",          note = "57 parts" },
	{ name = "Werewolf",     template = "FixWereWolf",      note = "35 parts" },
	{ name = "Tree Goober",  template = "TreeGoober",       note = "~65 studs tall -- boss scale" },
	{ name = "Combat Dummy", template = "CombatDummy",      note = "passive test target" },
}

-- SHROOM MOB ("SporeGooberChild" rig) -- see ShroomManager.
-- Rig facts confirmed live 2026-07-21: the rig is workspace.SporeGooberChild, a 4-legged
-- (UpperLeg1-4 / LowerLeg1-4) Torso+Head+Teeth model. It DOES have a Humanoid with an
-- Animator (the spec assumed a non-Humanoid AnimationController rig -- it isn't one), so
-- movement uses Humanoid:MoveTo + PathfindingService and animations load off Humanoid.Animator.
-- Workspace also holds two similar "SporeGoober" models (one same-scale, one ~33% larger).
-- Those are NOT the mob -- owner confirmed SporeGooberChild is the one to use.
Config.ShroomMob = {
	ModelName   = "SporeGooberChild", -- real rig name in Workspace; "Shroom" is the display name
	DisplayName = "Shroom",
	WalkSpeed   = 8,
	ChaseSpeed  = 12,
	SightRange  = 40,
	SightAngle  = 120, -- degrees, full cone width
	LoseInterestRange = 80,
	AttackRange = 7,
	LeashRange  = 100,
	Health      = 120,
	AttackDamage = 18,
	PostureDamage = 15,
	-- MEASURED on a CLONE, not read off the placed model: a spawned clone rests in bind pose
	-- with its legs fully extended, giving a root-to-sole distance of 5.44 -- the model sitting
	-- in Workspace is posed with bent legs and reads 4.80, which is NOT the spawn geometry.
	-- R6 HipHeight is exactly that root-to-sole distance; verified that at 5.44 the feet land
	-- at Y=+0.00 on a ground plane. The rig ships with HipHeight = 0, which would plant the
	-- ROOT on the ground and bury all four legs.
	HipHeight   = 5.44,
	ScanInterval    = 0.4,
	RepathInterval  = 0.5,
	AlertPause      = 0.6,
	-- Roaming (2026-07-22 user request: "make the shroom roam around"). It now wanders almost
	-- constantly instead of standing idle -- high PatrolChance + short RoamWait so that after
	-- reaching a wander point it picks a new one within a couple seconds rather than 3-6s.
	PatrolRadius    = 28,
	PatrolChance    = 0.9,
	RoamWaitMin     = 1.5,
	RoamWaitMax     = 3.5,
	FleeHealthPct   = 0.20,
	FleeChance      = 0.40,
	DespawnAfter    = 8,
	FadeOutDuration = 4,   -- on death it slowly fades out of existence over this many seconds (no ragdoll)
	-- Getting hit by the Shroom: a short stun, a sideways shove along the swing arc, and the
	-- real M1GotHit reaction animation -- the same three things a player hit does, so mob hits
	-- carry the same weight. Hitstun is deliberately shorter than a player M1's 0.3s baseline
	-- feel would suggest being stacked with knockback -- it staggers, it does not lock you down.
	HitstunDuration  = 0.35,
	KnockbackForce   = 32, -- backward, vs Config.Combat.KnockbackForce 40 for a player M1
	KnockbackLateral = 26, -- sideways component along the swing direction
	ParryStunDuration = 1.5,
	ParryBonusDamageMult = 1.25, -- +25% while stunned
	-- ADVANCED COMBAT (2026-07-22): same depth pass the Wolf got, tuned SLOWER/lurkier -- the
	-- Shroom stalks in a tight arc, hops in to bite, feints, and occasionally FLURRIES two swings.
	-- No block/parry (it has no such clips -- those stay the Wolf's specialty); the Shroom is the
	-- relentless circling swarmer instead of an agile duelist.
	TargetReassessInterval = 2.0,  -- re-pick the best target this often (distance + recent-damage threat)
	ThreatWeight     = 0.6,
	TargetStickiness = 7,
	ThreatDecay      = 7,
	EngageRange      = 20,   -- within this it orbits/commits; beyond, shambles straight in
	StrafeRadius     = 11,   -- tight orbit radius (AttackRange 7 + 4)
	StrafeAngle      = 26,   -- slower circling than the Wolf's 34deg
	StrafeInterval   = 2.0,
	CircleMin        = 1.0,  -- lurks/stalks this long...
	CircleMax        = 2.6,  -- ...to this, then commits
	LungeRange       = 14,   -- medium gap at which it may HOP in
	LungeChance      = 0.4,
	LungeCooldown    = 5.5,
	LungeWindup      = 0.30,
	LungeActive      = 0.35,
	LungeRecovery    = 0.70,
	LungeSpeed       = 42,   -- slower pounce than the Wolf (62)
	FeintChance      = 0.20, -- fake a swing to bait a parry/dodge
	FeintCooldown    = 4.5,
	ComboChance      = 0.35, -- after a swing, sometimes IMMEDIATELY chain another (a flurry)
	Anims = {
		Walk  = "rbxassetid://125376616694125", -- verified 1.95s
		Swing = "rbxassetid://94284574431844",  -- verified 0.65s
		Left  = "rbxassetid://126627454959985", -- verified 0.65s
	},
	-- Attack phases. Windup+Active MUST fit inside the clip length or the hitbox goes live
	-- after the animation has already finished: the spec's Swing timing (0.5+0.2=0.70s)
	-- overran its 0.65s clip, so Swing is retimed to 0.45+0.20. Left (0.40+0.25) already fit.
	Attacks = {
		-- lateralSign: which way along the mob's RightVector the swing throws you.
		-- Swing is a wide right-to-left arc (+1); Left sweeps to the mob's left (-1).
		-- bleed: claws tear, so a landed hit can open a bleed via BleedManager (tiers from
		-- Config.Bleed.Tiers). Light tier only -- the Shroom should chip the blood bar over a
		-- drawn-out fight, not burst it in two hits the way a dagger crit does.
		Swing = { anim="Swing", windup=0.45, active=0.20, recovery=0.80, damageMult=1.0, range=7, lateralSign=1,
		          bleedTier="Light", bleedChance=0.60 },
		Left  = { anim="Left",  windup=0.40, active=0.25, recovery=0.70, damageMult=0.9, range=7, lateralSign=-1,
		          bleedTier="Light", bleedChance=0.45 },
		-- Lunge: the hop-in gap-closer's bite (the hop itself is driven by ShroomManager.doLunge).
		Lunge = { anim="Swing", windup=0.30, active=0.35, recovery=0.70, damageMult=1.2, range=8, lateralSign=1,
		          bleedTier="Light", bleedChance=0.55 },
	},
}

Config.ShroomLoot = {
	{ item = "shroom_cap",        weight = 60, min = 1, max = 2 },
	{ item = "spore_dust",        weight = 30, min = 1, max = 3 },
	{ item = "rare_bloodshroom",  weight = 10, min = 1, max = 1 },
}

-- LESSER WOLF ("LesserWolf" rig) -- see WolfManager. A quadruped predator: faster and hits
-- harder than the Shroom, with a two-bite mixup plus a slow, heavily-telegraphed lunge.
-- Rig facts confirmed live 2026-07-22: RigType R6 custom quadruped, 24 parts / 20 Motor6Ds
-- (four Thigh/Leg/Foot legs, tail, jaw), HAS a Humanoid + Animator so movement is
-- Humanoid:MoveTo + PathfindingService and anims load off Humanoid.Animator (same pattern as
-- the Shroom). HipHeight MEASURED on a fresh clone in bind pose = 3.67 (root-centre-to-sole);
-- the placed model ships with HipHeight 2.6, which would sink the feet ~1 stud into the floor.
--
-- ANIMATIONS: the LesserWolf's clips exist only as UNPUBLISHED KeyframeSequences in
-- ServerStorage.RBX_ANIMSAVES.LesserWolf (heavy attack / walk / jump / howl / idle / run /
-- true blocking / bite left / bite right / parry). Roblox has no scriptable animation-upload,
-- so each must be published in the Animation Editor to get an asset id. Until then every slot
-- below is rbxassetid://0 and WolfManager's loadAnims placeholder-SKIPS it (no failed-load
-- spam, the mob just doesn't animate that action). Publish a clip -> paste its id here.
Config.WolfMob = {
	ModelName   = "LesserWolf",
	DisplayName = "Lesser Wolf",
	WalkSpeed   = 10,
	ChaseSpeed  = 21,   -- a wolf runs you down; much faster than the Shroom's 12
	SightRange  = 55,
	SightAngle  = 140,
	LoseInterestRange = 110,
	AttackRange = 9,
	LeashRange  = 140,
	Health      = 160,
	AttackDamage = 22,
	PostureDamage = 18,
	HipHeight   = 3.67, -- MEASURED on a clone in bind pose (root-centre-to-sole); see note above
	ScanInterval    = 0.35,
	RepathInterval  = 0.4,
	AlertPause      = 0.8,  -- the howl telegraph before it commits to the chase
	-- Roaming: wolves prowl. Same near-continuous wander the Shroom got 2026-07-22.
	PatrolRadius    = 34,
	PatrolChance    = 0.9,
	RoamWaitMin     = 1.5,
	RoamWaitMax     = 3.0,
	FleeHealthPct   = 0.15, -- less skittish than the Shroom (0.20)
	FleeChance      = 0.25,
	DespawnAfter    = 8,
	FadeOutDuration = 4,   -- on death it slowly fades out of existence over this many seconds (no ragdoll)
	HitstunDuration  = 0.4,
	KnockbackForce   = 40,  -- a full-weight lunge, harder than the Shroom's 32
	KnockbackLateral = 20,
	ParryStunDuration = 1.6,
	ParryBonusDamageMult = 1.3,
	-- The wolf can defend itself: it READS incoming player M1s. When an M1 is swung its way (the
	-- attacker is in front + in range) it SOMETIMES parries during the swing's startup telegraph,
	-- negating that one hit + landing a brief counter-stun. It is NOT a flat per-hit dice roll --
	-- it only ever parries an attack it actually read, and a cooldown keeps it occasional/not busted.
	-- It also howls at random while idle (atmosphere), and being hit pulls it into the fight.
	ParryChance      = 0.35,  -- chance to parry a READ M1 (raised from 0.20 -- it barely landed before)
	ParryCooldown    = 2.5,   -- min seconds between parries (the anti-busted governor; was 3.5)
	ParryReadRange   = 13,    -- attacker must be within this range for the wolf to read the M1 (was 11)
	ParryReadWindow  = 0.8,   -- seconds the parry stays armed after a read (was 0.65; covers ~0.53s M1 startup + slack)
	ParryCounterStun = 0.4,   -- brief hitstun on the attacker when the parry lands
	-- BLOCK: brief defensive MOMENTS where it raises a guard instead of attacking -- soaks most of
	-- an incoming hit and gives it a window to catch a parry, so it isn't a pure relentless attacker.
	BlockChance          = 0.30, -- chance, when in range, to block instead of committing an attack
	BlockDuration        = 1.2,  -- seconds it holds the block
	BlockCooldown        = 4.0,  -- min seconds between blocks (so it never just turtles)
	BlockDamageReduction = 0.70, -- fraction of an incoming hit negated while blocking
	-- ADVANCED COMBAT (2026-07-22): the wolf swaps targets, orbits then commits, lunges to close
	-- gaps and feints to bait -- so a fight has rhythm instead of a straight-line bite spam.
	TargetReassessInterval = 2.0,  -- re-pick the best target this often (closer + higher-threat)
	ThreatWeight     = 0.6,   -- how strongly recent damage-to-the-wolf pulls its target choice
	TargetStickiness = 7,     -- score bonus for the CURRENT target so it doesn't flip-flop every check
	ThreatDecay      = 7,     -- threat points a player sheds per second when not hitting the wolf
	EngageRange      = 24,    -- within this it orbits/commits; beyond, it just sprints straight in
	StrafeRadius     = 14,    -- orbit radius around the target (sits just outside AttackRange 9)
	StrafeAngle      = 34,    -- degrees it swings around the target each approach tick (the circling)
	StrafeInterval   = 1.6,   -- flips which way it circles this often
	CircleMin        = 0.9,   -- orbit (stalk) for this long...
	CircleMax        = 2.2,   -- ...to this long, then COMMIT: dart in to attack
	LungeRange       = 17,    -- medium gap at which it may POUNCE to close distance
	LungeChance      = 0.5,   -- per eligible approach
	LungeCooldown    = 4.5,
	LungeWindup      = 0.22,
	LungeActive      = 0.35,
	LungeRecovery    = 0.55,
	LungeSpeed       = 62,    -- pounce launch velocity
	FeintChance      = 0.22,  -- fake a bite to bait a parry/dodge instead of committing
	FeintCooldown    = 4.0,
	SpaceAfterAttackChance = 0.45, -- after an attack, sometimes disengage & reset spacing
	AmbientHowlMin   = 10,    -- random idle howl every 10..22s (suppressed once it has a target)
	AmbientHowlMax   = 22,
	Anims = {
		-- Published by owner 2026-07-22 from ServerStorage.RBX_ANIMSAVES.LesserWolf.
		Idle      = "rbxassetid://111126078286526",
		Walk      = "rbxassetid://136607198922315",
		Run       = "rbxassetid://99173183979083",
		Jump      = "rbxassetid://138242319089426",
		Howl      = "rbxassetid://77137175431049",  -- alert telegraph
		Block     = "rbxassetid://119537775708166",
		Parry     = "rbxassetid://115307898632675",
		BiteLeft  = "rbxassetid://118574968596715",
		BiteRight = "rbxassetid://99018697212309",
		Heavy     = "rbxassetid://103134883583325",
	},
	-- Three attacks. Bites are the fast mixup (thrown opposite ways via lateralSign so a player
	-- who always dodges one way eats the other); Heavy is the slow, readable, high-reward lunge.
	-- windup+active MUST fit the clip length once published -- retime if a clip is shorter.
	Attacks = {
		BiteLeft  = { anim="BiteLeft",  windup=0.35, active=0.18, recovery=0.60, damageMult=1.0, range=9, lateralSign=-1,
		              bleedTier="Medium", bleedChance=0.55, weight=40 },
		BiteRight = { anim="BiteRight", windup=0.35, active=0.18, recovery=0.60, damageMult=1.0, range=9, lateralSign=1,
		              bleedTier="Medium", bleedChance=0.55, weight=40 },
		-- Heavy is the RED / unparryable lunge: a red pulsing tell warns you, and it CANNOT be
		-- parried OR blocked -- the only escape is a dodge (dash iframes). Big reward for reading it.
		Heavy     = { anim="Heavy",     windup=0.85, active=0.25, recovery=1.10, damageMult=1.8, range=11, lateralSign=1,
		              bleedTier="Heavy",  bleedChance=0.75, weight=20, heavy=true, unparryable=true, unblockable=true },
		-- Lunge: the pounce gap-closer's bite (the leap itself is driven by WolfManager.doLunge; this
		-- is just the hit it lands on arrival). Uses the BiteRight clip for the snap.
		Lunge     = { anim="BiteRight", windup=0.22, active=0.35, recovery=0.55, damageMult=1.3, range=10, lateralSign=1,
		              bleedTier="Medium", bleedChance=0.55 },
	},
}

Config.WolfLoot = {
	{ item = "wolf_pelt",   weight = 55, min = 1, max = 1 },
	{ item = "wolf_fang",   weight = 30, min = 1, max = 2 },
	{ item = "raw_meat",    weight = 40, min = 1, max = 3 },
	{ item = "alpha_heart", weight = 8,  min = 1, max = 1 },
}

-- ALLY SYSTEM -- see AllyManager.
Config.Ally = {
	RequiredProximitySeconds = 1000, -- ~16.5 min within ProximityRange, post-mutual-introduction
	ProximityRange           = 30,
	NearAllyRange            = 20, -- passive sanity-drain / Soothing radius
	CheckInterval            = 1,
	KillAllySanityGain       = 60,
}

-- LIGHTING MOOD -- the genuinely-static properties WeatherClient never touches (verified by
-- grep before adding these -- it only ever writes Ambient/OutdoorAmbient/Brightness/Fog/
-- Atmosphere*/ColorCorrection's Brightness/Contrast/Saturation/TintColor, all of which live in
-- Config.WeatherProfiles.Clear instead, see the comment there). Applied once by LightingManager
-- on server start; safe to coexist with WeatherClient since there's no overlap.
Config.LightingMood = {
	ColorShift_Top    = Color3.fromRGB(180, 160, 130), -- warm sun tone
	ColorShift_Bottom = Color3.fromRGB(60, 55, 50),    -- dark cool shadow
	EnvironmentDiffuseScale  = 0.4,
	EnvironmentSpecularScale = 0.3,
	ExposureCompensation     = -0.3,
	GlobalShadows = true,
}

Config.BloomMood = {
	Intensity = 0.5,
	Size      = 20,
	Threshold = 0.9, -- lower than the map's authored default (2) so warm highlights actually catch bloom
}

-- WEAPON SCALING (design doc PART FOUR/4D) -- every attack in this codebase actually
-- scales off Strength only (CombatManager's damage calc uses getStat(attacker,"Strength")
-- uniformly for M1/M2/crits/sweep, confirmed by reading every damage= line before adding
-- this rather than inventing a fake per-weapon split that doesn't reflect real behavior).
-- Keyed by Enums.WeaponType; EquippedWeapon strings that don't match one of these keys
-- (custom/lore item names) still scale with Strength like everything else -- the mod panel
-- falls back to that same answer rather than showing "Unknown".
Config.Weapons = {
	Longsword = { name = "Longsword", scalesWith = "Strength" },
	Spear     = { name = "Spear",     scalesWith = "Strength" },
	Axe       = { name = "Axe",       scalesWith = "Strength" },
	Dagger    = { name = "Dagger",    scalesWith = "Strength" },
	Fists     = { name = "Fists",     scalesWith = "Strength" },
}

Config.SunRaysMood = {
	Intensity = 0.15, -- map's authored default (0.01) reads as functionally invisible, see [[project_abyss_lighting_findings]]
	Spread    = 0.3,
}

-- Small shared utilities reused across Interactable/Mining/Smelting/Farming (all need
-- "roll a random count from a 'N' or 'N-M' string" and "weighted-random pick a pool entry")
-- rather than each system reimplementing the same ~5 lines.
Config.Util = {}
function Config.Util.rollRange(rangeStr)
	local lo, hi = tostring(rangeStr):match("^(%d+)%-(%d+)$")
	if lo then return math.random(tonumber(lo), tonumber(hi)) end
	return tonumber(rangeStr) or 1
end
function Config.Util.weightedPick(pool)
	local total = 0
	for _, e in ipairs(pool) do total += e.weight end
	local r = math.random(1, total)
	local c = 0
	for _, e in ipairs(pool) do
		c += e.weight
		if r <= c then return e end
	end
	return pool[#pool]
end

-- SHADOW BOXING (design doc PART ONE) -- client-side practice sparring. See ShadowBoxManager/ShadowBoxClient.
Config.ShadowBoxing = {
	HP = 100,
	Damage = 5,  -- reduced damage the shadow deals back to the player (cosmetic/local only)
	AttackFrequency = 0.5, -- seconds between the shadow AI's decision ticks
	ParryChance = 0.15,
	MoveSpeed = 12,
	MinIdleSeconds = 1,  -- must be stationary this long before /shadowbox can trigger
	SpawnDistance = 6,
	PlayerHitDamage = 20,   -- flat "full damage" per landed player swing (100 HP / 5 hits)
	PlayerHitCooldown = 0.4, -- roughly matches the real M1 swing rate so clicking can't be spammed
	HitRange = 7,
	DefaultHitsToDefeat = 5, -- mod-overridable per player via ModManager.setShadowBoxHits (Player Attribute ShadowBoxMaxHits)
}

-- BOATS (design doc PART TWO). See BoatManager.
Config.Boat = {
	DefaultHullHP = 500,
	DefaultAmmo = 20,
	SpeedCap = 50,       -- studs/sec forward
	TurnRate = 15,        -- degrees/sec
	Acceleration = 5,     -- studs/sec^2
	CannonDamage = 50,
	CannonCooldown = 3,
	CannonballSpeed = 120,
	CannonballLifetime = 5,
	SinkDuration = 15,
	DeckFollowUpdateRate = 0.033, -- ~30Hz; confirmed live that anchored-CFrame motion alone doesn't carry a standing character horizontally, so this drives the real client-side compensation (BoatDeckClient) -- needs to be frequent enough to not read as teleport-y snapping
	WindAlignBonus = 0.2, -- +/-20% speed sailing with/against wind
}

-- Wind DIRECTION is already server-authoritative in WeatherManager (windAngle/getWindDirection,
-- continuously drifting) -- BoatManager reads that directly rather than inventing a second wind
-- system. This table only adds wind STRENGTH (studs/sec), keyed by the real
-- Config.WeatherProfiles names (confirmed live: Clear/Sunny/Cloudy/Foggy/Rain/HeavyRain/
-- Thunderstorm/Snow/Hail/Sandstorm/BloodRain/RedMist/RedSky, plus the pre-existing Fog/Storm/
-- Earthquake aliases) -- BoatManager falls back to Speed.Clear for anything not listed here.
Config.Wind = {
	Speed = {
		Clear = 5, Sunny = 4, Cloudy = 8, Foggy = 6, Fog = 6,
		Rain = 15, HeavyRain = 20, Thunderstorm = 25, Storm = 25,
		Snow = 10, Hail = 18, Sandstorm = 22, BloodRain = 15, RedMist = 12, RedSky = 12, Earthquake = 8,
	},
}

-- Ocean wave visuals reuse Terrain's own native WaterWave* animation -- Roblox Terrain
-- water animates its waves internally with zero per-frame scripting required, so "moving
-- water" just means keeping these two properties set correctly, never spawning wave parts.
-- Keyed the same way as Config.Wind.Speed above; BoatManager/OceanManager fall back to
-- OceanWaves.Clear for any weather name not explicitly listed.
Config.OceanWaves = {
	Clear = { WaterWaveSize = 0.15, WaterWaveSpeed = 5 },
	Sunny = { WaterWaveSize = 0.12, WaterWaveSpeed = 4 },
	Cloudy = { WaterWaveSize = 0.2, WaterWaveSpeed = 7 },
	Foggy = { WaterWaveSize = 0.15, WaterWaveSpeed = 5 }, Fog = { WaterWaveSize = 0.15, WaterWaveSpeed = 5 },
	Rain = { WaterWaveSize = 0.3, WaterWaveSpeed = 10 },
	HeavyRain = { WaterWaveSize = 0.4, WaterWaveSpeed = 13 },
	Thunderstorm = { WaterWaveSize = 0.5, WaterWaveSpeed = 15 }, Storm = { WaterWaveSize = 0.5, WaterWaveSpeed = 15 },
	Snow = { WaterWaveSize = 0.2, WaterWaveSpeed = 6 },
	Hail = { WaterWaveSize = 0.35, WaterWaveSpeed = 12 },
	Sandstorm = { WaterWaveSize = 0.3, WaterWaveSpeed = 11 },
	BloodRain = { WaterWaveSize = 0.35, WaterWaveSpeed = 12 },
	RedMist = { WaterWaveSize = 0.25, WaterWaveSpeed = 9 },
	RedSky = { WaterWaveSize = 0.25, WaterWaveSpeed = 9 },
	Earthquake = { WaterWaveSize = 0.45, WaterWaveSpeed = 14 },
}

-- TRADING / DROPPING (design doc PART THREE). See TradeManager.
Config.CoinPouch = {
	Item = "Coin_Pouch",
	Cost = 50, -- Obol, purchase from a merchant NPC or mod-granted
	MaxCoinsInside = 10000,
}
Config.ItemDrop = {
	DespawnAfter = 300, -- 5 min
}

-- INTOXICATION (design doc PART FOUR) -- Wine/Ale side effect. See EdibleManager/IntoxicationClient.
Config.Intoxication = {
	SwayAmplitude = 0.5,
	MovementNoise = 0.15,
	Duration_Wine = 30,
	Duration_Ale = 90,
	StaminaRegenMult = 0.8, -- -20% stamina regen while intoxicated
}

return Config
