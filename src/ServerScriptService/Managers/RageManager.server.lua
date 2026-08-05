-- RageManager -- berserker state (design doc PART THREE). Entered at HP<=15%+Sanity>=80,
-- or bypassed entirely on an ally's death (see AllyManager). CombatManager/StaminaManager
-- read this module's small query API (getDamageMult/isStaggerImmune/isKnockbackImmune/
-- getSpeedMult/getRegenMult) via _G, same cross-manager pattern used everywhere else.
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris     = game:GetService("Debris")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local rageCfg = Config.Rage

local function getOrCreate(name, isFunc)
	local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
		local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
	end)()
	local r=folder:FindFirstChild(name); if r then return r end
	r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_RageStateChanged = getOrCreate("RageStateChanged")
local RE_RageBroadcast    = getOrCreate("RageBroadcast")
local RE_RageDebuffPrompt = getOrCreate("RageDebuffPrompt")
local RE_LiveFeedUpdate   = getOrCreate("LiveFeedUpdate")

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
			RE_LiveFeedUpdate:FireClient(p, { type = "RAGE", h = now.hour, m = now.min, zone = "?", charName = charName, message = message })
		end
	end
end

local state = {} -- [userId] = {active=,until_=,knockbackImmuneUntil=,exhaustedUntil=,bypass=,debuffAssigned=}

local RageManager = {}

function RageManager.isRaging(player)
	local s = state[player.UserId]; return s ~= nil and s.active == true
end
function RageManager.isExhausted(player)
	local s = state[player.UserId]
	return s ~= nil and s.exhaustedUntil ~= nil and s.exhaustedUntil > 0 and tick() < s.exhaustedUntil
end
function RageManager.isStaggerImmune(player) return RageManager.isRaging(player) end
function RageManager.isKnockbackImmune(player)
	local s = state[player.UserId]
	return s ~= nil and s.active == true and tick() < (s.knockbackImmuneUntil or 0)
end
function RageManager.getDamageMult(player)
	if RageManager.isRaging(player) then return rageCfg.DamageBoost end
	if RageManager.isExhausted(player) then return rageCfg.ExhaustionDamagePenalty end
	return 1
end
function RageManager.getSpeedMult(player)
	if RageManager.isExhausted(player) then return rageCfg.ExhaustionSpeedMultiplier end
	return 1
end
function RageManager.getRegenMult(player)
	if RageManager.isExhausted(player) then return rageCfg.ExhaustionRegenMultiplier end
	return 1
end
function RageManager.canEnterRage(player)
	return not RageManager.isRaging(player) and not RageManager.isExhausted(player)
end

-- Red pulsing glow + full-body fire aura, replicates automatically to every nearby client
-- since these are real Instances parented under the character (no separate broadcast
-- needed for the glow/aura itself -- only the affected player's own screen-space pulse,
-- see RageClient, needs a remote). Cloned from the reference rig at workspace.Rage (a real
-- authored aura asset the user placed for this. workspace."Mastered Rage" is a separate,
-- more advanced version reserved for a later feature -- it was briefly used here and has now
-- been swapped back (2026-07-21, per user request). Both rigs share the same per-part
-- Head/Torso/HumanoidRootPart/Left-Right Leg/Arm structure, so the clone-per-part +
-- clone-Highlight logic below works against either with no other changes.
local AURA_SOURCE = workspace:FindFirstChild("Rage")
local AURA_PART_NAMES = {"Head", "Torso", "HumanoidRootPart", "Left Leg", "Right Leg", "Left Arm", "Right Arm"}
local activeAuraFX = {} -- [userId] = {instances...}

local function clearAura(uid)
	local list = activeAuraFX[uid]; if not list then return end
	for _, inst in ipairs(list) do if inst.Parent then inst:Destroy() end end
	activeAuraFX[uid] = nil
end

local function applyGlow(uid, char, on)
	if not on then
		clearAura(uid)
		return
	end
	clearAura(uid)
	local created = {}
	if AURA_SOURCE then
		for _, partName in ipairs(AURA_PART_NAMES) do
			local srcPart = AURA_SOURCE:FindFirstChild(partName)
			local dstPart = char:FindFirstChild(partName)
			if srcPart and dstPart then
				for _, child in ipairs(srcPart:GetChildren()) do
					if child:IsA("ParticleEmitter") or child:IsA("Attachment") then
						local clone = child:Clone()
						clone.Parent = dstPart
						table.insert(created, clone)
					end
				end
			end
		end
		local srcHighlight = AURA_SOURCE:FindFirstChild("Highlight")
		if srcHighlight then
			local hl = srcHighlight:Clone()
			hl.Name = "RageGlow"
			hl.Adornee = char
			hl.Parent = char
			table.insert(created, hl)
		end
	end
	if #created == 0 then
		-- Fallback if the reference rig is ever removed/renamed -- keeps rage functional.
		local hl = Instance.new("Highlight")
		hl.Name="RageGlow"; hl.FillColor=Color3.fromRGB(180,10,10); hl.OutlineColor=Color3.fromRGB(255,40,40)
		hl.FillTransparency=0.7; hl.DepthMode=Enum.HighlightDepthMode.AlwaysOnTop; hl.Adornee=char; hl.Parent=char
		table.insert(created, hl)
	end
	activeAuraFX[uid] = created
end

local function playScream(char)
	local hrp = char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
	local snd = Instance.new("Sound")
	snd.SoundId = "rbxassetid://0" -- PLACEHOLDER_SOUND: rage_scream
	snd.Volume = 1; snd.Parent = hrp
	snd:Play()
	snd.Ended:Once(function() snd:Destroy() end)
	Debris:AddItem(snd, 6)
	local hum = char:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	if animator then
		local animId = "rbxassetid://0" -- PLACEHOLDER_ANIMATION: rage_scream
		if animId ~= "" and animId ~= "rbxassetid://0" then
			local anim = Instance.new("Animation"); anim.AnimationId = animId
			local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
			if ok and track then track.Priority = Enum.AnimationPriority.Action; track:Play() end
		end
	end
end

local function playExhaustionCues(char, duration)
	local hrp = char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
	local snd = Instance.new("Sound")
	snd.SoundId = "rbxassetid://0" -- PLACEHOLDER_SOUND: exhaustion_breathing
	snd.Looped = true; snd.Volume = 0.6; snd.Parent = hrp
	snd:Play()
	local hum = char:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	local track
	if animator then
		local animId = "rbxassetid://0" -- PLACEHOLDER_ANIMATION: exhaustion_idle
		if animId ~= "" and animId ~= "rbxassetid://0" then
			local anim = Instance.new("Animation"); anim.AnimationId = animId
			local ok, t = pcall(function() return animator:LoadAnimation(anim) end)
			if ok then track = t; track.Looped = true; track.Priority = Enum.AnimationPriority.Idle; track:Play() end
		end
	end
	task.delay(duration, function()
		if snd.Parent then snd:Stop(); snd:Destroy() end
		if track then track:Stop() end
	end)
end

function RageManager.enterRage(player, opts)
	opts = opts or {}
	if RageManager.isRaging(player) then return false end
	if RageManager.isExhausted(player) and not opts.force then return false end
	local char = player.Character; if not char then return false end
	local uid = player.UserId
	local now = tick()
	state[uid] = {
		active = true,
		until_ = now + rageCfg.Duration,
		knockbackImmuneUntil = now + rageCfg.KnockbackImmuneDuration,
		exhaustedUntil = 0,
		bypass = opts.bypass == true,
		debuffAssigned = nil,
	}
	local dm = _G.DataManager
	if dm then dm.setValue(player, "RageActive", true) end
	char:SetAttribute("RageActive", true)
	applyGlow(uid, char, true)
	playScream(char)
	local cm = _G.CombatManager; if cm and cm.refreshSpeed then cm.refreshSpeed(player) end

	RE_RageStateChanged:FireClient(player, {active = true})
	RE_RageBroadcast:FireAllClients(player.UserId, true)

	local charName = getCharName(player)
	local sanM = _G.SanityManager
	local sanity = sanM and sanM.getSanity(player) or -1
	local hum = char:FindFirstChildOfClass("Humanoid")
	local hpPct = (hum and hum.MaxHealth > 0) and math.floor(hum.Health / hum.MaxHealth * 100) or 0
	local msg = string.format("%s entered rage (HP %d%%, Sanity %d)%s", charName, hpPct, sanity,
		opts.bypass and " -- ally death bypass" or "")
	print("[RageManager] " .. msg)
	local disc = _G.DiscordManager
	if disc and disc.logRage then disc.logRage(charName, msg) end
	fireLiveFeed(charName, msg)

	-- Lore team must assign an exit debuff (see RageManager.assignExitDebuff / ModManager).
	for _, p in ipairs(Players:GetPlayers()) do
		local mm = _G.ModManager
		if mm and mm.isMod(p) then
			RE_RageDebuffPrompt:FireClient(p, {targetName = player.Name, charName = charName})
		end
	end

	task.delay(rageCfg.Duration, function()
		local cur = state[uid]
		if cur and cur.active then RageManager.exitRage(player) end
	end)
	return true
end

function RageManager.exitRage(player)
	local uid = player.UserId
	local s = state[uid]; if not s or not s.active then return false end
	s.active = false
	local now = tick()
	s.exhaustedUntil = now + rageCfg.ExhaustionDuration

	local dm = _G.DataManager
	if dm then
		dm.setValue(player, "RageActive", false)
		dm.setValue(player, "RageExhaustedUntil", os.time() + rageCfg.ExhaustionDuration)
	end
	local char = player.Character
	if char then
		char:SetAttribute("RageActive", false)
		char:SetAttribute("RageExhausted", true)
		applyGlow(uid, char, false)
		playExhaustionCues(char, rageCfg.ExhaustionDuration)
	end
	local cm = _G.CombatManager; if cm and cm.refreshSpeed then cm.refreshSpeed(player) end

	RE_RageStateChanged:FireClient(player, {active = false, exhausted = true})
	RE_RageBroadcast:FireAllClients(player.UserId, false)

	local charName = getCharName(player)
	-- WitnessAllyDeath sanity fires AFTER rage ends for an ally-death-bypass entry (the rage
	-- bypass itself doesn't touch sanity -- see design doc PART FOUR).
	if s.bypass then
		local sanM = _G.SanityManager
		if sanM then sanM.notifyWitnessAllyDeath(player) end
	end
	local msg = charName .. " exited rage -> exhaustion (" .. rageCfg.ExhaustionDuration .. "s)"
	print("[RageManager] " .. msg)
	local disc = _G.DiscordManager
	if disc and disc.logRage then disc.logRage(charName, msg) end
	fireLiveFeed(charName, msg)

	task.delay(rageCfg.ExhaustionDuration, function()
		local cur = state[uid]
		if cur and cur.exhaustedUntil and tick() >= cur.exhaustedUntil then
			local c2 = player.Character
			if c2 then c2:SetAttribute("RageExhausted", false) end
			print("[RageManager] " .. player.Name .. " exhaustion ended")
		end
	end)
	return true
end

function RageManager.forceEnter(player) return RageManager.enterRage(player, {force = true}) end
function RageManager.forceExit(player) return RageManager.exitRage(player) end
-- Ally death: bypasses the HP/Sanity thresholds entirely (an exception to the normal rule --
-- see design doc PART FOUR) and, since losing an ally like this is exactly the kind of event
-- exhaustion exists to represent the aftermath of, also bypasses an active exhaustion lock.
function RageManager.allyDeathBypass(player) return RageManager.enterRage(player, {bypass = true, force = true}) end

-- Exit debuff options: Injury / ReduceSanityRecovery / Curse (flavor-only) / None.
function RageManager.assignExitDebuff(exec, target, debuffType, arg)
	local s = state[target.UserId]
	assert(s, "target has no rage record (never entered rage)")
	assert(not s.debuffAssigned, "exit debuff already assigned for this rage cycle")
	local charName = getCharName(target)
	local detail
	if debuffType == "Injury" then
		local im = assert(_G.InjuryManager, "InjuryManager not ready")
		local execName = exec and exec.Name or "LoreTeam"
		local ok, err = im.applyInjury(target, arg, execName .. " (Rage exit debuff)")
		assert(ok, err)
		detail = "Injury: " .. tostring(arg)
	elseif debuffType == "ReduceSanityRecovery" then
		local sanM = assert(_G.SanityManager, "SanityManager not ready")
		sanM.setRecoveryDebuff(target, 0.5, 600) -- half recovery rate for 10 minutes
		detail = "Reduced sanity recovery rate (10 min)"
	elseif debuffType == "Curse" then
		detail = "Lore curse: " .. tostring(arg)
	elseif debuffType == "None" then
		detail = "No additional debuff"
	else
		error("Unknown debuffType: " .. tostring(debuffType))
	end
	s.debuffAssigned = {type = debuffType, detail = detail}
	local msg = charName .. " rage exit debuff -> " .. detail
	print("[RageManager] " .. msg)
	local disc = _G.DiscordManager
	if disc and disc.logRage then disc.logRage(charName, msg) end
	fireLiveFeed(charName, msg)
	return true
end

-- Automatic entry check, every Config.Rage.CheckInterval seconds.
local accum = 0
RunService.Heartbeat:Connect(function(dt)
	accum += dt
	if accum < rageCfg.CheckInterval then return end
	accum = 0
	local sanM = _G.SanityManager
	for _, player in ipairs(Players:GetPlayers()) do
		if RageManager.canEnterRage(player) then
			local char = player.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if hum and hum.MaxHealth > 0 and hum.Health > 0 then
				local hpFrac = hum.Health / hum.MaxHealth
				if hpFrac <= rageCfg.HPThreshold and sanM and sanM.isRageEligible(player) then
					RageManager.enterRage(player, {})
				end
			end
		end
	end
end)

Players.PlayerRemoving:Connect(function(player) state[player.UserId] = nil; clearAura(player.UserId) end)

_G.RageManager = RageManager
print("[RageManager] Init")
