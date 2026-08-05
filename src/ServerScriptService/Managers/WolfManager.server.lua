-- WolfManager -- the Lesser Wolf mob (rig: workspace.LesserWolf) as a real state machine.
--
-- RIG FACTS (confirmed live in Studio 2026-07-22, measured not assumed):
--   * The rig is "LesserWolf", a RigType-R6 custom QUADRUPED: 24 parts / 20 Motor6Ds
--     (four Thigh/Leg/Foot legs, tail chain, jaw), plus Head/Body/BackBody.
--   * It HAS a Humanoid with an Animator, so movement is Humanoid:MoveTo + PathfindingService
--     and animations load off Humanoid.Animator (the same simple path the Shroom uses).
--   * HipHeight MEASURED on a fresh clone in bind pose = 3.67 (root-centre-to-sole). The
--     placed model ships with 2.6, which sinks the feet ~1 stud into the floor -- force 3.67.
--   * The wolf's animation clips are UNPUBLISHED KeyframeSequences in
--     ServerStorage.RBX_ANIMSAVES.LesserWolf. Until each is published to an asset id, its
--     Config.WolfMob.Anims slot stays rbxassetid://0 and loadAnims SKIPS it -- the mob still
--     roams/chases/attacks with live hitboxes, it just doesn't play that clip yet.
--
-- Server-authoritative per CLAUDE.md: the mob lives entirely on the server, hitboxes use
-- GetPartBoundsInBox (never Touched), and the client is never trusted for anything. This is a
-- deliberate sibling of ShroomManager -- same proven state machine, parry-window law and
-- knockback/bleed/got-hit wiring -- extended to a three-attack (two-bite mixup + heavy) kit.

local Players            = game:GetService("Players")
local RepStorage         = game:GetService("ReplicatedStorage")
local RunService         = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local Debris             = game:GetService("Debris")

local Config   = require(RepStorage.Shared.Config)
local cfg      = Config.WolfMob
local lootCfg  = Config.WolfLoot
local ParryCfg = Config.Parry

local WolfManager = {}
local active = {}   -- [model] = state table
local nextId = 0

-- ── helpers ──────────────────────────────────────────
local function log(...) print("[WolfManager]", ...) end

local function discord(event, details)
	local d = _G.DiscordManager
	if d and d.logNPC then pcall(d.logNPC, event, details) end
end

local function template()
	return RepStorage:FindFirstChild(cfg.ModelName) or workspace:FindFirstChild(cfg.ModelName)
end

local function alivePlayers()
	local t = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local char = p.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local dm = _G.DataManager
		local state = dm and dm.getValue and dm.getValue(p, "PlayerState")
		if hum and hrp and hum.Health > 0 and state ~= "Dead" then
			t[#t+1] = { player = p, hum = hum, hrp = hrp }
		end
	end
	return t
end

-- ── animation (placeholder-SKIP: rbxassetid://0 slots are simply never loaded) ───────
local LOCOMOTION = { Idle = true, Walk = true, Run = true }
local function loadAnims(s)
	local animator = s.hum:FindFirstChildOfClass("Animator")
	if not animator then animator = Instance.new("Animator"); animator.Parent = s.hum end
	s.tracks = {}
	for key, id in pairs(cfg.Anims) do
		if id and id ~= "" and id ~= "rbxassetid://0" then
			local a = Instance.new("Animation"); a.AnimationId = id
			local ok, track = pcall(function() return animator:LoadAnimation(a) end)
			if ok and track then
				track.Looped = LOCOMOTION[key] == true
				track.Priority = LOCOMOTION[key] and Enum.AnimationPriority.Movement or Enum.AnimationPriority.Action
				s.tracks[key] = track
			else
				warn("[WolfManager] animation failed to load: " .. key)
			end
		end
	end
end

-- One looping locomotion clip at a time (Idle/Walk/Run), crossfaded.
local function setLocomotion(s, name, speedScale)
	if not s.tracks then return end
	for key in pairs(LOCOMOTION) do
		local t = s.tracks[key]
		if t then
			if key == name then
				if not t.IsPlaying then t:Play(0.2) end
				t:AdjustSpeed(speedScale or 1)
			elseif t.IsPlaying then
				t:Stop(0.2)
			end
		end
	end
end
local function stopLocomotion(s)
	if not s.tracks then return end
	for key in pairs(LOCOMOTION) do
		local t = s.tracks[key]
		if t and t.IsPlaying then t:Stop(0.2) end
	end
end
local function playOnce(s, key, fade)
	local t = s.tracks and s.tracks[key]
	if t then t:Play(fade or 0.1) end
	return t
end

local function nearestPlayer(s, maxRange)
	local best, bestD = nil, maxRange or math.huge
	for _, e in ipairs(alivePlayers()) do
		local d = (e.hrp.Position - s.root.Position).Magnitude
		if d < bestD then best, bestD = e, d end
	end
	return best
end

-- Rotate the rig to look at a world point WITHOUT moving it. With Humanoid.AutoRotate turned OFF
-- (see the Chase movement block), this lets the wolf STRAFE and BACKPEDAL while keeping its eyes
-- locked on the target -- it moves back and forth facing you instead of turning its back to walk.
-- Defined up here (above doAttack) on purpose: as a local it must exist before its callers capture
-- it as an upvalue, or they'd silently resolve a nil global.
local function faceFlat(s, worldPos)
	if not s.root then return end
	local pos = s.root.Position
	local look = Vector3.new(worldPos.X, pos.Y, worldPos.Z)
	if (look - pos).Magnitude > 0.05 then
		s.root.CFrame = CFrame.lookAt(pos, look)
	end
end

-- Atmospheric random howl while idle & out of combat. Not a telegraph, does nothing mechanical.
local function maybeAmbientHowl(s, now)
	if s.target then return end -- the Alert howl covers combat; this is prowl-only
	if not s.nextHowl then
		s.nextHowl = now + cfg.AmbientHowlMin + math.random() * (cfg.AmbientHowlMax - cfg.AmbientHowlMin)
		return
	end
	if now < s.nextHowl then return end
	s.nextHowl = now + cfg.AmbientHowlMin + math.random() * (cfg.AmbientHowlMax - cfg.AmbientHowlMin)
	playOnce(s, "Howl")
	-- PLACEHOLDER_SOUND: wolf_howl_ambient
end

-- ── windup telegraph ──────────────────────────────────────
-- PLACEHOLDER_ASSET: wolf_windup_tell -- a real authored VFX would replace this Highlight.
-- Heavy uses a hotter red tell than the bites so the big punishable lunge reads differently.
local function windupTell(s, on, heavy)
	if on then
		if s.tell then s.tell:Destroy() end
		local hl = Instance.new("Highlight")
		hl.Name = "WolfWindup"
		hl.FillColor = heavy and Color3.fromRGB(255, 25, 25) or Color3.fromRGB(210, 150, 40)
		hl.FillTransparency = heavy and 0.4 or 0.8
		hl.OutlineColor = heavy and Color3.fromRGB(255, 60, 60) or Color3.fromRGB(255, 200, 90)
		hl.OutlineTransparency = 0.2
		hl.Parent = s.model
		s.tell = hl
	else
		if s.tell then s.tell:Destroy(); s.tell = nil end
	end
end

-- ── loot ─────────────────────────────────────────
local function rollLoot()
	local total = 0
	for _, e in ipairs(lootCfg) do total += e.weight end
	local r, acc = math.random() * total, 0
	for _, e in ipairs(lootCfg) do
		acc += e.weight
		if r <= acc then return e.item, math.random(e.min, e.max) end
	end
	local last = lootCfg[#lootCfg]
	return last.item, last.min
end

local function dropLoot(position, killerName)
	local item, count = rollLoot()
	local drop = Instance.new("Part")
	drop.Name = "WolfDrop_" .. item
	drop.Size = Vector3.new(1.4, 1.4, 1.4)
	drop.Position = position + Vector3.new(0, 2, 0)
	drop.Anchored = false
	drop.CanCollide = true
	drop.Color = Color3.fromRGB(120, 100, 80)
	drop.Material = Enum.Material.Slate
	drop:SetAttribute("LootItem", item)
	drop:SetAttribute("LootCount", count)
	drop.Parent = workspace

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Collect"
	prompt.ObjectText = item .. " x" .. count
	prompt.HoldDuration = 0.3
	prompt.MaxActivationDistance = 8
	prompt.Parent = drop
	prompt.Triggered:Connect(function(p)
		local inv = _G.InventoryManager
		if inv and inv.addItem then pcall(inv.addItem, p, item, "Iron", count) end
		discord("MOB_LOOT", string.format("%s collected %s x%d from a Lesser Wolf", p.Name, item, count))
		drop:Destroy()
	end)

	Debris:AddItem(drop, 300)
	return item, count
end

-- ── hitbox (GetPartBoundsInBox -- never Touched, per CLAUDE.md rule 5) ──────────────
local function playersInHitbox(s, range)
	local hrp = s.root
	if not hrp then return {} end
	local params = OverlapParams.new()
	params.FilterDescendantsInstances = { s.model }
	params.FilterType = Enum.RaycastFilterType.Exclude
	local parts = workspace:GetPartBoundsInBox(
		hrp.CFrame * CFrame.new(0, 0, -range * 0.5),
		Vector3.new(range * 1.2, 8, range),
		params)
	local seen, hits = {}, {}
	for _, part in ipairs(parts) do
		local char = part.Parent
		local p = char and Players:GetPlayerFromCharacter(char)
		if p and not seen[p] then seen[p] = true; hits[#hits+1] = p end
	end
	return hits
end

-- ── stun (what a successful parry does to the mob) ─────────────────────────
local function stun(s, duration, reason)
	s.state = "Stunned"
	s.stunUntil = tick() + duration
	s.attacking = false
	windupTell(s, false)
	if s.hum then s.hum.WalkSpeed = 0; s.hum:MoveTo(s.root.Position) end
	stopLocomotion(s)
	for key, t in pairs(s.tracks or {}) do if t.IsPlaying and not LOCOMOTION[key] then t:Stop(0.1) end end
	log(string.format("stunned %.2fs (%s)", duration, tostring(reason)))
end

-- ── attack resolution (parry classified locally against Config.Parry, same law as PvP) ───
local function resolveHit(s, atkCfg)
	local pm   = _G.ParryManager
	local cm   = _G.CombatManager
	local pmgr = _G.PostureManager
	local victims = playersInHitbox(s, atkCfg.range)

	for _, p in ipairs(victims) do
		local char = p.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		-- Captured nil-safe: a player respawning mid-hit can have a Humanoid but no HRP for a frame.
		-- Indexing char.HumanoidRootPart.Position directly (even as a pcall arg) would THROW here,
		-- killing the doAttack coroutine with s.attacking stuck true -> the wolf freezes forever.
		local vhrp = char and char:FindFirstChild("HumanoidRootPart")
		if hum and hum.Health > 0 then
			-- Unparryable attacks (the red Heavy) never register a parry -- pressing parry does nothing.
			local parried, perfect = false, false
			if not atkCfg.unparryable and pm and pm.isParrying and pm.isParrying(p) then
				local elapsed = pm.getElapsed and pm.getElapsed(p)
				if elapsed then
					if elapsed <= ParryCfg.PerfectWindow / 60 then parried, perfect = true, true
					elseif elapsed <= ParryCfg.WindowTotal / 60 then parried = true end
				end
			end

			if parried then
				if perfect then
					stun(s, cfg.ParryStunDuration, "perfect parry by " .. p.Name)
					s.bonusDamageUntil = tick() + cfg.ParryStunDuration
					playOnce(s, "Parry")
					if cm and cm.spawnParryVFX and vhrp then
						pcall(cm.spawnParryVFX, (s.root.Position + vhrp.Position) / 2)
					end
					local re = RepStorage:FindFirstChild("RemoteEvents")
					re = re and re:FindFirstChild("OnParryResult")
					if re then re:FireClient(p, { result = "Perfect", source = "Wolf" }) end
				else
					local re = RepStorage:FindFirstChild("RemoteEvents")
					re = re and re:FindFirstChild("OnParryResult")
					if re then re:FireClient(p, { result = "Late", source = "Wolf" }) end
				end
				return true -- a parried swing hits nobody else either
			end

			-- Red Heavy vs a guard: trying to parry OR block it does NOT save you -- it BREAKS your
			-- guard (PostureManager guard break + 3s stun) and the lunge still lands. Only a dodge
			-- (dash iframes) avoids it entirely.
			if atkCfg.unparryable and not (cm and cm.hasIframes and cm.hasIframes(p)) then
				local guarding = (pm and pm.isParrying and pm.isParrying(p))
					or (cm and cm.getCombatState and cm.getCombatState(p) == "Blocking")
				if guarding then
					local postureM = _G.PostureManager
					if postureM and postureM.triggerGuardBreak then pcall(postureM.triggerGuardBreak, p) end
					if cm and cm.spawnBlockVFX and vhrp then pcall(cm.spawnBlockVFX, vhrp.Position) end
				end
			end

			-- Unblockable makes a held block count as no-block, so the hit flows through to damage below.
			local blocking = (not atkCfg.unblockable) and cm and cm.getCombatState and cm.getCombatState(p) == "Blocking"
			if blocking then
				if pmgr and pmgr.fill then pcall(pmgr.fill, p, cfg.PostureDamage) end
				if cm and cm.spawnBlockVFX and vhrp then pcall(cm.spawnBlockVFX, vhrp.Position) end
			elseif cm and cm.hasIframes and cm.hasIframes(p) then
				-- dodged (dash iframes) -- nothing happens, and the mob learns from it below
			else
				local dmg = cfg.AttackDamage * (atkCfg.damageMult or 1)
				if cm and cm.applyDamage then
					pcall(cm.applyDamage, hum, dmg, p, "Mob")
				else
					hum:TakeDamage(dmg)
				end
				if pmgr and pmgr.fill then pcall(pmgr.fill, p, cfg.PostureDamage * 0.5) end
				if cm and cm.spawnHitVFX and vhrp then pcall(cm.spawnHitVFX, vhrp.Position) end

				if cm and cm.applyHitstun then pcall(cm.applyHitstun, p, cfg.HitstunDuration) end
				if cm and cm.applyKnockback then
					local lateral = s.root.CFrame.RightVector * (atkCfg.lateralSign or 1)
					pcall(cm.applyKnockback, s.model, char, cfg.KnockbackForce, lateral, cfg.KnockbackLateral)
				end
				if atkCfg.bleedTier and math.random() < (atkCfg.bleedChance or 0) then
					local bm = _G.BleedManager
					if bm and bm.applyBleed then pcall(bm.applyBleed, p, atkCfg.bleedTier) end
				end

				local reFolder = RepStorage:FindFirstChild("RemoteEvents")
				local rePlayAnim = reFolder and reFolder:FindFirstChild("PlayCombatAnim")
				if rePlayAnim then rePlayAnim:FireClient(p, "M1GotHit", math.random(1, 5)) end

				s.lastHitPlayer = p
			end
		end
	end
	return false
end

-- ── attack selection (adaptive, weighted, no heavy-twice) ─────────────────────
local function weightedBite(s, targetHRP)
	-- Side read: if the player is circling to the wolf's left, favour the bite that sweeps left.
	local toTarget = (targetHRP.Position - s.root.Position)
	local side = s.root.CFrame.RightVector:Dot(toTarget.Unit)
	if side < -0.15 then return (math.random() < 0.7) and "BiteLeft" or "BiteRight"
	elseif side > 0.15 then return (math.random() < 0.7) and "BiteRight" or "BiteLeft"
	else return (math.random() < 0.5) and "BiteLeft" or "BiteRight" end
end

local function chooseAttack(s, targetHRP)
	-- Adaptive read: dodged the same attack twice running -> switch it up to catch them.
	if s.evadeStreakAttack and (s.evadeStreak or 0) >= 2 then
		s.evadeStreak = 0
		if s.evadeStreakAttack == "Heavy" then return weightedBite(s, targetHRP) end
		return s.evadeStreakAttack == "BiteLeft" and "BiteRight" or "BiteLeft"
	end
	-- Heavy is the slow high-reward option, but never back-to-back (too punishable).
	local heavyCfg = cfg.Attacks.Heavy
	if heavyCfg and s.lastAttack ~= "Heavy" and math.random() < ((heavyCfg.weight or 20) / 100) then
		return "Heavy"
	end
	return weightedBite(s, targetHRP)
end

-- ── the three-phase attack ─────────────────────────────────────
local function doAttack(s, attackName)
	local atk = cfg.Attacks[attackName]
	if not atk then return end
	s.attacking = true
	s.state = "Attack"
	s.currentAttack = attackName
	s.lastAttack = attackName
	s.hum.WalkSpeed = 0
	stopLocomotion(s)
	-- Face the target as the swing starts (AutoRotate is off in combat, so nothing else turns it).
	local atkHRP = s.target and s.target.Character and s.target.Character:FindFirstChild("HumanoidRootPart")
	if atkHRP then faceFlat(s, atkHRP.Position) end

	playOnce(s, atk.anim)

	-- WINDUP: no hitbox, visible tell. This is the read/parry window.
	windupTell(s, true, atk.heavy)
	local t0 = tick()
	while tick() - t0 < atk.windup do
		if not s.alive or s.state == "Stunned" then windupTell(s, false); s.attacking = false; return end
		if atk.heavy and s.tell then
			-- pulse the red tell so the unparryable/unblockable Heavy reads as "dodge this"
			s.tell.FillTransparency = 0.2 + 0.35 * (0.5 + 0.5 * math.sin((tick() - t0) * 18))
		end
		task.wait()
	end
	windupTell(s, false)

	-- ACTIVE: hitbox live for exactly these frames, resolved once per swing.
	s.state = "Attack"
	local hitLanded = false
	local t1 = tick()
	while tick() - t1 < atk.active do
		if not s.alive or s.state == "Stunned" then s.attacking = false; return end
		if not hitLanded then
			hitLanded = true
			if resolveHit(s, atk) then s.attacking = false; return end
		end
		task.wait()
	end

	-- Adaptive read bookkeeping: nobody took damage from this swing = an evade.
	if s.lastHitPlayer == nil then
		if s.evadeStreakAttack == attackName then s.evadeStreak = (s.evadeStreak or 0) + 1
		else s.evadeStreakAttack, s.evadeStreak = attackName, 1 end
	else
		s.evadeStreakAttack, s.evadeStreak = nil, 0
	end
	s.lastHitPlayer = nil

	-- RECOVERY: the punish window. Mob cannot act.
	s.state = "Recover"
	local t2 = tick()
	while tick() - t2 < atk.recovery do
		if not s.alive or s.state == "Stunned" then s.attacking = false; return end
		task.wait()
	end

	s.attacking = false
	if s.alive and s.state == "Recover" then
		s.state = "Chase"
		-- Start a fresh orbit (stalk) window after committing, so it circles/repositions instead
		-- of mashing bites in your face -- this is what gives the fight its in-out rhythm.
		s.circleUntil = tick() + (cfg.CircleMin or 0.9) + math.random() * ((cfg.CircleMax or 2.2) - (cfg.CircleMin or 0.9))
	end
end

-- ── advanced targeting + movement ─────────────────────────────
-- Score every reachable player by proximity + how much they've recently hurt the wolf, with a
-- stickiness bonus for the current target so it commits rather than flip-flopping every check.
local function pickTarget(s)
	local best, bestScore = nil, -math.huge
	for _, e in ipairs(alivePlayers()) do
		local dist = (e.hrp.Position - s.root.Position).Magnitude
		if dist <= cfg.LoseInterestRange then
			local threat = (s.threat and s.threat[e.player.UserId]) or 0
			local score = -dist + threat * (cfg.ThreatWeight or 0.6)
			if s.target == e.player then score = score + (cfg.TargetStickiness or 7) end
			if score > bestScore then best, bestScore = e, score end
		end
	end
	return best
end

-- A point on a ring around the target, rotated to the wolf's current circling side. Moving toward
-- it makes the wolf STALK in an arc instead of charging dead-straight at you.
local function orbitPoint(s, tHRP)
	local flat = s.root.Position - tHRP.Position
	flat = Vector3.new(flat.X, 0, flat.Z)
	local dir = (flat.Magnitude > 0.1) and flat.Unit or s.root.CFrame.LookVector
	local ang = math.rad((cfg.StrafeAngle or 34) * (s.strafeSign or 1))
	local c, sn = math.cos(ang), math.sin(ang)
	local rot = Vector3.new(dir.X * c - dir.Z * sn, 0, dir.X * sn + dir.Z * c)
	return tHRP.Position + rot * (cfg.StrafeRadius or 14)
end

-- Pounce: a leaping gap-closer -- leap clip + a velocity burst toward the target, then a bite.
local function doLunge(s, tHRP)
	s.attacking = true; s.state = "Attack"; s.lastAttack = "Lunge"
	s.lungeCdUntil = tick() + (cfg.LungeCooldown or 4.5)
	s.hum.WalkSpeed = 0; stopLocomotion(s)
	playOnce(s, "Jump")
	local face = Vector3.new(tHRP.Position.X, s.root.Position.Y, tHRP.Position.Z)
	pcall(function() s.model:PivotTo(CFrame.lookAt(s.root.Position, face)) end)
	windupTell(s, true, false)
	local t0 = tick()
	while tick() - t0 < (cfg.LungeWindup or 0.22) do
		if not s.alive or s.state == "Stunned" then windupTell(s, false); s.attacking = false; return end
		task.wait()
	end
	windupTell(s, false)
	if not s.alive or s.state == "Stunned" then s.attacking = false; return end
	local dir = face - s.root.Position
	dir = (dir.Magnitude > 0.1) and dir.Unit or s.root.CFrame.LookVector
	s.root.AssemblyLinearVelocity = dir * (cfg.LungeSpeed or 62) + Vector3.new(0, 16, 0)
	local atk = cfg.Attacks.Lunge or cfg.Attacks.BiteRight
	local hit, t1 = false, tick()
	while tick() - t1 < (cfg.LungeActive or 0.35) do
		if not s.alive or s.state == "Stunned" then s.attacking = false; return end
		if not hit then hit = true; if resolveHit(s, atk) then break end end
		task.wait()
	end
	s.lastHitPlayer = nil
	s.state = "Recover"
	local t2 = tick()
	while tick() - t2 < (cfg.LungeRecovery or 0.55) do
		if not s.alive or s.state == "Stunned" then s.attacking = false; return end
		task.wait()
	end
	s.attacking = false
	if s.alive and s.state == "Recover" then s.state = "Chase"; s.circleUntil = tick() + (cfg.CircleMin or 0.9) end
end

-- Feint: start a bite windup then abort before the hitbox -- baits a panic parry/dodge, then
-- drops straight back into Chase to punish the whiff.
local function doFeint(s)
	s.attacking = true; s.state = "Attack"
	s.feintCdUntil = tick() + (cfg.FeintCooldown or 4)
	s.hum.WalkSpeed = 0; stopLocomotion(s)
	local key = (math.random() < 0.5) and "BiteLeft" or "BiteRight"
	local atk = cfg.Attacks[key]
	playOnce(s, atk.anim)
	windupTell(s, true, false)
	local t0 = tick()
	while tick() - t0 < (atk.windup or 0.35) * 0.55 do
		if not s.alive or s.state == "Stunned" then windupTell(s, false); s.attacking = false; return end
		task.wait()
	end
	windupTell(s, false)
	if s.tracks and s.tracks[atk.anim] then s.tracks[atk.anim]:Stop(0.12) end
	s.state = "Recover"
	local t1 = tick()
	while tick() - t1 < 0.28 do
		if not s.alive or s.state == "Stunned" then s.attacking = false; return end
		task.wait()
	end
	s.attacking = false
	if s.alive and s.state == "Recover" then s.state = "Chase" end
end

-- ── death ─────────────────────────────────────────
local function die(s, killer)
	if not s.alive then return end
	s.alive = false
	s.state = "Dead"
	s.attacking = false
	windupTell(s, false)
	stopLocomotion(s)
	active[s.model] = nil

	local pos = s.root and s.root.Position or s.model:GetPivot().Position
	-- PLACEHOLDER_SOUND: wolf_death

	-- Death: no ragdoll, no breaking into parts -- the rig gently FADES out of existence.
	-- PLACEHOLDER: a real death animation would play here before/under the fade.
	if s.hum then s.hum.WalkSpeed = 0; s.hum.AutoRotate = false end
	-- Freeze it in place so it stands still (not slumping/sliding) while it dissolves.
	for _, d in ipairs(s.model:GetDescendants()) do
		if d:IsA("BasePart") then d.Anchored = true end
	end
	local fadeDur = cfg.FadeOutDuration or 4
	task.spawn(function()
		local faders = {}
		for _, d in ipairs(s.model:GetDescendants()) do
			if d:IsA("BasePart") or d:IsA("Decal") or d:IsA("Texture") then
				faders[#faders+1] = { inst = d, from = d.Transparency }
			end
		end
		local t0 = tick()
		while tick() - t0 < fadeDur do
			local a = (tick() - t0) / fadeDur
			for _, e in ipairs(faders) do e.inst.Transparency = e.from + (1 - e.from) * a end
			task.wait()
		end
		if s.model and s.model.Parent then s.model:Destroy() end
	end)

	local item, count = dropLoot(pos, killer and killer.Name or nil)
	if killer then
		discord("MOB_KILLED", string.format("%s killed a Lesser Wolf (dropped %s x%d)", killer.Name, item, count))
	else
		discord("MOB_KILLED", string.format("A Lesser Wolf died (dropped %s x%d)", item, count))
	end

	task.delay(cfg.DespawnAfter, function()
		if s.model and s.model.Parent then s.model:Destroy() end
	end)
end

-- ── perception ──────────────────────────────────────
local function scan(s)
	local best, bestDist = nil, math.huge
	local halfCos = math.cos(math.rad(cfg.SightAngle / 2))
	for _, e in ipairs(alivePlayers()) do
		local delta = e.hrp.Position - s.root.Position
		local dist = delta.Magnitude
		if dist <= cfg.SightRange and dist < bestDist then
			local facing = s.root.CFrame.LookVector
			if facing:Dot(delta.Unit) >= halfCos then
				best, bestDist = e, dist
			end
		end
	end
	return best
end

local function hasLineOfSight(s, hrp)
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = { s.model }
	params.FilterType = Enum.RaycastFilterType.Exclude
	local delta = hrp.Position - s.root.Position
	local hit = workspace:Raycast(s.root.Position, delta, params)
	if not hit then return true end
	return hit.Instance:IsDescendantOf(hrp.Parent)
end

-- Async repath. ComputeAsync YIELDS, and step() runs INLINE inside the Heartbeat loop, so the old
-- synchronous version stalled the whole wolf every RepathInterval -- that is the "takes a step then
-- freezes" stutter. Compute on a side coroutine and swap the waypoints in when they're ready; the
-- step loop never blocks, so locomotion stays smooth. A single in-flight compute at a time.
local function repath(s, destination)
	if s.pathComputing then return end
	if tick() < (s.nextRepath or 0) then return end
	s.nextRepath = tick() + cfg.RepathInterval
	s.pathComputing = true
	local origin = s.root.Position
	task.spawn(function()
		local path = PathfindingService:CreatePath({ AgentRadius = 3, AgentHeight = 6, AgentCanJump = false })
		local ok = pcall(function() path:ComputeAsync(origin, destination) end)
		if s.alive and ok and path.Status == Enum.PathStatus.Success then
			s.waypoints = path:GetWaypoints()
			s.waypointIndex = 2
		else
			s.waypoints = nil
		end
		s.pathComputing = false
	end)
end

local function followPath(s, destination)
	if s.waypoints and s.waypointIndex and s.waypointIndex <= #s.waypoints then
		local wp = s.waypoints[s.waypointIndex]
		s.hum:MoveTo(wp.Position)
		if (s.root.Position - wp.Position).Magnitude < 4 then s.waypointIndex += 1 end
	else
		s.hum:MoveTo(destination)
	end
end

-- ── state machine ────────────────────────────────────
local function step(s)
	if not s.alive then return end
	if not s.model.Parent or not s.root or not s.root.Parent then s.alive = false; active[s.model] = nil; return end
	if s.hum.Health <= 0 then die(s, s.lastAttacker); return end

	local now = tick()

	if s.state == "Stunned" then
		if now >= s.stunUntil then
			s.state = "Chase"
			s.hum.WalkSpeed = cfg.ChaseSpeed
		end
		return
	end
	if s.attacking then return end

	if not s.fleeRolled and s.hum.Health <= cfg.Health * cfg.FleeHealthPct then
		s.fleeRolled = true
		if math.random() < cfg.FleeChance then s.state = "Flee" end
	end

	local target = s.target
	local tHRP = target and target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	local distToSpawn = (s.root.Position - s.spawnPos).Magnitude

	if s.state == "Idle" then
		s.hum.WalkSpeed = 0
		setLocomotion(s, "Idle")
		maybeAmbientHowl(s, now)
		if now >= (s.nextScan or 0) then
			s.nextScan = now + cfg.ScanInterval
			local seen = scan(s)
			if seen then s.target = seen.player; s.state = "Alert"; s.alertUntil = now + cfg.AlertPause; return end
		end
		if now >= (s.nextIdleDecision or 0) then
			s.nextIdleDecision = now + (cfg.RoamWaitMin or 3) + math.random() * ((cfg.RoamWaitMax or 6) - (cfg.RoamWaitMin or 3))
			if math.random() < cfg.PatrolChance then
				local a = math.random() * math.pi * 2
				local r = math.random() * cfg.PatrolRadius
				s.patrolTarget = s.spawnPos + Vector3.new(math.cos(a) * r, 0, math.sin(a) * r)
				s.state = "Patrol"
			end
		end

	elseif s.state == "Patrol" then
		s.hum.WalkSpeed = cfg.WalkSpeed
		s.hum.AutoRotate = true -- roaming: face where it walks (combat turns this off)
		setLocomotion(s, "Walk", 1)
		followPath(s, s.patrolTarget)
		repath(s, s.patrolTarget)
		if (s.root.Position - s.patrolTarget).Magnitude < 5 then s.state = "Idle"; s.waypoints = nil end
		if now >= (s.nextScan or 0) then
			s.nextScan = now + cfg.ScanInterval
			local seen = scan(s)
			if seen then s.target = seen.player; s.state = "Alert"; s.alertUntil = now + cfg.AlertPause end
		end

	elseif s.state == "Alert" then
		-- Stop, turn to face, HOWL. The "the pack found you" telegraph.
		s.hum.WalkSpeed = 0
		stopLocomotion(s)
		if tHRP then
			local flat = Vector3.new(tHRP.Position.X, s.root.Position.Y, tHRP.Position.Z)
			s.model:PivotTo(CFrame.lookAt(s.root.Position, flat))
		end
		if not s.alertSounded then
			s.alertSounded = true
			playOnce(s, "Howl")
			-- PLACEHOLDER_SOUND: wolf_howl
		end
		if now >= s.alertUntil then s.state = "Chase"; s.alertSounded = false end

	elseif s.state == "Chase" then
		if not tHRP then s.state = "Idle"; s.target = nil; return end

		-- Re-pick the best target periodically so it doesn't tunnel on one player while another is
		-- closer or beating on it (pickTarget weighs distance + recent damage-to-the-wolf).
		if now >= (s.nextTargetCheck or 0) then
			local dtCheck = cfg.TargetReassessInterval or 2.0
			s.nextTargetCheck = now + dtCheck
			-- Threat decays so stale damage fades and the wolf tracks whoever's hurting it NOW.
			if s.threat then
				for uid, v in pairs(s.threat) do
					local nv = v - (cfg.ThreatDecay or 7) * dtCheck
					s.threat[uid] = (nv > 0) and nv or nil
				end
			end
			local best = pickTarget(s)
			if best and best.player ~= s.target then s.target = best.player end
			target = s.target
			tHRP = target and target.Character and target.Character:FindFirstChild("HumanoidRootPart")
			if not tHRP then s.state = "Idle"; s.target = nil; return end
		end

		-- Flip circling direction on an interval so it doesn't orbit predictably one way.
		if now >= (s.nextStrafeFlip or 0) then
			s.nextStrafeFlip = now + (cfg.StrafeInterval or 1.6)
			s.strafeSign = (math.random() < 0.5) and 1 or -1
		end

		local dist = (tHRP.Position - s.root.Position).Magnitude
		if dist > cfg.LoseInterestRange or distToSpawn > cfg.LeashRange then
			s.target = nil; s.state = "Flee"; return
		end

		-- IN RANGE (and past the stalk window): commit -- block / feint / attack.
		if dist <= cfg.AttackRange and hasLineOfSight(s, tHRP) and now >= (s.circleUntil or 0) then
			-- BLOCK: a defensive moment (soaks a hit, can catch a parry).
			if now >= (s.blockCdUntil or 0) and math.random() < (cfg.BlockChance or 0) then
				s.state = "Block"
				s.blockUntil   = now + (cfg.BlockDuration or 1.2)
				s.blockCdUntil = now + (cfg.BlockCooldown or 4)
				s.hum.WalkSpeed = 0; stopLocomotion(s)
				playOnce(s, "Block")
				return
			end
			-- FEINT: fake a bite to bait a panic parry/dodge.
			if now >= (s.feintCdUntil or 0) and math.random() < (cfg.FeintChance or 0) then
				task.spawn(function()
					local ok = pcall(doFeint, s)
					if not ok then s.attacking = false; windupTell(s, false); if s.alive then s.state = "Chase" end end
				end)
				return
			end
			-- ATTACK (protected so a resolveHit error can never freeze it mid-swing forever).
			task.spawn(function()
				local ok, err = pcall(doAttack, s, chooseAttack(s, tHRP))
				if not ok then
					warn("[WolfManager] doAttack error: " .. tostring(err))
					s.attacking = false; windupTell(s, false)
					if s.alive and (s.state == "Attack" or s.state == "Recover") then s.state = "Chase" end
				end
			end)
			return
		end

		-- LUNGE: pounce to close a medium gap (a burst of aggression between the circling).
		if dist > cfg.AttackRange and dist <= (cfg.LungeRange or 17) and hasLineOfSight(s, tHRP)
		   and now >= (s.lungeCdUntil or 0) and math.random() < (cfg.LungeChance or 0.5) then
			task.spawn(function()
				local ok = pcall(doLunge, s, tHRP)
				if not ok then s.attacking = false; windupTell(s, false); if s.alive then s.state = "Chase" end end
			end)
			return
		end

		-- MOVE -- two regimes:
		--   COMBAT SPACING (within EngageRange + line of sight): drive straight toward the destination
		--   with AutoRotate OFF and the rig hand-aimed at the target, so it STRAFES / BACKPEDALS while
		--   facing you instead of turning around to walk. No pathfinding here -- a direct MoveTo every
		--   frame is what keeps it fluid (the async ComputeAsync was the stutter, so we skip it at range).
		--   APPROACH (far, or LOS blocked): natural face-forward run, pathfinding around obstacles.
		s.hum.WalkSpeed = cfg.ChaseSpeed
		setLocomotion(s, "Run", 1)
		if dist <= (cfg.EngageRange or 24) and hasLineOfSight(s, tHRP) then
			local orbiting = now < (s.circleUntil or 0) or dist <= cfg.AttackRange
			s.hum.AutoRotate = false
			faceFlat(s, tHRP.Position)
			s.waypoints = nil
			s.hum:MoveTo(orbiting and orbitPoint(s, tHRP) or tHRP.Position)
		else
			s.hum.AutoRotate = true
			repath(s, tHRP.Position)
			followPath(s, tHRP.Position)
		end

	elseif s.state == "Block" then
		-- Hold the guard, keep facing the target. Damage taken here is soaked (see HealthChanged).
		s.hum.WalkSpeed = 0
		if tHRP then
			local flat = Vector3.new(tHRP.Position.X, s.root.Position.Y, tHRP.Position.Z)
			pcall(function() s.model:PivotTo(CFrame.lookAt(s.root.Position, flat)) end)
		end
		if not tHRP or now >= (s.blockUntil or 0) then s.state = "Chase" end

	elseif s.state == "Flee" then
		s.hum.WalkSpeed = cfg.ChaseSpeed
		s.hum.AutoRotate = true -- fleeing: face away toward home, not the target
		setLocomotion(s, "Run", 1)
		repath(s, s.spawnPos)
		followPath(s, s.spawnPos)
		if distToSpawn < 8 then s.state = "Idle"; s.target = nil; s.waypoints = nil end

	elseif s.state == "Recover" then
		s.hum.WalkSpeed = 0
	end
end

-- ── spawn ───────────────────────────────────────
function WolfManager.spawn(position, overrides)
	local tpl = template()
	if not tpl then warn("[WolfManager] no " .. cfg.ModelName .. " template found"); return nil end
	overrides = overrides or {}

	local wasArchivable = tpl.Archivable
	tpl.Archivable = true
	local model = tpl:Clone()
	tpl.Archivable = wasArchivable
	if not model then warn("[WolfManager] clone failed"); return nil end

	nextId += 1
	model.Name = "LesserWolf_" .. nextId
	local hum = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not hum or not root then model:Destroy(); warn("[WolfManager] rig missing Humanoid/HRP"); return nil end

	hum.MaxHealth = overrides.Health or cfg.Health
	hum.Health    = hum.MaxHealth
	hum.WalkSpeed = cfg.WalkSpeed
	hum.HipHeight = cfg.HipHeight -- measured 3.67; rig ships with 2.6 which buries the feet
	hum.DisplayName = cfg.DisplayName
	-- Keep the rig WHOLE on death so it fades intact instead of the joints shattering the instant
	-- Health hits 0 (Roblox's default BreakJointsOnDeath). The LesserWolf rig already had this off,
	-- but set it explicitly so the fade-out never depends on a per-rig authoring detail.
	hum.BreakJointsOnDeath = false
	-- Keep the long quadruped UPRIGHT: don't let a knockback shove or uneven ground tip it into a
	-- FallingDown/Ragdoll humanoid state, which read as the rig "breaking" and left it unable to act.
	pcall(function()
		hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
		hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
	end)

	model:PivotTo(CFrame.new(position))
	model.Parent = workspace

	local s = {
		model = model, hum = hum, root = root,
		state = "Idle", alive = true, attacking = false,
		spawnPos = position,
		evadeStreak = 0,
		stunUntil = 0, bonusDamageUntil = 0,
		threat = {}, strafeSign = 1,
	}
	loadAnims(s)
	active[model] = s

	s.lastHealth = hum.Health
	hum.HealthChanged:Connect(function()
		if not s.alive then return end
		local cur, prev = hum.Health, (s.lastHealth or hum.Health)
		if cur <= 0 then s.lastHealth = cur; die(s, s.lastAttacker); return end

		if cur < prev then
			-- READ-based parry: only negate the hit if the wolf pre-emptively parried an M1 it read
			-- coming (parryWindow armed by the RequestM1 listener below). No flat per-hit dice roll.
			if tick() < (s.parryWindow or 0) then
				s.parryWindow = 0
				s.lastHealth = prev      -- set first so the refund's own HealthChanged is a no-op
				hum.Health = prev        -- the read parry negated the hit
				local cm = _G.CombatManager
				local victim = nearestPlayer(s, 10)
				if victim and cm and cm.applyHitstun then pcall(cm.applyHitstun, victim.player, cfg.ParryCounterStun or 0.4) end
				return
			end
			-- BLOCKING soaks most of the hit (chip damage) instead of taking it in full.
			if s.state == "Block" then
				local reduced = (prev - cur) * (1 - (cfg.BlockDamageReduction or 0.7))
				s.lastHealth = prev - reduced   -- set first so the refund's own HealthChanged is a no-op
				hum.Health   = prev - reduced
				local cm = _G.CombatManager
				if cm and cm.spawnBlockVFX then pcall(cm.spawnBlockVFX, s.root.Position) end
				return
			end
			-- The hit landed. Credit THREAT to whoever's nearest (the likely attacker) so target
			-- selection favours whoever's actually hurting it -- and pull it into the fight.
			local hitter = nearestPlayer(s, cfg.SightRange * 1.5)
			if hitter then
				s.threat = s.threat or {}
				s.threat[hitter.player.UserId] = (s.threat[hitter.player.UserId] or 0) + (prev - cur)
				if s.state == "Idle" or s.state == "Patrol" or s.state == "Flee" then
					s.target = hitter.player; s.state = "Chase"
				end
			end
		end
		s.lastHealth = cur
	end)

	discord("MOB_SPAWNED", string.format("Lesser Wolf spawned at (%.0f, %.0f, %.0f)", position.X, position.Y, position.Z))
	log("spawned " .. model.Name .. " at " .. tostring(position))
	return model
end

-- Damage entry point so attackers get the stunned-target bonus and kill attribution.
function WolfManager.damage(model, amount, attacker)
	local s = active[model]
	if not s or not s.alive then return false end
	local mult = (tick() < (s.bonusDamageUntil or 0)) and cfg.ParryBonusDamageMult or 1
	s.lastAttacker = attacker
	s.hum:TakeDamage(amount * mult)
	if attacker and (s.state == "Idle" or s.state == "Patrol") then
		s.target = attacker; s.state = "Chase"
	end
	return true, amount * mult, mult > 1
end

function WolfManager.isWolf(model) return active[model] ~= nil end
function WolfManager.getState(model) local s = active[model]; return s and s.state end
function WolfManager.getAll()
	local t = {}
	for m in pairs(active) do t[#t+1] = m end
	return t
end
function WolfManager.despawnAll()
	for m, s in pairs(active) do s.alive = false; if m.Parent then m:Destroy() end end
	active = {}
end

-- ── driver ──────────────────────────────────────
RunService.Heartbeat:Connect(function()
	for _, s in pairs(active) do
		local ok, err = pcall(step, s)
		if not ok then warn("[WolfManager] step error: " .. tostring(err)) end
	end
end)

-- Read incoming player M1s. When a player swings an M1 with a wolf in front of them and in
-- range, that wolf SOMETIMES parries it: it arms a short parry window (so the hit, which lands
-- ~0.53s later after the M1 startup telegraph, gets negated in HealthChanged) and plays the
-- parry animation as the read. Chance + a cooldown keep it occasional -- it only parries attacks
-- actually swung its way, never a flat roll on every hit.
--
-- 2026-08-02 combat teardown: RequestM1 no longer exists, so this hook is dormant. Rather
-- than sit in a 20s WaitForChild that always times out, it now binds through the seam --
-- the revamp exposes its swing signal as _G.CombatSystem.PlayerSwung (a signal with a
-- :Connect(player) contract) and the wolf's read-parry comes back with no edits here.
-- The whole body below is preserved and unchanged; only the wiring in front of it moved.
task.spawn(function()
	local swung
	for _ = 1, 60 do -- ~30s of polling, then give up quietly
		local cs = _G.CombatSystem
		if cs and cs.PlayerSwung and cs.PlayerSwung.Connect then swung = cs.PlayerSwung; break end
		task.wait(0.5)
	end
	if not swung then return end -- combat absent: wolves simply never read-parry
	swung:Connect(function(player)
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not hrp then return end
		for _, s in pairs(active) do
			if s.alive and not s.attacking and s.state ~= "Stunned"
			   and tick() >= (s.parryUntil or 0) and s.root and s.root.Parent then
				local toWolf = s.root.Position - hrp.Position
				local dist = toWolf.Magnitude
				-- Only "coming its way": attacker close enough AND facing the wolf.
				if dist <= (cfg.ParryReadRange or 11) and dist > 0
				   and hrp.CFrame.LookVector:Dot(toWolf.Unit) > 0.35
				   and math.random() < (cfg.ParryChance or 0) then
					s.parryUntil  = tick() + (cfg.ParryCooldown or 3.5)
					s.parryWindow = tick() + (cfg.ParryReadWindow or 0.65)
					playOnce(s, "Parry")
					-- Turn to face the attacker as it reads the swing.
					local flat = Vector3.new(hrp.Position.X, s.root.Position.Y, hrp.Position.Z)
					pcall(function() s.model:PivotTo(CFrame.lookAt(s.root.Position, flat)) end)
					-- PLACEHOLDER_SOUND: wolf_parry
				end
			end
		end
	end)
end)

_G.WolfManager = WolfManager
log("Initialized -- rig=" .. cfg.ModelName .. " (R6 quadruped, Humanoid+Animator confirmed)")
