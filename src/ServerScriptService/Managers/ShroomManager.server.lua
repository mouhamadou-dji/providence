-- ShroomManager -- the Shroom mob (rig: workspace.SporeGoober) as a real state machine.
--
-- RIG FACTS (confirmed live in Studio 2026-07-21, NOT assumed):
--   * The rig is "SporeGooberChild", 4 legs (UpperLeg1-4 / LowerLeg1-4) + Torso + Head + Teeth.
--     Workspace also has two plain "SporeGoober" models -- those are NOT the mob.
--   * It HAS a Humanoid with an Animator. The spec assumed a non-Humanoid AnimationController
--     rig; it is not one. So movement is Humanoid:MoveTo + PathfindingService (the simpler,
--     recommended path) and animations load off Humanoid.Animator.
--   * All three animation IDs verified loadable on this rig: Walk 1.95s, Swing 0.65s, Left 0.65s.
--
-- Server-authoritative per CLAUDE.md: the mob lives entirely on the server, hitboxes use
-- GetPartBoundsInBox (never Touched), and the client is never trusted for anything.

local Players           = game:GetService("Players")
local RepStorage        = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local PathfindingService = game:GetService("PathfindingService")
local Debris            = game:GetService("Debris")

local Config   = require(RepStorage.Shared.Config)
local cfg      = Config.ShroomMob
local lootCfg  = Config.ShroomLoot
local ParryCfg = Config.Parry

local ShroomManager = {}
local active = {}   -- [model] = state table
local nextId = 0

-- ── helpers ─────────────────────────────────────────────────────────────────
local function log(...) print("[ShroomManager]", ...) end

local function discord(event, details)
	local d = _G.DiscordManager
	if d and d.logNPC then pcall(d.logNPC, event, details) end
end

local function template()
	return RepStorage:FindFirstChild(cfg.ModelName) or workspace:FindFirstChild(cfg.ModelName)
end

-- Rotate the rig to look at a world point WITHOUT moving it. With Humanoid.AutoRotate turned OFF
-- (see the Chase movement block) this lets the Shroom STRAFE and BACKPEDAL while keeping its eyes
-- on the target -- it circles/backs off facing you instead of turning its back to walk. Declared
-- up here as a local so doAttack and step capture it as an upvalue (order matters for locals).
local function faceFlat(s, worldPos)
	if not s.root then return end
	local pos = s.root.Position
	local look = Vector3.new(worldPos.X, pos.Y, worldPos.Z)
	if (look - pos).Magnitude > 0.05 then
		s.root.CFrame = CFrame.lookAt(pos, look)
	end
end

local function alivePlayers()
	local t = {}
	for _, p in ipairs(Players:GetPlayers()) do
		local char = p.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		-- Valhalla players (PlayerState Dead) are fully immune per CLAUDE.md -- never target them.
		local dm = _G.DataManager
		local state = dm and dm.getValue and dm.getValue(p, "PlayerState")
		if hum and hrp and hum.Health > 0 and state ~= "Dead" then
			t[#t+1] = { player = p, hum = hum, hrp = hrp }
		end
	end
	return t
end

-- ── animation ────────────────────────────────────────────────────────
local function loadAnims(s)
	local animator = s.hum:FindFirstChildOfClass("Animator")
	if not animator then animator = Instance.new("Animator"); animator.Parent = s.hum end
	s.tracks = {}
	for key, id in pairs(cfg.Anims) do
		local a = Instance.new("Animation"); a.AnimationId = id
		local ok, track = pcall(function() return animator:LoadAnimation(a) end)
		if ok and track then
			track.Looped = (key == "Walk")
			track.Priority = (key == "Walk") and Enum.AnimationPriority.Movement or Enum.AnimationPriority.Action
			s.tracks[key] = track
		else
			warn("[ShroomManager] animation failed to load: " .. key)
		end
	end
end

local function playWalk(s, speedScale)
	local t = s.tracks and s.tracks.Walk
	if not t then return end
	if not t.IsPlaying then t:Play(0.2) end
	t:AdjustSpeed(speedScale or 1)
end
local function stopWalk(s)
	local t = s.tracks and s.tracks.Walk
	if t and t.IsPlaying then t:Stop(0.2) end
end

-- ── windup telegraph ──────────────────────────────────────────────────
-- PLACEHOLDER_ASSET: shroom_windup_tell -- a real authored VFX would replace this Highlight.
-- The visual tell is what makes the attack readable/parryable, so it exists even as a stub.
local function windupTell(s, on)
	if on then
		if s.tell then return end
		local hl = Instance.new("Highlight")
		hl.Name = "ShroomWindup"
		hl.FillColor = Color3.fromRGB(210, 150, 40)
		hl.FillTransparency = 0.8
		hl.OutlineColor = Color3.fromRGB(255, 200, 90)
		hl.OutlineTransparency = 0.2
		hl.Parent = s.model
		s.tell = hl
	else
		if s.tell then s.tell:Destroy(); s.tell = nil end
	end
end

-- ── loot ──────────────────────────────────────────────────────────
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

-- Physical pickup at the death location. Reuses the game's existing interactable convention
-- (attributes + ProximityPrompt) rather than inventing a second pickup system.
local function dropLoot(position, killerName)
	local item, count = rollLoot()
	local drop = Instance.new("Part")
	drop.Name = "ShroomDrop_" .. item
	drop.Size = Vector3.new(1.4, 1.4, 1.4)
	drop.Position = position + Vector3.new(0, 2, 0)
	drop.Anchored = false
	drop.CanCollide = true
	drop.Color = Color3.fromRGB(150, 120, 90)
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
		discord("MOB_LOOT", string.format("%s collected %s x%d from a Shroom", p.Name, item, count))
		drop:Destroy()
	end)

	Debris:AddItem(drop, 300)
	return item, count
end

-- ── hitbox (GetPartBoundsInBox -- never Touched, per CLAUDE.md rule 5) ────────────────
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

-- ── stun (what a successful parry does to the mob) ─────────────────────────────
local function stun(s, duration, reason)
	s.state = "Stunned"
	s.stunUntil = tick() + duration
	s.attacking = false
	windupTell(s, false)
	if s.hum then s.hum.WalkSpeed = 0; s.hum:MoveTo(s.root.Position) end
	stopWalk(s)
	for _, t in pairs(s.tracks or {}) do if t.IsPlaying and t ~= s.tracks.Walk then t:Stop(0.1) end end
	log(string.format("stunned %.2fs (%s)", duration, tostring(reason)))
end

-- ── attack resolution ────────────────────────────────────────────────
-- Parry is classified here rather than through ParryManager.checkHit, because that function
-- expects a Player attacker and the Shroom is a Model. The WINDOWS come from Config.Parry all
-- the same, so mob parries obey exactly the same law as player-vs-player parries.
local function resolveHit(s, atkCfg)
	local pm = _G.ParryManager
	local cm = _G.CombatManager
	local pmgr = _G.PostureManager
	local victims = playersInHitbox(s, atkCfg.range)

	for _, p in ipairs(victims) do
		local char = p.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		-- nil-safe HRP: a player respawning mid-hit can have a Humanoid but no HRP for a frame, and
		-- indexing char.HumanoidRootPart.Position (even as a pcall arg) would THROW, killing the
		-- doAttack coroutine with s.attacking stuck true (the mob would freeze). See WolfManager.
		local vhrp = char and char:FindFirstChild("HumanoidRootPart")
		if hum and hum.Health > 0 then
			local parried, perfect = false, false
			if pm and pm.isParrying and pm.isParrying(p) then
				local elapsed = pm.getElapsed and pm.getElapsed(p)
				if elapsed then
					if elapsed <= ParryCfg.PerfectWindow / 60 then parried, perfect = true, true
					elseif elapsed <= ParryCfg.WindowTotal / 60 then parried = true end
				end
			end

			if parried then
				-- Perfect parry: full punish window + bonus damage. Late: damage denied, no stun.
				if perfect then
					stun(s, cfg.ParryStunDuration, "perfect parry by " .. p.Name)
					s.bonusDamageUntil = tick() + cfg.ParryStunDuration
					if cm and cm.spawnParryVFX then
						if vhrp then pcall(cm.spawnParryVFX, (s.root.Position + vhrp.Position) / 2) end
					end
					local re = RepStorage:FindFirstChild("RemoteEvents")
					re = re and re:FindFirstChild("OnParryResult")
					if re then re:FireClient(p, { result = "Perfect", source = "Shroom" }) end
					if pmgr and pmgr.fill then pcall(pmgr.fill, p, -0) end
				else
					local re = RepStorage:FindFirstChild("RemoteEvents")
					re = re and re:FindFirstChild("OnParryResult")
					if re then re:FireClient(p, { result = "Late", source = "Shroom" }) end
				end
				return true -- a parried swing hits nobody else either
			end

			-- Blocking: chip posture, no damage.
			local blocking = cm and cm.getCombatState and cm.getCombatState(p) == "Blocking"
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

				-- Impact reaction: brief stun + sideways shove + the real got-hit animation.
				-- Without these a mob hit just silently removed HP while you kept full control.
				if cm and cm.applyHitstun then
					pcall(cm.applyHitstun, p, cfg.HitstunDuration)
				end
				if cm and cm.applyKnockback then
					-- Shoved ALONG the swing arc, not just straight back -- these are sweeping
					-- attacks, and the two attacks throw you opposite ways (lateralSign).
					local lateral = s.root.CFrame.RightVector * (atkCfg.lateralSign or 1)
					pcall(cm.applyKnockback, s.model, char, cfg.KnockbackForce, lateral, cfg.KnockbackLateral)
				end
				-- Claws tear: a landed hit can open a bleed, chipping the blood bar over the fight.
				if atkCfg.bleedTier and math.random() < (atkCfg.bleedChance or 0) then
					local bm = _G.BleedManager
					if bm and bm.applyBleed then pcall(bm.applyBleed, p, atkCfg.bleedTier) end
				end

				-- Reuses the player got-hit reaction (M1GotHit, 5 variants) via the same remote
				-- CombatManager fires, so the mob's hits animate identically to a player's.
				local reFolder = RepStorage:FindFirstChild("RemoteEvents")
				local rePlayAnim = reFolder and reFolder:FindFirstChild("PlayCombatAnim")
				if rePlayAnim then rePlayAnim:FireClient(p, "M1GotHit", math.random(1, 5)) end

				s.lastHitPlayer = p
			end
		end
	end
	return false
end

-- ── attack selection (adaptive, not random) ──────────────────────────────────
local function chooseAttack(s, targetHRP)
	local toTarget = (targetHRP.Position - s.root.Position)
	local right = s.root.CFrame.RightVector
	local side = right:Dot(toTarget.Unit) -- <0 means the player is on the mob's LEFT

	-- Adaptive read: if the player has evaded the same attack twice running, switch to the
	-- other one to catch them. This is what makes it feel like it's reading you.
	if s.evadeStreakAttack and s.evadeStreak >= 2 then
		s.evadeStreak = 0
		return s.evadeStreakAttack == "Swing" and "Left" or "Swing"
	end

	if side < -0.15 then
		-- player is circling left -> ShroomLeft is the anti-strafe tool
		return (math.random() < 0.70) and "Left" or "Swing"
	else
		return (math.random() < 0.70) and "Swing" or "Left"
	end
end

-- ── the three-phase attack ──────────────────────────────────────────────
local function doAttack(s, attackName)
	local atk = cfg.Attacks[attackName]
	if not atk then return end
	s.attacking = true
	s.state = "Attack"
	s.currentAttack = attackName
	s.hum.WalkSpeed = 0
	stopWalk(s)
	-- Face the target as the swing starts (AutoRotate is off in combat, so nothing else turns it).
	local atkHRP = s.target and s.target.Character and s.target.Character:FindFirstChild("HumanoidRootPart")
	if atkHRP then faceFlat(s, atkHRP.Position) end

	local track = s.tracks and s.tracks[atk.anim]
	if track then track:Play(0.1) end

	-- WINDUP: no hitbox, visible tell. This is the read/parry window.
	windupTell(s, true)
	local t0 = tick()
	while tick() - t0 < atk.windup do
		if not s.alive or s.state == "Stunned" then windupTell(s, false); s.attacking = false; return end
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
			local wasParried = resolveHit(s, atk)
			if wasParried then s.attacking = false; return end
		end
		task.wait()
	end

	-- Track evasion for the adaptive read: nobody took damage from this swing.
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
		-- FLURRY: sometimes skip the stalk and immediately press another swing; otherwise start a
		-- fresh orbit window. This is the Shroom's aggressive in-out rhythm.
		if math.random() < (cfg.ComboChance or 0) then
			s.circleUntil = 0
		else
			s.circleUntil = tick() + (cfg.CircleMin or 1.0) + math.random() * ((cfg.CircleMax or 2.6) - (cfg.CircleMin or 1.0))
		end
	end
end

-- ── advanced targeting + movement (mirrors WolfManager, tuned slower/lurkier) ────────
local function nearestPlayer(s, maxRange)
	local best, bestD = nil, maxRange or math.huge
	for _, e in ipairs(alivePlayers()) do
		local d = (e.hrp.Position - s.root.Position).Magnitude
		if d < bestD then best, bestD = e, d end
	end
	return best
end

-- Score every reachable player by proximity + how much they've recently hurt the Shroom, with a
-- stickiness bonus for the current target so it doesn't flip-flop every check.
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

-- A point on a ring around the target, rotated to the Shroom's circling side -- moving toward it
-- makes it STALK in an arc instead of shambling dead-straight at you.
local function orbitPoint(s, tHRP)
	local flat = s.root.Position - tHRP.Position
	flat = Vector3.new(flat.X, 0, flat.Z)
	local dir = (flat.Magnitude > 0.1) and flat.Unit or s.root.CFrame.LookVector
	local ang = math.rad((cfg.StrafeAngle or 26) * (s.strafeSign or 1))
	local c, sn = math.cos(ang), math.sin(ang)
	local rot = Vector3.new(dir.X * c - dir.Z * sn, 0, dir.X * sn + dir.Z * c)
	return tHRP.Position + rot * (cfg.StrafeRadius or 11)
end

-- Hop-in gap-closer: a short spore lunge -- Swing clip + a forward velocity burst, then a bite.
local function doLunge(s, tHRP)
	s.attacking = true; s.state = "Attack"; s.currentAttack = "Lunge"
	s.lungeCdUntil = tick() + (cfg.LungeCooldown or 5.5)
	s.hum.WalkSpeed = 0; stopWalk(s)
	local face = Vector3.new(tHRP.Position.X, s.root.Position.Y, tHRP.Position.Z)
	pcall(function() s.model:PivotTo(CFrame.lookAt(s.root.Position, face)) end)
	local st = s.tracks and s.tracks.Swing; if st then st:Play(0.1) end
	windupTell(s, true)
	local t0 = tick()
	while tick() - t0 < (cfg.LungeWindup or 0.3) do
		if not s.alive or s.state == "Stunned" then windupTell(s, false); s.attacking = false; return end
		task.wait()
	end
	windupTell(s, false)
	if not s.alive or s.state == "Stunned" then s.attacking = false; return end
	local dir = face - s.root.Position
	dir = (dir.Magnitude > 0.1) and dir.Unit or s.root.CFrame.LookVector
	s.root.AssemblyLinearVelocity = dir * (cfg.LungeSpeed or 42) + Vector3.new(0, 12, 0)
	local atk = cfg.Attacks.Lunge or cfg.Attacks.Swing
	local hit, t1 = false, tick()
	while tick() - t1 < (cfg.LungeActive or 0.35) do
		if not s.alive or s.state == "Stunned" then s.attacking = false; return end
		if not hit then hit = true; if resolveHit(s, atk) then break end end
		task.wait()
	end
	s.lastHitPlayer = nil
	s.state = "Recover"
	local t2 = tick()
	while tick() - t2 < (cfg.LungeRecovery or 0.7) do
		if not s.alive or s.state == "Stunned" then s.attacking = false; return end
		task.wait()
	end
	s.attacking = false
	if s.alive and s.state == "Recover" then s.state = "Chase"; s.circleUntil = tick() + (cfg.CircleMin or 1.0) end
end

-- Feint: start a swing windup then abort before the hitbox -- baits a panic parry/dodge.
local function doFeint(s)
	s.attacking = true; s.state = "Attack"
	s.feintCdUntil = tick() + (cfg.FeintCooldown or 4.5)
	s.hum.WalkSpeed = 0; stopWalk(s)
	local key = (math.random() < 0.5) and "Swing" or "Left"
	local atk = cfg.Attacks[key]
	local st = s.tracks and s.tracks[atk.anim]; if st then st:Play(0.1) end
	windupTell(s, true)
	local t0 = tick()
	while tick() - t0 < (atk.windup or 0.4) * 0.55 do
		if not s.alive or s.state == "Stunned" then windupTell(s, false); s.attacking = false; return end
		task.wait()
	end
	windupTell(s, false)
	if st then st:Stop(0.12) end
	s.state = "Recover"
	local t1 = tick()
	while tick() - t1 < 0.3 do
		if not s.alive or s.state == "Stunned" then s.attacking = false; return end
		task.wait()
	end
	s.attacking = false
	if s.alive and s.state == "Recover" then s.state = "Chase" end
end

-- ── death ────────────────────────────────────────────────────────
local function die(s, killer)
	if not s.alive then return end
	s.alive = false
	s.state = "Dead"
	s.attacking = false
	windupTell(s, false)
	stopWalk(s)
	active[s.model] = nil

	local pos = s.root and s.root.Position or s.model:GetPivot().Position
	-- PLACEHOLDER_SOUND: shroom_death

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
		discord("MOB_KILLED", string.format("%s killed a Shroom (dropped %s x%d)", killer.Name, item, count))
	else
		discord("MOB_KILLED", string.format("A Shroom died (dropped %s x%d)", item, count))
	end

	task.delay(cfg.DespawnAfter, function()
		if s.model and s.model.Parent then s.model:Destroy() end
	end)
end

-- ── perception ────────────────────────────────────────────────────
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

-- Async pathfinding. ComputeAsync YIELDS and step() runs INLINE in the Heartbeat loop, so the old
-- synchronous version stalled the mob every RepathInterval (the "steps then freezes" stutter).
-- Compute on a side coroutine and swap the waypoints in when ready -- the step loop never blocks.
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
			s.waypointIndex = 2 -- [1] is where we already are
		else
			s.waypoints = nil -- fall back to a direct MoveTo
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

-- ── state machine ─────────────────────────────────────────────────
local function step(s)
	if not s.alive then return end
	if not s.model.Parent or not s.root or not s.root.Parent then s.alive = false; active[s.model] = nil; return end
	if s.hum.Health <= 0 then die(s, s.lastAttacker); return end

	local now = tick()

	-- Stunned overrides everything (this is the parry punish window).
	if s.state == "Stunned" then
		if now >= s.stunUntil then
			s.state = "Chase"
			s.hum.WalkSpeed = cfg.ChaseSpeed
		end
		return
	end
	if s.attacking then return end -- doAttack owns the mob during its phases

	-- Flee check: low HP, once, by chance.
	if not s.fleeRolled and s.hum.Health <= cfg.Health * cfg.FleeHealthPct then
		s.fleeRolled = true
		if math.random() < cfg.FleeChance then s.state = "Flee" end
	end

	local target = s.target
	local tHRP = target and target.Character and target.Character:FindFirstChild("HumanoidRootPart")
	local distToSpawn = (s.root.Position - s.spawnPos).Magnitude

	if s.state == "Idle" then
		s.hum.WalkSpeed = 0
		stopWalk(s)
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
		playWalk(s, 0.8)
		followPath(s, s.patrolTarget)
		repath(s, s.patrolTarget)
		if (s.root.Position - s.patrolTarget).Magnitude < 5 then s.state = "Idle"; s.waypoints = nil end
		if now >= (s.nextScan or 0) then
			s.nextScan = now + cfg.ScanInterval
			local seen = scan(s)
			if seen then s.target = seen.player; s.state = "Alert"; s.alertUntil = now + cfg.AlertPause end
		end

	elseif s.state == "Alert" then
		-- Stop, turn to face, hold a beat. The "it noticed you" telegraph.
		s.hum.WalkSpeed = 0
		stopWalk(s)
		if tHRP then
			local flat = Vector3.new(tHRP.Position.X, s.root.Position.Y, tHRP.Position.Z)
			s.model:PivotTo(CFrame.lookAt(s.root.Position, flat))
		end
		if not s.alertSounded then
			s.alertSounded = true
			-- PLACEHOLDER_SOUND: shroom_alert
		end
		if now >= s.alertUntil then s.state = "Chase"; s.alertSounded = false end

	elseif s.state == "Chase" then
		if not tHRP then s.state = "Idle"; s.target = nil; return end

		-- Re-pick the best target periodically (distance + recent damage-to-the-Shroom) so it
		-- doesn't tunnel on one player while another is closer or beating on it.
		if now >= (s.nextTargetCheck or 0) then
			local dtCheck = cfg.TargetReassessInterval or 2.0
			s.nextTargetCheck = now + dtCheck
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

		if now >= (s.nextStrafeFlip or 0) then
			s.nextStrafeFlip = now + (cfg.StrafeInterval or 2.0)
			s.strafeSign = (math.random() < 0.5) and 1 or -1
		end

		local dist = (tHRP.Position - s.root.Position).Magnitude
		if dist > cfg.LoseInterestRange or distToSpawn > cfg.LeashRange then
			s.target = nil; s.state = "Flee"; return
		end

		-- IN RANGE (past the stalk window): feint or attack.
		if dist <= cfg.AttackRange and hasLineOfSight(s, tHRP) and now >= (s.circleUntil or 0) then
			if now >= (s.feintCdUntil or 0) and math.random() < (cfg.FeintChance or 0) then
				task.spawn(function()
					local ok = pcall(doFeint, s)
					if not ok then s.attacking = false; windupTell(s, false); if s.alive then s.state = "Chase" end end
				end)
				return
			end
			-- Protected: a one-off error in doAttack/resolveHit can never freeze the mob mid-attack.
			task.spawn(function()
				local ok, err = pcall(doAttack, s, chooseAttack(s, tHRP))
				if not ok then
					warn("[ShroomManager] doAttack error: " .. tostring(err))
					s.attacking = false; windupTell(s, false)
					if s.alive and (s.state == "Attack" or s.state == "Recover") then s.state = "Chase" end
				end
			end)
			return
		end

		-- HOP-LUNGE to close a medium gap (a burst of aggression between the circling).
		if dist > cfg.AttackRange and dist <= (cfg.LungeRange or 14) and hasLineOfSight(s, tHRP)
		   and now >= (s.lungeCdUntil or 0) and math.random() < (cfg.LungeChance or 0.4) then
			task.spawn(function()
				local ok = pcall(doLunge, s, tHRP)
				if not ok then s.attacking = false; windupTell(s, false); if s.alive then s.state = "Chase" end end
			end)
			return
		end

		-- MOVE -- two regimes:
		--   COMBAT SPACING (within EngageRange + line of sight): drive straight toward the destination
		--   with AutoRotate OFF and the rig hand-aimed at the target, so it CIRCLES / BACKS OFF while
		--   facing you instead of turning around to walk. No pathfinding here -- a direct MoveTo every
		--   frame keeps it fluid (the async ComputeAsync was the stutter, so we skip it at close range).
		--   APPROACH (far, or LOS blocked): natural face-forward shamble, pathfinding around obstacles.
		s.hum.WalkSpeed = cfg.ChaseSpeed
		if dist <= (cfg.EngageRange or 20) and hasLineOfSight(s, tHRP) then
			local orbiting = now < (s.circleUntil or 0) or dist <= cfg.AttackRange
			s.hum.AutoRotate = false
			faceFlat(s, tHRP.Position)
			s.waypoints = nil
			playWalk(s, orbiting and 1.0 or 1.2)
			s.hum:MoveTo(orbiting and orbitPoint(s, tHRP) or tHRP.Position)
		else
			s.hum.AutoRotate = true
			playWalk(s, 1.2)
			repath(s, tHRP.Position)
			followPath(s, tHRP.Position)
		end

	elseif s.state == "Flee" then
		s.hum.WalkSpeed = cfg.ChaseSpeed
		s.hum.AutoRotate = true -- fleeing: face away toward home, not the target
		playWalk(s, 1.2)
		repath(s, s.spawnPos)
		followPath(s, s.spawnPos)
		if distToSpawn < 8 then s.state = "Idle"; s.target = nil; s.waypoints = nil end

	elseif s.state == "Recover" then
		s.hum.WalkSpeed = 0
	end
end

-- ── spawn ──────────────────────────────────────────────────────
function ShroomManager.spawn(position, overrides)
	local tpl = template()
	if not tpl then warn("[ShroomManager] no " .. cfg.ModelName .. " template found"); return nil end
	overrides = overrides or {}

	local wasArchivable = tpl.Archivable
	tpl.Archivable = true
	local model = tpl:Clone()
	tpl.Archivable = wasArchivable
	if not model then warn("[ShroomManager] clone failed"); return nil end

	nextId += 1
	model.Name = "Shroom_" .. nextId
	local hum = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not hum or not root then model:Destroy(); warn("[ShroomManager] rig missing Humanoid/HRP"); return nil end

	hum.MaxHealth = overrides.Health or cfg.Health
	hum.Health    = hum.MaxHealth
	hum.WalkSpeed = cfg.WalkSpeed
	-- The rig ships with HipHeight = 0, which would plant the ROOT on the ground and bury all
	-- four legs. cfg.HipHeight is its measured root-to-sole distance (4.80), so force it.
	hum.HipHeight = cfg.HipHeight
	hum.DisplayName = cfg.DisplayName
	-- Keep the rig WHOLE on death: Roblox breaks all joints the instant Health hits 0 by default,
	-- which would scatter the parts before the fade-out runs. We want it to fade intact, not shatter.
	hum.BreakJointsOnDeath = false

	model:PivotTo(CFrame.new(position))
	model.Parent = workspace

	local s = {
		model = model, hum = hum, root = root,
		state = "Idle", alive = true, attacking = false,
		spawnPos = position,
		damage = overrides.AttackDamage or cfg.AttackDamage,
		leash = overrides.LeashRange or cfg.LeashRange,
		evadeStreak = 0,
		stunUntil = 0, bonusDamageUntil = 0,
		threat = {}, strafeSign = 1,
	}
	loadAnims(s)
	active[model] = s

	-- HealthChanged: death + THREAT credit (target selection favours whoever's hurting it) +
	-- aggro-on-hit (a hit pulls a roaming Shroom into the fight even if it never saw you coming).
	s.lastHealth = hum.Health
	hum.HealthChanged:Connect(function()
		if not s.alive then return end
		local cur, prev = hum.Health, (s.lastHealth or hum.Health)
		if cur <= 0 then s.lastHealth = cur; die(s, s.lastAttacker); return end
		if cur < prev then
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

	discord("MOB_SPAWNED", string.format("Shroom spawned at (%.0f, %.0f, %.0f)", position.X, position.Y, position.Z))
	log("spawned " .. model.Name .. " at " .. tostring(position))
	return model
end

-- Damage entry point so attackers get the stunned-target bonus and kill attribution.
function ShroomManager.damage(model, amount, attacker)
	local s = active[model]
	if not s or not s.alive then return false end
	local mult = (tick() < (s.bonusDamageUntil or 0)) and cfg.ParryBonusDamageMult or 1
	s.lastAttacker = attacker
	s.hum:TakeDamage(amount * mult)
	-- Any hit pulls it into the fight even if it never saw you coming.
	if attacker and s.state == "Idle" or s.state == "Patrol" then
		s.target = attacker; s.state = "Chase"
	end
	return true, amount * mult, mult > 1
end

function ShroomManager.isShroom(model) return active[model] ~= nil end
function ShroomManager.getState(model) local s = active[model]; return s and s.state end
function ShroomManager.getAll()
	local t = {}
	for m in pairs(active) do t[#t+1] = m end
	return t
end
function ShroomManager.despawnAll()
	for m, s in pairs(active) do s.alive = false; if m.Parent then m:Destroy() end end
	active = {}
end

-- ── driver ──────────────────────────────────────────────────────
RunService.Heartbeat:Connect(function()
	for _, s in pairs(active) do
		local ok, err = pcall(step, s)
		if not ok then warn("[ShroomManager] step error: " .. tostring(err)) end
	end
end)

_G.ShroomManager = ShroomManager
log("Initialized -- rig=" .. cfg.ModelName .. " (Humanoid+Animator confirmed)")
