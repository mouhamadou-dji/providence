-- AllyManager -- trusted companions (design doc PART FOUR). Requires mutual /introduce full
-- (see ChatManager/IdentityManager.learnName's KnownNames.family field) AND accumulated
-- proximity time afterward. Persisted per-player in DataManager's AllyProgress/Allies fields.
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local allyCfg = Config.Ally

local function getOrCreate(name, isFunc)
	local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
		local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
	end)()
	local r=folder:FindFirstChild(name); if r then return r end
	r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_ShowNotification  = getOrCreate("ShowNotification")
local RE_AllyBondFormed    = getOrCreate("AllyBondFormed")
local RE_LiveFeedUpdate    = getOrCreate("LiveFeedUpdate")

local function getCharName(player)
	local dm = _G.DataManager
	local n = dm and dm.getValue(player, "FirstName")
	if not n or n == "" then n = player.Name end
	return n
end

local function getFullName(player)
	local dm = _G.DataManager
	local fn = (dm and dm.getValue(player, "FirstName")) or ""
	local ln = (dm and dm.getValue(player, "FamilyName")) or ""
	if fn == "" then return player.Name end
	return (#ln > 0) and (fn .. " " .. ln) or fn
end

local function fireLiveFeed(charName, message)
	local now = os.date("*t")
	local mgr = _G.ModManager
	for _, p in ipairs(Players:GetPlayers()) do
		if mgr and mgr.isMod(p) then
			RE_LiveFeedUpdate:FireClient(p, { type = "ALLY", h = now.hour, m = now.min, zone = "?", charName = charName, message = message })
		end
	end
end

local AllyManager = {}

-- ── Data accessors (DataManager-backed, see DataManager's AllyProgress/Allies fields) ────
local function getProgress(player)
	local dm = _G.DataManager; if not dm then return {} end
	return dm.getValue(player, "AllyProgress") or {}
end
local function setProgress(player, tbl)
	local dm = _G.DataManager; if dm then dm.setValue(player, "AllyProgress", tbl) end
end
local function getAlliesList(player)
	local dm = _G.DataManager; if not dm then return {} end
	return dm.getValue(player, "Allies") or {}
end
local function setAlliesList(player, tbl)
	local dm = _G.DataManager; if dm then dm.setValue(player, "Allies", tbl) end
end

function AllyManager.isAlly(playerA, playerB)
	if not playerA or not playerB then return false end
	for _, uid in ipairs(getAlliesList(playerA)) do
		if uid == playerB.UserId then return true end
	end
	return false
end

-- Online allies only (proximity/journal don't need offline ones resolvable to a Player).
function AllyManager.getAllies(player)
	local result = {}
	for _, uid in ipairs(getAlliesList(player)) do
		local p = Players:GetPlayerByUserId(uid)
		if p then table.insert(result, p) end
	end
	return result
end

function AllyManager.isNearAnyAlly(player)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return false end
	for _, ally in ipairs(AllyManager.getAllies(player)) do
		local ac = ally.Character
		local ahrp = ac and ac:FindFirstChild("HumanoidRootPart")
		if ahrp and (ahrp.Position - hrp.Position).Magnitude <= allyCfg.NearAllyRange then
			return true
		end
	end
	return false
end

-- Fully introduced = each side has learned the OTHER's family name (KnownNames[...].family
-- set only by /introduce full -- see IdentityManager.learnName's includeFamily param).
local function isFullyIntroduced(playerA, playerB)
	local dm = _G.DataManager; if not dm then return false end
	local knownA = dm.getValue(playerA, "KnownNames") or {}
	local knownB = dm.getValue(playerB, "KnownNames") or {}
	local eA = knownA[tostring(playerB.UserId)]
	local eB = knownB[tostring(playerA.UserId)]
	return eA ~= nil and eA.family ~= nil and eB ~= nil and eB.family ~= nil
end

local function confirmAlly(playerA, playerB)
	local listA = getAlliesList(playerA); table.insert(listA, playerB.UserId); setAlliesList(playerA, listA)
	local listB = getAlliesList(playerB); table.insert(listB, playerA.UserId); setAlliesList(playerB, listB)

	local msgA = "You now consider " .. getCharName(playerB) .. " an ally."
	local msgB = "You now consider " .. getCharName(playerA) .. " an ally."
	RE_ShowNotification:FireClient(playerA, {title="Ally", body=msgA, duration=8, style="info"})
	RE_ShowNotification:FireClient(playerB, {title="Ally", body=msgB, duration=8, style="info"})
	RE_AllyBondFormed:FireClient(playerA, {allyUserId=playerB.UserId, allyName=getCharName(playerB)})
	RE_AllyBondFormed:FireClient(playerB, {allyUserId=playerA.UserId, allyName=getCharName(playerA)})

	local logMsg = getCharName(playerA) .. " and " .. getCharName(playerB) .. " are now allies"
	print("[AllyManager] " .. logMsg)
	local disc = _G.DiscordManager
	if disc and disc.logAlly then disc.logAlly(getCharName(playerA), logMsg) end
	fireLiveFeed(getCharName(playerA), logMsg)
end

-- ── Progress tick (Config.Ally.CheckInterval, default 1s) ─────────────────────────
local accum = 0
RunService.Heartbeat:Connect(function(dt)
	accum += dt
	if accum < allyCfg.CheckInterval then return end
	local step = accum; accum = 0

	local players = Players:GetPlayers()
	for i = 1, #players do
		for j = i+1, #players do
			local a, b = players[i], players[j]
			local dm = _G.DataManager
			if dm and dm.isLoaded(a) and dm.isLoaded(b) and not AllyManager.isAlly(a, b) then
				local ca, cb = a.Character, b.Character
				local ha = ca and ca:FindFirstChild("HumanoidRootPart")
				local hb = cb and cb:FindFirstChild("HumanoidRootPart")
				if ha and hb and (ha.Position - hb.Position).Magnitude <= allyCfg.ProximityRange then
					local introduced = isFullyIntroduced(a, b)
					local progA = getProgress(a); local progB = getProgress(b)
					local keyA = tostring(b.UserId); local keyB = tostring(a.UserId)
					local eA = progA[keyA] or {bothIntroduced=false, timeAccumulated=0, isAlly=false, revoked=false}
					local eB = progB[keyB] or {bothIntroduced=false, timeAccumulated=0, isAlly=false, revoked=false}
					if not eA.revoked and not eB.revoked then
						eA.bothIntroduced = introduced; eB.bothIntroduced = introduced
						if introduced then
							eA.timeAccumulated += step; eB.timeAccumulated += step
						end
						progA[keyA] = eA; progB[keyB] = eB
						setProgress(a, progA); setProgress(b, progB)
						-- Aedui's AllyBondSpeedup shortens the required time. The pair uses whichever
						-- side needs LESS -- one diplomat in the conversation is enough to bring two
						-- people together faster, which is exactly what that caste is for.
						if introduced and eA.timeAccumulated >= AllyManager.getRequiredSeconds(a, b) then
							eA.isAlly = true; eB.isAlly = true
							confirmAlly(a, b)
						end
					end
				end
			end
		end
	end
end)

-- ── Death / kill consequences (called from CombatManager's execution-completion hook) ──
function AllyManager.onPlayerKilled(attacker, target)
	local wasAlly = AllyManager.isAlly(attacker, target)
	local sanM = _G.SanityManager
	if wasAlly then
		if sanM then sanM.notifyKillPlayer(attacker, true) end
		-- Ally status permanently revoked between the two -- can't become allies again this
		-- session (mark `revoked` on both progress entries so the tick loop above skips them).
		local listA = getAlliesList(attacker)
		for i = #listA, 1, -1 do if listA[i] == target.UserId then table.remove(listA, i) end end
		setAlliesList(attacker, listA)
		local listB = getAlliesList(target)
		for i = #listB, 1, -1 do if listB[i] == attacker.UserId then table.remove(listB, i) end end
		setAlliesList(target, listB)

		local progA = getProgress(attacker); local keyA = tostring(target.UserId)
		progA[keyA] = progA[keyA] or {}; progA[keyA].revoked = true; setProgress(attacker, progA)
		local progB = getProgress(target); local keyB = tostring(attacker.UserId)
		progB[keyB] = progB[keyB] or {}; progB[keyB].revoked = true; setProgress(target, progB)

		local charName = getCharName(attacker)
		local msg = "[BETRAYAL] " .. charName .. " killed his ally " .. getCharName(target)
		print("[AllyManager] " .. msg)
		local disc = _G.DiscordManager
		if disc and disc.logAlly then disc.logAlly(charName, msg) end
		fireLiveFeed(charName, msg)
	else
		if sanM then sanM.notifyKillPlayer(attacker, false) end
	end

	-- Ally death: every OTHER player (not the attacker, not the target) who has `target` as
	-- an ally and is within AllyWitnessRadius instantly enters rage regardless of their own
	-- conditions (see RageManager.allyDeathBypass); the +40 WitnessAllyDeath sanity is fired
	-- by RageManager once THEIR rage ends, per design doc PART FOUR.
	local tc = target.Character
	local thrp = tc and tc:FindFirstChild("HumanoidRootPart")
	if thrp then
		local sanCfg = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config")).Sanity
		for _, observer in ipairs(Players:GetPlayers()) do
			if observer ~= attacker and observer ~= target and AllyManager.isAlly(observer, target) then
				local oc = observer.Character
				local ohrp = oc and oc:FindFirstChild("HumanoidRootPart")
				if ohrp and (ohrp.Position - thrp.Position).Magnitude <= sanCfg.AllyWitnessRadius then
					local fm = _G.FeelingsManager
					if fm then fm.trigger(observer, "OnAllyDeath") end
					local rm = _G.RageManager
					if rm then rm.allyDeathBypass(observer) end
				end
			end
		end
	end
end

-- ── Journal hook (see DNAManager.RequestJournalData -- no Journal UI exists yet, same
-- "data hook for whenever one gets built" caveat as BloodMemory) ──────────────────────
function AllyManager.getJournalAllies(player)
	local result = {}
	local progress = getProgress(player)
	for _, uid in ipairs(getAlliesList(player)) do
		local name = tostring(uid)
		local ally = Players:GetPlayerByUserId(uid)
		if ally then name = getFullName(ally) end
		local entry = progress[tostring(uid)]
		local hours = entry and (entry.timeAccumulated / 3600) or 0
		table.insert(result, {name = name, hoursTogether = math.floor(hours * 10) / 10})
	end
	return result
end

-- Required proximity time for a specific pair, after caste speedups. Passing one player (or
-- nil for the second) gives that player's own requirement -- used by the progress readouts.
function AllyManager.getRequiredSeconds(playerA, playerB)
	local cm = _G.CasteManager
	if not cm then return allyCfg.RequiredProximitySeconds end
	local req = cm.getAllyBondSeconds(playerA)
	if playerB then req = math.min(req, cm.getAllyBondSeconds(playerB)) end
	return req
end

-- ── Mod panel hooks ──────────────────────────────────────────────────────────
function AllyManager.forceAllyBond(playerA, playerB)
	if AllyManager.isAlly(playerA, playerB) then return false end
	confirmAlly(playerA, playerB)
	return true
end

function AllyManager.removeAllyBond(playerA, playerB)
	if not AllyManager.isAlly(playerA, playerB) then return false end
	local listA = getAlliesList(playerA)
	for i = #listA, 1, -1 do if listA[i] == playerB.UserId then table.remove(listA, i) end end
	setAlliesList(playerA, listA)
	local listB = getAlliesList(playerB)
	for i = #listB, 1, -1 do if listB[i] == playerA.UserId then table.remove(listB, i) end end
	setAlliesList(playerB, listB)
	local charName = getCharName(playerA)
	local msg = "Ally bond removed between " .. charName .. " and " .. getCharName(playerB)
	print("[AllyManager] " .. msg)
	local disc = _G.DiscordManager
	if disc and disc.logAlly then disc.logAlly(charName, msg) end
	fireLiveFeed(charName, msg)
	return true
end

function AllyManager.getProgressSummary(player)
	local progress = getProgress(player)
	local result = {}
	for otherUidStr, entry in pairs(progress) do
		local name = otherUidStr
		local other = Players:GetPlayerByUserId(tonumber(otherUidStr))
		if other then name = getCharName(other) end
		table.insert(result, {
			name = name,
			timeAccumulated = entry.timeAccumulated or 0,
			required = AllyManager.getRequiredSeconds(player, other),
			bothIntroduced = entry.bothIntroduced == true,
			isAlly = entry.isAlly == true,
		})
	end
	return result
end

_G.AllyManager = AllyManager
print("[AllyManager] Init")
