-- MovementController.client.lua
-- Client-side movement: custom animations, A/D body tilt, shiftlock, footsteps, idle/fidget
-- Animations run at Action priority, overriding Roblox's default Animate script.
-- Server syncs isCrouching / isSliding via UpdateMovementState RemoteEvent.

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local UIS    = UserInputService
local UGS    = UserSettings():GetService("UserGameSettings")

-- Animation IDs
local ANIMS = {
	walk         = "rbxassetid://83155167958854",
	run          = "rbxassetid://79554907659094",
	crouch_idle  = "rbxassetid://116456219420832",
	crouch_walk  = "rbxassetid://116858287593059",
	slide        = "rbxassetid://138077862875076",
	climb_static = "rbxassetid://72081837672712",
	climb        = "rbxassetid://91810250110374",
	climb_down   = "rbxassetid://105697524652702",
	scaredy_run  = "rbxassetid://87118930583801",
	dash_left    = "rbxassetid://77205663808585",
	dash_right   = "rbxassetid://105519507786022",
	dash_back    = "rbxassetid://74820799886147",
	dash_forward = "rbxassetid://124019507634490",
	fist_idle    = "rbxassetid://132786615307995",
	-- Walk cycle with the fists HELD UP (legs/torso from the normal walk, both arms frozen in
	-- the fist_idle stance). Without a dedicated clip, walking with fists out plays the plain
	-- `walk`, which swings the arms back down out of stance -- this keeps them up. A ready-to-
	-- publish clip was generated at ServerStorage.RBX_ANIMSAVES.PlayerFistWalk.fist_walk; publish
	-- it in the Animation Editor and paste the asset id here (placeholder-skipped while 0).
	fist_walk    = "rbxassetid://0",	-- PLACEHOLDER_ANIMATION: fist_walk
	block        = "rbxassetid://107606771251321",
	fist_dodge   = "rbxassetid://0",	-- PLACEHOLDER_ANIMATION: fist_dodge

	slide_jump   = "rbxassetid://0",	-- PLACEHOLDER_ANIMATION: slide_jump
	dash_feint   = "rbxassetid://0",	-- PLACEHOLDER_ANIMATION: dash_feint

	jump         = "rbxassetid://127548639034751",
	jump_loop    = "rbxassetid://97375498256832",
	land         = "rbxassetid://89670666875141",

	-- Combat polish 4C additions
	land_heavy       = "rbxassetid://0", -- PLACEHOLDER_ANIMATION: land_heavy (15+ stud falls)
	breathing_idle   = "rbxassetid://0", -- PLACEHOLDER_ANIMATION: idle_breathing_subtle
	turn_left        = "rbxassetid://0", -- PLACEHOLDER_ANIMATION: turn_in_place_left
	turn_right       = "rbxassetid://0", -- PLACEHOLDER_ANIMATION: turn_in_place_right
}

-- Movement state (synced from server)
local isCrouching = false
local isSliding   = false
local isDashing       = false
local dashDir         = nil
local isDashFeinting  = false
local isSlideJumping  = false
local isBlockingLocal = false
local isLanding       = false
local isJumping       = false
local landingToken     = 0
local jumpToken        = 0
local dashCooldownUntil = 0
local DASH_COOLDOWN_CLIENT = 0.6 -- must match MovementManager's DASH_COOLDOWN server-side
local stuckWatchdogAccum = 0 -- see the watchdog note in the Heartbeat block below
local LANDING_ANTICIPATION_TIME = 0.15 -- seconds of lead-in before actual touchdown
local LEG_CLEARANCE             = 3    -- studs from HRP down to roughly the feet
local ANTICIPATION_SAFETY_TIMEOUT = 0.4 -- clears the pose if the predicted landing never happens

local function triggerLanding(duration)
	isLanding = true
	landingToken += 1
	local myToken = landingToken
	task.delay(duration, function()
		if myToken == landingToken then isLanding = false end
	end)
end

-- Combat polish 4C: heavy vs light landing variation. Mirrors the SAME fall-distance idea
-- CombatManager's server-side landing recovery already uses (LANDING_RECOVERY_MIN_FALL /
-- 15-stud threshold), tracked independently here purely for the cosmetic anim choice --
-- doesn't need to match server exactly since this never gates anything mechanical.
local landingVariant = "land"
local fallStartY = nil
local HEAVY_LANDING_MIN_FALL = 15

-- Combat polish 4C: turn-in-place. Only while stationary -- a >60 degree facing change
-- (e.g. spinning the camera around while shiftlocked and not moving) plays a brief turn
-- pose instead of snapping instantly.
local isTurningInPlace = false
local turnToken = 0
local turnAnimName = "turn_right"
local lastFacingAngle = nil
local TURN_TRIGGER_DEG = 60
local function triggerTurn(direction, duration)
	turnAnimName = direction
	isTurningInPlace = true
	turnToken += 1
	local myToken = turnToken
	task.delay(duration, function()
		if myToken == turnToken then isTurningInPlace = false end
	end)
end
-- Character refs -- declared here (not down by acquireCharacter) because
-- ensureAttackAlign/updateAttackFacing below reference hrp/hum: as locals they're
-- only visible after this declaration point, so defining those functions any earlier
-- silently resolved hrp to a nil global instead of the real character part (this is
-- exactly the attackTurnSpeedDeg ordering bug from earlier, just for a different
-- variable -- the align/attachment were never actually getting created).
local character, hrp, hum, rootJoint, defaultC0

local isAttackingLocal = false
local attackSafetyToken = 0
local attackAttachment, attackAlign

local attackTurnSpeedDeg = 120
do
	local ok, cfg = pcall(function() return require(ReplicatedStorage:WaitForChild("Shared",5):WaitForChild("Config",3)) end)
	if ok and cfg and cfg.Combat and cfg.Combat.AttackTurnSpeed then attackTurnSpeedDeg = cfg.Combat.AttackTurnSpeed end
end

local function ensureAttackAlign()
	if attackAlign and attackAlign.Parent == hrp then return end
	if not hrp then return end
	local existingAlign = hrp:FindFirstChild("AttackFacingAlign")
	if existingAlign then existingAlign:Destroy() end
	local existingAtt = hrp:FindFirstChild("AttackFacingAttachment")
	if existingAtt then existingAtt:Destroy() end

	attackAttachment = Instance.new("Attachment")
	attackAttachment.Name = "AttackFacingAttachment"
	attackAttachment.Parent = hrp

	attackAlign = Instance.new("AlignOrientation")
	attackAlign.Name = "AttackFacingAlign"
	attackAlign.Attachment0 = attackAttachment
	attackAlign.Mode = Enum.OrientationAlignmentMode.OneAttachment
	attackAlign.MaxAngularVelocity = math.rad(attackTurnSpeedDeg) -- the actual turn-speed cap
	attackAlign.MaxTorque = math.huge
	attackAlign.Responsiveness = 25
	attackAlign.Enabled = false
	attackAlign.Parent = hrp
end

-- Remote
local function getMovRE(name)
	local folder = ReplicatedStorage:WaitForChild("RemoteEvents", 5)
	return folder and folder:WaitForChild(name, 5)
end
local RE_MovState = getMovRE("UpdateMovementState")
local RE_DashDenied = getMovRE("OnDashDenied")
-- Safety net: if the server rejects a dash for a reason this client didn't predict (e.g.
-- insufficient stamina, or landing recovery), cancel whatever dash anim already started
-- instead of letting it play out to a move that never actually happened.
if RE_DashDenied then
	RE_DashDenied.OnClientEvent:Connect(function()
		isDashing = false; dashDir = nil
	end)
end

if RE_MovState then
	RE_MovState.OnClientEvent:Connect(function(state)
		if     state == "Slide"     then isSliding   = true
		elseif state == "SlideEnd"  then isSliding = false; stopSlideSound()
		elseif state == "SlideJump" then isSliding = false; stopSlideSound(); isSlideJumping = true
		elseif state == "Crouch"    then isCrouching = true
		elseif state == "CrouchEnd" then isCrouching = false
		elseif state == "Block"     then isBlockingLocal = true
		elseif state == "BlockEnd"  then isBlockingLocal = false
		elseif state == "DashFeint" then
			-- Server confirmed a dash feint: cut the in-flight dash pose short and briefly show
			-- the feint pose instead (see resolveAnim -- placeholder until dash_feint has a real clip).
			isDashing = false; dashDir = nil
			isDashFeinting = true
			task.delay(0.2, function() isDashFeinting = false end)
		elseif state == "AttackStart" then
			isAttackingLocal = true
			-- Safety net: CombatManager's combatState stays "Attacking" across an entire M1 chain
			-- (not per-swing), so the server may not always send a timely AttackEnd between
			-- chain hits. Bound the cap's worst case to one chain's realistic max duration
			-- instead of letting it get stuck if the player just stops mid-chain.
			attackSafetyToken += 1
			local myToken = attackSafetyToken
			task.delay(2.5, function()
				if myToken == attackSafetyToken then isAttackingLocal = false end
			end)
		elseif state == "AttackEnd"   then isAttackingLocal = false
		end
	end)
end

local sounds = {}

-- Animation tracks
local tracks      = {}
local currentAnim = nil

local ownAnimator = nil
local ownTrackSet = {}

local function loadAnims(animator)
	for _, t in pairs(tracks) do pcall(function() t:Stop(0) end) end
	tracks = {}; currentAnim = nil; ownTrackSet = {}
	ownAnimator = animator
	for name, id in pairs(ANIMS) do
		local anim = Instance.new("Animation")
		anim.AnimationId = id
		local ok, t = pcall(function() return animator:LoadAnimation(anim) end)
		if ok and t then
			t.Priority = Enum.AnimationPriority.Action
			if name == "block" or name == "jump_loop" or name == "breathing_idle" then t.Looped = true end -- held/looping clips, not one-shots
			tracks[name] = t
			ownTrackSet[t] = true
		end
	end
end

-- The default Roblox Animate script stays enabled (airborne states rely on it for
-- jump/fall), but its walk/idle clips don't cover every joint our custom clips do,
-- so at equal-ish priority they can bleed through and blend into a glitchy pose
-- (this is what broke crouch-walking). Whenever we have an active custom animation,
-- forcibly stop anything Animate is playing that isn't one of ours.
local function suppressForeignTracks()
	if not ownAnimator then return end
	for _, t in ipairs(ownAnimator:GetPlayingAnimationTracks()) do
		-- Only suppress tracks at our own priority (Action) or lower — that's the default
		-- Animate script's walk/idle clips this was built to silence. Higher-priority tracks
		-- (Action2+, e.g. InputHandler's M1/parry combat animations and dash clips) are
		-- intentional and must be left alone, or they get killed within milliseconds of
		-- starting every time this runs (every RenderStepped frame).
		if not ownTrackSet[t] and t.Priority.Value <= Enum.AnimationPriority.Action.Value then
			pcall(function() t:Stop(0) end)
		end
	end
end

local function playAnim(name)
	if name then suppressForeignTracks() end
	if currentAnim == name then return end
	if currentAnim and tracks[currentAnim] then
		tracks[currentAnim]:Stop(0.15)
	end
	currentAnim = name
	if name and tracks[name] then
		tracks[name]:Play(0.15)
	end
end

local function resolveAnim()
	if not hum or not hrp then return nil end
	local state = hum:GetState()

	-- Slide jump: only the initial launch (Jumping) shows the slide_jump pose. Once actually
	-- falling (Freefall) it clears here so the normal airborne checks below take over and
	-- play the regular fall animation (jump_loop), instead of holding slide_jump for the
	-- entire time you're in the air.
	if isSlideJumping then
		if state ~= Enum.HumanoidStateType.Jumping then
			isSlideJumping = false
		elseif not isLanding then
			return "slide_jump"
		end
	end

	-- Landing: brief one-shot on touchdown, takes priority over everything else briefly
	if isLanding then
		return landingVariant
	end

	-- Turn-in-place: also a brief one-shot, same priority tier as landing
	if isTurningInPlace then
		return turnAnimName
	end

	-- Climbing
	if state == Enum.HumanoidStateType.Climbing then
		local vy = hrp.Velocity.Y
		if math.abs(vy) < 1 then return "climb_static"
		elseif vy > 0          then return "climb"
		else                        return "climb_down" end
	end

	if isDashFeinting then
		return "dash_feint"
	end

	if isDashing and dashDir then
		-- Left/right dashes have real clips regardless of fist state — use them directly.
		if dashDir == "left" or dashDir == "right" then
			return "dash_" .. dashDir
		end
		-- Forward/back prefer fist_dodge when unarmed, but that clip is still an unauthored
		-- placeholder (rbxassetid://0) — falling through to it would silently play nothing
		-- and hide the real dash_forward/dash_back clips. Fall back to the direction clip
		-- until fist_dodge actually has a real id (same placeholder-skip convention used
		-- elsewhere, e.g. soundId() returning nil for unset sounds).
		if character and character:GetAttribute("FistsEquipped") and ANIMS.fist_dodge ~= "rbxassetid://0" then
			return "fist_dodge"
		end
		return "dash_" .. dashDir
	end

	-- Blocking holds its stance regardless of movement -- outranks jump/fall so holding F
	-- while airborne (or landing into a block) still reads as blocking, not jumping.
	if isBlockingLocal then return "block" end

	-- Airborne — takeoff plays once entering Jumping, loop plays while falling.
	-- isJumping is event-driven (StateChanged), not polled from GetState(): the Jumping
	-- state is often too transient for a single RenderStepped frame to ever observe it.
	if isJumping then
		return "jump"
	end
	if state == Enum.HumanoidStateType.Freefall then
		return "jump_loop"
	end

	if isSliding then return "slide" end

	local moving = hum.MoveDirection.Magnitude > 0.05

	if isCrouching then
		return moving and "crouch_walk" or "crouch_idle"
	end

	if not moving then
		-- Fists out = fist idle stance (user request 2026-07-20). E toggles FistsEquipped via
		-- InputHandler/RequestEquipFists, so lowering fists with E returns to the normal idle.
		-- CombatStance (10s after a landed hit) also still forces the stance.
		if character and (character:GetAttribute("FistsEquipped") or character:GetAttribute("CombatStance")) then return "fist_idle" end
		-- Combat polish 4C: subtle breathing loop while genuinely idle. This system is a
		-- single-track state machine (see loadAnims/playAnim), not a layering rig, so this
		-- replaces the default Animate idle rather than blending on top of it -- same
		-- approach fist_idle already uses one branch up.
		-- Placeholder-skip: while breathing_idle is an unauthored rbxassetid://0, selecting
		-- it plays NOTHING while still suppressing the default Animate idle every frame --
		-- the character just froze solid whenever standing still. Fall through to nil so
		-- Animate's own idle keeps playing until a real clip exists.
		if ANIMS.breathing_idle ~= "rbxassetid://0" then return "breathing_idle" end
		return nil
	end

	local speed = Vector3.new(hrp.Velocity.X, 0, hrp.Velocity.Z).Magnitude
	if hum.WalkSpeed > 20 then
		if hum.MaxHealth > 0 and (hum.Health / hum.MaxHealth) < 0.3 then
			return "scaredy_run"
		end
		return "run"
	end

	-- Fists out while walking: keep the fists UP with the combined fist-walk clip (walk legs,
	-- arms frozen in the fist stance) instead of the plain walk that drops the arms. Same
	-- placeholder-skip convention as fist_dodge/breathing_idle: until fist_walk has a real
	-- published id it stays rbxassetid://0, so fall through to the normal walk rather than
	-- selecting a track that plays nothing.
	if character and (character:GetAttribute("FistsEquipped") or character:GetAttribute("CombatStance"))
	   and ANIMS.fist_walk ~= "rbxassetid://0" then
		return "fist_walk"
	end
	return "walk"
end

-- Sounds — volumes/rolloffs are local defaults; SoundId always comes from ReplicatedStorage._Sounds.Movement
-- Combat polish 4C: footstep_walk/run/crouch (pace-based) replaced by surface-material-based
-- sounds -- pace already drives WHEN a footstep fires (stepInterval below), material drives
-- WHICH sound plays, matching the actual ask ("different sound per material").
local SOUND_DEFS = {
	footstep_grass  = { volume = 0.4, rolloff = 0 },
	footstep_wood   = { volume = 0.4, rolloff = 0 },
	footstep_stone  = { volume = 0.4, rolloff = 0 },
	footstep_sand   = { volume = 0.35, rolloff = 0 },
	footstep_water  = { volume = 0.45, rolloff = 0 },
	footstep_snow   = { volume = 0.35, rolloff = 0 },
	footstep_metal  = { volume = 0.45, rolloff = 0 },
	footstep_rock   = { volume = 0.4, rolloff = 0 },
	slide_sound     = { volume = 0.5, rolloff = 0, looped = true },
	land_impact     = { volume = 0.7, rolloff = 0 },
}

local MATERIAL_FOOTSTEP = {
	[Enum.Material.Grass] = "footstep_grass", [Enum.Material.LeafyGrass] = "footstep_grass",
	[Enum.Material.Wood] = "footstep_wood", [Enum.Material.WoodPlanks] = "footstep_wood",
	[Enum.Material.Concrete] = "footstep_stone", [Enum.Material.Slate] = "footstep_stone",
	[Enum.Material.Cobblestone] = "footstep_stone", [Enum.Material.Limestone] = "footstep_stone",
	[Enum.Material.Rock] = "footstep_rock", [Enum.Material.Basalt] = "footstep_rock", [Enum.Material.Granite] = "footstep_rock",
	[Enum.Material.Sand] = "footstep_sand",
	[Enum.Material.Water] = "footstep_water",
	[Enum.Material.Snow] = "footstep_snow", [Enum.Material.Ice] = "footstep_snow", [Enum.Material.Glacier] = "footstep_snow",
	[Enum.Material.Metal] = "footstep_metal", [Enum.Material.DiamondPlate] = "footstep_metal", [Enum.Material.CorrodedMetal] = "footstep_metal",
}
local function materialFootstepName()
	if not hum then return "footstep_stone" end
	return MATERIAL_FOOTSTEP[hum.FloorMaterial] or "footstep_stone" -- reasonable default for anything unmapped
end

local MovementSoundsFolder = ReplicatedStorage:WaitForChild("_Sounds", 5):WaitForChild("Movement", 5)
local function movementSoundId(name)
	local snd = MovementSoundsFolder:FindFirstChild(name)
	local id = snd and snd.SoundId
	if not id or id == "" or id == "rbxassetid://0" then return "" end
	return id
end

function setupSounds()
	if not hrp then return end
	for name, def in pairs(SOUND_DEFS) do
		local s = hrp:FindFirstChild(name) or Instance.new("Sound")
		s.Name = name; s.SoundId = movementSoundId(name); s.Volume = def.volume
		s.RollOffMaxDistance = def.rolloff; s.Looped = def.looped or false
		s.Parent = hrp; sounds[name] = s
	end
end

function stopSlideSound()
	if sounds.slide_sound and sounds.slide_sound.IsPlaying then
		sounds.slide_sound:Stop()
	end
end

local footstepTimer = 0
local wasGrounded   = false

local function stepInterval()
	if isSliding   then return math.huge end
	if isCrouching then return 0.7 end
	if hum and hum.WalkSpeed > 20 then return 0.3 end
	return 0.5
end

-- ── Movement feel state (camera impulses shared by dash/landing/bob below) ────────
-- Springy vertical dip on landings, a directional roll kick on dashes, and a dash FOV
-- pulse flag CombatFeelClient's unified FOV block reads (it owns FieldOfView -- writing
-- FOV from two scripts would fight every frame).
local camDipY, camDipVel = 0, 0
local dashRoll, dashRollTarget = 0, 0

-- ── Dash (hold direction + Q) ──────────────────────────────────────────
local function playDashWhoosh()
	if not hrp then return end
	local id = movementSoundId("dash_whoosh")
	if id == "" then return end
	local snd = Instance.new("Sound")
	snd.SoundId = id; snd.Volume = 0.4
	snd.Parent = hrp
	snd:Play()
	-- Destroy once actually finished, not on a fixed timer -- a fixed Debris delay can
	-- destroy the instance before a slower-to-stream asset ever finishes playing.
	local cleaned = false
	local function cleanup() if not cleaned then cleaned = true; if snd.Parent then snd:Destroy() end end end
	snd.Ended:Once(cleanup)
	task.delay(8, cleanup)
end

local function fireDash()
	if not hum or isDashing or isCrouching or isSliding then return end
	-- Predicted cooldown: without this, the dash animation played every Q press even while
	-- the server was about to silently reject it (still on its own 0.6s cooldown), which read
	-- as "the dash animation played but nothing happened."
	if tick() < dashCooldownUntil then return end
	local w = UIS:IsKeyDown(Enum.KeyCode.W)
	local s = UIS:IsKeyDown(Enum.KeyCode.S)
	local a = UIS:IsKeyDown(Enum.KeyCode.A)
	local d = UIS:IsKeyDown(Enum.KeyCode.D)
	if not w and not s and not a and not d then return end
	local dir
	if a and not d then dir = "left"
	elseif d and not a then dir = "right"
	elseif s and not w then dir = "back"
	else dir = "forward" end
	dashCooldownUntil = tick() + DASH_COOLDOWN_CLIENT
	isDashing = true; dashDir = dir
	playDashWhoosh()
	-- Camera feel: sideways dashes kick a quick roll toward the dash, all dashes pulse FOV
	-- (read by CombatFeelClient's FOV block via this shared timestamp).
	if dir == "left" then dashRollTarget = 5 elseif dir == "right" then dashRollTarget = -5 end
	_G.MovementFeelDashUntil = tick() + 0.3
	task.delay(0.4, function() isDashing = false; dashDir = nil end)
end

UIS.InputBegan:Connect(function(input, gp)
	if gp then return end
	if input.KeyCode == Enum.KeyCode.Q then fireDash() end
end)

-- Shiftlock
local shiftlocked = false
-- True once the player has deliberately turned shiftlock OFF themselves (Alt while on) --
-- a manual toggle-off is a real choice and must stick even if a combat input (M2) would
-- otherwise want to auto-engage it again; only another manual Alt press clears this.
local manuallyDisabled = false

local function setShiftlock(enabled)
	shiftlocked = enabled
	UGS.RotationType  = enabled and Enum.RotationType.CameraRelative or Enum.RotationType.MovementRelative
	UIS.MouseBehavior = enabled and Enum.MouseBehavior.LockCenter    or Enum.MouseBehavior.Default
	-- Custom cursor image replaces the OS arrow entirely while locked (StarterGui.ShiftlockCursor)
	UIS.MouseIconEnabled = not enabled
	local cur = player.PlayerGui:FindFirstChild("ShiftlockCursor")
	if cur then cur.Enabled = enabled end
end

-- Called by combat inputs that require shiftlock to function (M2) -- engages it only if the
-- player hasn't just deliberately turned it off; respects manuallyDisabled instead of
-- fighting a real manual toggle-off every time M2 is pressed.
local function requestShiftlock()
	if not shiftlocked and not manuallyDisabled then
		setShiftlock(true)
	end
end

-- Cross-LocalScript access (same convention as the server's _G.CombatManager/_G.MovementManager)
-- so InputHandler can request shiftlock for inputs that actually require it (M2), instead
-- of silently no-op'ing when the player never manually turned it on.
_G.MovementController = {
	setShiftlock = setShiftlock,
	requestShiftlock = requestShiftlock,
	isShiftlocked = function() return shiftlocked end,
	isSliding = function() return isSliding end, -- read by CombatFeelClient's slide FOV widen
}

UIS.InputBegan:Connect(function(input, gp)
	if gp then return end
	if input.KeyCode == Enum.KeyCode.LeftAlt or input.KeyCode == Enum.KeyCode.RightAlt then
		local turningOn = not shiftlocked
		manuallyDisabled = not turningOn
		setShiftlock(turningOn)
	end
end)

-- A/D Tilt
local TILT_MAX   = math.rad(8)
local TILT_SPEED = 10
local curTilt    = 0
local targetTilt = 0

local function shouldTilt()
	if not character then return false end
	if isCrouching or isSliding then return false end
	local attr = character:GetAttribute("CombatState")
	if attr == "GuardBroken" or attr == "Staggered" or attr == "Downed" then return false end
	return true
end

UIS.InputBegan:Connect(function(input, gp)
	if gp then return end
	if input.KeyCode == Enum.KeyCode.A then if shouldTilt() then targetTilt = -TILT_MAX end end
	if input.KeyCode == Enum.KeyCode.D then if shouldTilt() then targetTilt =  TILT_MAX end end
end)

UIS.InputEnded:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.A or input.KeyCode == Enum.KeyCode.D then
		if not UIS:IsKeyDown(Enum.KeyCode.A) and not UIS:IsKeyDown(Enum.KeyCode.D) then
			targetTilt = 0
		elseif UIS:IsKeyDown(Enum.KeyCode.A) then targetTilt = -TILT_MAX
		else targetTilt = TILT_MAX end
	end
end)

-- Idle / Fidget
local FIDGET_DELAY = 9
local FIDGET_IDS   = { fidget_1 = 0, fidget_2 = 0 }
local fidgetThread = nil
local fidgetTracks = {}

local function combatStateBlocks()
	if not character then return true end
	local attr = character:GetAttribute("CombatState")
	return attr == "Staggered" or attr == "GuardBroken" or attr == "Downed"
		or attr == "M1Active"  or attr == "M2Swing"     or attr == "Blocking"
end

local function playFidget()
	if not hum or combatStateBlocks() or isCrouching or isSliding then return end
	if not hum.Animator then return end
	local names = {"fidget_1","fidget_2"}
	local pick  = names[math.random(1, #names)]
	local id    = FIDGET_IDS[pick]
	if id == 0 then task.wait(2); return end
	local anim = Instance.new("Animation")
	anim.AnimationId = "rbxassetid://" .. id
	local track = hum.Animator:LoadAnimation(anim)
	fidgetTracks[#fidgetTracks+1] = track
	track:Play(); track.Stopped:Wait()
end

function resetIdleTimer()
	if fidgetThread then task.cancel(fidgetThread) end
	for _, t in ipairs(fidgetTracks) do pcall(function() t:Stop() end) end
	fidgetTracks = {}
	fidgetThread = task.delay(FIDGET_DELAY, function()
		while true do
			playFidget()
			if combatStateBlocks() or isCrouching or isSliding then break end
			task.wait(FIDGET_DELAY)
		end
	end)
end

UIS.InputBegan:Connect(function(input, gp)
	if gp then return end
	resetIdleTimer()
end)

-- Character setup
local function acquireCharacter(char)
	character   = char
	hrp         = char:WaitForChild("HumanoidRootPart", 5)
	hum         = char:WaitForChild("Humanoid", 5)
	rootJoint   = hrp and hrp:FindFirstChild("RootJoint")
	defaultC0   = rootJoint and rootJoint.C0
	isSliding   = false; isCrouching = false; isDashing   = false; dashDir     = nil; currentAnim = nil
	isBlockingLocal = false
	isAttackingLocal = false; attackAlign = nil; attackAttachment = nil
	isLanding = false; wasGrounded = false
	isJumping = false
	setupSounds()
	resetIdleTimer()
	task.spawn(function()
		local animator = hum and hum:WaitForChild("Animator", 5)
		if animator then
			task.wait(0.1)
			loadAnims(animator)
		end
	end)
	-- Jumping is event-driven, not polled: the Jumping HumanoidStateType is often too
	-- transient for GetState() to ever observe it on a RenderStepped frame.
	if hum then
		hum.StateChanged:Connect(function(_, new)
			if new ~= Enum.HumanoidStateType.Jumping then return end
			-- A fresh jump means we're airborne again on purpose -- clear any lingering "land"
			-- pose immediately (bump the token so its own delayed auto-clear can't race this).
			-- Without this, spam-jumping (bunny-hopping) lands, re-triggers isLanding for its
			-- full ~0.93s duration, and the next jump starts before that expires -- resolveAnim()
			-- checks isLanding before isJumping, so "land" wins and the jump/fall animation
			-- never shows, making every rapid jump look stuck or broken.
			isLanding = false
			landingToken += 1
			isJumping = true
			jumpToken += 1
			local myJumpToken = jumpToken
			local jumpLen = tracks.jump and tracks.jump.Length
			local jumpDur = (jumpLen and jumpLen > 0) and jumpLen or 0.3
			task.delay(jumpDur, function()
				if myJumpToken == jumpToken then isJumping = false end
			end)
		end)
	end
end

-- Facing overrides: two situations where the character's rotation shouldn't just follow
-- Roblox's default AutoRotate-toward-MoveDirection behavior --
--  1) Attacks: facing tracks the camera direction, but at a capped rate (deg/s) instead of
--     snapping instantly, so a flanker who gets behind an attacker mid-swing can't be
--     instantly punished.
--  2) Sliding: facing tracks the slide's actual velocity direction instead of raw
--     camera-relative MoveDirection -- outside shiftlock, panning the mouse mid-slide fed a
--     constantly-changing MoveDirection into Roblox's own (near-instant) AutoRotate, which
--     spun the character in place independently of the direction the slide's BodyVelocity
--     was actually carrying it. Aligning to real velocity instead means the model only ever
--     faces where it's actually going, turning at the same capped rate the slide itself
--     carves at (MovementManager's MOM.SlideTurnSpeed).
-- Camera itself still moves freely in both cases; only the character model's Y-rotation is
-- capped/overridden. Outside both, Humanoid.AutoRotate is restored and rotation is free again.
local SLIDE_TURN_SPEED_DEG = 200 -- must match MovementManager's MOM.SlideTurnSpeed
local function updateFacingOverrides(dt)
	if not hum or not hrp then return end
	ensureAttackAlign()
	local overriding = isAttackingLocal or isSliding
	if not overriding then
		if not hum.AutoRotate then hum.AutoRotate = true end
		if attackAlign then attackAlign.Enabled = false end
		-- Restore shiftlock's own camera-follow rotation now that no cap is needed
		if shiftlocked and UGS.RotationType ~= Enum.RotationType.CameraRelative then
			UGS.RotationType = Enum.RotationType.CameraRelative
		end
		return
	end
	hum.AutoRotate = false
	-- Shiftlock's RotationType.CameraRelative makes Roblox's own character controller
	-- snap the character to face the camera every frame, completely bypassing AutoRotate
	-- and our AlignOrientation cap -- that's why the turn cap did nothing while
	-- shiftlocked. Suspend it while overriding so our cap is the only thing driving
	-- rotation; MouseBehavior stays locked, so aiming still feels the same.
	if shiftlocked and UGS.RotationType ~= Enum.RotationType.MovementRelative then
		UGS.RotationType = Enum.RotationType.MovementRelative
	end
	if not attackAlign then return end
	-- AlignOrientation applies TORQUE toward the target, coexisting with normal movement
	-- forces (unlike directly writing hrp.CFrame, which teleports the part and fights/
	-- resets the physics simulation every frame — that was breaking movement entirely).
	-- Its own MaxAngularVelocity natively enforces the turn-speed cap.
	if isSliding then
		local vel = hrp.AssemblyLinearVelocity
		local flatVel = Vector3.new(vel.X, 0, vel.Z)
		if flatVel.Magnitude < 1 then return end
		attackAlign.MaxAngularVelocity = math.rad(SLIDE_TURN_SPEED_DEG)
		attackAlign.CFrame = CFrame.new(hrp.Position, hrp.Position + flatVel.Unit)
		attackAlign.Enabled = true
	else
		local camera = workspace.CurrentCamera; if not camera then return end
		local camLook = camera.CFrame.LookVector
		local flatLook = Vector3.new(camLook.X, 0, camLook.Z)
		if flatLook.Magnitude < 0.01 then return end
		attackAlign.MaxAngularVelocity = math.rad(attackTurnSpeedDeg)
		attackAlign.CFrame = CFrame.new(hrp.Position, hrp.Position + flatLook.Unit)
		attackAlign.Enabled = true
	end
end

-- RenderStepped: tilt + animation
RunService.RenderStepped:Connect(function(dt)
	if not rootJoint or not defaultC0 then
		if hrp then rootJoint = hrp:FindFirstChild("RootJoint") end
		if rootJoint then defaultC0 = rootJoint.C0 end
		return
	end
	if not shouldTilt() then targetTilt = 0 end
	curTilt = curTilt + (targetTilt - curTilt) * math.min(1, TILT_SPEED * dt)
	rootJoint.C0 = defaultC0 * CFrame.Angles(0, 0, curTilt)
	updateFacingOverrides(dt)
	playAnim(resolveAnim())
end)

-- Heartbeat: footsteps + slide sound
RunService.Heartbeat:Connect(function(dt)
	if not hum or not hrp then return end
	local grounded = hum.FloorMaterial ~= Enum.Material.Air

	-- Movement-stuck watchdog: a Roblox quirk can leave the Humanoid unresponsive to real
	-- WASD input after certain property changes while idle (first seen with crouch's
	-- WalkSpeed change). A one-time ChangeState nudge fired at the moment of the property
	-- change kept failing under real network latency -- fine in Studio Solo testing (client
	-- and server share a process, ~0 latency) but not for an actual friend testing over a
	-- real connection, since the fix's timing itself was latency-sensitive. This instead
	-- continuously watches for the actual symptom -- a movement key genuinely held down but
	-- MoveDirection staying ~0 -- and force-corrects it, regardless of cause or how much
	-- latency is involved.
	if grounded then
		local anyMoveKeyHeld = UIS:IsKeyDown(Enum.KeyCode.W) or UIS:IsKeyDown(Enum.KeyCode.A)
			or UIS:IsKeyDown(Enum.KeyCode.S) or UIS:IsKeyDown(Enum.KeyCode.D)
		if anyMoveKeyHeld and hum.MoveDirection.Magnitude < 0.05 then
			stuckWatchdogAccum += dt
			if stuckWatchdogAccum > 0.15 then
				hum:ChangeState(Enum.HumanoidStateType.Running)
				stuckWatchdogAccum = 0
			end
		else
			stuckWatchdogAccum = 0
		end
	end

	-- Landing anticipation: raycast ahead of an active fall so the land pose starts a
	-- little before actual touchdown instead of snapping in on contact (looked jarring).
	-- Uses a token so a real touchdown's full-length clear always overrides whatever
	-- the anticipatory trigger scheduled, and a safety timeout in case the predicted
	-- landing doesn't happen (e.g. knocked upward again mid-fall).
	if not grounded and wasGrounded then
		fallStartY = hrp.Position.Y -- Combat polish 4C: mark the moment a real fall begins
	end

	-- Combat polish 4C: turn-in-place detection. Only sampled while genuinely stationary --
	-- while moving, lastFacingAngle just tracks along silently so stopping never falsely
	-- reads as a big turn relative to some stale angle from before you started walking.
	do
		local lookFlat = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z)
		if lookFlat.Magnitude > 0.01 then
			local angle = math.deg(math.atan2(lookFlat.X, lookFlat.Z))
			local stationary = hum.MoveDirection.Magnitude < 0.05
			if stationary and grounded and not isTurningInPlace then
				if lastFacingAngle then
					local delta = ((angle - lastFacingAngle + 180) % 360) - 180
					if math.abs(delta) >= TURN_TRIGGER_DEG then
						-- Placeholder-skip: with turn clips still rbxassetid://0, triggering the
						-- turn state froze the rig for 0.4s on every big camera spin.
						local dirName = delta > 0 and "turn_right" or "turn_left"
						if ANIMS[dirName] ~= "rbxassetid://0" then triggerTurn(dirName, 0.4) end
						lastFacingAngle = angle
					end
				else
					lastFacingAngle = angle
				end
			else
				lastFacingAngle = angle
			end
		end
	end

	if not grounded and not isLanding then
		local vel = hrp.AssemblyLinearVelocity
		if vel.Y < -5 then
			local lookAheadDist = -vel.Y * LANDING_ANTICIPATION_TIME + LEG_CLEARANCE
			local params = RaycastParams.new()
			params.FilterDescendantsInstances = {character}
			params.FilterType = Enum.RaycastFilterType.Exclude
			if workspace:Raycast(hrp.Position, Vector3.new(0, -lookAheadDist, 0), params) then
				triggerLanding(ANTICIPATION_SAFETY_TIMEOUT)
			end
		end
	end

	if grounded and not wasGrounded then
		-- Combat polish 4C: heavy vs light landing, purely cosmetic (real landing-recovery
		-- lockout is server-authoritative in CombatManager, untouched here).
		local fallDist = fallStartY and (fallStartY - hrp.Position.Y) or 0
		-- land_heavy placeholder-skip: same frozen-pose problem as breathing_idle -- a 15+
		-- stud fall showed no landing at all instead of the heavy clip. Use the real light
		-- land until a heavy clip is authored.
		landingVariant = (fallDist >= HEAVY_LANDING_MIN_FALL and ANIMS.land_heavy ~= "rbxassetid://0") and "land_heavy" or "land"
		-- Camera dip: touchdown pushes the camera down with an impulse scaled by fall
		-- distance; the spring in the render step below bounces it back. Reads as weight.
		camDipVel = -math.clamp(1.5 + fallDist * 0.18, 1.5, 7)
		fallStartY = nil
		local snd = sounds.land_impact
		if snd then snd:Play() end
		local landLen = tracks[landingVariant] and tracks[landingVariant].Length
		local landDur = (landLen and landLen > 0) and landLen or 0.93
		triggerLanding(landDur)
	end
	wasGrounded = grounded

	local slideSnd = sounds.slide_sound
	if slideSnd then
		if isSliding and not slideSnd.IsPlaying then slideSnd:Play()
		elseif not isSliding and slideSnd.IsPlaying then slideSnd:Stop() end
	end

	if not grounded then footstepTimer = 0; return end
	local moving = hum.MoveDirection.Magnitude > 0.05
	if not moving then footstepTimer = 0; return end
	if isSliding then return end

	footstepTimer = footstepTimer + dt
	local interval = stepInterval()
	if footstepTimer >= interval then
		footstepTimer = 0
		local snd = sounds[materialFootstepName()]
		if snd then snd:Play() end
	end
end)

-- Combat polish 4C: subtle head bob while actually walking/running. Applied AFTER the
-- default camera script's own RenderStepped update (Camera priority + 1), same technique
-- SanityEffectsClient's cliff tilt and FeelingsClient's shake already use so multiple
-- cosmetic camera layers stack instead of fighting each other.
-- Movement feel render layer: head bob (now also during shiftlock, where most combat
-- happens -- it was fully disabled there, one big reason movement read as dull), lateral
-- sway, the landing-dip spring, and the dash roll kick. Also keeps walk/run animation
-- playback speed matched to actual ground velocity so the body sells the speed.
local bobPhase = 0
RunService:BindToRenderStep("MovementHeadBob", Enum.RenderPriority.Camera.Value + 1, function(dt)
	if not hum or not hrp then return end
	local camera = workspace.CurrentCamera; if not camera then return end
	local grounded = hum.FloorMaterial ~= Enum.Material.Air
	local moving = hum.MoveDirection.Magnitude > 0.05

	-- Landing-dip spring (always simulated so it can recover even while standing still)
	camDipVel += (-camDipY * 90 - camDipVel * 11) * dt
	camDipY += camDipVel * dt
	-- Dash roll: chase the kick target, which itself decays back to 0
	dashRoll = dashRoll + (dashRollTarget - dashRoll) * math.min(1, 12 * dt)
	dashRollTarget = dashRollTarget * math.max(0, 1 - 7 * dt)

	local yOffset, xSway = 0, 0
	local bobActive = grounded and moving and not isBlockingLocal
		and not isCrouching and not isSliding and not isDashing and not isAttackingLocal
	if bobActive then
		local cadence = 1 / math.max(0.05, stepInterval()) -- one bob cycle per footstep
		bobPhase = bobPhase + dt * cadence * (2 * math.pi)
		local amplitude = (hum.WalkSpeed > 20) and 0.16 or 0.09
		if shiftlocked then amplitude *= 0.65 end -- present but softer while aiming
		yOffset = math.sin(bobPhase) * amplitude
		xSway = math.sin(bobPhase * 0.5) * amplitude * 0.7
	else
		bobPhase = 0
	end

	if yOffset ~= 0 or xSway ~= 0 or math.abs(camDipY) > 0.001 or math.abs(dashRoll) > 0.02 then
		camera.CFrame = camera.CFrame * CFrame.new(xSway, yOffset + camDipY, 0) * CFrame.Angles(0, 0, math.rad(dashRoll))
	end

	-- Anim speed matching: playback rate follows real horizontal velocity so slowdowns
	-- (blocking-walk, stat effects, momentum) don't play a full-speed clip while crawling.
	local track = currentAnim and tracks[currentAnim]
	if track and track.IsPlaying then
		local hSpeed = Vector3.new(hrp.Velocity.X, 0, hrp.Velocity.Z).Magnitude
		if currentAnim == "run" or currentAnim == "scaredy_run" then
			track:AdjustSpeed(math.clamp(hSpeed / 25, 0.7, 1.4))
		elseif currentAnim == "walk" then
			track:AdjustSpeed(math.clamp(hSpeed / 16, 0.6, 1.3))
		end
	end
end)

if player.Character then acquireCharacter(player.Character) end
player.CharacterAdded:Connect(acquireCharacter)
