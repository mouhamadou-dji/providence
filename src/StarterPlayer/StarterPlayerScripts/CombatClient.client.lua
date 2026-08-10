--[[
	CombatClient -- input and presentation for level-based melee (2026-08-09).

	CLIENT OWNS FEEL, SERVER OWNS TRUTH -- the same split MovementClient keeps. This script
	binds the inputs, plays the swing clips and the local cues, and nothing else. It does not
	decide whether a swing lands, what level it was, or whether a guard held: every one of
	those is answered on the server, and every remote below is fired WITH NO PAYLOAD.

	In particular the LEVEL is never sent. The server derives it from its own replicated
	crouch/slide state and hands it BACK on the guard and parry events, so the pose this
	script picks is the level the server actually latched rather than a local guess at it.
	(It used to guess, off the MoveState attribute. The guess was only ever cosmetic, but a
	value the server is already sending is strictly better than one we re-derive.)

	BINDS: LMB = swing. RMB = guard, held for as long as you hold the button.

	THE PARRY IS THE OPENING FRAMES OF THE GUARD (reworked 2026-08-09). There is no separate
	parry input. Pressing guard opens Config.Melee.ParryWindow of parry frames server-side and
	then settles into an ordinary block. The previous design split tap-vs-hold and only fired
	the parry on BUTTON RELEASE, which is precisely why it felt dead -- you had to finish a
	whole tap before the window even opened, and a 0.2s hold threshold delayed the guard too.
	Now the press does both, immediately, with one remote.

	ANIMATION PRIORITY IS Action2, NOT Action. MovementController's suppressForeignTracks
	stops every foreign track at Action or below on each RenderStepped frame -- that is
	exactly what made the old critical animations play for a single frame and vanish.

	THE REACTION LAYER (2026-08-10). Until now this script played swing clips and nothing
	else: a guard was invisible, a parry looked identical to a block, and being hit moved
	nobody. Everything a fight does to a body now has a clip, driven ENTIRELY by server
	events -- the guard pose included. Nothing here is predicted off the local button press,
	because startGuard can refuse (dead, staggered, in hitstun) and a body visibly guarding
	while the server lets every hit through is the worst lie this game could tell.

	The clips are Config.Melee.ReactionAnims. Unauthored entries ("" or rbxassetid://0) are
	treated as ABSENT and fall back, per the house placeholder-skip convention -- so a
	half-authored set degrades instead of freezing the rig on a track that plays nothing.
]]

local Players           = game:GetService("Players")
local UIS               = game:GetService("UserInputService")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Model  = require(Shared:WaitForChild("CombatModel"))

local MCFG = Config.Melee

local remotes     = ReplicatedStorage:WaitForChild("RemoteEvents", 10)
local RE_Swing    = remotes:WaitForChild("RequestSwing", 10)
local RE_Guard    = remotes:WaitForChild("RequestGuard", 10)
local RE_GuardEnd = remotes:WaitForChild("RequestGuardEnd", 10)
-- RequestParry is deliberately NOT bound here any more: raising the guard opens the parry
-- window server-side. The remote still exists for the meleetest mod command and for a
-- future dedicated parry input, but the client never fires it.
local RE_Event    = remotes:WaitForChild("OnMeleeEvent", 10)

local hum, animator

--[[ THREE LAYERS, and the priorities are the whole design:

       Action2  swing clips        -- what you are doing
       Action2  the guard HOLD     -- what you are doing, but persistent
       Action3  one-shot reactions -- what just happened TO you

     Reactions sit a full step above so a flinch, a recoil or a guard break visibly
     interrupts whatever the body was part-way through instead of blending into it.

     The hold shares Action2 with the swings, which WOULD fight if both ever played at once,
     so it is suppressed for as long as any swing or reaction runs and restored by the
     Heartbeat driver the moment they finish. Suppressed, not cancelled: the server lets you
     swing out of a guard and the guard is still up underneath.

     Nothing here may sit at Action or below -- see the header. ]]
local PRI_SWING    = Enum.AnimationPriority.Action2
local PRI_POSE     = Enum.AnimationPriority.Action2
local PRI_REACTION = Enum.AnimationPriority.Action3

local RA = MCFG.ReactionAnims or {}

local tracks = {}      -- swing clips, indexed by chain hit
local reacts = {}      -- name -> track, or an array of tracks for the per-hit sets

local guardActive = false   -- the local BUTTON state (what we have told the server)
local poseHeld    = false   -- the guard the SERVER confirmed. Never the same question.
local poseLevel   = nil
local poseTrack   = nil     -- the hold currently playing, if any
local reactTrack  = nil     -- the one-shot currently playing, if any
local guardBrokeAt = 0      -- see the Hit handler: a break swallows the flinch behind it

-- ── Animation ─────────────────────────────────────────────────────────────
-- An unauthored id is treated as ABSENT so the caller falls back, rather than loading a track
-- that plays nothing and freezes the rig on it. Same convention MovementController uses.
local function isPlaceholder(id)
	return type(id) ~= "string" or id == "" or id == "rbxassetid://0"
end

local function loadClip(anim, id, looped, priority)
	if not anim or isPlaceholder(id) then return nil end
	local a = Instance.new("Animation")
	a.AnimationId = id
	local ok, t = pcall(function() return anim:LoadAnimation(a) end)
	if not ok or not t then return nil end
	t.Priority = priority
	t.Looped = looped
	return t
end

local function loadList(anim, ids, priority)
	local out = {}
	for i, id in ipairs(ids or {}) do out[i] = loadClip(anim, id, false, priority) end
	return out
end

local function loadTracks(anim)
	tracks, reacts = {}, {}
	poseTrack, reactTrack = nil, nil
	if not anim then return end

	for i, id in ipairs(MCFG.Anims or {}) do
		tracks[i] = loadClip(anim, id, false, PRI_SWING)
	end

	-- The hold is the only LOOPED clip here; everything else fires once.
	reacts.guard      = loadClip(anim, RA.Guard, true, PRI_POSE)
	-- A low guard shown in the wrong stance is bad; a guard shown as nothing at all is worse,
	-- so this falls back to the standing hold until the clip exists. See
	-- Config.Melee.ReactionAnims.GuardLow for why that fallback is a known compromise.
	reacts.guardLow   = loadClip(anim, RA.GuardLow, true, PRI_POSE) or reacts.guard
	reacts.parry      = loadClip(anim, RA.Parry, false, PRI_REACTION)
	reacts.guardBreak = loadClip(anim, RA.GuardBreak, false, PRI_REACTION)
	reacts.stagger    = loadClip(anim, RA.Stagger, false, PRI_REACTION) or reacts.guardBreak
	reacts.parried    = loadList(anim, RA.Parried, PRI_REACTION)
	reacts.gotHit     = loadList(anim, RA.GotHit, PRI_REACTION)
end

-- Pick the clip for a chain hit, tolerating a nil or out-of-range hit number and a
-- half-authored list (a missing entry falls back to whatever the first slot holds).
local function clipFor(list, hit)
	if not list or #list == 0 then return nil end
	return list[math.clamp(tonumber(hit) or 1, 1, #list)] or list[1]
end

local function stopSwings(fade)
	for _, t in pairs(tracks) do
		if t.IsPlaying then t:Stop(fade or 0.05) end
	end
end

local function anySwingPlaying()
	for _, t in pairs(tracks) do
		if t.IsPlaying then return true end
	end
	return false
end

--[[ Start a clip at a speed that makes it LAST exactly `fitTo` seconds.

     Every window in this system is a server-side number -- the windup, the parry window, the
     hitstun, the stagger -- and a clip authored to a different length either keeps playing
     after the player has control back or leaves them posed and idle inside a stun they can
     still feel. Guarded on Length, which is 0 until the asset finishes streaming.

     Restarting is done by hand rather than by Play(): Play on an already-playing track is a
     no-op, so the second flinch of a chain would never show. ]]
local function startFitted(track, fitTo)
	local speed = 1
	if fitTo and fitTo > 0 and track.Length > 0 then speed = track.Length / fitTo end
	if track.IsPlaying then
		track.TimePosition = 0
		track:AdjustSpeed(speed)
	else
		track:Play(0.05, 1, speed)
	end
end

local function playSwing(hitNum)
	local t = tracks[hitNum]
	if not t then return end
	-- A swing is a deliberate action and outranks whatever reaction was still finishing.
	if reactTrack and reactTrack.IsPlaying then reactTrack:Stop(0.05) end
	reactTrack = nil
	for i, other in pairs(tracks) do
		if i ~= hitNum and other.IsPlaying then other:Stop(0.05) end
	end
	-- Windup plus the committed tail is the real length of a swing (0.45 + 0.20 = 0.65).
	-- NOT ActiveWindow -- that is now a single hitbox frame at the boundary between the two,
	-- so fitting the clip to it would play the whole animation in one frame.
	startFitted(t, (MCFG.Windup or 0.45) + (MCFG.SwingPhase or 0.20))
end

-- Reactions outrank the hold: drop the pose so the two never blend, and let updatePose put it
-- back once this finishes.
local function playReaction(track, fitTo)
	-- The swing dies FIRST, and dies even when the clip turns out to be missing: the server has
	-- already invalidated it, so an unauthored reaction must not leave a strike playing out
	-- that cannot land.
	stopSwings(0.05)
	if not track then return end
	if reactTrack and reactTrack ~= track and reactTrack.IsPlaying then reactTrack:Stop(0.05) end
	if poseTrack and poseTrack.IsPlaying then poseTrack:Stop(0.05) end
	poseTrack = nil
	reactTrack = track
	startFitted(track, fitTo)
end

local function poseClip()
	if poseLevel == Model.Level.Low then return reacts.guardLow end
	return reacts.guard
end

--[[ The hold is DRIVEN every frame rather than toggled on the guard events, for the same
     reason MovementController resolves its locomotion clip every frame: the pose has to yield
     to swings and reactions and come back on its own afterwards, and a toggle would need
     every one of those exit paths to remember to restore it. ]]
local function updatePose()
	local busy = anySwingPlaying() or (reactTrack ~= nil and reactTrack.IsPlaying)
	local alive = hum ~= nil and hum.Health > 0
	local want = (poseHeld and alive and not busy) and poseClip() or nil
	if poseTrack == want then return end
	if poseTrack and poseTrack.IsPlaying then poseTrack:Stop(0.15) end
	poseTrack = want
	if want and not want.IsPlaying then want:Play(0.15) end
end

-- No dedicated block-impact clip exists, so an absorbed hit restarts the hold from frame 0:
-- the guard visibly re-raises. It reads as taking the blow on the guard and costs no asset.
local function rebrace()
	if poseTrack and poseTrack.IsPlaying then poseTrack.TimePosition = 0 end
end

-- ── Input ─────────────────────────────────────────────────────────────────
local function requestGuard()
	if guardActive then return end
	guardActive = true
	if RE_Guard then RE_Guard:FireServer() end
end

local function releaseGuard()
	if not guardActive then return end
	guardActive = false
	if RE_GuardEnd then RE_GuardEnd:FireServer() end
end

UIS.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		if RE_Swing then RE_Swing:FireServer() end
	elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
		-- Immediate, on the press. The server opens the parry window as part of raising the
		-- guard, so there is nothing to wait for and no second remote to send.
		requestGuard()
	end
end)

UIS.InputEnded:Connect(function(input)
	if input.UserInputType ~= Enum.UserInputType.MouseButton2 then return end
	releaseGuard()
end)

-- ── Server events ─────────────────────────────────────────────────────────
if RE_Event then
	RE_Event.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then return end
		local kind, role = payload.kind, payload.role

		if kind == "Swing" then
			playSwing(payload.hit or 1)
			-- ATTACK DASH FLOW (2026-08-10): Lunge and Aerial launch the exact same
			-- steerable, decelerating push MovementClient's real Q-dash uses, off the same
			-- Config.Movement.Dash numbers -- "as if you did another dash + attack". The
			-- server only NAMES the kind; MovementClient owns the physics, the same split
			-- every other movement feel in this game keeps.
			if (payload.attack == "Lunge" or payload.attack == "Aerial")
				and _G.MovementClient and _G.MovementClient.attackDash then
				_G.MovementClient.attackDash()
			end

		elseif kind == "Guard" then
			-- Server-confirmed, which is why this is not set in requestGuard: startGuard
			-- refuses outright when dead, staggered or in hitstun.
			poseHeld, poseLevel = true, payload.level

		elseif kind == "GuardEnd" then
			poseHeld, poseLevel = false, nil

		elseif kind == "Parry" then
			-- The opening frames of the guard, played whether or not they end up catching
			-- anything: the flash is what tells you the window opened at all.
			poseLevel = payload.level
			playReaction(reacts.parry, MCFG.ParryWindow)

		elseif kind == "Parried" then
			if role == "attacker" then
				-- Read. The recoil is stretched over the whole stagger the server just applied,
				-- so the body is still recovering for exactly as long as the input is dead.
				playReaction(clipFor(reacts.parried, payload.hit), MCFG.ParryStagger)
			end
			-- role == "victim" deliberately does nothing: we are the one who read it, and the
			-- parry flash from the "Parry" event is already on screen mid-follow-through.
			-- Restarting it here would reset the clip at its most expressive moment.

		elseif kind == "Blocked" then
			if role ~= "attacker" then rebrace() end

		elseif kind == "Hit" then
			-- ROLE IS LOAD-BEARING. Both sides receive kind == "Hit"; keying on the kind alone
			-- is exactly the bug the server's fireExchange header calls out, and here it would
			-- have given the ATTACKER the victim's flinch on every landed swing.
			--
			-- A hit that arrives right behind a guard break is the SAME blow -- the guard
			-- collapsed and it landed -- so the break clip keeps the body and the flinch is
			-- dropped rather than cutting it off two frames in.
			if role ~= "attacker" and (os.clock() - guardBrokeAt) > 0.2 then
				playReaction(clipFor(reacts.gotHit, payload.hit), MCFG.HitLockout)
			end

		elseif kind == "GuardBreak" then
			-- The guard collapsed under a block this player could not pay the stamina for. The
			-- server's own GuardEnd is right behind this; setting the flag here too means the
			-- pose drops on the same frame as the clip that replaces it.
			poseHeld, poseLevel = false, nil
			guardBrokeAt = os.clock()
			playReaction(reacts.guardBreak, MCFG.HitLockout)

		elseif kind == "Staggered" then
			-- Cut the swing either way: the server has already invalidated it, so letting the
			-- animation finish would show a strike that cannot land.
			if payload.cause == "Parried" then
				-- The Parried recoil is one event behind this and covers the same window with a
				-- clip that actually shows what happened. Playing the generic pose first would
				-- start two clips back to back over the same 0.8s.
				stopSwings(0.1)
			else
				playReaction(reacts.stagger, payload.duration)
			end
		end
	end)
end

-- ── Character lifecycle ───────────────────────────────────────────────────
local function acquire(char)
	hum = char:WaitForChild("Humanoid", 10)
	animator = hum and hum:WaitForChild("Animator", 10)
	-- Every piece of pose state resets on SPAWN, not just on join -- the server's onCharacter
	-- does the same, and for the same reason: dying mid-guard otherwise leaves the fresh
	-- character holding a pose for a guard that no longer exists on either side.
	guardActive = false
	poseHeld, poseLevel = false, nil
	poseTrack, reactTrack = nil, nil
	guardBrokeAt = 0
	if animator then
		task.wait(0.1) -- same settle the locomotion loader uses before LoadAnimation
		loadTracks(animator)
	end
end

-- The hold's driver. Heartbeat rather than RenderStepped: this only starts and stops tracks,
-- and none of it needs to run before the camera does.
RunService.Heartbeat:Connect(updatePose)

if player.Character then task.spawn(acquire, player.Character) end
player.CharacterAdded:Connect(acquire)

print(string.format(
	"[CombatClient] Loaded -- LMB swing / RMB guard (first %.2fs are parry frames), %d swing clips",
	MCFG.ParryWindow or 0.25, #(MCFG.Anims or {})))
