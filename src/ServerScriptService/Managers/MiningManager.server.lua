-- MiningManager -- design doc PART TWO. Ore nodes are E-interact Parts that run a
-- ReactiveClick QTE (see Config.QTETiers.MiningQTE, QTEManager's overrideCfg param, and
-- QTEClient.runReactiveClick) tuned per-node by OreRarity and per-player by Endurance.
local Players           = game:GetService("Players")
local RepStorage        = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local rarityCfg     = Config.MiningRarityTuning
local enduranceCfg  = Config.MiningEndurance
local oreCfg        = Config.OreNodes

local function getOrCreate(name, isFunc)
	local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
		local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
	end)()
	local r=folder:FindFirstChild(name); if r then return r end
	r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_ShowNotification = getOrCreate("ShowNotification")
local RE_LiveFeedUpdate   = getOrCreate("LiveFeedUpdate")

local ORE_TAG = "ABYSSOreNode"
local DEFAULT_COOLDOWN = 5
local DEFAULT_RESPAWN  = 300
local DEFAULT_RANGE    = 8

local depleted   = {} -- [part] = true while respawning
local cooldowns  = {} -- ["uid_partId"] = tick() the cooldown clears

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
			RE_LiveFeedUpdate:FireClient(p, { type = "ACTION", h = now.hour, m = now.min, zone = "?", charName = charName, message = message })
		end
	end
end

local function notify(player, title, body)
	RE_ShowNotification:FireClient(player, { title = title, body = body, duration = 4, style = "info" })
end

local function notifyLoreTeam(title, body)
	local mgr = _G.ModManager
	for _, p in ipairs(Players:GetPlayers()) do
		if mgr and mgr.isMod(p) then
			RE_ShowNotification:FireClient(p, { title = title, body = body, duration = 8, style = "lore" })
		end
	end
end

local function cooldownKey(player, part) return player.UserId .. "_" .. tostring(part) end
local function isOnCooldown(player, part)
	local until_ = cooldowns[cooldownKey(player, part)]
	return until_ ~= nil and tick() < until_
end
local function setCooldown(player, part)
	local cd = tonumber(part:GetAttribute("InteractCooldown")) or DEFAULT_COOLDOWN
	if cd > 0 then cooldowns[cooldownKey(player, part)] = tick() + cd end
end

local function getEndurance(player)
	local dm = _G.DataManager
	local stats = dm and dm.getValue(player, "Stats")
	return (stats and stats.Endurance) or 0
end

-- ── Node visibility toggle on deplete/respawn (single-Part nodes per the design doc) ──
local function setNodeDepleted(part, isDepleted)
	part:SetAttribute("Mined", isDepleted)
	part.Transparency = isDepleted and 1 or (part:GetAttribute("_OrigTransparency") or 0)
	part.CanCollide = not isDepleted
	part.CanQuery = not isDepleted
	local prompt = part:FindFirstChildOfClass("ProximityPrompt")
	if prompt then prompt.Enabled = not isDepleted end
end

local function onMine(player, part)
	if depleted[part] then notify(player, "Mining", "This node is depleted. Come back later."); return end
	if isOnCooldown(player, part) then notify(player, "Mining", "You must wait to try again."); return end
	setCooldown(player, part)

	local rarity = part:GetAttribute("OreRarity")
	rarity = (rarity and rarity ~= "") and rarity or "Common"
	local tuning = rarityCfg[rarity] or rarityCfg.Common
	local tolerance = (tuning.toleranceMs or 400) + getEndurance(player) * (enduranceCfg.TolerancePerPoint or 5)

	local oreType = part:GetAttribute("OreType"); oreType = (oreType and oreType ~= "") and oreType or "Iron"
	local quantityRange = part:GetAttribute("OreQuantity"); quantityRange = (quantityRange and quantityRange ~= "") and quantityRange or "1-3"
	local charName = getCharName(player)

	local qte = _G.QTEManager
	if not qte then return end
	qte.startQTE(player, "MiningQTE", { source = "Mining", nodeName = part.Name }, function(p, success)
		local disc = _G.DiscordManager
		if success then
			local qty = Config.Util.rollRange(quantityRange)
			local inv = _G.InventoryManager
			if inv then inv.addItem(p, oreType .. "_Ore", "Material", qty) end
			fireLiveFeed(charName, "mined " .. qty .. " " .. oreType .. "_Ore from " .. part.Name)
			if disc then disc.logInteractable(p, part.Name, "MINING SUCCESS " .. qty .. "x " .. oreType .. "_Ore") end
			if rarity == "Rare" or rarity == "Legendary" then
				notifyLoreTeam("Rare Find", charName .. " mined " .. rarity .. " " .. oreType .. " at " .. part.Name)
			end
			local respawnAfter = tonumber(part:GetAttribute("RespawnAfterMining")) or DEFAULT_RESPAWN
			if respawnAfter > 0 then
				part:SetAttribute("_OrigTransparency", part.Transparency)
				depleted[part] = true
				setNodeDepleted(part, true)
				task.delay(respawnAfter, function()
					if part.Parent then depleted[part] = nil; setNodeDepleted(part, false) end
				end)
			end
		else
			fireLiveFeed(charName, "failed to mine " .. part.Name)
			if disc then disc.logInteractable(p, part.Name, "MINING FAIL") end
		end
	end, { toleranceMs = tolerance, clickCount = tuning.clickCount, countdownSpeed = tuning.countdownSpeed })
end

local function setupPrompt(part)
	if not part:IsA("BasePart") then return end
	local prompt = part:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.HoldDuration = 0
		prompt.RequiresLineOfSight = true
		prompt.KeyboardKeyCode = Enum.KeyCode.E
		prompt.Style = Enum.ProximityPromptStyle.Custom
		prompt.Parent = part
	end
	prompt.ActionText = part:GetAttribute("InteractPrompt") or "Mine"
	prompt.MaxActivationDistance = tonumber(part:GetAttribute("InteractRange")) or DEFAULT_RANGE
	prompt.Triggered:Connect(function(player) onMine(player, part) end)
end

for _, part in ipairs(CollectionService:GetTagged(ORE_TAG)) do setupPrompt(part) end
CollectionService:GetInstanceAddedSignal(ORE_TAG):Connect(setupPrompt)

local MiningManager = {}

function MiningManager.createNode(position, oreType, oreRarity)
	oreType = oreType or "Iron"
	local preset = oreCfg[oreType]
	oreRarity = (oreRarity and oreRarity ~= "") and oreRarity or (preset and preset.rarity) or "Common"
	local quantity = (preset and preset.quantity) or "1-3"
	local part = Instance.new("Part")
	part.Name = oreType .. "Node"
	part.Anchored = true; part.CanCollide = true
	part.Size = Vector3.new(3, 2, 3)
	part.Material = Enum.Material.Rock
	part.Color = Color3.fromRGB(90, 90, 95)
	part.CFrame = CFrame.new(position)
	part:SetAttribute("IsInteractable", true)
	part:SetAttribute("InteractType", "Mining")
	part:SetAttribute("InteractPrompt", "Mine")
	part:SetAttribute("OreType", oreType)
	part:SetAttribute("OreRarity", oreRarity)
	part:SetAttribute("OreQuantity", quantity)
	part:SetAttribute("InteractCooldown", 0)
	part:SetAttribute("RespawnAfterMining", DEFAULT_RESPAWN)
	CollectionService:AddTag(part, ORE_TAG)
	return part
end

_G.MiningManager = MiningManager
print("[MiningManager] Init")
