-- DNAManager -- hidden bloodline attribute, mod-assigned only (see Config.LoreClans).
-- Persists across PDE wipes (bloodline continues even when characters die -- see
-- IdentityManager.resetForWipe, which deliberately does NOT touch DNA). Not shown in the
-- player's journal unless they hold the BloodInsight talent. Buffs are never cached/baked --
-- every getter below reads Config.LoreClans + characterData.DNA fresh each call, so a mod
-- changing Config, or the player's Clan/Purity, takes effect immediately with no separate
-- "recalculate" step needed.

local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))
local clans = Config.LoreClans

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

local DNAManager = {}

function DNAManager.getDNA(player)
	local dm = _G.DataManager; if not dm then return { Clan = "", Purity = 0, Caste = "" } end
	return dm.getValue(player, "DNA") or { Clan = "", Purity = 0, Caste = "" }
end

function DNAManager.setDNA(player, clanName, purity)
	if clanName ~= "None" and clanName ~= "" and not clans[clanName] then return false end
	local dm = _G.DataManager; if not dm then return false end
	local resolved = (clanName == "None") and "" or clanName
	-- Caste lives in this same table (see CasteManager) -- carry it through, or a clan edit
	-- from the mod panel would silently erase the player's caste.
	local existing = DNAManager.getDNA(player)
	dm.setValue(player, "DNA", { Clan = resolved, Purity = math.clamp(tonumber(purity) or 0, 0, 100), Caste = existing.Caste or "" })
	local charName = getCharName(player)
	fireLiveFeed(charName, "DNA set to " .. (resolved ~= "" and (clans[resolved] and clans[resolved].name or resolved) or "None"))
	local disc = _G.DiscordManager
	if disc and disc.logDNA then disc.logDNA(charName, "Clan set to " .. (resolved ~= "" and resolved or "None") .. ", Purity " .. tostring(purity or 0)) end
	return true
end

-- Clears clan, purity AND caste (the panel's "Clear All DNA"). Also drops the crown, since
-- King is only valid on a Celtae and clearing the caste ends that.
function DNAManager.clearDNA(player)
	local dm = _G.DataManager; if not dm then return end
	dm.setValue(player, "DNA", { Clan = "", Purity = 0, Caste = "" })
	local cm = _G.CasteManager
	if cm and cm.hasTitle(player, "King") then cm.revokeTitle(player, "King") end
	local charName = getCharName(player)
	fireLiveFeed(charName, "DNA cleared")
	local disc = _G.DiscordManager
	if disc and disc.logDNA then disc.logDNA(charName, "DNA cleared") end
end

-- ── Buff readers -- generic over any clan shape (amount/multiplier/frames), so a lore team
-- adding a new clan to Config.LoreClans with the same buff shapes works with zero code changes.
local function activeBuffs(player)
	local dna = DNAManager.getDNA(player)
	if not dna or dna.Clan == "" or not clans[dna.Clan] then return nil end
	return clans[dna.Clan].buffs
end

function DNAManager.getEffectiveStat(player, statName, baseValue)
	local buffs = activeBuffs(player); if not buffs then return baseValue end
	local total = baseValue
	for _, b in ipairs(buffs) do
		if b.stat == statName and b.amount then total += b.amount end
	end
	return total
end

function DNAManager.getDamageMultiplier(player, damageType)
	local buffs = activeBuffs(player); if not buffs then return 1 end
	local mult = 1
	for _, b in ipairs(buffs) do
		if b.stat == damageType and b.multiplier then mult *= b.multiplier end
	end
	return mult
end

function DNAManager.getParryWindowBonusFrames(player)
	local buffs = activeBuffs(player); if not buffs then return 0 end
	local total = 0
	for _, b in ipairs(buffs) do
		if b.stat == "ParryWindow" and b.frames then total += b.frames end
	end
	return total
end

function DNAManager.getStaminaMaxBonus(player)
	local buffs = activeBuffs(player); if not buffs then return 0 end
	local total = 0
	for _, b in ipairs(buffs) do
		if b.stat == "StaminaMax" and b.amount then total += b.amount end
	end
	return total
end

-- BloodInsight talent: reveals a "Blood Memory" section (Clan/Purity) in the player's own
-- journal. NOTE: no Journal UI/backend exists anywhere in this codebase yet (RequestJournalData
-- was declared in RemoteEvents but had no server handler at all) -- this wires the DNA-reveal
-- piece specifically so a future Journal implementation has a real hook to call.
Remotes.RequestJournalData.OnServerInvoke = function(player)
	local tm = _G.TalentManager
	local hasBloodInsight = tm and tm.hasTalent(player, "BloodInsight")
	local data = {}
	if hasBloodInsight then
		local dna = DNAManager.getDNA(player)
		data.BloodMemory = {
			Clan = (dna.Clan ~= "" and clans[dna.Clan] and clans[dna.Clan].name) or "Unknown",
			Purity = dna.Purity,
		}
	end
	-- Sanity is hidden by default (see SanityManager / design doc PART ONE) -- only
	-- BloodInsight or AwakenedEyes (lore team's choice of "a rare talent MAY reveal it")
	-- exposes the real number here. Same "no Journal UI exists yet" caveat as BloodMemory
	-- above: this is the data hook for whenever one gets built.
	if hasBloodInsight or (tm and tm.hasTalent(player, "AwakenedEyes")) then
		local sanM = _G.SanityManager
		if sanM then data.Sanity = sanM.getSanity(player) end
	end
	-- Allies section (see AllyManager) -- same "no Journal UI yet" hook pattern.
	local allyM = _G.AllyManager
	if allyM and allyM.getJournalAllies then data.Allies = allyM.getJournalAllies(player) end
	-- Bloodline section: what a Revealer NPC has actually told this player about themselves.
	-- Unlike BloodMemory above (a talent reading your own blood), this is knowledge bought or
	-- earned in the world -- see RevealManager. Caste is never visible any other way.
	local revM = _G.RevealManager
	if revM and revM.getJournalBloodline then data.Bloodline = revM.getJournalBloodline(player) end
	return data
end

_G.DNAManager = DNAManager
print("[DNAManager] Init — " .. (function() local n=0; for _ in pairs(clans) do n+=1 end; return n end)() .. " lore clan(s) defined")
