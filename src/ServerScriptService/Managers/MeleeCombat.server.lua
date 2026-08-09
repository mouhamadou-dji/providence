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

local function setSpeed(player, mult)
	local cm = _G.CombatManager
	if cm and cm.setSpeed then cm.setSpeed(player, mult) end
end

local function fireEvent(player, payload)
	if player then RE_Event:FireClient(player, payload) end
end

local function playSound3D(parent, name, volume)
	if not parent or not name or not SoundsCombat then return end
	local template = SoundsCombat:FindFirstChild(name)
	local id = template and template.SoundId
	-- Silence beats a broken clip: several of these are still unauthored placeholders.
	if not id or id == "" or id == "rbxassetid://0" then return end
	local snd = Instance.new("Sound")
	snd.SoundId = id
	snd.Volume = volume or 0.4
	snd.PlaybackSpeed = 0.92 + math.random() * 0.16
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

-- ── Action gating ─────────────────────────────────────────────────────────
local function isBusy(s, now)
	if not s then return true end -- fail closed
	if now < s.staggeredUntil then return true end
	if now < s.hitLockUntil then return true end
	return false
end

local function isActionBlocked(player)
	local s = getPS(player)
	if not s then return true end
	local _, hum = charParts(player)
	if not hum or hum.Health <= 0 then return true end
	return isBusy(s, os.clock())
end

-- ── Stagger ───────────────────────────────────────────────────────────────
local function applyStagger(player, duration)
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
	setSpeed(player, MCFG.StaggerSpeedMult)
	fireEvent(player, { kind = "Staggered", duration = duration })
	task.delay(duration, function()
		local cur = getPS(player)
		if not cur or os.clock() < cur.staggeredUntil then return end
		if cur.combatState == "Staggered" then
			setCombatState(player, cur.guarding and "Blocking" or "Idle")
			setSpeed(player, cur.guarding and MCFG.GuardSpeedMult or 1)
		end
	end)
end

-- ── Guard ─────────────────────────────────────────────────────────────────
local function startGuard(player)
	local s = getPS(player)
	if not s or s.guarding then return end
	if isActionBlocked(player) then return end
	s.guarding = true
	-- The level is latched AT THE PRESS, not read per hit. Otherwise standing up mid-guard
	-- would silently convert a low guard into a high one and the read would be unloseable.
	s.guardLevel = levelFor(player)
	setCombatState(player, "Blocking")
	setSpeed(player, MCFG.GuardSpeedMult)
	local ms = _G.MovementSystem
	if ms and ms.stopSprint then ms.stopSprint(player) end
end

local function endGuard(player)
	local s = getPS(player)
	if not s or not s.guarding then return end
	s.guarding = false
	s.guardLevel = nil
	if s.combatState == "Blocking" then
		setCombatState(player, "Idle")
		setSpeed(player, 1)
	end
end

-- ── Parry ─────────────────────────────────────────────────────────────────
local function startParry(player)
	local s = getPS(player)
	if not s then return end
	local now = os.clock()
	if now < s.parryCooldownUntil then
		fireEvent(player, { kind = "Denied", reason = "cooldown" })
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
local function applyOutcome(outcome, attacker, attackerChar, victimChar, victimPlayer, hum, hitNum, isFinisher, level)
	if not hum or hum.Health <= 0 then return end
	local vHRP = victimChar:FindFirstChild("HumanoidRootPart")

	if outcome == "Parried" then
		local vs = getPS(victimPlayer)
		if vs then
			vs.parryIntercepted = true
			vs.parryStartedAt = nil
			vs.parryLevel = nil
			vs.parryCooldownUntil = os.clock() + MCFG.ParryCooldown
		end
		applyStagger(attacker, MCFG.ParryStagger)
		playSound3D(vHRP, MCFG.ParrySound, 0.5)
		fireEvent(victimPlayer, { kind = "Parried", level = level, attackerName = attacker.Name })
		fireEvent(attacker,     { kind = "Parried", level = level, victimName = victimPlayer.Name })
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
			fireEvent(victimPlayer, { kind = "Blocked", level = level, attackerName = attacker.Name })
			fireEvent(attacker,     { kind = "Blocked", level = level, victimName = victimPlayer.Name })
			return
		end
		endGuard(victimPlayer) -- out of stamina: the guard collapses and the hit lands
	end

	-- HIT. Damage goes through CombatCore's funnel, which owns godmode, meditation immunity,
	-- the i-frame gate, damage history and the combat tag. Never reimplemented here.
	local cm = _G.CombatManager
	local damage = MCFG.Damage
	if cm and cm.applyDamage then
		cm.applyDamage(hum, damage, victimPlayer, "Player")
	else
		hum:TakeDamage(damage)
	end

	if cm and cm.applyKnockback then
		pcall(cm.applyKnockback, attackerChar, victimChar, Model.knockbackFor(isFinisher, MCFG))
	end

	local vs = getPS(victimPlayer)
	if vs then
		-- Being hit interrupts: the in-flight swing is invalidated and the chain resets, so
		-- trading blindly loses to landing first.
		vs.swingToken += 1
		vs.chain = Model.newChain()
		vs.hitLockUntil = math.max(vs.hitLockUntil, os.clock() + (MCFG.HitLockout or 0.3))
	end

	local hitSounds = MCFG.HitSounds or {}
	playSound3D(vHRP, hitSounds[math.clamp(hitNum, 1, #hitSounds)], 0.45)
	fireEvent(victimPlayer, { kind = "Hit", level = level, hit = hitNum, attackerName = attacker.Name })
	fireEvent(attacker,     { kind = "Hit", level = level, hit = hitNum, victimName = victimPlayer.Name })
end

local function resolveAgainst(attacker, attackerChar, victimChar, victimPlayer, hum, hitNum, isFinisher, level)
	-- i-frames (dash/dodge) beat everything, and short-circuit before the grace window so a
	-- dodged swing costs the defender no stamina and no parry.
	local cm = _G.CombatManager
	if victimPlayer and cm and cm.hasIframes and cm.hasIframes(victimPlayer) then return end

	local now = os.clock()
	local outcome = Model.resolve(level, defenceOf(victimPlayer), now, MCFG)

	if not Model.shouldDefer(outcome) then
		applyOutcome(outcome, attacker, attackerChar, victimChar, victimPlayer, hum, hitNum, isFinisher, level)
		return
	end

	-- THE REACTION GRACE. Only a would-be Hit is deferred -- a parry or block is already the
	-- best result available to the defender, and waiting could only take it away.
	task.delay(MCFG.ReactionGrace, function()
		if not victimChar.Parent or hum.Health <= 0 then return end
		if victimPlayer and cm and cm.hasIframes and cm.hasIframes(victimPlayer) then return end
		local late = Model.resolve(level, defenceOf(victimPlayer), os.clock(), MCFG)
		applyOutcome(late, attacker, attackerChar, victimChar, victimPlayer, hum, hitNum, isFinisher, level)
	end)
end

-- ── Swing ─────────────────────────────────────────────────────────────────
local function processSwing(attacker)
	local s = getPS(attacker)
	if not s then return end
	local now = os.clock()

	if isBusy(s, now) then
		fireEvent(attacker, { kind = "Denied", reason = "busy" })
		return
	end
	-- The rhythm IS the rate limit: clicking faster than SwingCooldown never swings faster.
	if not checkRateLimit(s, "Swing", MCFG.SwingCooldown) then return end

	local char, hum, hrp = charParts(attacker)
	if not char or not hum or not hrp or hum.Health <= 0 then return end

	local level = levelFor(attacker)
	local chain, hitNum, isFinisher = Model.advanceChain(s.chain, now, MCFG)
	s.chain = chain
	s.lastSwingAt = now
	s.swingToken += 1
	local myToken = s.swingToken

	setCombatState(attacker, "Attacking")
	setSpeed(attacker, MCFG.AttackSpeedMult)
	swungBindable:Fire(attacker) -- WolfManager read-parry hook

	local swingSounds = MCFG.SwingSounds or {}
	if #swingSounds > 0 then
		playSound3D(hrp, swingSounds[math.random(1, #swingSounds)], 0.2)
	end
	-- The client plays the clip; the level travels with it so a low swing can animate
	-- differently once low clips are authored.
	fireEvent(attacker, { kind = "Swing", hit = hitNum, level = level, finisher = isFinisher })

	task.spawn(function()
		-- WINDUP: the telegraph. No hitbox exists yet -- this is the window a defender reads
		-- the level in and commits to a matching guard or parry.
		task.wait(MCFG.Windup)
		local cur = getPS(attacker)
		if not cur or cur.swingToken ~= myToken then return end -- staggered, hit, or superseded
		local aChar, aHum, aHRP = charParts(attacker)
		if not aChar or not aHum or not aHRP or aHum.Health <= 0 then return end

		-- ACTIVE FRAMES. Polled every frame across the window rather than sampled once: a
		-- single instant either whiffs or lands purely on where both fighters happened to be
		-- that tick, which is what read as "the hitbox is behind me" in the old stack.
		-- `seen` makes a victim catchable at most once per swing.
		local seen = {}
		local windowStart = os.clock()
		while os.clock() - windowStart < MCFG.ActiveWindow do
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
						resolveAgainst(attacker, aChar2, vc, vp, vHum, hitNum, isFinisher, level)
					end
				end
			end
			RunService.Heartbeat:Wait()
		end

		-- Hand movement back. Guarding survives a swing (you can swing out of a guard), so
		-- the restore respects it rather than stamping Idle over everything.
		local after = getPS(attacker)
		if after and after.swingToken == myToken and after.combatState == "Attacking" then
			setCombatState(attacker, after.guarding and "Blocking" or "Idle")
			setSpeed(attacker, after.guarding and MCFG.GuardSpeedMult or 1)
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
Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function()
		initState(player.UserId)
		setCombatState(player, "Idle")
	end)
end)
for _, p in ipairs(Players:GetPlayers()) do
	p.CharacterAdded:Connect(function()
		initState(p.UserId)
		setCombatState(p, "Idle")
	end)
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
	return s ~= nil and s.guarding == true
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
