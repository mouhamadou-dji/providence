--[[
	MeleeCombat -- the level-based combat system (2026-08-09).

	This is the revamp the 2026-08-02 teardown left room for. It registers itself at
	_G.CombatSystem, which is the ONLY sanctioned way in: CombatCore keeps every old global
	name alive and delegates its inert combat questions here by name.

	WHAT IT DELIBERATELY DOES NOT DO: it does not register `applyDamage`. That hook replaces
	CombatCore's entire damage funnel -- godmode, deep-meditation immunity, the i-frame gate,
	the damage history that refundRecentDamage depends on, and the combat tag would all
	silently vanish with it. Damage goes THROUGH the funnel instead, by calling it.

	THE MECHANIC. Every attack has a LEVEL: swung from a crouch or a slide it is Low,
	otherwise High. Guard and parry carry a level too, from the same stance. A defence only
	works if its level MATCHES the incoming attack -- guard high against a low sweep and it
	lands on you. That single rule is what makes stance a read rather than a movement option,
	and it lives in ReplicatedStorage.Shared.CombatModel so it can be tested without a rig.

	SERVER DERIVES THE LEVEL, ALWAYS. The client picks its own intent for animation purposes,
	but never sends it -- every melee remote here takes no payload whatsoever. The character's
	MoveState attribute is client-written and does not replicate, so the server reads the
	replicated CrouchActive attribute and MovementSystem.isSliding instead. A client cannot
	claim to be crouching.

	THE REACTION GRACE. A caught hit is not resolved on contact: it is held for
	Config.Melee.ReactionGrace and re-checked, so a guard or parry that STARTS inside that
	window still saves you. It is ping forgiveness that costs the attacker nothing, and
	because both the contact time and the re-check are server-side there is nothing to spoof.

	Timing is os.clock() everywhere. CombatCore's header calls out mixing that with tick() as
	a silent-correctness hazard, and the old stack mixed them freely.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared  = ReplicatedStorage:WaitForChild("Shared")
local Config  = require(Shared:WaitForChild("Config"))
local Model   = require(Shared:WaitForChild("CombatModel"))

local MCFG  = Config.Melee
local Level = Model.Level

-- Same local getOrCreate every manager uses (the canonical declarations live in
-- Shared.RemoteEvents; this is the accepted duplication so load order never matters).
local reFolder = ReplicatedStorage:FindFirstChild("RemoteEvents") or (function()
	local f = Instance.new("Folder"); f.Name = "RemoteEvents"; f.Parent = ReplicatedStorage; return f
end)()
local function getOrCreateRE(name)
	local r = reFolder:FindFirstChild(name)
	if r then return r end
	r = Instance.new("RemoteEvent"); r.Name = name; r.Parent = reFolder
	return r
end

local RE_Swing    = getOrCreateRE("RequestSwing")
local RE_Guard    = getOrCreateRE("RequestGuard")
local RE_GuardEnd = getOrCreateRE("RequestGuardEnd")
local RE_Parry    = getOrCreateRE("RequestParry")
local RE_Event    = getOrCreateRE("OnMeleeEvent")

local SoundsCombat = (function()
	local s = ReplicatedStorage:FindFirstChild("_Sounds")
	return s and s:FindFirstChild("Combat")
end)()

-- ── Per-player state ──────────────────────────────────────────────────────
-- Fails CLOSED: every gate treats a missing record as "blocked", so a player mid-respawn
-- cannot swing through the gap.
local pState = {}

local function initState(userId)
	pState[userId] = {
		chain          = Model.newChain(),
		swingToken     = 0,
		lastSwingAt    = 0,
		guarding       = false,
		guardLevel     = nil,
		parryStartedAt = nil,
		parryLevel     = nil,
		parryCooldownUntil = 0,
		parryIntercepted   = false, -- did this parry actually catch something (whiff bookkeeping)
		staggeredUntil = 0,
		hitLockUntil   = 0,
		combatState    = "Idle",
		cooldowns      = {},
		-- When crouch was last RELEASED. Attacking inside Config.Melee.UpTilt.Window of this
		-- turns the swing into an up-tilt. Stamped from the CrouchActive attribute, which
		-- MovementManager writes server-side (so it replicates and a client cannot fake it).
		uncrouchedAt   = nil,
	}
end

local function getPS(player) return player and pState[player.UserId] end

for _, p in ipairs(Players:GetPlayers()) do initState(p.UserId) end
Players.PlayerAdded:Connect(function(p) initState(p.UserId) end)
Players.PlayerRemoving:Connect(function(p) pState[p.UserId] = nil end)

local function charParts(player)
	local char = player and player.Character
	if not char then return nil, nil, nil end
	return char, char:FindFirstChildOfClass("Humanoid"), char:FindFirstChild("HumanoidRootPart")
end

-- Per-action rate limit. No shared utility exists in this repo -- every manager carries its
-- own copy of this shape (ModManager, DiscordManager, and the archived combat stack), so
-- this is the house pattern rather than a missing abstraction.
local function checkRateLimit(s, action, cooldown)
	local now = os.clock()
	local last = s.cooldowns[action] or 0
	if now - last < cooldown then return false end
	s.cooldowns[action] = now
	return true
end

-- ── PlayerSwung signal ────────────────────────────────────────────────────
-- WolfManager polls for _G.CombatSystem.PlayerSwung for ~30s after server start to drive its
-- read-parry, then gives up quietly. Exposing it costs nothing and makes wolves able to react
-- to swings the moment this system loads.
local swungBindable = Instance.new("BindableEvent")
local PlayerSwung = {}
function PlayerSwung:Connect(fn) return swungBindable.Event:Connect(fn) end

-- ── Level derivation (SERVER TRUTH) ───────────────────────────────────────
-- MoveState is a client attribute and never replicates, so it is unusable here. CrouchActive
-- is written by MovementManager on the server and does replicate; isSliding is server state.
--[[ Watch crouch release so an up-tilt has something to key off.

     CrouchActive is written by MovementManager on the SERVER, so unlike MoveState it
     replicates and is not client-authored -- which is exactly why the up-tilt window keys
     off it rather than off anything the client says. SlideActive gets the same treatment:
     standing up out of a slide is the same gesture. ]]
local function watchStanceRelease(player, char)
	local function onRelease()
		local s = getPS(player)
		if s then s.uncrouchedAt = os.clock() end
	end
	char:GetAttributeChangedSignal("CrouchActive"):Connect(function()
		if char:GetAttribute("CrouchActive") == false then onRelease() end
	end)
	char:GetAttributeChangedSignal("SlideActive"):Connect(function()
		if char:GetAttribute("SlideActive") == false then onRelease() end
	end)
end

local function levelFor(player)
	local char = player and player.Character
	if char and char:GetAttribute("CrouchActive") == true then return Level.Low end
	local ms = _G.MovementSystem
	if ms and ms.isSliding and ms.isSliding(player) then return Level.Low end
	return Level.High
end

local function setCombatState(player, state)
	local s = getPS(player)
	if not s then return end
	s.combatState = state
	-- CombatCore mirrors this onto the character every Heartbeat; CameraClient's combat
	-- framing and EmoteWheelClient's blocked-state list both read it and have been waiting
	-- for a producer since the teardown.
	local cm = _G.CombatManager
	if cm and cm.setCombatState then cm.setCombatState(player, state) end
end

--[[ SPEED IS OWNED BY NAMED SOURCES (2026-08-10), not by a shared slot.

     Each combat state registers its own key and clears its own key. It never "restores to 1",
     because restoring to a constant asserts a value this system does not own -- that is
     precisely how tapping guard during a swing used to leave the player at 4 studs/s forever:
     the swing's slow landed, its restore was skipped because an unrelated state flag had
     changed, and nothing else was scheduled to write speed again.

     Clearing a key is idempotent and order-independent, so a restore can be called twice, out
     of order, or after another source took over, and still be correct. ]]
local FW = Config.Movement.FlowWeights

local function flowSet(player, name, weight, walkMult, opts)
	local mf = _G.MovementFlow
	if mf then mf.set(player, name, weight, walkMult, nil, opts) end
end

local function flowClear(player, name)
	local mf = _G.MovementFlow
	if mf then mf.clear(player, name) end
end

-- Every key a swing can own. Only "Windup" is registered today -- the swing phase itself
-- deliberately owns no speed source since 2026-08-10 -- but "Attack" stays in the sweep so a
-- future attack that DOES want one cannot leak it by forgetting to update this list.
-- Clearing an unregistered key is a no-op, so the insurance is free.
local SWING_KEYS = { "Windup", "Attack" }

local function clearSwingSpeed(player)
	for _, k in ipairs(SWING_KEYS) do flowClear(player, k) end
end

local function fireEvent(player, payload)
	if player then RE_Event:FireClient(player, payload) end
end

--[[ Tell both sides about an exchange.

     ROLE IS EXPLICIT, and that matters. Both parties used to receive the same `kind` string
     ("Hit"), distinguishable only by which of attackerName/victimName happened to be set --
     so the first client handler keyed on kind == "Hit" would have given the ATTACKER the
     victim's flinch. That is exactly the bug class that put the killer's screen through the
     victim's death vignette, so the discriminator is a first-class field here.

     victimPlayer is nil for every NPC, wolf, shroom and the CombatDummy, so nothing may
     dereference it unguarded -- doing so previously threw inside the swing coroutine and
     left the attacker stuck at attack walk-speed until their next swing. ]]
local function fireExchange(kind, attacker, victimPlayer, extra)
	local victimName = victimPlayer and victimPlayer.Name or "NPC"
	local base = extra or {}
	local toVictim = table.clone(base)
	toVictim.kind, toVictim.role, toVictim.attackerName = kind, "victim", attacker.Name
	fireEvent(victimPlayer, toVictim)

	local toAttacker = table.clone(base)
	toAttacker.kind, toAttacker.role, toAttacker.victimName = kind, "attacker", victimName
	fireEvent(attacker, toAttacker)
end

local function soundIdOf(name)
	if not name or not SoundsCombat then return nil end
	local template = SoundsCombat:FindFirstChild(name)
	local id = template and template.SoundId
	-- Several entries in _Sounds.Combat are still unauthored placeholders; treat those as
	-- absent so callers can fall back rather than playing nothing.
	if not id or id == "" or id == "rbxassetid://0" then return nil end
	return id
end

local function playSound3D(parent, name, volume, pitchMult)
	if not parent then return end
	local id = soundIdOf(name)
	if not id then return end
	local snd = Instance.new("Sound")
	snd.SoundId = id
	snd.Volume = volume or 0.4
	snd.PlaybackSpeed = (0.92 + math.random() * 0.16) * (pitchMult or 1)
	snd.Parent = parent
	snd:Play()
	-- Destroy on Ended rather than a fixed timer -- a fixed delay can kill a slow-streaming
	-- asset before it ever starts, which is what read as "combat sounds sometimes not
	-- playing" in the old stack. The 8s backstop covers a clip that never fires Ended.
	local cleaned = false
	local function cleanup()
		if cleaned then return end
		cleaned = true
		if snd.Parent then snd:Destroy() end
	end
	snd.Ended:Once(cleanup)
	task.delay(8, cleanup)
end

--[[ A parry needs to be AUDIBLE or the player cannot tell a parry from a block.
     Parry_Perfect exists in _Sounds.Combat but may still be an unauthored placeholder, so
     when it is missing this falls back to the block sound pitched up — clearly the same
     family of impact, clearly not the same event. ]]
local function playParrySound(parent)
	if soundIdOf(MCFG.ParrySound) then
		playSound3D(parent, MCFG.ParrySound, 0.55)
	else
		playSound3D(parent, MCFG.BlockSound, 0.55, MCFG.ParryPitchFallback or 1.6)
	end
end

-- ── Action gating ─────────────────────────────────────────────────────────
local function isBusy(s, now)
	if not s then return true end -- fail closed
	if now < s.staggeredUntil then return true end
	if now < s.hitLockUntil then return true end
	return false
end

--[[ The EXTERNAL seam, and deliberately NARROWER than isBusy.

     isBusy answers "can this player start an attack" -- staggered or inside the hit lockout
     both say no. This one answers "is this player incapacitated", because it gates things
     that have nothing to do with attacking.

     MovementManager.processCrouch is the one that bit us: crouch is a TOGGLE, so refusing it
     during hitstun ate the RELEASE and left the player stuck crouched until they pressed and
     released again. Being briefly unable to swing must not mean being unable to stand up, so
     only a real stagger blocks here. ]]
local function isActionBlocked(player)
	local s = getPS(player)
	if not s then return true end
	local _, hum = charParts(player)
	if not hum or hum.Health <= 0 then return true end
	return os.clock() < s.staggeredUntil
end

-- ── Stagger ───────────────────────────────────────────────────────────────
--[[ `cause` is PRESENTATION ONLY and never changes what a stagger does. A stagger caused by
     a parry already has the attacker's dedicated Parried recoil clip arriving from
     fireExchange a moment later, so the client is told the cause and skips the generic
     stagger pose rather than starting two clips back to back over the same 0.8s.

     Optional and THIRD, so the (player, duration) call sites on the registered surface --
     CombatCore's delegate and anything reaching it through _G.CombatManager -- are untouched
     and keep the generic pose. ]]
local function applyStagger(player, duration, cause)
	local s = getPS(player)
	if not s then return end
	duration = duration or MCFG.ParryStagger
	local now = os.clock()
	s.staggeredUntil = math.max(s.staggeredUntil, now + duration)
	-- Cancel anything in flight: the swing coroutine checks this token before it ever
	-- activates a hitbox, so a staggered attacker's pending swing simply never lands.
	s.swingToken += 1
	s.chain = Model.newChain()
	setCombatState(player, "Staggered")
	-- A stagger cancels the swing outright, so its keys go too. Stagger outranks Guard, so a
	-- player staggered mid-guard is correctly held at stagger speed until it expires and the
	-- guard's own key resumes -- no coordination between the two needed.
	clearSwingSpeed(player)
	flowSet(player, "Stagger", FW.Stagger, MCFG.StaggerSpeedMult)
	fireEvent(player, { kind = "Staggered", duration = duration, cause = cause })
	task.delay(duration, function()
		local cur = getPS(player)
		if not cur or os.clock() < cur.staggeredUntil then return end
		-- Clear unconditionally. The old version only restored when combatState was still
		-- "Staggered", so anything that changed that flag first left the stagger slow stuck.
		flowClear(player, "Stagger")
		if cur.combatState == "Staggered" then
			setCombatState(player, cur.guarding and "Blocking" or "Idle")
		end
	end)
end

-- ── Guard ─────────────────────────────────────────────────────────────────
--[[ Forward declaration: raising a guard OPENS the parry window, so startGuard needs
     startParry, which in turn reads guard state. ]]
local startParry

local function startGuard(player)
	local s = getPS(player)
	if not s or s.guarding then return end
	if isActionBlocked(player) then return end
	s.guarding = true
	-- The level is latched AT THE PRESS, not read per hit. Otherwise standing up mid-guard
	-- would silently convert a low guard into a high one and the read would be unloseable.
	s.guardLevel = levelFor(player)
	setCombatState(player, "Blocking")
	local ms = _G.MovementSystem
	-- stopSprint BEFORE registering the guard. It used to run one line after, and since it
	-- cleared the sprint state it also rewrote speed -- overwriting the guard slow that had
	-- just been set. Order no longer strictly matters now that the two own separate keys, but
	-- doing it first keeps the intent obvious.
	if ms and ms.stopSprint then ms.stopSprint(player) end
	flowSet(player, "Guard", FW.Guard, MCFG.GuardSpeedMult)
	-- THE GUARD POSE IS SERVER-CONFIRMED, never predicted on the press. startGuard refuses
	-- outright when the player is dead, staggered or in hitstun, and a client that painted the
	-- pose optimistically on mouse-down would stand there visibly guarding while the server let
	-- every hit through -- the worst possible lie for a mechanic read off body language.
	-- Fired BEFORE startParry so the hold is up before the parry flash plays over it.
	fireEvent(player, { kind = "Guard", level = s.guardLevel })
	-- THE PARRY IS THE FIRST FRAMES OF THE GUARD. Opening it here rather than on a separate
	-- input is the whole responsiveness fix: the window now begins the instant the button
	-- goes down, instead of waiting for a tap to complete.
	startParry(player)
end

local function endGuard(player)
	local s = getPS(player)
	if not s or not s.guarding then return end
	s.guarding = false
	s.guardLevel = nil
	-- Unconditional, and that matters: endGuard is also called SERVER-SIDE when a block
	-- collapses on empty stamina, and the client has no other way to learn about that one.
	-- Without this the pose would stay up on a guard that no longer exists.
	fireEvent(player, { kind = "GuardEnd" })
	-- Unconditional, like the fireEvent above. Previously this only released the speed when
	-- combatState was still "Blocking", so a swing that had overwritten that flag left the
	-- guard slow applied to a player who was no longer guarding.
	flowClear(player, "Guard")
	if s.combatState == "Blocking" then
		setCombatState(player, "Idle")
	end
end

-- ── Parry ─────────────────────────────────────────────────────────────────
--[[ Opens the parry window. Called by startGuard, never bound to an input of its own.

     A parry that CONNECTS costs nothing (ParryCooldown 0) -- reading correctly should not
     be punished. Opening frames that catch nothing lock the next attempt for
     ParryWhiffCooldown, so raising guard is still free but spamming it for the parry frames
     is not. Guarding itself is never blocked by the cooldown; only the window is. ]]
function startParry(player)
	local s = getPS(player)
	if not s then return end
	local now = os.clock()
	if now < s.parryCooldownUntil then
		-- Guard still went up (startGuard already ran) -- you just get no parry frames.
		fireEvent(player, { kind = "Denied", reason = "parrycooldown" })
		return
	end
	-- Hitstun is deliberately NOT a block here: parry is the escape from a combo, and the
	-- old stack made the same call for the same reason.
	if now < s.staggeredUntil then
		fireEvent(player, { kind = "Denied", reason = "staggered" })
		return
	end
	local _, hum = charParts(player)
	if not hum or hum.Health <= 0 then return end

	s.parryStartedAt = now
	s.parryLevel = levelFor(player)
	s.parryIntercepted = false
	fireEvent(player, { kind = "Parry", level = s.parryLevel })

	-- Whiff resolution. A parry that never intercepted anything eats the harsher cooldown,
	-- so mashing costs strictly more than reading -- without this, tapping every swing is
	-- free and there is no reason not to.
	task.delay(MCFG.ParryWindow, function()
		local cur = getPS(player)
		if not cur or cur.parryStartedAt ~= now then return end -- superseded by a newer parry
		cur.parryStartedAt = nil
		cur.parryLevel = nil
		if not cur.parryIntercepted then
			cur.parryCooldownUntil = os.clock() + MCFG.ParryWhiffCooldown
			fireEvent(player, { kind = "ParryWhiff" })
			local _, _, hrp = charParts(player)
			playSound3D(hrp, MCFG.ParryWhiffSound, 0.35)
		end
	end)
end

-- The victim's defensive posture, as the model wants it.
local function defenceOf(victimPlayer)
	local vs = getPS(victimPlayer)
	if not vs then return nil end
	return {
		guarding       = vs.guarding,
		guardLevel     = vs.guardLevel,
		parryStartedAt = vs.parryStartedAt,
		parryLevel     = vs.parryLevel,
	}
end

-- ── Hitbox ────────────────────────────────────────────────────────────────
local function hitboxQuery(attackerChar, hrp)
	local boxCF = hrp.CFrame * CFrame.new(MCFG.HitboxOffset)
	if _G.DEBUG_HITBOXES then _G.DEBUG_HITBOXES(boxCF, MCFG.HitboxSize, "Melee") end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { attackerChar }
	params.MaxParts = MCFG.MaxHitParts or 24
	return workspace:GetPartBoundsInBox(boxCF, MCFG.HitboxSize, params)
end

-- The old system had no line-of-sight test at all and cheerfully hit through walls.
local function hasLineOfSight(attackerChar, fromPos, victimChar, toPos)
	if not MCFG.RequireLineOfSight then return true end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { attackerChar, victimChar }
	local delta = toPos - fromPos
	if delta.Magnitude < 0.01 then return true end
	local hit = workspace:Raycast(fromPos, delta, params)
	return hit == nil
end

-- ── Resolution ────────────────────────────────────────────────────────────
--[[ `atk` describes the swing once, so it can be threaded through resolution without a
     growing tail of positional arguments:
        { attacker, char, hitNum, isFinisher, level, kind }
     It is built once per swing in processSwing and never mutated afterwards, which also
     means a swing's level cannot change out from under a deferred resolution. ]]
local function applyOutcome(outcome, atk, victimChar, victimPlayer, hum)
	local attacker     = atk.attacker
	local attackerChar = atk.char
	local hitNum       = atk.hitNum
	local isFinisher   = atk.isFinisher
	local level        = atk.level
	local kind         = atk.kind
	if not hum or hum.Health <= 0 then return end
	local vHRP = victimChar:FindFirstChild("HumanoidRootPart")

	if outcome == "Parried" then
		local vs = getPS(victimPlayer)
		if vs then
			vs.parryIntercepted = true
			vs.parryStartedAt = nil
			vs.parryLevel = nil
			-- A connected parry costs NOTHING (ParryCooldown is 0): the whiff penalty is what
			-- makes mashing expensive, so landing the read must not also be taxed.
			vs.parryCooldownUntil = os.clock() + (MCFG.ParryCooldown or 0)
		end
		applyStagger(attacker, MCFG.ParryStagger, "Parried")
		playParrySound(vHRP)
		-- Both sides hear it: the attacker needs to know they were read, not just punished.
		local aHRP = attackerChar and attackerChar:FindFirstChild("HumanoidRootPart")
		if aHRP and aHRP ~= vHRP then playParrySound(aHRP) end
		-- hitNum rides along so the attacker's recoil clip indexes by chain hit, exactly as the
		-- archived stack did (RE_PlayCombatAnim:FireClient(attacker, "M1Parried", chainCount)).
		fireExchange("Parried", attacker, victimPlayer, { level = level, hit = hitNum })
		return
	end

	if outcome == "Blocked" then
		-- The cost is charged on the hit ABSORBED, not per second of holding: guarding
		-- nothing is free, guarding a real chain is not. drain() is all-or-nothing, and a
		-- block you cannot afford simply fails through to a hit.
		local sm = _G.StaminaManager
		local afforded = true
		if sm and sm.drain then afforded = sm.drain(victimPlayer, MCFG.GuardStaminaPerHit) end
		if afforded then
			playSound3D(vHRP, MCFG.BlockSound, 0.45)
			fireExchange("Blocked", attacker, victimPlayer, { level = level })
			return
		end
		-- Out of stamina: the guard collapses and the hit lands. The cue goes out BEFORE
		-- endGuard so "GuardBreak" arrives ahead of the plain "GuardEnd" that endGuard fires --
		-- reversed, the collapse would read as an ordinary button release.
		fireEvent(victimPlayer, { kind = "GuardBreak" })
		endGuard(victimPlayer)
	end

	-- HIT. Damage goes through CombatCore's funnel, which owns godmode, meditation immunity,
	-- the i-frame gate, damage history and the combat tag. Never reimplemented here.
	local cm = _G.CombatManager
	local profile = Model.profileFor(kind, MCFG)
	-- The chain's finisher bonus applies to chain hits only; the contextual attacks carry
	-- their own flat figures.
	local knockForce = (kind == Model.Kind.Chain)
		and Model.knockbackFor(isFinisher, MCFG) or profile.knockback

	if cm and cm.applyDamage then
		cm.applyDamage(hum, profile.damage, victimPlayer, "Player")
	else
		hum:TakeDamage(profile.damage)
	end

	if cm and cm.applyKnockback then
		local ok, spec = pcall(cm.applyKnockback, attackerChar, victimChar, knockForce)
		-- VERTICAL. applyKnockback only builds a planar shove, so an up-tilt's launch and an
		-- aerial's slam ride along as a SECOND contribution -- contributions vector-sum, so
		-- the two combine rather than one replacing the other.
		--
		-- Gating on a non-nil spec is doing real work: applyKnockback returns nil precisely
		-- when the victim was rage-immune or immovable, so this inherits all of its immunity,
		-- KnockbackResist and talent handling instead of duplicating (and drifting from) it.
		if ok and spec and profile.vertical ~= 0 then
			local vm = _G.VelocityManager
			if vm and vm.push then
				pcall(vm.push, victimChar, {
					planar   = Vector3.zero, -- required field; the horizontal already landed above
					vertical = profile.vertical,
					duration = 0.25,
					decay    = "linear",
				})
			end
		end
	end

	local vs = getPS(victimPlayer)
	if vs then
		-- Being hit interrupts: the in-flight swing is invalidated and the chain resets, so
		-- trading blindly loses to landing first.
		vs.swingToken += 1
		vs.chain = Model.newChain()
		vs.hitLockUntil = math.max(vs.hitLockUntil, os.clock() + (MCFG.HitLockout or 0.7))
		-- That invalidated swing bails out of its own coroutine without reaching its cleanup,
		-- so its keys are ours to release. Clearing named keys means we do not have to know
		-- whether the victim is also guarding -- their Guard key is untouched and simply
		-- becomes the winner again.
		clearSwingSpeed(victimPlayer)
		if vs.combatState == "Attacking" then
			setCombatState(victimPlayer, vs.guarding and "Blocking" or "Idle")
		end
	end

	-- KILL ATTRIBUTION. Humanoid.Died carries no notion of who did it, so the damage source
	-- has to leave the trail: LoreManager's death hook reads these to keep the KILLER out of
	-- the witnessed-a-death crowd. Without it the killer catches the Anxiety vignette and a
	-- permanent +10 Sanity on every kill, because they are always inside the 30-stud witness
	-- radius of someone they just hit from 5 studs away.
	victimChar:SetAttribute("LastHitBy", attacker.UserId)
	victimChar:SetAttribute("LastHitAt", os.clock())

	local hitSounds = MCFG.HitSounds or {}
	playSound3D(vHRP, hitSounds[math.clamp(hitNum, 1, #hitSounds)], 0.45)
	fireExchange("Hit", attacker, victimPlayer, { level = level, hit = hitNum })
end

local function resolveAgainst(atk, victimChar, victimPlayer, hum)
	local level = atk.level
	-- i-frames (dash/dodge) beat everything, and short-circuit before the grace window so a
	-- dodged swing costs the defender no stamina and no parry.
	local cm = _G.CombatManager
	if victimPlayer and cm and cm.hasIframes and cm.hasIframes(victimPlayer) then return end

	local now = os.clock()
	local outcome = Model.resolve(level, defenceOf(victimPlayer), now, MCFG)

	if not Model.shouldDefer(outcome) then
		applyOutcome(outcome, atk, victimChar, victimPlayer, hum)
		return
	end

	-- THE REACTION GRACE. Only a would-be Hit is deferred -- a parry or block is already the
	-- best result available to the defender, and waiting could only take it away.
	task.delay(MCFG.ReactionGrace, function()
		if not victimChar.Parent or hum.Health <= 0 then return end
		if victimPlayer and cm and cm.hasIframes and cm.hasIframes(victimPlayer) then return end
		local late = Model.resolve(level, defenceOf(victimPlayer), os.clock(), MCFG)
		applyOutcome(late, atk, victimChar, victimPlayer, hum)
	end)
end

-- ── Swing ─────────────────────────────────────────────────────────────────
--[[ MOVEMENT CONTEXT -- what the server believes you were doing when you swung.

     THE PROBLEM. A player's character is client-owned, so the server's copy of the Humanoid
     lags behind the client's. `FloorMaterial == Air` was the only airborne signal, and it is
     among the SLOWEST things to replicate: jump and swing immediately and the server still
     saw you standing, so the swing resolved as an ordinary chain hit. That is the "I have to
     wait a bit before the aerial registers" report exactly.

     THE FIX is not to trust the client -- it is to read faster-replicating signals. Velocity
     and position stream continuously at roughly frame rate; Humanoid STATE changes on the
     transition; FloorMaterial trails all of them. Taking ANY of them as sufficient means the
     server recognises the jump on essentially the first frame it could possibly know about it.

     Deliberately NOT a client payload. Every melee remote is payload-free and the attack
     LEVEL depends on this context, so a client that could assert its own stance could claim
     a low attack while standing and beat a high guard -- the one thing the mixup cannot
     survive. These signals are all server-side readings of replicated physics. ]]
local function movementContext(attacker, char, hum, hrp)
	local mcfg = MCFG

	-- AIRBORNE, in increasing order of responsiveness.
	local airborne = hum.FloorMaterial == Enum.Material.Air

	if not airborne then
		local st = hum:GetState()
		airborne = (st == Enum.HumanoidStateType.Jumping)
			or (st == Enum.HumanoidStateType.Freefall)
	end

	if not airborne and hrp then
		-- Rising fast enough that you can only just have jumped. This is the signal that
		-- actually closes the gap, because velocity replicates before either of the above.
		if hrp.AssemblyLinearVelocity.Y > (mcfg.AirborneRiseSpeed or 5) then
			airborne = true
		end
	end

	if not airborne and hrp then
		-- Falling with nothing underneath: catches the case where you walked off a ledge, so
		-- vertical speed is negative and the Humanoid has not caught up either.
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { char }
		local drop = mcfg.GroundProbeDepth or 4
		airborne = workspace:Raycast(hrp.Position, Vector3.new(0, -drop, 0), params) == nil
	end

	-- SPRINTING. The server's own flag needs the RequestSprint round trip to land, so a swing
	-- thrown the instant you start sprinting would miss the lunge. Actual replicated speed is
	-- the corroborating signal -- you cannot be moving at sprint pace without sprinting.
	local ms = _G.MovementSystem
	local sprinting = ms and ms.isSprinting and ms.isSprinting(attacker) or false
	if not sprinting and hrp and not airborne then
		local v = hrp.AssemblyLinearVelocity
		local flat = Vector3.new(v.X, 0, v.Z).Magnitude
		if flat >= (mcfg.LungeSpeedThreshold or 20) then sprinting = true end
	end

	return airborne, sprinting
end

local function processSwing(attacker)
	local s = getPS(attacker)
	if not s then return end
	local now = os.clock()

	if isBusy(s, now) then
		fireEvent(attacker, { kind = "Denied", reason = "busy" })
		return
	end
	-- GUARD AND ATTACK ARE EXCLUSIVE. Swinging out of a raised guard let you hold the
	-- defensive option and the offensive one at once, which costs nothing and beats reading
	-- the level. Drop guard first.
	if s.guarding then
		fireEvent(attacker, { kind = "Denied", reason = "guarding" })
		return
	end
	-- The rhythm IS the rate limit: clicking faster than SwingCooldown never swings faster.
	if not checkRateLimit(s, "Swing", MCFG.SwingCooldown) then return end

	local char, hum, hrp = charParts(attacker)
	if not char or not hum or not hrp or hum.Health <= 0 then return end

	-- WHICH ATTACK THIS IS. Every input is the same click; the situation decides. All three
	-- contextual attacks are HIGH -- only the chain reads stance for its level.
	local airborne, sprinting = movementContext(attacker, char, hum, hrp)
	local ms = _G.MovementSystem
	local kind = Model.attackKind({
		airborne     = airborne,
		sprinting    = sprinting,
		uncrouchedAt = s.uncrouchedAt,
		now          = now,
	}, MCFG)

	local level = (kind == Model.Kind.Chain) and levelFor(attacker) or Level.High

	local hitNum, isFinisher
	if kind == Model.Kind.Chain then
		local chain
		chain, hitNum, isFinisher = Model.advanceChain(s.chain, now, MCFG)
		s.chain = chain
	else
		-- Contextual attacks sit OUTSIDE the chain: they neither advance nor reset it, so a
		-- lunge mid-combo does not cost you your place. Their clip is named directly.
		hitNum = (MCFG[kind] and MCFG[kind].AnimIndex) or MCFG.ChainMax
		isFinisher = false
	end

	-- An up-tilt consumes its window, so one crouch-release buys exactly one up-tilt rather
	-- than every swing for the next 0.4s.
	if kind == Model.Kind.UpTilt then s.uncrouchedAt = nil end

	s.lastSwingAt = now
	s.swingToken += 1
	local myToken = s.swingToken

	setCombatState(attacker, "Attacking")
	-- WINDUP CARRIES YOU FORWARD. The telegraph is a small speed BOOST rather than neutral,
	-- so committing to a swing steps you into it; the slow lands when the hitbox opens.
	-- Still a multiplier, because MovementFlow scales the winner by the health / injury /
	-- rage / caste / talent scalars -- a wounded player gets the boost against THEIR ceiling.
	flowSet(attacker, "Windup", FW.Windup, MCFG.WindupSpeedMult or 1)
	swungBindable:Fire(attacker) -- WolfManager read-parry hook

	-- LUNGE AND AERIAL both carry you forward. Pushed as a velocity CONTRIBUTION rather than a
	-- raw AssemblyLinearVelocity write (which the old stack used and which a client-owned
	-- character overwrites on the next replication tick anyway), so it sums with any knockback
	-- landing at the same moment instead of one clobbering the other.
	local forwardCfg = MCFG[kind]
	if forwardCfg and forwardCfg.ForwardForce then
		if kind == Model.Kind.Lunge and ms and ms.stopSprint then ms.stopSprint(attacker) end
		local vm = _G.VelocityManager
		local dir = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z)
		if vm and vm.pushPlayer and dir.Magnitude > 0.01 then
			pcall(vm.pushPlayer, attacker, {
				planar   = dir.Unit * forwardCfg.ForwardForce,
				duration = MCFG.Windup,
				decay    = "linear",
				suppressInput = false, -- you keep steering through it; it is not a dash
			})
		end
	end

	local swingSounds = MCFG.SwingSounds or {}
	if #swingSounds > 0 then
		playSound3D(hrp, swingSounds[math.random(1, #swingSounds)], 0.2)
	end
	-- The client plays whatever clip index we name, so the contextual attacks need no client
	-- change at all -- they just ask for clip 4.
	fireEvent(attacker, {
		kind = "Swing", hit = hitNum, level = level,
		finisher = isFinisher, attack = kind,
	})

	local atk = {
		attacker = attacker, char = char,
		hitNum = hitNum, isFinisher = isFinisher, level = level, kind = kind,
	}

	task.spawn(function()
		--[[ The whole body runs inside a pcall so the CLEANUP BELOW ALWAYS RUNS.

		     A throw in here used to strand the attacker at attack walk-speed until their next
		     swing -- it happened once already, when the hit payload dereferenced a nil victim
		     player against an NPC. That specific dereference was fixed; the structural hazard
		     (a slow with no guaranteed release) was not, until now. ]]
		local ok, err = pcall(function()
			-- WINDUP: the telegraph. No hitbox exists yet -- this is the window a defender reads
			-- the level in and commits to a matching guard or parry.
			task.wait(MCFG.Windup)
			local cur = getPS(attacker)
			if not cur or cur.swingToken ~= myToken then return end -- staggered, hit, or superseded
			local aChar, aHum, aHRP = charParts(attacker)
			if not aChar or not aHum or not aHRP or aHum.Health <= 0 then return end

			--[[ THE SWING PHASE DOES NOT SLOW YOU (2026-08-10, dev's call).

			     The windup carries its speed boost; from the hitbox frame onward the attack
			     simply stops having an opinion about movement. Releasing the Windup key here
			     rather than replacing it with a slower one means the swing phase falls through
			     to whatever else is live -- crouch speed if you are crouched, normal otherwise
			     -- instead of the attack asserting a speed it no longer wants to own.

			     This is why the sources are named: "stop affecting speed" is expressible.
			     Under the old single-slot system the only way to stop slowing someone was to
			     write a number over the slot, which is what clobbered every other source. ]]
			flowClear(attacker, "Windup")

			--[[ THE HITBOX. A do-while: it always runs AT LEAST ONE frame, then keeps polling
			     for as long as ActiveWindow lasts. At the configured ActiveWindow of 0 that is
			     exactly the single frame the dev asked for -- the hitbox flickering once at
			     the windup/swing boundary -- and raising the config re-opens a polled window
			     with no code change. `seen` caps a victim at one hit per swing either way. ]]
			local seen = {}
			local windowStart = os.clock()
			repeat
				local curAttacker = getPS(attacker)
				if not curAttacker or curAttacker.swingToken ~= myToken then break end
				local aChar2, _, aHRP2 = charParts(attacker)
				if not aChar2 or not aHRP2 then break end

				for _, part in ipairs(hitboxQuery(aChar2, aHRP2)) do
					local vc = part:FindFirstAncestorOfClass("Model")
					if vc and vc ~= aChar2 and not seen[vc] then
						local vHum = vc:FindFirstChildOfClass("Humanoid")
						local vHRP = vc:FindFirstChild("HumanoidRootPart")
						if vHum and vHRP and vHum.Health > 0
							and hasLineOfSight(aChar2, aHRP2.Position, vc, vHRP.Position) then
							seen[vc] = true
							local vp = Players:GetPlayerFromCharacter(vc)
							resolveAgainst(atk, vc, vp, vHum)
						end
					end
				end
				if os.clock() - windowStart >= (MCFG.ActiveWindow or 0) then break end
				RunService.Heartbeat:Wait()
			until false

			-- THE COMMITTED TAIL. No hitbox any more, but the speed penalty and the Attacking
			-- state hold for SwingPhase, so a whiff still costs you the follow-through. This
			-- is what makes the attack 0.65s long rather than ending the instant it connects.
			if MCFG.SwingPhase and MCFG.SwingPhase > 0 then
				task.wait(MCFG.SwingPhase)
			end
		end)

		if not ok then
			warn("[MeleeCombat] swing body errored: " .. tostring(err))
		end

		--[[ CLEANUP. Runs on EVERY exit -- normal finish, early return, break, or a throw.

		     Only release the keys if this swing is still the current one: a newer swing owns
		     them now and clearing here would cancel its slow. Note there is no "restore to
		     1" any more, and no combatState gate on the speed -- releasing a named key is
		     correct regardless of what else has happened, which is exactly what the old
		     state-gated restore got wrong. ]]
		local after = getPS(attacker)
		if after and after.swingToken == myToken then
			clearSwingSpeed(attacker)
			if after.combatState == "Attacking" then
				setCombatState(attacker, after.guarding and "Blocking" or "Idle")
			end
		end
	end)
end

-- ── Remotes ───────────────────────────────────────────────────────────────
-- Every one is payload-free. There is nothing here for a client to lie about.
RE_Swing.OnServerEvent:Connect(function(p) processSwing(p) end)
RE_Guard.OnServerEvent:Connect(function(p) startGuard(p) end)
RE_GuardEnd.OnServerEvent:Connect(function(p) endGuard(p) end)
RE_Parry.OnServerEvent:Connect(function(p) startParry(p) end)

-- ── Lifecycle ─────────────────────────────────────────────────────────────
-- Reset on every SPAWN, not just on join. The old stack needed this same fix in five
-- separate managers: dying mid-parry-window or mid-guard otherwise left the fresh character
-- permanently unable to parry, or silently guarding nothing.
local function onCharacter(player, char)
	initState(player.UserId)
	setCombatState(player, "Idle")
	watchStanceRelease(player, char)
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(char) onCharacter(player, char) end)
end)
for _, p in ipairs(Players:GetPlayers()) do
	p.CharacterAdded:Connect(function(char) onCharacter(p, char) end)
	if p.Character then onCharacter(p, p.Character) end
end

-- ── Registration ──────────────────────────────────────────────────────────
-- These key names are what CombatCore.sys() looks up; several differ from CombatCore's own
-- method names (checkBlockHit vs isBlocking, getParryElapsed vs getElapsed), so they are
-- spelled to match the seam, not the caller.
local MeleeCombat = {}

MeleeCombat.isActionBlocked   = isActionBlocked
MeleeCombat.isSprintLocked    = function(player)
	local s = getPS(player)
	if not s then return false end
	-- Swinging and guarding both drop sprint; a fight should not be escapable by holding W.
	return s.guarding or s.combatState == "Attacking" or os.clock() < s.staggeredUntil
end
MeleeCombat.isTurnCapped      = function(player)
	local s = getPS(player)
	return s ~= nil and s.combatState == "Attacking"
end
MeleeCombat.isLandingRecovery = function() return false end -- not modelled this pass
MeleeCombat.applyStagger      = applyStagger
MeleeCombat.clearHitstun      = function(player)
	local s = getPS(player)
	if s then s.hitLockUntil = 0 end
end
MeleeCombat.isBlocking        = function(player)
	local s = getPS(player)
	return s ~= nil and s.guarding == true
end
MeleeCombat.checkBlockHit     = function(player, _attacker, _attackType)
	-- The mob path: mobs do not carry a level, so a guard stops them outright. Returning
	-- `true` means fully absorbed, matching what NPCManager expects.
	local s = getPS(player)
	local absorbed = s ~= nil and s.guarding == true
	if absorbed then
		-- Mob hits never reach applyOutcome, so this is the ONLY place a wolf's or an NPC's
		-- blocked swing can produce a re-brace on the defender. Player-side only: the mob's own
		-- reaction is its manager's business, and PlayCombatAnim stays retired.
		fireEvent(player, { kind = "Blocked", role = "victim" })
	end
	return absorbed
end
MeleeCombat.isParrying        = function(player)
	local s = getPS(player)
	return s ~= nil and Model.parryActive(s.parryStartedAt, os.clock(), MCFG)
end
MeleeCombat.getParryElapsed   = function(player)
	local s = getPS(player)
	if not s or not s.parryStartedAt then return nil end
	return os.clock() - s.parryStartedAt
end
MeleeCombat.cancelParry       = function(player)
	local s = getPS(player)
	if s then s.parryStartedAt = nil; s.parryLevel = nil end
end

-- Public surface for the harness and for future systems. Deliberately NOT named
-- getCombatState: registering that key would make our table the source of truth for reads
-- while CombatCore stayed the source for writes, and anything calling CombatCore
-- .setCombatState directly (ModManager does) would desync the two silently.
MeleeCombat.getMeleeState = function(player)
	local s = getPS(player)
	return s and s.combatState or "Idle"
end
MeleeCombat.getLevel   = levelFor
MeleeCombat.getChain   = function(player) local s = getPS(player); return s and s.chain.count or 0 end
MeleeCombat.swing      = processSwing
MeleeCombat.guard      = startGuard
MeleeCombat.guardEnd   = endGuard
MeleeCombat.parry      = startParry
MeleeCombat.PlayerSwung = PlayerSwung

-- setCombatState is deliberately NOT registered: CombatCore's own implementation writes the
-- state it mirrors onto the character, and ours calls back into it. Registering would make
-- that recurse.

_G.CombatSystem = MeleeCombat

print(string.format(
	"[MeleeCombat] Loaded -- %d-hit chain, %d dmg, %.2fs windup, %.2fs parry window, %.2fs reaction grace",
	MCFG.ChainMax, MCFG.Damage, MCFG.Windup, MCFG.ParryWindow, MCFG.ReactionGrace))
