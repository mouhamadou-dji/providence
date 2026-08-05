-- TailoringManager -- design doc PART FOUR ("Squid Game cookie" path-trace QTE). Client
-- tracks cursor-vs-path deviation and determines the outcome locally (same trust model as
-- every other cooperative minigame in this codebase); server owns material consumption
-- (spec: ALL outcomes -- success/rip/timeout -- consume materials) and reward delivery.
local Players           = game:GetService("Players")
local RepStorage        = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local recipes = Config.TailoringRecipes
local shapes   = Config.TailoringShapes

local function getOrCreate(name, isFunc)
	local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
		local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
	end)()
	local r=folder:FindFirstChild(name); if r then return r end
	r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_ShowNotification    = getOrCreate("ShowNotification")
local RE_LiveFeedUpdate      = getOrCreate("LiveFeedUpdate")
local RE_TailoringOpenUI     = getOrCreate("TailoringOpenUI")
local RE_RequestStart        = getOrCreate("RequestStartTailoring")
local RE_TailoringStart      = getOrCreate("TailoringStart")
local RE_SubmitResult        = getOrCreate("TailoringSubmitResult")
local RE_TailoringResult     = getOrCreate("TailoringResult")

local STATION_TAG = "ABYSSTailoringStation"
local TIME_LIMIT = 30

local stationBusy   = {} -- [part] = userId
local activeAttempt = {} -- [userId] = {part=, recipe=, garmentName=, startedAt=}

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

local function onStationInteract(player, part)
	if stationBusy[part] then notify(player, "Tailoring", "This station is in use."); return end
	local available = {}
	for garmentName, recipe in pairs(recipes) do
		if hasMaterials(player, recipe.materials) then table.insert(available, garmentName) end
	end
	if #available == 0 then notify(player, "Tailoring", "You lack the materials for any garment."); return end
	RE_TailoringOpenUI:FireClient(player, { stationPart = part, recipes = available })
end

RE_RequestStart.OnServerEvent:Connect(function(player, part, garmentName)
	if typeof(part) ~= "Instance" or not part.Parent then return end
	if stationBusy[part] then notify(player, "Tailoring", "This station is in use."); return end
	local recipe = recipes[garmentName]; if not recipe then return end
	if not hasMaterials(player, recipe.materials) then notify(player, "Tailoring", "You lack the materials."); return end
	local shape = shapes[recipe.shape]; if not shape then return end

	-- Consumed up front: every outcome (success/rip/timeout) consumes materials per the design doc.
	consumeMaterials(player, recipe.materials)
	stationBusy[part] = player.UserId
	activeAttempt[player.UserId] = { part = part, recipe = recipe, garmentName = garmentName, startedAt = tick() }
	RE_TailoringStart:FireClient(player, { stationPart = part, shape = shape, timeLimit = TIME_LIMIT })
end)

RE_SubmitResult.OnServerEvent:Connect(function(player, part, outcome)
	local active = activeAttempt[player.UserId]
	if not active or active.part ~= part then return end
	activeAttempt[player.UserId] = nil
	stationBusy[part] = nil
	if tick() - active.startedAt > TIME_LIMIT + 2 then outcome = "Timeout" end
	if outcome ~= "Success" and outcome ~= "Rip" and outcome ~= "Timeout" then outcome = "Timeout" end

	local charName = getCharName(player)
	local disc = _G.DiscordManager
	RE_TailoringResult:FireClient(player, { outcome = outcome })
	if outcome == "Success" then
		local inv = _G.InventoryManager
		if inv then inv.addItem(player, active.recipe.output, "Material", 1) end
		notify(player, "Tailoring", "You finished a " .. active.garmentName .. "!")
		fireLiveFeed(charName, "tailored a " .. active.garmentName .. " at " .. part.Name)
		if disc then disc.logInteractable(player, part.Name, "TAILORING SUCCESS " .. active.garmentName) end
	else
		notify(player, "Tailoring", outcome == "Rip" and "The fabric ripped. Materials lost." or "You ran out of time. Materials lost.")
		fireLiveFeed(charName, "failed tailoring " .. active.garmentName .. " (" .. outcome .. ")")
		if disc then disc.logInteractable(player, part.Name, "TAILORING " .. outcome:upper() .. " " .. active.garmentName) end
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
	prompt.ActionText = part:GetAttribute("InteractPrompt") or "Sew"
	prompt.MaxActivationDistance = tonumber(part:GetAttribute("InteractRange")) or 8
	prompt.Triggered:Connect(function(player) onStationInteract(player, part) end)
end

for _, part in ipairs(CollectionService:GetTagged(STATION_TAG)) do setupPrompt(part) end
CollectionService:GetInstanceAddedSignal(STATION_TAG):Connect(setupPrompt)

local TailoringManager = {}
function TailoringManager.createStation(position, tier)
	local part = Instance.new("Part")
	part.Name = "TailoringStation"
	part.Anchored = true; part.CanCollide = true
	part.Size = Vector3.new(3, 3, 2)
	part.Material = Enum.Material.Wood
	part.Color = Color3.fromRGB(110, 80, 50)
	part.CFrame = CFrame.new(position)
	part:SetAttribute("IsInteractable", true)
	part:SetAttribute("InteractType", "Tailoring")
	part:SetAttribute("InteractPrompt", "Sew")
	part:SetAttribute("TailoringTier", (tier and tier ~= "") and tier or "Basic")
	CollectionService:AddTag(part, STATION_TAG)
	return part
end

_G.TailoringManager = TailoringManager
print("[TailoringManager] Init")
