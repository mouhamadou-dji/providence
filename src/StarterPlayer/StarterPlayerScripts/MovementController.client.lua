--[[
	MovementController -- what survives the 2026-08-04 movement teardown.

	This is now ONLY two things:
	  1. the custom R6 animation state machine (idle / walk / run / jump / fall / land /
	     climb / crouch), which overrides Roblox's default Animate clips
	  2. crouch state, mirrored down from MovementManager over UpdateMovementState

	UPDATE 2026-08-04 (later the same day): the movement revamp landed. Locomotion state now
	arrives as the `MoveState` character attribute published by MovementClient, rather than
	being inferred from WalkSpeed. This script still owns the clips and the Animator; it just
	no longer guesses what the body is doing.

	UPDATE 2026-08-07: the slide got its presentation back. MoveState "Sliding" plays the
	Slide clip -- loaded from the ReplicatedStorage._Animations.Movement.Slide INSTANCE, not
	a pasted id, so re-publishing the animation there needs no code change -- and loops
	_Sounds.Movement.slide_sound from the character's root while the slide lasts. The slide
	check sits ABOVE the landing/jump checks on purpose: the slide's air-grace lets it
	survive bumps that flick the Humanoid through Freefall/landing for a frame or two, and
	those must not flicker the clip.

	DELETED WITH THE TEARDOWN (archived at ServerStorage._OldMovement_2026_08_04.Client):
	  mechanics -- Q dash + dash feint + dash cooldown prediction, slide, slide-jump,
	               block/fist stance states, sprint
	  camera    -- shiftlock (Alt) and its cursor GUI, head bob, lateral sway, landing dip
	               spring, dash roll kick, sprint FOV, lean-into-turns, camera follow lag,
	               and the AlignOrientation attack/slide facing overrides
	  feel      -- A/D body tilt, turn-in-place, landing anticipation raycast, heavy-landing
	               variant, idle fidgets, surface-material footsteps, anim speed matching

	NOTHING in this file touches workspace.CurrentCamera or UserGameSettings any more.
	Roblox's stock camera is the only thing driving the view.

	The animation ids below are kept intact so the revamp can drive them straight away.
	The ones the deleted states owned (slide, dash_*, fist_*, block, ...) live in the
	archived copy of this script.
]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local UIS    = UserInputService

-- Animation IDs -- locomotion set only.
local ANIMS = {
	walk         = "rbxassetid://83155167958854",
	run          = "rbxassetid://79554907659094",
	scaredy_run  = "rbxassetid://87118930583801",
	crouch_idle  = "rbxassetid://116456219420832",
	crouch_walk  = "rbxassetid://116858287593059",
	climb_static = "rbxassetid://72081837672712",
	climb        = "rbxassetid://91810250110374",
	climb_down   = "rbxassetid://105697524652702",
	jump         = "rbxassetid://127548639034751",
	jump_loop    = "rbxassetid://97375498256832",
	land         = "rbxassetid://89670666875141",

	-- DIRECTIONAL LOCOMOTION -- wired, not yet authored (2026-08-05 pt3).
	-- Outside shiftlock these are effectively unreachable: AutoRotate turns the body to face
	-- wherever it is moving, so MoveAngle sits at ~0 and everything resolves to the forward
	-- clip. Under shiftlock the body is locked to the camera and A/D/S become real strafes and
	-- backpedals, which is when playing the forward run sideways starts to look wrong.
	--
	-- Every one of these deliberately points at its forward clip TODAY, so behaviour is
	-- unchanged. Publish strafe animations whenever you like and paste the ids in here -- the
	-- selection logic in resolveAnim() is already live and needs no code change.
	-- (Animations cannot be published through the Studio MCP bridge; that step is yours.)
	walk_left    = "rbxassetid://83155167958854", -- PLACEHOLDER_ANIMATION: = walk
	walk_right   = "rbxassetid://83155167958854", -- PLACEHOLDER_ANIMATION: = walk
	walk_back    = "rbxassetid://83155167958854", -- PLACEHOLDER_ANIMATION: = walk
	run_left     = "rbxassetid://79554907659094", -- PLACEHOLDER_ANIMATION: = run
	run_right    = "rbxassetid://79554907659094", -- PLACEHOLDER_ANIMATION: = run
	run_back     = "rbxassetid://79554907659094", -- PLACEHOLDER_ANIMATION: = run
}

-- MoveAngle (published by MovementClient) is the direction of travel measured against the
-- direction the body FACES: 0 straight ahead, negative to the left, +/-180 backwards. Bands are
-- deliberately wide at the front so a diagonal still reads as running forward.
local function directionSuffix(character)
	local a = character and character:GetAttribute("MoveAngle")
	if type(a) ~= "number" then return nil end
	local mag = math.abs(a)
	if mag <= 45  then return nil end        -- forward: the plain clip
	if mag >= 135 then return "back" end
	return a < 0 and "left" or "right"
end

-- Falls back to the plain clip whenever a directional variant is missing, so half-authored
-- animation sets degrade to today's behaviour instead of freezing the rig on a dead track.
local function directionalClip(base, character)
	local suffix = directionSuffix(character)
	if not suffix then return base end
	local name = base .. "_" .. suffix
	return ANIMS[name] and name or base
end

-- The only movement state left. Synced from MovementManager, never inferred locally.
local isCrouching = false

local character, hrp, hum

local isLanding, landingToken = false, 0
local isJumping,  jumpToken   = false, 0
local stuckWatchdogAccum = 0

local function triggerLanding(duration)
	isLanding = true
	landingToken += 1
	local myToken = landingToken
	task.delay(duration, function()
		if myToken == landingToken then isLanding = false end
	end)
end

-- ─── Remote ────────────────────────────────────────────────────────────────
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local remotes = ReplicatedStorage:WaitForChild("RemoteEvents", 5)
local RE_MovState = remotes and remotes:WaitForChild("UpdateMovementState", 5)

if RE_MovState then
	RE_MovState.OnClientEvent:Connect(function(state)
		if     state == "Crouch"    then isCrouching = true
		elseif state == "CrouchEnd" then isCrouching = false
		end
	end)
end

-- ─── Slide presentation assets ────────────────────────────────────────────
-- The clip comes from the Animation INSTANCE in _Animations.Movement (its id lives in the
-- place, not in this file); the sound from _Sounds.Movement, cloned per character so the
-- rolloff is 3D and the library instance stays pristine.
local animsRoot     = ReplicatedStorage:WaitForChild("_Animations", 5)
local AnimMovement  = animsRoot and animsRoot:WaitForChild("Movement", 5)
-- Dash length, so the dash clip can be time-scaled to finish exactly within the dash
-- rather than being cut off partway through the roll.
local sharedFolder  = ReplicatedStorage:FindFirstChild("Shared")
local movementCfg   = sharedFolder and require(sharedFolder:WaitForChild("Config", 5)).Movement
local DASH_DURATION = (movementCfg and movementCfg.Dash and movementCfg.Dash.Duration) or 0.22
local soundsRoot    = ReplicatedStorage:WaitForChild("_Sounds", 5)
local SoundMovement = soundsRoot and soundsRoot:WaitForChild("Movement", 5)

local slideSound = nil -- this character's cloned slide_sound, parented to its root

-- ─── Animation tracks ─────────────────────────────────────────────────────
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
			if name == "jump_loop" then t.Looped = true end
			tracks[name] = t
			ownTrackSet[t] = true
		end
	end

	-- Slide is loaded from its library INSTANCE, not the ANIMS id table -- see the header.
	-- NOT looped: a slide has no fixed length and the replay hitch read as a glitch, so the
	-- clip plays once and the RenderStepped driver freeze-frames its final pose for however
	-- long the slide actually lasts.
	local slideAnim = AnimMovement and AnimMovement:FindFirstChild("Slide")
	if slideAnim and slideAnim:IsA("Animation") and slideAnim.AnimationId ~= "" then
		local ok, t = pcall(function() return animator:LoadAnimation(slideAnim) end)
		if ok and t then
			t.Priority = Enum.AnimationPriority.Action
			t.Looped = false
			tracks.slide = t
			ownTrackSet[t] = true
		end
	end

	-- Dash_Forward, same instance-not-id loading as the slide. Played for EVERY dash
	-- direction for now: the clip is forward-only, so a side or back dash currently rolls
	-- forwards. Directional variants can drop in later exactly the way the walk/run ones are
	-- wired -- the dash already computes a 4-way token for the server.
	local dashAnim = AnimMovement and AnimMovement:FindFirstChild("Dash_Forward")
	if dashAnim and dashAnim:IsA("Animation") and dashAnim.AnimationId ~= "" then
		local ok, t = pcall(function() return animator:LoadAnimation(dashAnim) end)
		if ok and t then
			t.Priority = Enum.AnimationPriority.Action
			t.Looped = false
			tracks.dash = t
			ownTrackSet[t] = true
		end
	end
end

-- The default Roblox Animate script stays enabled (airborne states rely on it), but its
-- walk/idle clips don't cover every joint ours do, so at equal-ish priority they bleed
-- through into a glitchy pose (this is what broke crouch-walking). Whenever we have an
-- active custom animation, forcibly stop anything Animate is playing that isn't ours.
-- Only tracks at our own priority (Action) or lower -- higher-priority clips (emotes,
-- and whatever the combat revamp brings) are intentional and must be left alone.
local function suppressForeignTracks()
	if not ownAnimator then return end
	for _, t in ipairs(ownAnimator:GetPlayingAnimationTracks()) do
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
		local t = tracks[name]
		if name == "dash" then
			-- A dash lasts DASH_DURATION (0.22s). The usual 0.15s crossfade would eat most of
			-- it, and a clip authored longer than the dash would be cut off mid-roll -- so it
			-- snaps in and is time-scaled to finish exactly as the dash does.
			t:Play(0.05)
			if t.Length > 0 then t:AdjustSpeed(t.Length / DASH_DURATION) end
		else
			t:Play(0.15)
		end
	end
end

local function resolveAnim()
	if not hum or not hrp then return nil end
	local state = hum:GetState()

	-- MoveState is published every frame by MovementClient (movement revamp, 2026-08-04).
	-- Reading it instead of re-deriving from WalkSpeed matters now that momentum lives in
	-- the move-vector MAGNITUDE rather than in WalkSpeed -- a sprinting player and a walking
	-- player can share a WalkSpeed for a moment mid-ramp, so the old `WalkSpeed > 20` test
	-- would flicker between clips. The fallback paths below keep this script standalone if
	-- MovementClient ever fails to load.
	local moveState = character and character:GetAttribute("MoveState")

	-- SLIDING OWNS THE RIG, checked before everything else: the slide's air-grace rides out
	-- bumps that flick the Humanoid through Freefall (and re-trigger landing) for a frame or
	-- two, and none of that may flicker the clip. No track loaded (unpublished animation) --
	-- fall through to the normal chain, per the placeholder-skip convention.
	if moveState == "Sliding" and tracks.slide then return "slide" end
	-- Dash sits up here with the slide for the same reason: it is brief and can clip the
	-- Humanoid through a landing/Freefall frame, which must not flicker the clip.
	if moveState == "Dashing" and tracks.dash then return "dash" end

	if isLanding then return "land" end

	if state == Enum.HumanoidStateType.Climbing then
		local vy = hrp.AssemblyLinearVelocity.Y
		if math.abs(vy) < 1 then return "climb_static"
		elseif vy > 0        then return "climb"
		else                      return "climb_down" end
	end

	-- isJumping is event-driven (StateChanged), not polled: the Jumping state is often
	-- too transient for a single RenderStepped frame to ever observe it.
	if isJumping then return "jump" end
	if state == Enum.HumanoidStateType.Freefall then return "jump_loop" end

	local moving = hum.MoveDirection.Magnitude > 0.05

	if moveState == "Dashing" then
		-- PLACEHOLDER_ANIMATION: dash / dodge roll. No clip authored yet, so fall through to
		-- the locomotion pose rather than freezing the rig on a track that plays nothing --
		-- the same placeholder-skip convention the rest of this file uses.
		moveState = nil
	end

	if isCrouching or moveState == "Crouching" or moveState == "CrouchWalking" then
		local crouchMoving = (moveState == "CrouchWalking") or (moveState == nil and moving)
		return crouchMoving and "crouch_walk" or "crouch_idle"
	end

	local function runClip()
		if hum.MaxHealth > 0 and (hum.Health / hum.MaxHealth) < 0.3 then
			return "scaredy_run"
		end
		return "run"
	end

	if moveState == "Sprinting" then return directionalClip(runClip(), character) end
	if moveState == "Walking"   then return directionalClip("walk", character) end
	-- Idle falls through to nil so the default Animate idle keeps playing.
	if moveState == "Idle"      then return nil end

	-- Fallback path (no MovementClient): the pre-revamp inference.
	if not moving then return nil end
	if hum.WalkSpeed > 20 then return runClip() end
	return "walk"
end

-- ─── Character setup ──────────────────────────────────────────────────────
local wasGrounded = false

local function acquireCharacter(char)
	character   = char
	hrp         = char:WaitForChild("HumanoidRootPart", 5)
	hum         = char:WaitForChild("Humanoid", 5)
	isCrouching = false
	currentAnim = nil
	isLanding   = false
	isJumping   = false
	wasGrounded = false

	task.spawn(function()
		local animator = hum and hum:WaitForChild("Animator", 5)
		if animator then
			task.wait(0.1)
			loadAnims(animator)
		end
	end)

	-- Slide sound: a fresh clone per character (the old one died with the old rig). Event-
	-- driven off the same MoveState attribute the clips read, so sound and animation can
	-- never disagree about whether a slide is happening.
	if slideSound then slideSound:Destroy(); slideSound = nil end
	local slideLib = SoundMovement and SoundMovement:FindFirstChild("slide_sound")
	if slideLib and hrp then
		slideSound = slideLib:Clone()
		slideSound.Looped = true -- a slide has no fixed length; Stop() ends it
		slideSound.Parent = hrp
	end
	char:GetAttributeChangedSignal("MoveState"):Connect(function()
		if not slideSound then return end
		local sliding = char:GetAttribute("MoveState") == "Sliding"
		if sliding and not slideSound.IsPlaying then
			slideSound:Play()
		elseif not sliding and slideSound.IsPlaying then
			slideSound:Stop()
		end
	end)

	if hum then
		-- Dying mid-slide freezes the MoveState attribute at "Sliding" (MovementClient's
		-- frame loop stops publishing at 0 HP), so the attribute watcher above would never
		-- see the exit -- stop the loop here or it plays over the corpse.
		hum.Died:Connect(function()
			if slideSound then slideSound:Stop() end
		end)
		hum.StateChanged:Connect(function(_, new)
			if new ~= Enum.HumanoidStateType.Jumping then return end
			-- A fresh jump means we're airborne on purpose -- clear any lingering "land"
			-- pose immediately (bump the token so its delayed auto-clear can't race this).
			-- Without this, spam-jumping re-triggers isLanding for its full ~0.93s and the
			-- jump/fall clip never shows.
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

-- ─── Drivers ───────────────────────────────────────────────────────────────
RunService.RenderStepped:Connect(function()
	playAnim(resolveAnim())

	-- Slide freeze-frame (2026-08-08): hold the clip's final pose for as long as the slide
	-- lasts. Polled here rather than scheduled on a timer so an early slide exit can never
	-- leave a stale AdjustSpeed behind (playAnim's Play resets speed to 1 on the next
	-- slide), and the not-IsPlaying branch covers the frame-drop race where the non-looped
	-- track manages to finish before the freeze lands.
	local st = tracks.slide
	if currentAnim == "slide" and st then
		if not st.IsPlaying then
			st:Play(0.05)
			st.TimePosition = math.max(0, (st.Length or 0) - 0.001)
			st:AdjustSpeed(0)
		elseif st.Speed > 0 and st.Length > 0 and st.TimePosition >= st.Length - 0.1 then
			st:AdjustSpeed(0)
		end
	end
end)

RunService.Heartbeat:Connect(function(dt)
	if not hum or not hrp then return end
	local grounded = hum.FloorMaterial ~= Enum.Material.Air

	-- Movement-stuck watchdog: a Roblox quirk can leave the Humanoid unresponsive to real
	-- WASD input after certain property changes while idle -- first seen with crouch's
	-- WalkSpeed change, which is exactly the state that survives here. A one-time
	-- ChangeState nudge at the moment of the change kept failing under real network
	-- latency (fine in Studio Solo, not for a friend on a real connection), so this
	-- watches for the symptom instead: a movement key genuinely held but MoveDirection
	-- staying ~0, and force-corrects regardless of cause.
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

	if grounded and not wasGrounded then
		local landLen = tracks.land and tracks.land.Length
		triggerLanding((landLen and landLen > 0) and landLen or 0.93)
	end
	wasGrounded = grounded
end)

if player.Character then acquireCharacter(player.Character) end
player.CharacterAdded:Connect(acquireCharacter)

print("[MovementController] Loaded -- locomotion clips + crouch mirror + slide anim/sound (2026-08-07), no camera layer.")
