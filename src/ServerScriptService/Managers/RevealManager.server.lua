-- RevealManager -- NPC stat revelation.
--
-- A player cannot read their own caste, purity, clan or sanity anywhere in the UI. The only
-- way to learn them is to find an NPC the lore team has flagged as a Revealer and ask. That
-- makes knowledge a service sought out in the world rather than a stat screen.
--
-- A Revealer is just a normal NPC with attributes set (from the mod panel or a script):
--   IsRevealer     = true
--   RevealType     = "Caste"|"Purity"|"Clan"|"Stats"|"FullDNA"|"Sanity"|"Everything"
--   RevealCost     = Obol charged per use (0 = free)
--   RevealCooldown = seconds before the SAME player may ask the SAME NPC again
--
-- Attributes (not a separate registry) so a Revealer survives anything that rebuilds the NPC
-- table, and so BTools/mod-panel edits are visible in the Explorer like every other NPC knob.

local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")

local Config  = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))

local revealCfg = Config.Reveal
local castes    = Config.Castes
local clans     = Config.LoreClans

local RevealManager = {}

-- [npcModel] = { [userId] = nextAllowedTick }
local cooldowns = setmetatable({}, { __mode = "k" })

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

local function notify(player, title, body, style)
	Remotes.ShowNotification:FireClient(player, { title = title, body = body, duration = 7, style = style or "info" })
end

-- ================================================================================
-- REVELATION TEXT -- written as NPC dialogue, not a stat dump. The number is there, but it
-- arrives in a sentence a seer would actually say.
-- ================================================================================

local function casteLine(player)
	local cm = _G.CasteManager; if not cm then return "Your blood tells me nothing." end
	local casteId = cm.getCaste(player)
	local info = castes[casteId]
	if not info then return "Your blood... it has no caste I can name. You are nobody's." end
	return string.format("Your blood... you are of the %s. %s", info.name, info.loreNotes or "")
end

local function purityLine(player)
	local cm = _G.CasteManager; if not cm then return "I cannot taste your blood." end
	local p = cm.getPurity(player)
	local flavour
	if p >= 80 then flavour = "Your bloodline runs strong."
	elseif p >= 50 then flavour = "Your bloodline holds, but it has been watered."
	elseif p >= 20 then flavour = "Your blood is thin. Something was lost along the way."
	else flavour = "There is almost nothing of the old blood left in you." end
	return string.format("%s (Purity: %d)", flavour, p)
end

local function clanLine(player)
	local dnaM = _G.DNAManager; if not dnaM then return "No name comes to me." end
	local dna = dnaM.getDNA(player)
	local clan = dna.Clan ~= "" and clans[dna.Clan]
	if not clan then return "You carry no house name. You are the first of your line, or the last." end
	return string.format("You carry the name of %s.", clan.name)
end

local function statsLine(player)
	local dm = _G.DataManager; if not dm then return "I cannot read your body." end
	local stats = dm.getValue(player, "Stats") or {}
	local dnaM = _G.DNAManager
	local function eff(name)
		local base = stats[name] or 0
		return dnaM and dnaM.getEffectiveStat(player, name, base) or base
	end
	local str, endur, agi = eff("Strength"), eff("Endurance"), eff("Agility")
	local build
	if str >= endur and str >= agi then build = "A fighter's build."
	elseif agi >= str and agi >= endur then build = "Built to run, not to stand."
	else build = "Built to endure." end
	return string.format("Strength %d. Endurance %d. Agility %d. %s", str, endur, agi, build)
end

local function fullDNALine(player)
	local cm, dnaM = _G.CasteManager, _G.DNAManager
	if not cm or not dnaM then return "Your blood is closed to me." end
	local dna = dnaM.getDNA(player)
	local casteInfo = castes[cm.getCaste(player)]
	local clan = dna.Clan ~= "" and clans[dna.Clan]
	local purity = cm.getPurity(player)
	local casteWord = casteInfo and (casteInfo.name .. " blood") or "Casteless blood"
	local clanWord = clan and (", " .. clan.name) or ", of no house"
	local pureWord = purity >= 70 and ", and pure at that" or ""
	return string.format("%s%s%s. (Purity: %d)", casteWord, clanWord, pureWord, purity)
end

local function sanityLine(player)
	local sm = _G.SanityManager; if not sm then return "Your mind is quiet to me." end
	local s = sm.getSanity(player) or 0
	local flavour
	if s >= 75 then flavour = "Your mind... something claws at it. It is close to open."
	elseif s >= 40 then flavour = "Something walks behind your thoughts."
	else flavour = "Your mind is your own. For now." end
	return string.format("%s (a knowing look)", flavour)
end

local LINE_BUILDERS = {
	Caste = casteLine, Purity = purityLine, Clan = clanLine,
	Stats = statsLine, FullDNA = fullDNALine, Sanity = sanityLine,
}

local function buildLines(player, revealType)
	if revealType == "Everything" then
		return { fullDNALine(player), statsLine(player), sanityLine(player) }
	end
	local fn = LINE_BUILDERS[revealType]
	if not fn then return nil end
	return { fn(player) }
end

-- ================================================================================
-- KNOWN-ABOUT-SELF PERSISTENCE -- once told, the player keeps knowing it, and the Bloodline
-- section of their journal starts showing it.
-- ================================================================================

function RevealManager.getKnown(player)
	local dm = _G.DataManager
	local k = dm and dm.getValue(player, "KnownAboutSelf")
	if type(k) ~= "table" then return { Caste = false, Purity = false, Clan = false, Stats = false, Sanity = false } end
	return k
end

function RevealManager.markKnown(player, revealType)
	local dm = _G.DataManager; if not dm then return end
	local grants = revealCfg.Grants[revealType]; if not grants then return end
	local known = RevealManager.getKnown(player)
	for _, flag in ipairs(grants) do known[flag] = true end
	dm.setValue(player, "KnownAboutSelf", known)
end

-- Journal "Bloodline" section -- only the fields a Revealer has actually told this player.
-- Returns nil when they know nothing, so the journal can omit the section entirely rather
-- than render an empty panel.
function RevealManager.getJournalBloodline(player)
	local known = RevealManager.getKnown(player)
	local cm, dnaM = _G.CasteManager, _G.DNAManager
	if not cm or not dnaM then return nil end
	local out, any = {}, false
	if known.Caste then
		local info = castes[cm.getCaste(player)]
		out.Caste = info and info.name or "Casteless"; any = true
	end
	if known.Purity then out.Purity = cm.getPurity(player); any = true end
	if known.Clan then
		local dna = dnaM.getDNA(player)
		local clan = dna.Clan ~= "" and clans[dna.Clan]
		out.Clan = clan and clan.name or "No house"; any = true
	end
	if known.Sanity then
		local sm = _G.SanityManager
		if sm then out.Sanity = sm.getSanity(player); any = true end
	end
	local titles = cm.getTitles(player)
	if #titles > 0 then out.Titles = titles; any = true end
	if not any then return nil end
	return out
end

-- ================================================================================
-- CONFIGURATION (called by ModManager)
-- ================================================================================

function RevealManager.isRevealer(model)
	return model:GetAttribute("IsRevealer") == true
end

function RevealManager.getConfig(model)
	return {
		isRevealer = model:GetAttribute("IsRevealer") == true,
		revealType = model:GetAttribute("RevealType") or "Caste",
		cost       = tonumber(model:GetAttribute("RevealCost")) or 0,
		cooldown   = tonumber(model:GetAttribute("RevealCooldown")) or 0,
	}
end

function RevealManager.setRevealer(model, isRevealer, revealType, cost, cooldown)
	if isRevealer and revealType and not table.find(revealCfg.Types, revealType) then
		return false, "Unknown reveal type: " .. tostring(revealType)
	end
	model:SetAttribute("IsRevealer", isRevealer == true)
	if revealType then model:SetAttribute("RevealType", revealType) end
	model:SetAttribute("RevealCost", math.max(0, math.floor(tonumber(cost) or 0)))
	model:SetAttribute("RevealCooldown", math.max(0, tonumber(cooldown) or 0))
	-- Reconfiguring is a fresh deal: drop every player's outstanding cooldown on this NPC.
	-- Without this, shortening (or zeroing) the cooldown leaves players still locked out by the
	-- OLD, longer timer -- the new setting appears to do nothing until the old one expires.
	cooldowns[model] = nil
	RevealManager.refreshPrompt(model)
	return true
end

-- ================================================================================
-- THE PROMPT -- Custom style, so InteractPromptClient renders it as the same "E - Speak" HUD
-- prompt every other interactable in the game uses instead of a floating 3D bubble.
-- Parented to the Head so it reads as talking TO the NPC.
-- ================================================================================

local PROMPT_NAME = "RevealPrompt"

function RevealManager.refreshPrompt(model)
	local head = model:FindFirstChild("Head")
	if not head then return end
	local prompt = head:FindFirstChild(PROMPT_NAME)

	if not RevealManager.isRevealer(model) then
		if prompt then prompt:Destroy() end
		return
	end

	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = PROMPT_NAME
		prompt.HoldDuration = 0
		prompt.RequiresLineOfSight = true
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.Style = Enum.ProximityPromptStyle.Custom
		prompt.Parent = head
		prompt.Triggered:Connect(function(player)
			RevealManager.requestReveal(player, model)
		end)
	end
	prompt.MaxActivationDistance = revealCfg.PromptRange

	-- Surface the price in the prompt itself -- a player should know they're about to be
	-- charged before they press E, not after.
	local cost = tonumber(model:GetAttribute("RevealCost")) or 0
	prompt.ActionText = cost > 0
		and (revealCfg.PromptLabel .. " (" .. cost .. " Obol)")
		or revealCfg.PromptLabel
end

-- ================================================================================
-- THE REVEAL
-- ================================================================================

function RevealManager.requestReveal(player, model)
	if not model or not model.Parent then return false end
	if not RevealManager.isRevealer(model) then return false end

	local dm = _G.DataManager
	if not dm or not dm.isLoaded(player) then return false end

	local cfg = RevealManager.getConfig(model)
	local npcM = _G.NPCManager
	local npcName = model:GetAttribute("NPCName") or "NPC"

	-- Range re-check: the ProximityPrompt already enforces this client-side, but a spoofed
	-- Triggered can't be trusted -- same defensive pattern SpiritManager uses.
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local head = model:FindFirstChild("Head")
	if not hrp or not head then return false end
	if (hrp.Position - head.Position).Magnitude > revealCfg.PromptRange + 5 then return false end

	-- 1. Cooldown
	local perNPC = cooldowns[model]
	if not perNPC then perNPC = {}; cooldowns[model] = perNPC end
	local nextAt = perNPC[player.UserId] or 0
	if tick() < nextAt then
		local wait = math.ceil(nextAt - tick())
		if npcM then npcM.speakText(model, "I have told you what I saw. Come back later.", "Reveal") end
		notify(player, npcName, "You must wait " .. wait .. "s before asking again.", "warning")
		return false
	end

	-- 2. Cost. An oracle selling knowledge is a merchant, so the Aedui MerchantPriceReduction
	-- applies here -- currently the only currency-spending flow in the game, and the natural
	-- home for that buff until a proper shop system exists.
	local cm = _G.CasteManager
	local price = cfg.cost
	if price > 0 and cm then
		price = math.max(1, math.floor(price * cm.getMerchantPriceMultiplier(player) + 0.5))
	end
	if price > 0 then
		local cur = dm.getValue(player, "Currency")
		if type(cur) ~= "table" or (cur.Obol or 0) < price then
			if npcM then npcM.speakText(model, "Knowledge is not free. Come back with coin.", "Reveal") end
			notify(player, npcName, "You need " .. price .. " Obol.", "warning")
			return false
		end
		cur.Obol -= price
		dm.setValue(player, "Currency", cur)
	end

	-- 3. Build and deliver
	local lines = buildLines(player, cfg.revealType)
	if not lines then
		warn("[RevealManager] " .. npcName .. " has an invalid RevealType: " .. tostring(cfg.revealType))
		return false
	end

	if cfg.cooldown > 0 then perNPC[player.UserId] = tick() + cfg.cooldown end

	if npcM then npcM.speakText(model, lines[1], "Reveal") end

	-- PLACEHOLDER_GUI: StatRevealPanel / PLACEHOLDER_SOUND: reveal_chime -- the styled panel is
	-- built client-side by StatRevealClient; only this player ever receives it.
	Remotes.ShowStatReveal:FireClient(player, {
		speaker = npcName,
		revealType = cfg.revealType,
		lines = lines,
		cost = price,
		sound = revealCfg.RevealSound,
	})

	RevealManager.markKnown(player, cfg.revealType)

	local charName = getCharName(player)
	fireLiveFeed(charName, "learned their " .. cfg.revealType .. " from " .. npcName)
	local disc = _G.DiscordManager
	if disc and disc.logNPC then
		disc.logNPC("REVEAL", charName .. " learned their " .. cfg.revealType .. " from " .. npcName)
	end
	return true
end

-- Any NPC that already has IsRevealer set (spawned by a script, or restored by BTools) needs
-- its prompt built without a mod-panel round trip. Watching workspace.NPCs covers both the
-- "already there" and "added later" cases with one code path.
local function watchFolder()
	local folder = workspace:FindFirstChild("NPCs")
	if not folder then return end
	local function consider(model)
		if not model:IsA("Model") then return end
		task.defer(function()
			if model.Parent then RevealManager.refreshPrompt(model) end
		end)
		model:GetAttributeChangedSignal("IsRevealer"):Connect(function()
			RevealManager.refreshPrompt(model)
		end)
		model:GetAttributeChangedSignal("RevealCost"):Connect(function()
			RevealManager.refreshPrompt(model)
		end)
	end
	for _, m in ipairs(folder:GetChildren()) do consider(m) end
	folder.ChildAdded:Connect(consider)
end

task.spawn(function()
	local folder = workspace:WaitForChild("NPCs", 30)
	if folder then watchFolder() end
end)

_G.RevealManager = RevealManager
print("[RevealManager] Init -- " .. #revealCfg.Types .. " reveal types")
