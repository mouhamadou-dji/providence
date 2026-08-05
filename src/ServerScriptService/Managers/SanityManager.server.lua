-- SanityManager -- hidden psychological-horror meter (see design doc PART ONE/TWO).
-- Never shown to the player by default; drives the hallucination tiers and Rage eligibility.
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local sanityCfg   = Config.Sanity
local recoveryCfg = Config.SanityRecovery

local function getOrCreate(name, isFunc)
	local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
		local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
	end)()
	local r=folder:FindFirstChild(name); if r then return r end
	r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_UpdateSanityEffects = getOrCreate("UpdateSanityEffects")
local RE_LiveFeedUpdate      = getOrCreate("LiveFeedUpdate")
local RE_SanityScratch       = getOrCreate("SanityScratchTrigger")
local RE_SanityShadowSpawn   = getOrCreate("SanityShadowSpawn")

local function getCharName(player)
	local dm = _G.DataManager
	local n = dm and dm.getValue(player, "FirstName")
	if not n or n == "" then n = player.Name end
	return n
end

local function fireLiveFeed(charName, message)
	local now = os.date("*t")
	local mgr = _G.ModManager
	for _, p in ipairs(Players:GetPlayers()) do
		if mgr and mgr.isMod(p) then
			RE_LiveFeedUpdate:FireClient(p, { type = "SANITY", h = now.hour, m = now.min, zone = "?", charName = charName, message = message })
		end
	end
end

local function getPlayersInRange(position, range, excludeSet)
	local result = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if not (excludeSet and excludeSet[p]) then
			local char = p.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp and (hrp.Position - position).Magnitude <= range then
				table.insert(result, p)
			end
		end
	end
	return result
end

-- ── Per-player runtime state (session-only -- resets on rejoin; the persisted number
-- itself lives in DataManager's "Sanity" field) ───────────────────────────────────
local tierState        = {} -- [userId] = {scratch=,scribble=,shadow=,shadowAttack=,cliffPull=}
local nextScratchAt    = {} -- [userId] = tick
local nextShadowRollAt = {} -- [userId] = tick
local lastShadowStunAt = {} -- [userId] = tick
local hostileExposure  = {} -- [userId] = {since=tick, applied=bool}
local meditateAccum    = {} -- [userId] = seconds accumulated toward next per-minute tick
local allyAccum        = {} -- [userId] = seconds accumulated toward next per-minute tick
local recoveryDebuff   = {} -- [userId] = {mult=, until_=tick} -- lore-team Rage exit debuff option

local SanityManager = {}

function SanityManager.getSanity(player)
	local dm = _G.DataManager
	return dm and (dm.getValue(player, "Sanity") or 0) or 0
end

local function tierActive(sanity, threshold, wasActive)
	if wasActive then return sanity >= (threshold - sanityCfg.Hysteresis) end
	return sanity >= threshold
end

local function refreshTiers(player)
	local sanity = SanityManager.getSanity(player)
	local uid = player.UserId
	local prev = tierState[uid] or {}
	local cur = {
		scratch      = tierActive(sanity, sanityCfg.ScratchThreshold, prev.scratch),
		scribble     = tierActive(sanity, sanityCfg.FaceScribbleThreshold, prev.scribble),
		shadow       = tierActive(sanity, sanityCfg.ShadowFiguresThreshold, prev.shadow),
		shadowAttack = tierActive(sanity, sanityCfg.ShadowFiguresStunThreshold, prev.shadowAttack),
		cliffPull    = tierActive(sanity, sanityCfg.CliffPullThreshold, prev.cliffPull),
	}
	tierState[uid] = cur
	local changed = prev.scratch~=cur.scratch or prev.scribble~=cur.scribble or prev.shadow~=cur.shadow
		or prev.shadowAttack~=cur.shadowAttack or prev.cliffPull~=cur.cliffPull
	if changed then RE_UpdateSanityEffects:FireClient(player, {tiers=cur}) end
	return cur
end

function SanityManager.isRageEligible(player)
	return SanityManager.getSanity(player) >= sanityCfg.RageEligibilityThreshold
end

function SanityManager.getTiers(player)
	return tierState[player.UserId] or {}
end

function SanityManager.adjustSanity(player, delta, reason)
	local dm = _G.DataManager
	if not dm or not dm.isLoaded(player) then return end
	-- Aquitani SanityResistance slows how fast sanity RISES only. Recovery (negative delta) is
	-- untouched -- a disciplined mind resists the dark, it does not heal from it faster.
	if delta > 0 then
		local cm = _G.CasteManager
		if cm then delta = delta * cm.getSanityRiseMultiplier(player) end
	end
	local cur = dm.getValue(player, "Sanity") or 0
	local new = math.clamp(cur + delta, 0, 100)
	dm.setValue(player, "Sanity", new)
	if new == cur then return new end
	local charName = getCharName(player)
	local msg = string.format("%s sanity %d -> %d (%s: %s%d)", charName, cur, new, tostring(reason),
		(delta >= 0) and "+" or "", delta)
	print("[SanityManager] " .. msg)
	local disc = _G.DiscordManager
	if disc and disc.logSanity then disc.logSanity(charName, msg) end
	fireLiveFeed(charName, msg)
	refreshTiers(player)
	return new
end

function SanityManager.setSanity(player, value, reason)
	local dm = _G.DataManager
	if not dm or not dm.isLoaded(player) then return end
	local cur = dm.getValue(player, "Sanity") or 0
	SanityManager.adjustSanity(player, math.clamp(value, 0, 100) - cur, reason or "LoreTeamAction")
end

-- ── Witness / event triggers (called by other managers) ───────────────────────────
function SanityManager.notifyWitnessDeath(position, isGrip, excludeSet)
	local amount = isGrip and sanityCfg.WitnessGripDeath or sanityCfg.WitnessDeath
	for _, p in ipairs(getPlayersInRange(position, sanityCfg.WitnessRadius, excludeSet)) do
		SanityManager.adjustSanity(p, amount, isGrip and "WitnessGripDeath" or "WitnessDeath")
		local fm = _G.FeelingsManager
		if fm then fm.trigger(p, isGrip and "OnWitnessGripDeath" or "OnWitnessDeath") end
	end
end

function SanityManager.notifyKillPlayer(attacker, isAllyKill)
	if isAllyKill then
		SanityManager.adjustSanity(attacker, sanityCfg.KillAlly, "KillAlly")
	else
		SanityManager.adjustSanity(attacker, sanityCfg.KillPlayer, "KillPlayer")
		local fm, tm = _G.FeelingsManager, _G.TalentManager
		if fm and not (tm and tm.hasTalent(attacker, "ColdBlood")) then fm.trigger(attacker, "OnKillWithNoTalent") end
	end
end

function SanityManager.notifyWitnessAllyDeath(player)
	SanityManager.adjustSanity(player, sanityCfg.WitnessAllyDeath, "WitnessAllyDeath")
end

function SanityManager.notifyInjury(player, reasonKey)
	local amount = sanityCfg[reasonKey]
	if amount then SanityManager.adjustSanity(player, amount, reasonKey) end
end

function SanityManager.notifyRitualFailure(position)
	for _, p in ipairs(getPlayersInRange(position, sanityCfg.RitualFailureRadius)) do
		SanityManager.adjustSanity(p, sanityCfg.NearRitualFailure, "NearRitualFailure")
	end
end

-- Called from SpiritManager's own Heartbeat loop (already scanning hostile spirits nearby
-- every 2s for AwakenedEyes holders) -- tracks continuous unbroken exposure and grants
-- sanity once per 30s window, resetting if the player leaves range in between.
function SanityManager.trackHostileSpiritExposure(player)
	local uid = player.UserId
	local now = tick()
	local e = hostileExposure[uid]
	if not e then e = {since = now, applied = false}; hostileExposure[uid] = e end
	if not e.applied and (now - e.since) >= 30 then
		e.applied = true
		SanityManager.adjustSanity(player, sanityCfg.SpiritHostileEncounter, "SpiritHostileEncounter")
	end
end
function SanityManager.clearHostileSpiritExposure(player)
	hostileExposure[player.UserId] = nil
end

-- ── Recovery actions (explicit only -- no passive drift; see Config.SanityRecovery) ──
function SanityManager.recoverPerMinuteTick(player, kind)
	local amount = recoveryCfg[kind]
	if not amount then return end
	local rd = recoveryDebuff[player.UserId]
	local mult = (rd and tick() < rd.until_) and rd.mult or 1
	SanityManager.adjustSanity(player, -amount * mult, kind)
end

-- Rage exit debuff option: "Reduce Sanity Recovery Rate temporarily" (see RageManager /
-- ModManager.commands.assignRageDebuff).
function SanityManager.setRecoveryDebuff(player, mult, duration)
	recoveryDebuff[player.UserId] = {mult = mult, until_ = tick() + duration}
end

-- ── Hallucination tier behavior loop ────────────────────────────────────────────────
RunService.Heartbeat:Connect(function(dt)
	local now = tick()
	for _, player in ipairs(Players:GetPlayers()) do
		local dm = _G.DataManager
		if dm and dm.isLoaded(player) and player.Character then
			local tiers = refreshTiers(player)
			local uid = player.UserId
			local char = player.Character
			local hum = char:FindFirstChildOfClass("Humanoid")
			local sm = _G.StaminaManager
			local inCombat = sm and sm.isInCombat and sm.isInCombat(player)

			-- Meditation recovery (Early/Deep rate) -- reads MeditationManager's own focus
			-- state rather than duplicating it.
			local medM = _G.MeditationManager
			if medM and medM.isFocusing and medM.isFocusing(player) then
				meditateAccum[uid] = (meditateAccum[uid] or 0) + dt
				if meditateAccum[uid] >= 60 then
					meditateAccum[uid] -= 60
					local deep = medM.isDeepMeditating and medM.isDeepMeditating(player)
					SanityManager.recoverPerMinuteTick(player, deep and "MeditateDeep" or "Meditate")
				end
			else
				meditateAccum[uid] = 0
			end

			-- Near-ally recovery -- reads AllyManager's confirmed Allies list.
			local allyM = _G.AllyManager
			local nearAlly = false
			if allyM and allyM.isNearAnyAlly then nearAlly = allyM.isNearAnyAlly(player) end
			if nearAlly then
				allyAccum[uid] = (allyAccum[uid] or 0) + dt
				if allyAccum[uid] >= 60 then
					allyAccum[uid] -= 60
					SanityManager.recoverPerMinuteTick(player, "NearAlly")
				end
			else
				allyAccum[uid] = 0
			end

			-- Tier 1: scratching, only while out of combat
			if tiers.scratch and not inCombat and hum and hum.Health > 0 then
				if not nextScratchAt[uid] then nextScratchAt[uid] = now + math.random(20,40) end
				if now >= nextScratchAt[uid] then
					nextScratchAt[uid] = now + math.random(20,40)
					local dmg = hum.MaxHealth * 0.04
					hum.Health = math.max(0, hum.Health - dmg)
					RE_SanityScratch:FireClient(player, {})
				end
			elseif not tiers.scratch then
				nextScratchAt[uid] = nil
			end

			-- Tier 3/4: shadow figure spawn roll (attack sub-roll only once tier4 is active)
			if tiers.shadow then
				if not nextShadowRollAt[uid] then nextShadowRollAt[uid] = now + math.random(15,30) end
				if now >= nextShadowRollAt[uid] then
					nextShadowRollAt[uid] = now + math.random(15,30)
					local willAttack = tiers.shadowAttack and math.random() < 0.30
						and (now - (lastShadowStunAt[uid] or 0)) >= 20
					RE_SanityShadowSpawn:FireClient(player, {attack = willAttack})
					if willAttack then
						lastShadowStunAt[uid] = now
						local fm = _G.FeelingsManager
						if fm then fm.trigger(player, "OnShadowFigureAttack") end
						-- Rough travel time before the figure "reaches" the player and the real
						-- stun lands -- mirrors ModManager.applyFreeze's Anchored-based freeze
						-- rather than WalkSpeed (which several other systems also mutate).
						task.delay(1.0, function()
							local p2 = Players:GetPlayerByUserId(uid)
							local c2 = p2 and p2.Character
							local hrp2 = c2 and c2:FindFirstChild("HumanoidRootPart")
							if not hrp2 then return end
							local wasAnchored = hrp2.Anchored
							hrp2.Anchored = true
							task.delay(0.8, function()
								if hrp2.Parent then hrp2.Anchored = wasAnchored end
							end)
						end)
					end
				end
			else
				nextShadowRollAt[uid] = nil
			end
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	local uid = player.UserId
	tierState[uid]=nil; nextScratchAt[uid]=nil; nextShadowRollAt[uid]=nil
	lastShadowStunAt[uid]=nil; hostileExposure[uid]=nil; meditateAccum[uid]=nil; allyAccum[uid]=nil
	recoveryDebuff[uid]=nil
end)

_G.SanityManager = SanityManager
print("[SanityManager] Init")
