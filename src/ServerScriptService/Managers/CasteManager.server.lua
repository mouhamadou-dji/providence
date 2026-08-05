-- CasteManager -- the six hereditary castes of the Celtic Crun, plus the King title.
--
-- Caste lives inside characterData.DNA (alongside Clan/Purity) so it inherits DNA's existing
-- "survives a PDE wipe" property for free -- IdentityManager.resetForWipe deliberately never
-- touches the DNA table, and bloodline is exactly what a caste is.
--
-- Nothing here is ever cached or baked into the character. Every getter re-reads Config.Castes
-- + the player's live Caste/Purity, so a lore-team purity change from the mod panel takes
-- effect on the very next combat swing / merchant price / drain tick with no "recalculate"
-- step -- same design rule DNAManager already follows.
--
-- Purity scales every buff linearly (baseAmount is the value AT PURITY 100), floored per buff
-- type by Config.PurityScaling.MinimumFloors.

local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")

local Config  = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))

local castes    = Config.Castes
local scaling   = Config.PurityScaling
local kingCfg   = Config.KingTitle
local factionGroups = Config.CasteFactionGroups

local CasteManager = {}

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

-- ================================================================================
-- CASTE + PURITY ACCESS
-- ================================================================================

-- Always returns a table with all three DNA fields present, even for saves written before
-- Caste existed (DataManager's merge backfills Caste="", but a mod-set DNA table written by
-- an older DNAManager.setDNA could still be missing it).
function CasteManager.getDNA(player)
	local dm = _G.DataManager
	local dna = dm and dm.getValue(player, "DNA")
	if type(dna) ~= "table" then return { Clan = "", Purity = 0, Caste = "" } end
	return { Clan = dna.Clan or "", Purity = tonumber(dna.Purity) or 0, Caste = dna.Caste or "" }
end

function CasteManager.getCaste(player)
	return CasteManager.getDNA(player).Caste
end

function CasteManager.getPurity(player)
	return CasteManager.getDNA(player).Purity
end

function CasteManager.getCasteInfo(casteId)
	return castes[casteId]
end

function CasteManager.getAllCasteIds()
	local ids = {}
	for id in pairs(castes) do table.insert(ids, id) end
	table.sort(ids, function(a, b)
		if castes[a].rank == castes[b].rank then return a < b end
		return castes[a].rank < castes[b].rank
	end)
	return ids
end

-- Writes Caste while preserving Clan/Purity (and vice-versa for setPurity) -- the DNA table is
-- stored whole, so a naive setValue would silently wipe the other fields.
local function writeDNAField(player, field, value)
	local dm = _G.DataManager; if not dm then return false end
	local dna = CasteManager.getDNA(player)
	dna[field] = value
	dm.setValue(player, "DNA", dna)
	return true
end

function CasteManager.setCaste(player, casteId)
	if casteId == "None" or casteId == nil then casteId = "" end
	if casteId ~= "" and not castes[casteId] then return false, "Unknown caste: " .. tostring(casteId) end
	if not writeDNAField(player, "Caste", casteId) then return false, "DataManager not ready" end

	-- Losing Celtae must strip the crown -- King is validated against caste on grant, so an
	-- un-validated caste change would otherwise leave a non-Celtae King standing.
	if casteId ~= kingCfg.RequiresCaste and CasteManager.hasTitle(player, "King") then
		CasteManager.revokeTitle(player, "King")
	end

	CasteManager.grantStartingCurrencyIfOwed(player)

	local charName = getCharName(player)
	local label = casteId ~= "" and castes[casteId].name or "None"
	fireLiveFeed(charName, "Caste set to " .. label)
	local disc = _G.DiscordManager
	if disc and disc.logDNA then disc.logDNA(charName, "Caste set to " .. label) end
	return true
end

function CasteManager.setPurity(player, purity)
	local n = math.clamp(tonumber(purity) or 0, 0, 100)
	if not writeDNAField(player, "Purity", n) then return false, "DataManager not ready" end
	local charName = getCharName(player)
	fireLiveFeed(charName, "Purity set to " .. n)
	local disc = _G.DiscordManager
	if disc and disc.logDNA then disc.logDNA(charName, "Purity set to " .. n) end
	return true
end

-- ================================================================================
-- PURITY SCALING + BUFF LOOKUP
-- ================================================================================

function CasteManager.getEffectiveValue(buffType, baseAmount, purity)
	if not scaling.Enabled then return baseAmount end
	local floor = scaling.MinimumFloors[buffType] or 0
	local scaled = math.clamp((tonumber(purity) or 0) / 100, 0, 1)
	return baseAmount * math.max(floor, scaled)
end

-- Sums every buff of `buffType` on the player's caste, purity-scaled. `faction` (optional)
-- filters faction-scoped buffs; a buff that declares a faction only counts when asked for
-- that exact faction. Returns 0 when the player has no caste, so callers can add it blindly.
function CasteManager.getBuffTotal(player, buffType, faction)
	local dna = CasteManager.getDNA(player)
	local caste = castes[dna.Caste]
	if not caste then return 0 end
	local total = 0
	for _, b in ipairs(caste.buffs) do
		if b.type == buffType and (b.faction == nil or b.faction == faction) then
			total += CasteManager.getEffectiveValue(buffType, b.baseAmount, dna.Purity)
		end
	end
	return total
end

-- ================================================================================
-- TYPED GETTERS -- what the rest of the codebase actually calls. Each returns a value that is
-- a no-op (1.0 for multipliers, 0 for additive) when the player has no caste, so every call
-- site stays a single unconditional term.
-- ================================================================================

-- Belgae/Sequani: multiplies final M1/M2 damage, stacking multiplicatively alongside the
-- existing injury and DNA-clan multipliers in CombatManager.
function CasteManager.getDamageMultiplier(player)
	return 1 + CasteManager.getBuffTotal(player, "DamageBonus")
end

function CasteManager.getMaxPostureBonus(player)
	return CasteManager.getBuffTotal(player, "MaxPostureBonus")
end

function CasteManager.getMaxStaminaBonus(player)
	return CasteManager.getBuffTotal(player, "MaxStaminaBonus")
end

function CasteManager.getStaminaRegenMultiplier(player)
	return 1 + CasteManager.getBuffTotal(player, "StaminaRegenBonus")
end

-- Aedui: merchants charge less. Returns the multiplier to apply to a price (0.90 = 10% off).
function CasteManager.getMerchantPriceMultiplier(player)
	return math.max(0, 1 - CasteManager.getBuffTotal(player, "MerchantPriceReduction"))
end

-- Aedui: ally bonds form faster. Returns the required proximity seconds for THIS player,
-- floored at 10% of the base so a maxed speedup can never make bonds instant.
function CasteManager.getAllyBondSeconds(player)
	local base = Config.Ally.RequiredProximitySeconds
	local off = CasteManager.getBuffTotal(player, "AllyBondSpeedup")
	return math.max(base * 0.1, base - off)
end

-- Aquitani gain more from meditation; Belgae lose some from all non-combat progress. Both
-- fold into the one multiplier meditation applies.
function CasteManager.getMeditationProgressMultiplier(player)
	return math.max(0, 1 + CasteManager.getBuffTotal(player, "MeditationProgressBonus")
		- CasteManager.getBuffTotal(player, "NonCombatProgressPenalty"))
end

function CasteManager.getReadingProgressMultiplier(player)
	return math.max(0, 1 + CasteManager.getBuffTotal(player, "ReadingProgressBonus")
		- CasteManager.getBuffTotal(player, "NonCombatProgressPenalty"))
end

-- Generic non-combat progression (pushups, crafting, farming, gathering) -- Belgae only.
function CasteManager.getNonCombatProgressMultiplier(player)
	return math.max(0, 1 - CasteManager.getBuffTotal(player, "NonCombatProgressPenalty"))
end

-- Aquitani: sanity RISES slower (this multiplies positive deltas only -- recovery is untouched,
-- a disciplined mind resists the dark, it doesn't heal faster from it).
function CasteManager.getSanityRiseMultiplier(player)
	return math.max(0, 1 - CasteManager.getBuffTotal(player, "SanityResistance"))
end

-- Parisii: hunger and water drain slower.
function CasteManager.getHungerThirstDrainMultiplier(player)
	return math.max(0, 1 - CasteManager.getBuffTotal(player, "HungerThirstEfficiency"))
end

-- Parisii: knows the streets. Only applies while the player is actually inside Massalia --
-- ZoneManager is the authority on that, and returns nothing useful if it hasn't loaded yet.
function CasteManager.getMassaliaMovementMultiplier(player)
	local bonus = CasteManager.getBuffTotal(player, "MassaliaMovementBonus")
	if bonus == 0 then return 1 end
	local zm = _G.ZoneManager
	-- getCurrentZone returns the zone PART; its display name is the ZoneName attribute.
	local zonePart = zm and zm.getCurrentZone and zm.getCurrentZone(player)
	local zoneName = zonePart and zonePart:GetAttribute("ZoneName")
	if type(zoneName) == "string" and zoneName:lower():find("massalia") then return 1 + bonus end
	return 1
end

-- Faction rep bonus for a Config.Reputation key ("Gauls"/"Greeks"/"Military"). Resolves the
-- caste's group-level declarations ("AllGaulish") down to that concrete key, and adds the
-- King's flat perk on top.
function CasteManager.getFactionRepBonus(player, factionKey)
	local total = 0
	for groupName, keys in pairs(factionGroups) do
		if table.find(keys, factionKey) then
			total += CasteManager.getBuffTotal(player, "FactionRepBonus", groupName)
		end
	end
	if CasteManager.hasTitle(player, "King") then
		for _, perk in ipairs(kingCfg.Perks) do
			if perk.type == "FactionRepBonus" then
				local keys = factionGroups[perk.faction]
				if keys and table.find(keys, factionKey) then total += perk.amount end
			end
		end
	end
	return total
end

-- Effective standing with a faction: what is stored on the character plus the caste's (and
-- the King's) standing bonus. Nothing in the codebase writes the Reputation table on a regular
-- basis yet -- GreekTongue is the only writer -- so the bonus is applied live at read time
-- rather than baked in on spawn, which also means a purity change moves it immediately.
function CasteManager.getEffectiveReputation(player, factionKey)
	local dm = _G.DataManager; if not dm then return 0 end
	local rep = dm.getValue(player, "Reputation")
	local base = (type(rep) == "table" and rep[factionKey]) or 0
	return base + CasteManager.getFactionRepBonus(player, factionKey)
end

-- King only: +15% on all currency gained.
function CasteManager.getCurrencyIncomeMultiplier(player)
	if not CasteManager.hasTitle(player, "King") then return 1 end
	local mult = 1
	for _, perk in ipairs(kingCfg.Perks) do
		if perk.type == "CurrencyIncomeBonus" then mult += perk.amount end
	end
	return mult
end

-- ================================================================================
-- STARTING CURRENCY -- Celtae are born with a purse. Flat (floor 1.0), granted exactly once
-- per character ever, tracked by ReceivedCasteStartingCurrency so a re-grant of the same
-- caste, a rejoin, or a purity edit never pays out twice.
-- ================================================================================

function CasteManager.grantStartingCurrencyIfOwed(player)
	local dm = _G.DataManager; if not dm then return false end
	if dm.getValue(player, "ReceivedCasteStartingCurrency") then return false end
	local amount = CasteManager.getBuffTotal(player, "StartingCurrency")
	if amount <= 0 then return false end
	amount = math.floor(amount)

	local cur = dm.getValue(player, "Currency")
	if type(cur) ~= "table" then return false end
	cur.Obol = (cur.Obol or 0) + amount
	dm.setValue(player, "Currency", cur)
	dm.setValue(player, "ReceivedCasteStartingCurrency", true)

	Remotes.ShowNotification:FireClient(player, {
		title = "Born To It",
		body = "Your blood came with a purse. (+" .. amount .. " Obol)",
		duration = 8, style = "info",
	})
	fireLiveFeed(getCharName(player), "received " .. amount .. " Obol caste birthright")
	return true, amount
end

-- ================================================================================
-- TITLES
-- ================================================================================

function CasteManager.getTitles(player)
	local dm = _G.DataManager
	local t = dm and dm.getValue(player, "Titles")
	return type(t) == "table" and t or {}
end

function CasteManager.hasTitle(player, title)
	return table.find(CasteManager.getTitles(player), title) ~= nil
end

function CasteManager.findKing()
	for _, p in ipairs(Players:GetPlayers()) do
		if CasteManager.hasTitle(p, "King") then return p end
	end
	return nil
end

function CasteManager.grantTitle(player, title)
	local dm = _G.DataManager; if not dm then return false, "DataManager not ready" end
	if not table.find(Config.GrantableTitles, title) then return false, "Unknown title: " .. tostring(title) end
	if CasteManager.hasTitle(player, title) then return false, "Already holds " .. title end

	if title == "King" then
		if CasteManager.getCaste(player) ~= kingCfg.RequiresCaste then
			return false, "King requires the " .. kingCfg.RequiresCaste .. " caste"
		end
		if kingCfg.OnlyOneKing then
			local old = CasteManager.findKing()
			if old and old ~= player then CasteManager.revokeTitle(old, "King") end
		end
	end

	local titles = CasteManager.getTitles(player)
	table.insert(titles, title)
	dm.setValue(player, "Titles", titles)

	if title == "King" then CasteManager.onCrowned(player) end

	local charName = getCharName(player)
	fireLiveFeed(charName, "was granted the title " .. title)
	local disc = _G.DiscordManager
	if disc and disc.logDNA then disc.logDNA(charName, "Title granted: " .. title) end
	return true
end

function CasteManager.revokeTitle(player, title)
	local dm = _G.DataManager; if not dm then return false, "DataManager not ready" end
	local titles = CasteManager.getTitles(player)
	local idx = table.find(titles, title)
	if not idx then return false, "Does not hold " .. tostring(title) end
	table.remove(titles, idx)
	dm.setValue(player, "Titles", titles)
	if title == "King" then CasteManager.removeCrown(player) end
	fireLiveFeed(getCharName(player), "had the title " .. title .. " revoked")
	return true
end

-- ================================================================================
-- THE CROWN
-- ================================================================================

local CROWN_NAME = "AbyssCrown"

function CasteManager.removeCrown(player)
	local char = player.Character; if not char then return end
	local old = char:FindFirstChild(CROWN_NAME)
	if old then old:Destroy() end
end

-- PLACEHOLDER_ASSET: CrownModel. Until Config.KingTitle.CrownAssetId is a real accessory, the
-- crown renders as a gold ring floating above the head -- a real visible marker rather than
-- nothing at all, and it swaps to the accessory automatically the moment an ID is filled in.
function CasteManager.applyCrown(player)
	local char = player.Character; if not char then return end
	if char:FindFirstChild(CROWN_NAME) then return end
	local head = char:FindFirstChild("Head"); if not head then return end

	if kingCfg.CrownAssetId and kingCfg.CrownAssetId ~= 0 then
		local ok, asset = pcall(function()
			return game:GetService("InsertService"):LoadAsset(kingCfg.CrownAssetId)
		end)
		if ok and asset then
			local acc = asset:FindFirstChildOfClass("Accessory")
			if acc then
				acc.Name = CROWN_NAME
				local hum = char:FindFirstChildOfClass("Humanoid")
				if hum then hum:AddAccessory(acc) else acc.Parent = char end
				asset:Destroy()
				return
			end
			asset:Destroy()
		end
	end

	local crown = Instance.new("Part")
	crown.Name = CROWN_NAME
	crown.Shape = Enum.PartType.Cylinder
	crown.Size = Vector3.new(0.25, 1.6, 1.6)
	crown.Color = Color3.fromRGB(212, 175, 55)
	crown.Material = Enum.Material.Metal
	crown.CanCollide = false
	crown.Massless = true
	crown.Parent = char
	local weld = Instance.new("Weld")
	weld.Part0 = head
	weld.Part1 = crown
	weld.C0 = CFrame.new(0, 1.5, 0) * CFrame.Angles(0, 0, math.rad(90))
	weld.Parent = crown
end

function CasteManager.onCrowned(player)
	CasteManager.applyCrown(player)
	local charName = getCharName(player)
	local msg = charName .. " has been crowned King of the Celtic Crun."
	for _, p in ipairs(Players:GetPlayers()) do
		Remotes.ShowNotification:FireClient(p, { title = "[THE CROWN]", body = msg, duration = 12, style = "warning" })
	end
	local hud = _G.HUDManager
	if hud and hud.showGlobalMessage then hud.showGlobalMessage(msg) end
	-- PLACEHOLDER_SOUND: coronation_horn. Parented to SoundService so it replicates to every
	-- client at once without needing a per-client remote.
	if kingCfg.CoronationSound and kingCfg.CoronationSound ~= "rbxassetid://0" then
		local snd = Instance.new("Sound")
		snd.SoundId = kingCfg.CoronationSound
		snd.Volume = 0.7
		snd.Parent = game:GetService("SoundService")
		snd:Play()
		game:GetService("Debris"):AddItem(snd, 15)
	end
	local disc = _G.DiscordManager
	if disc and disc.logDNA then disc.logDNA(charName, "CROWNED KING") end
end

-- Crown must survive respawns -- it lives on the character model, which is rebuilt each death.
local function hookCharacter(player)
	player.CharacterAdded:Connect(function()
		task.wait(0.5)
		if CasteManager.hasTitle(player, "King") then CasteManager.applyCrown(player) end
	end)
end

local function onPlayerAdded(player)
	hookCharacter(player)
	task.spawn(function()
		-- Wait for DataManager to finish loading before touching currency/titles.
		local dm
		for _ = 1, 200 do
			dm = _G.DataManager
			if dm and dm.isLoaded(player) then break end
			task.wait(0.1)
		end
		if not (dm and dm.isLoaded(player)) then return end
		CasteManager.grantStartingCurrencyIfOwed(player)
		if player.Character and CasteManager.hasTitle(player, "King") then
			CasteManager.applyCrown(player)
		end
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, p in ipairs(Players:GetPlayers()) do onPlayerAdded(p) end

-- ================================================================================
-- MOD-PANEL READ MODEL -- "Active Caste Buffs (at current purity)" needs the resolved numbers,
-- not the config, so the lore team can see exactly what a purity value is buying.
-- ================================================================================

local BUFF_LABELS = {
	DamageBonus              = function(v) return string.format("+%.2f%% damage", v * 100) end,
	MaxPostureBonus          = function(v) return string.format("+%.1f max posture", v) end,
	MaxStaminaBonus          = function(v) return string.format("+%.1f max stamina", v) end,
	StaminaRegenBonus        = function(v) return string.format("+%.1f%% stamina regen", v * 100) end,
	NonCombatProgressPenalty = function(v) return string.format("-%.1f%% non-combat progress", v * 100) end,
	MerchantPriceReduction   = function(v) return string.format("-%.1f%% merchant prices", v * 100) end,
	AllyBondSpeedup          = function(v) return string.format("-%.0fs ally bond time", v) end,
	MeditationProgressBonus  = function(v) return string.format("+%.1f%% meditation", v * 100) end,
	ReadingProgressBonus     = function(v) return string.format("+%.1f%% lore reading", v * 100) end,
	SanityResistance         = function(v) return string.format("-%.1f%% sanity gain", v * 100) end,
	HungerThirstEfficiency   = function(v) return string.format("-%.1f%% hunger/water drain", v * 100) end,
	MassaliaMovementBonus    = function(v) return string.format("+%.1f%% speed in Massalia", v * 100) end,
	StartingCurrency         = function(v) return string.format("+%.0f Obol at birth", v) end,
	FactionRepBonus          = function(v) return string.format("+%.1f rep", v) end,
}

function CasteManager.describeActiveBuffs(player)
	local dna = CasteManager.getDNA(player)
	local caste = castes[dna.Caste]
	if not caste then return {} end
	local lines = {}
	for _, b in ipairs(caste.buffs) do
		local v = CasteManager.getEffectiveValue(b.type, b.baseAmount, dna.Purity)
		local fmt = BUFF_LABELS[b.type]
		local text = fmt and fmt(v) or (b.type .. " " .. tostring(v))
		if b.faction then text = text .. " (" .. b.faction .. ")" end
		table.insert(lines, text)
	end
	return lines
end

_G.CasteManager = CasteManager
print("[CasteManager] Init -- " .. #CasteManager.getAllCasteIds() .. " castes defined")
