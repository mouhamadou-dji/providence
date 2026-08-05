-- InjuryManager -- permanent character conditions applied by lore team or specific items
-- (dissection knife, etc). Persist across respawn via characterData.Injuries; reset only
-- on PDE wipe (see IdentityManager.resetForWipe). Injuries stack (multiple distinct types
-- at once), but only one active copy per type -- re-applying the same type updates its
-- params (side/severity/appliedBy) rather than adding a duplicate entry.

local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config  = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))
local injCfg  = Config.Injuries
local rampCfg = Config.BadVisionRamp
local hallucCfg = Config.InsanityHallucinations

local function getOrCreate(name, isFunc)
	local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
		local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
	end)()
	local r=folder:FindFirstChild(name); if r then return r end
	r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

-- Ongoing injury state (blind/blur/etc) is mirrored onto the Character as Attributes --
-- same replication pattern as CombatManager's CombatState / TalentManager's Talent_<id> --
-- so InjuryEffectsClient can react locally without a remote round trip. Only the transient,
-- one-shot hallucination EVENTS (fake figure spawn, face vanish, chat distortion) go over
-- an actual RemoteEvent, since those aren't persistent state.
local RE_InsanityHallucination = getOrCreate("InsanityHallucination") -- server -> owning client: {kind=..., ...params}

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
			Remotes.LiveFeedUpdate:FireClient(p, { type = "ACTION", h = now.hour, m = now.min, zone = "?", charName = charName, message = message })
		end
	end
end

local InjuryManager = {}

-- ── Data access ──────────────────────────────────────────────────────────
local function getInjuries(player)
	local dm = _G.DataManager; if not dm then return {} end
	return dm.getValue(player, "Injuries") or {}
end

local function setInjuries(player, list)
	local dm = _G.DataManager; if not dm then return end
	dm.setValue(player, "Injuries", list)
end

function InjuryManager.getInjury(player, injuryType)
	for _, inj in ipairs(getInjuries(player)) do
		if inj.type == injuryType then return inj end
	end
	return nil
end

function InjuryManager.hasInjury(player, injuryType)
	return InjuryManager.getInjury(player, injuryType) ~= nil
end

function InjuryManager.getAllInjuries(player)
	return getInjuries(player)
end

function InjuryManager.isInsane(player)
	return InjuryManager.hasInjury(player, "Insanity")
end

-- ── Visuals -- reapplies every persisted injury's Attribute/arm-hide state onto a fresh
-- Character. Called on every CharacterAdded (respawn) and immediately after any mod-panel
-- apply/remove while the target already has a live character.
function InjuryManager.applyVisuals(player, char)
	char = char or player.Character
	if not char then return end
	local list = getInjuries(player)
	local active = {}
	for _, inj in ipairs(list) do active[inj.type] = inj end

	-- Lost Arm: hides the affected arm outright (server-authoritative Transparency, so it
	-- replicates the same way any other server-set property does -- no client trust needed).
	local lostArm = active.LostArm
	local rightArm = char:FindFirstChild("Right Arm") or char:FindFirstChild("RightHand")
	local leftArm  = char:FindFirstChild("Left Arm")  or char:FindFirstChild("LeftHand")
	local function setArmTransparency(part, hidden)
		if not part then return end
		for _, d in ipairs({part}) do d.Transparency = hidden and 1 or 0 end
	end
	setArmTransparency(rightArm, lostArm and lostArm.side == "Right")
	setArmTransparency(leftArm,  lostArm and lostArm.side == "Left")
	char:SetAttribute("Injury_LostArm", lostArm ~= nil)
	char:SetAttribute("Injury_LostArm_Side", lostArm and lostArm.side or "")

	char:SetAttribute("Injury_Insanity", active.Insanity ~= nil)
	char:SetAttribute("Injury_Insanity_Severity", active.Insanity and active.Insanity.severity or 0)

	local halfBlind = active.HalfBlind
	char:SetAttribute("Injury_HalfBlind", halfBlind ~= nil)
	char:SetAttribute("Injury_HalfBlind_Side", halfBlind and halfBlind.side or "")

	char:SetAttribute("Injury_FullBlind", active.FullBlind ~= nil)

	local badVision = active.BadVision
	char:SetAttribute("Injury_BadVision", badVision ~= nil)
	char:SetAttribute("Injury_BadVision_Severity", badVision and badVision.severity or 0)

	char:SetAttribute("Injury_BrokenTissue", active.BrokenTissue ~= nil)
	char:SetAttribute("Injury_ConcussedMind", active.ConcussedMind ~= nil)

	-- BrokenTissue's speed penalty otherwise sits unnoticed on WalkSpeed until some unrelated
	-- combat action happens to call setSpeed again (see CombatManager.refreshSpeed's comment).
	local cm = _G.CombatManager
	if cm and cm.refreshSpeed then cm.refreshSpeed(player) end

	local deafEar = active.DeafEar
	char:SetAttribute("Injury_DeafEar", deafEar ~= nil)
	char:SetAttribute("Injury_DeafEar_Side", deafEar and deafEar.side or "")
end

-- ── Apply / remove ───────────────────────────────────────────────────────
function InjuryManager.applyInjury(player, injuryType, appliedBy, side, severity)
	if not injCfg[injuryType] then return false, "Unknown injury type: " .. tostring(injuryType) end

	local list = getInjuries(player)
	local entry
	for _, inj in ipairs(list) do
		if inj.type == injuryType then entry = inj; break end
	end
	local isNew = entry == nil
	entry = entry or { type = injuryType, appliedAt = os.time() }
	entry.appliedBy = (appliedBy and appliedBy ~= "") and appliedBy or "LoreTeam"

	if Config.InjurySideTypes[injuryType] then
		if side ~= "Left" and side ~= "Right" then
			side = (math.random(2) == 1) and "Left" or "Right" -- item-applied injuries roll randomly if no side given
		end
		entry.side = side
	end

	if Config.InjurySeverityTypes[injuryType] then
		if injuryType == "BadVision" then
			entry.severity = tonumber(severity) or rampCfg.InitialSeverity
		else -- Insanity
			entry.severity = math.clamp(tonumber(severity) or entry.severity or 0, 0, 100)
		end
	end

	if isNew then table.insert(list, entry) end
	setInjuries(player, list)
	InjuryManager.applyVisuals(player)

	-- Sanity fallout for the injuries the design doc calls out specifically -- only on first
	-- application (isNew), not on a severity refresh of an existing one.
	if isNew then
		local sanM = _G.SanityManager
		if sanM then
			if injuryType == "LostArm" then sanM.notifyInjury(player, "LoseArm")
			elseif injuryType == "HalfBlind" then sanM.notifyInjury(player, "LoseEye")
			elseif injuryType == "FullBlind" then sanM.notifyInjury(player, "GoFullBlind") end
		end
	end

	local charName = getCharName(player)
	fireLiveFeed(charName, "afflicted with " .. injCfg[injuryType].name .. (entry.side and (" (" .. entry.side .. ")") or ""))
	local disc = _G.DiscordManager
	if disc and disc.logInjury then disc.logInjury(charName, injCfg[injuryType].name .. " applied by " .. entry.appliedBy) end
	print("[InjuryManager] " .. player.Name .. " afflicted: " .. injuryType)
	return true
end

function InjuryManager.removeInjury(player, injuryType)
	local list = getInjuries(player)
	local found = false
	for i, inj in ipairs(list) do
		if inj.type == injuryType then table.remove(list, i); found = true; break end
	end
	if not found then return false end
	setInjuries(player, list)
	InjuryManager.applyVisuals(player)
	local charName = getCharName(player)
	fireLiveFeed(charName, "healed of " .. (injCfg[injuryType] and injCfg[injuryType].name or injuryType))
	local disc = _G.DiscordManager
	if disc and disc.logInjury then disc.logInjury(charName, (injCfg[injuryType] and injCfg[injuryType].name or injuryType) .. " removed") end
	return true
end

function InjuryManager.clearAllInjuries(player)
	setInjuries(player, {})
	InjuryManager.applyVisuals(player)
	local charName = getCharName(player)
	fireLiveFeed(charName, "all injuries cleared")
	local disc = _G.DiscordManager
	if disc and disc.logInjury then disc.logInjury(charName, "All injuries cleared") end
	return true
end

-- ── Combat/movement/stamina modifiers -- read by CombatManager/StaminaManager ───────────
-- LostArm and BrokenTissue damage reductions stack multiplicatively (both active = 0.5*0.75).
function InjuryManager.getDamageMultiplier(player)
	local mult = 1
	local lostArm = InjuryManager.getInjury(player, "LostArm")
	if lostArm then mult = mult * (injCfg.LostArm.damageMult or 1) end
	local broken = InjuryManager.getInjury(player, "BrokenTissue")
	if broken then mult = mult * (injCfg.BrokenTissue.damageMult or 1) end
	return mult
end

function InjuryManager.getHitboxMultiplier(player)
	local lostArm = InjuryManager.getInjury(player, "LostArm")
	return lostArm and (injCfg.LostArm.hitboxShrink or 1) or 1
end

function InjuryManager.getSpeedMultiplier(player)
	local broken = InjuryManager.getInjury(player, "BrokenTissue")
	return broken and (injCfg.BrokenTissue.speedMult or 1) or 1
end

function InjuryManager.getStaminaRegenMultiplier(player)
	local concussed = InjuryManager.getInjury(player, "ConcussedMind")
	return concussed and (injCfg.ConcussedMind.staminaRegenMult or 1) or 1
end

-- ── Reapply on respawn ───────────────────────────────────────────────────
Players.PlayerAdded:Connect(function(p)
	p.CharacterAdded:Connect(function(char)
		task.wait(0.2) -- let IdentityManager's stripToDefaultR6 run first, so LostArm's
		-- transparency isn't stomped by the default-appearance pass that follows spawn
		InjuryManager.applyVisuals(p, char)
	end)
end)

-- ── Bad Vision auto-ramp -- severity climbs +2/minute (capped at 100) for as long as the
-- injury persists; only healing (mod removal / RestorationDraught / ClarityElixir doesn't
-- touch BadVision specifically, but RestorationDraught's clear_all_injuries does) stops it.
task.spawn(function()
	while true do
		task.wait(60)
		for _, p in ipairs(Players:GetPlayers()) do
			local list = getInjuries(p)
			local changed = false
			for _, inj in ipairs(list) do
				if inj.type == "BadVision" then
					inj.severity = math.min((inj.severity or rampCfg.InitialSeverity) + rampCfg.IncreasePerMinute, rampCfg.MaxSeverity)
					changed = true
				end
			end
			if changed then setInjuries(p, list); InjuryManager.applyVisuals(p) end
		end
	end
end)

-- ── Insanity hallucination ticker -- every real minute, roll each of the 3 hallucination
-- types independently for every Insanity-afflicted player, scaled by their severity/100.
local HALLUCINATION_TICK_SECS = 60
task.spawn(function()
	while true do
		task.wait(HALLUCINATION_TICK_SECS)
		for _, p in ipairs(Players:GetPlayers()) do
			local inj = InjuryManager.getInjury(p, "Insanity")
			if inj and p.Character then
				local scale = (inj.severity or 0) / 100
				for kind, cfg in pairs(hallucCfg) do
					if math.random() < (cfg.chance * scale) then
						local payload = { kind = kind }
						if kind == "FakePlayerFigure" then
							local hrp = p.Character:FindFirstChild("HumanoidRootPart")
							if hrp then
								local ang = math.random() * math.pi * 2
								local dist = math.random(30, 60)
								payload.position = hrp.Position + Vector3.new(math.cos(ang)*dist, 0, math.sin(ang)*dist)
							end
						elseif kind == "FaceVanish" then
							local nearby = {}
							local hrp = p.Character:FindFirstChild("HumanoidRootPart")
							if hrp then
								for _, other in ipairs(Players:GetPlayers()) do
									if other ~= p and other.Character then
										local ohrp = other.Character:FindFirstChild("HumanoidRootPart")
										if ohrp and (ohrp.Position - hrp.Position).Magnitude <= 30 then
											table.insert(nearby, other)
										end
									end
								end
							end
							if #nearby > 0 then payload.targetUserId = nearby[math.random(#nearby)].UserId end
						end
						if kind ~= "FaceVanish" or payload.targetUserId then
							RE_InsanityHallucination:FireClient(p, payload)
						end
					end
				end
			end
		end
	end
end)

_G.InjuryManager = InjuryManager
print("[InjuryManager] Init — " .. (function() local n=0; for _ in pairs(injCfg) do n+=1 end; return n end)() .. " injury types defined")
