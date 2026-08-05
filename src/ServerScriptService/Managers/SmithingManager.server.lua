-- SmithingManager -- design doc PART FIVE. Runs qteCount sequential Tier2 QTEs through the
-- existing QTEManager (no new QTE type needed); fail count degrades the output quality tier
-- rather than failing outright until 3+ fails.
local Players           = game:GetService("Players")
local RepStorage        = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local recipes = Config.SmithingRecipes
local tierOrder = Config.QualityTierOrder

local function getOrCreate(name, isFunc)
	local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
		local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
	end)()
	local r=folder:FindFirstChild(name); if r then return r end
	r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_ShowNotification = getOrCreate("ShowNotification")
local RE_LiveFeedUpdate   = getOrCreate("LiveFeedUpdate")
local RE_SmithingOpenUI   = getOrCreate("SmithingOpenUI")
local RE_RequestStart     = getOrCreate("RequestStartSmithing")
local RE_HammerBeat       = getOrCreate("SmithingHammerBeat")
local RE_SmithingComplete = getOrCreate("SmithingComplete")

local FORGE_TAG = "ABYSSForge"
local HAMMER_PAUSE = 0.8

local forgeBusy = {} -- [part] = userId

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
	RE_ShowNotification:FireClient(player, { title = title, body = body, duration = 6, style = "info" })
end

local function hasMaterials(player, materials)
	local inv = _G.InventoryManager; if not inv then return false end
	for _, m in ipairs(materials) do
		if inv.countItem(player, m.item) < m.count then return false end
	end
	return true
end

local function consumeMaterials(player, materials)
	local inv = _G.InventoryManager; if not inv then return end
	for _, m in ipairs(materials) do inv.removeItem(player, m.item, m.count) end
end

local function degradeTier(qualityTier, fails)
	local idx = table.find(tierOrder, qualityTier) or 1
	idx = math.max(1, idx - fails)
	return tierOrder[idx]
end

local function onForgeInteract(player, part)
	if forgeBusy[part] then notify(player, "Smithing", "This forge is in use."); return end
	local available = {}
	for weaponName, recipe in pairs(recipes) do
		if hasMaterials(player, recipe.materials) then table.insert(available, weaponName) end
	end
	if #available == 0 then notify(player, "Smithing", "You lack the materials for any weapon."); return end
	RE_SmithingOpenUI:FireClient(player, { forgePart = part, recipes = available })
end

-- Runs qteCount sequential Tier2 QTEs, tracking fails, then resolves the final outcome.
local function runSmithingSequence(player, part, weaponName, recipe)
	local fails = 0
	local step = 0
	local function nextStep()
		step += 1
		if step > recipe.qteCount then
			-- All QTEs done -- resolve
			forgeBusy[part] = nil
			local charName = getCharName(player)
			local disc = _G.DiscordManager
			if fails >= 3 then
				RE_SmithingComplete:FireClient(player, { success = false, qualityTier = nil, fails = fails })
				notify(player, "Smithing", "The forging failed entirely. Materials lost.")
				fireLiveFeed(charName, "failed forging " .. weaponName .. " (" .. fails .. " QTE fails)")
				if disc then disc.logInteractable(player, part.Name, "SMITHING FULL FAIL " .. weaponName) end
				return
			end
			local finalTier = degradeTier(recipe.qualityTier, fails)
			local inv = _G.InventoryManager
			if inv then inv.addItem(player, recipe.output, finalTier, 1) end
			RE_SmithingComplete:FireClient(player, { success = true, qualityTier = finalTier, fails = fails })
			notify(player, "Smithing", "You have forged a " .. finalTier .. " " .. weaponName .. "!")
			fireLiveFeed(charName, "forged a " .. finalTier .. " " .. weaponName .. " (" .. fails .. " fails)")
			if disc then disc.logInteractable(player, part.Name, "SMITHING SUCCESS " .. finalTier .. " " .. weaponName) end
			return
		end
		RE_HammerBeat:FireClient(player, { step = step, total = recipe.qteCount })
		task.delay(HAMMER_PAUSE, function()
			if not player.Parent then forgeBusy[part] = nil; return end
			local qte = _G.QTEManager
			if not qte then forgeBusy[part] = nil; return end
			qte.startQTE(player, "Tier2", { source = "Smithing", weaponName = weaponName, step = step }, function(p, success)
				if not success then fails += 1 end
				nextStep()
			end)
		end)
	end
	nextStep()
end

RE_RequestStart.OnServerEvent:Connect(function(player, part, weaponName)
	if typeof(part) ~= "Instance" or not part.Parent then return end
	if forgeBusy[part] then notify(player, "Smithing", "This forge is in use."); return end
	local recipe = recipes[weaponName]; if not recipe then return end
	if not hasMaterials(player, recipe.materials) then notify(player, "Smithing", "You lack the materials."); return end
	consumeMaterials(player, recipe.materials)
	forgeBusy[part] = player.UserId
	runSmithingSequence(player, part, weaponName, recipe)
end)

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
	prompt.ActionText = part:GetAttribute("InteractPrompt") or "Forge"
	prompt.MaxActivationDistance = tonumber(part:GetAttribute("InteractRange")) or 8
	prompt.Triggered:Connect(function(player) onForgeInteract(player, part) end)
end

for _, part in ipairs(CollectionService:GetTagged(FORGE_TAG)) do setupPrompt(part) end
CollectionService:GetInstanceAddedSignal(FORGE_TAG):Connect(setupPrompt)

local SmithingManager = {}
function SmithingManager.createForge(position)
	local part = Instance.new("Part")
	part.Name = "Forge"
	part.Anchored = true; part.CanCollide = true
	part.Size = Vector3.new(4, 3, 4)
	part.Material = Enum.Material.Concrete
	part.Color = Color3.fromRGB(50, 45, 40)
	part.CFrame = CFrame.new(position)
	part:SetAttribute("IsInteractable", true)
	part:SetAttribute("InteractType", "Smithing")
	part:SetAttribute("InteractPrompt", "Forge")
	local fire = Instance.new("Fire"); fire.Size = 10; fire.Heat = 12; fire.Parent = part
	CollectionService:AddTag(part, FORGE_TAG)
	return part
end

_G.SmithingManager = SmithingManager
print("[SmithingManager] Init")
