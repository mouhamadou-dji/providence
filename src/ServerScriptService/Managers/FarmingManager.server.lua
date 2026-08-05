-- FarmingManager -- design doc PART SIX. Session-only (workspace Parts, no DataStore) --
-- growth continues off-player-time via a real Heartbeat-driven check (tick()-based, so it
-- also naturally resets on server restart, matching the design doc's own "session only" call).
local Players           = game:GetService("Players")
local RepStorage        = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local recipes = Config.FarmingRecipes
local CHECK_INTERVAL = Config.FarmingGrowthCheckInterval or 10

local function getOrCreate(name, isFunc)
	local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
		local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
	end)()
	local r=folder:FindFirstChild(name); if r then return r end
	r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_ShowNotification    = getOrCreate("ShowNotification")
local RE_LiveFeedUpdate      = getOrCreate("LiveFeedUpdate")
local RE_OpenSeedSelect      = getOrCreate("FarmingOpenSeedSelect")
local RE_RequestPlantSeed    = getOrCreate("RequestPlantSeed")
local RE_FarmingFeedback     = getOrCreate("FarmingFeedback")

local PLOT_TAG = "ABYSSFarmingPlot"

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
	RE_ShowNotification:FireClient(player, { title = title, body = body, duration = 5, style = "info" })
end

-- ── Visual: sprout / full-grown stand-ins (PLACEHOLDER_ASSET: SproutMesh / PlantFullyGrownMesh) ──
local function clearVisual(plot)
	local v = plot:FindFirstChild("PlantVisual"); if v then v:Destroy() end
end
local function setVisual(plot, stage) -- "sprout" | "grown" | nil
	clearVisual(plot)
	if not stage then return end
	local v = Instance.new("Part")
	v.Name = "PlantVisual"
	v.Anchored = true; v.CanCollide = false; v.CanQuery = false
	v.Material = Enum.Material.Grass
	v.Color = stage == "grown" and Color3.fromRGB(90, 160, 60) or Color3.fromRGB(120, 190, 90)
	v.Size = stage == "grown" and Vector3.new(1.4, 2.2, 1.4) or Vector3.new(0.6, 0.8, 0.6)
	v.Shape = Enum.PartType.Cylinder
	v.Orientation = Vector3.new(0, 0, 90)
	v.CFrame = plot.CFrame * CFrame.new(0, plot.Size.Y / 2 + v.Size.X / 2, 0)
	v.Parent = plot
end

local function resetPlot(plot)
	plot:SetAttribute("PlantedSeed", "")
	plot:SetAttribute("PlantedAt", 0)
	plot:SetAttribute("Harvestable", false)
	clearVisual(plot)
end

local function onPlotInteract(player, plot)
	local seed = plot:GetAttribute("PlantedSeed") or ""
	local harvestable = plot:GetAttribute("Harvestable") == true

	if seed == "" then
		-- Case 1: empty plot -- offer seeds the player actually has
		local inv = _G.InventoryManager
		local available = {}
		for seedName in pairs(recipes) do
			local cnt = inv and inv.countItem(player, seedName) or 0
			if cnt > 0 then table.insert(available, seedName) end
		end
		if #available == 0 then notify(player, "Farming", "You have no seeds to plant."); return end
		RE_OpenSeedSelect:FireClient(player, { plotPart = plot, seeds = available })
	elseif not harvestable then
		-- Case 2: still growing
		local growth = tonumber(plot:GetAttribute("GrowthDuration")) or 600
		local plantedAt = tonumber(plot:GetAttribute("PlantedAt")) or tick()
		local remain = math.max(0, math.ceil((plantedAt + growth - tick()) / 60))
		notify(player, "Farming", "Not ready yet. Return in " .. remain .. " minute" .. (remain == 1 and "" or "s") .. ".")
	else
		-- Case 3: harvestable
		local recipe = recipes[seed]
		if recipe then
			local qty = Config.Util.rollRange(recipe.harvestOutput.count)
			local inv = _G.InventoryManager
			if inv then inv.addItem(player, recipe.harvestOutput.item, "Material", qty) end
			notify(player, "Farming", "You harvested " .. qty .. "x " .. recipe.harvestOutput.item .. "!")
			fireLiveFeed(getCharName(player), "harvested " .. qty .. "x " .. recipe.harvestOutput.item .. " from " .. plot.Name)
			local disc = _G.DiscordManager
			if disc then disc.logInteractable(player, plot.Name, "HARVEST " .. qty .. "x " .. recipe.harvestOutput.item) end
		end
		resetPlot(plot)
	end
end

RE_RequestPlantSeed.OnServerEvent:Connect(function(player, plot, seedName)
	if typeof(plot) ~= "Instance" or not plot.Parent then return end
	if (plot:GetAttribute("PlantedSeed") or "") ~= "" then return end
	local recipe = recipes[seedName]; if not recipe then return end
	local inv = _G.InventoryManager
	if not inv or not inv.removeItem(player, seedName, 1) then notify(player, "Farming", "You don't have that seed."); return end
	plot:SetAttribute("PlantedSeed", seedName)
	plot:SetAttribute("PlantedAt", tick())
	plot:SetAttribute("GrowthDuration", recipe.growthSeconds)
	plot:SetAttribute("Harvestable", false)
	setVisual(plot, "sprout")
	fireLiveFeed(getCharName(player), "planted " .. seedName .. " at " .. plot.Name)
	local disc = _G.DiscordManager
	if disc then disc.logInteractable(player, plot.Name, "PLANTED " .. seedName) end
end)

-- Growth check -- every CHECK_INTERVAL seconds, off player-presence (design doc: "Growth
-- continues even if player disconnects").
local accum = 0
RunService.Heartbeat:Connect(function(dt)
	accum += dt
	if accum < CHECK_INTERVAL then return end
	accum = 0
	for _, plot in ipairs(CollectionService:GetTagged(PLOT_TAG)) do
		local seed = plot:GetAttribute("PlantedSeed") or ""
		if seed ~= "" and plot:GetAttribute("Harvestable") ~= true then
			local growth = tonumber(plot:GetAttribute("GrowthDuration")) or 600
			local plantedAt = tonumber(plot:GetAttribute("PlantedAt")) or tick()
			if tick() - plantedAt >= growth then
				plot:SetAttribute("Harvestable", true)
				setVisual(plot, "grown")
			end
		end
	end
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
	prompt.ActionText = part:GetAttribute("InteractPrompt") or "Farm"
	prompt.MaxActivationDistance = tonumber(part:GetAttribute("InteractRange")) or 8
	prompt.Triggered:Connect(function(player) onPlotInteract(player, part) end)
end

for _, part in ipairs(CollectionService:GetTagged(PLOT_TAG)) do setupPrompt(part) end
CollectionService:GetInstanceAddedSignal(PLOT_TAG):Connect(setupPrompt)

local FarmingManager = {}
function FarmingManager.createPlot(position)
	local part = Instance.new("Part")
	part.Name = "FarmingPlot"
	part.Anchored = true; part.CanCollide = true
	part.Size = Vector3.new(4, 0.5, 4)
	part.Material = Enum.Material.Ground
	part.Color = Color3.fromRGB(70, 50, 35)
	part.CFrame = CFrame.new(position)
	part:SetAttribute("IsInteractable", true)
	part:SetAttribute("InteractType", "Farming")
	part:SetAttribute("InteractPrompt", "Farm")
	part:SetAttribute("PlantedSeed", "")
	part:SetAttribute("PlantedAt", 0)
	part:SetAttribute("GrowthDuration", 600)
	part:SetAttribute("Harvestable", false)
	CollectionService:AddTag(part, PLOT_TAG)
	return part
end

_G.FarmingManager = FarmingManager
print("[FarmingManager] Init")
