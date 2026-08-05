-- SmeltingManager -- design doc PART THREE. Bespoke bouncing-bar QTE (not one of QTEManager's
-- named tiers -- geometry doesn't map cleanly onto any of them), client determines the
-- outcome locally same as GreenBar/CircleClose already do, server just sanity-checks timing.
-- Timed craft survives disconnect/server-restart via a small per-player PendingSmelts list in
-- DataManager (24h expiry, matching the design doc's own "ore is lost after 24 hours").
local Players           = game:GetService("Players")
local RepStorage        = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local recipes = Config.SmeltingRecipes

local function getOrCreate(name, isFunc)
	local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
		local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
	end)()
	local r=folder:FindFirstChild(name); if r then return r end
	r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_ShowNotification  = getOrCreate("ShowNotification")
local RE_LiveFeedUpdate    = getOrCreate("LiveFeedUpdate")
local RE_SmeltingOpenUI    = getOrCreate("SmeltingOpenUI")
local RE_RequestStartSmelt = getOrCreate("RequestStartSmelt")
local RE_SmeltingQTEStart  = getOrCreate("SmeltingQTEStart")
local RE_SmeltingQTESubmit = getOrCreate("SmeltingQTESubmit")
local RE_SmeltingQTEResult = getOrCreate("SmeltingQTEResult")
local RE_RequestCollect    = getOrCreate("RequestCollectSmelt")

local SMELTER_TAG = "ABYSSSmelter"
local PENDING_EXPIRY = 24 * 3600

-- whiteBarSpeed drives the moving WHITE bar the player is trying to stop; greenZoneSpeed
-- drives the greenZone drifting inside the red track (design doc: 300px/s and 100px/s
-- respectively at Basic tier).
local TIER_TUNING = {
	Basic    = { greenZoneWidth = 80, whiteBarSpeed = 300, greenZoneSpeed = 100 },
	Advanced = { greenZoneWidth = 60, whiteBarSpeed = 350, greenZoneSpeed = 130 },
	Master   = { greenZoneWidth = 45, whiteBarSpeed = 400, greenZoneSpeed = 160 },
}

local smelterBusy   = {} -- [part] = userId currently smelting there
local activeAttempt = {} -- [userId] = {part=, recipe=, oreName=, startedAt=}

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

-- Drops PendingSmelts entries older than 24h (design doc: "ore is lost after 24 hours") --
-- checked once per player on load, matching the DataStore-cleanup framing in the spec.
local function cleanupPending(player)
	task.delay(2, function()
		local dm = _G.DataManager; if not dm or not dm.isLoaded(player) then return end
		local pending = dm.getValue(player, "PendingSmelts") or {}
		local changed = false
		for i = #pending, 1, -1 do
			if (os.time() - (pending[i].startedAt or 0)) > PENDING_EXPIRY then
				table.remove(pending, i); changed = true
			end
		end
		if changed then dm.setValue(player, "PendingSmelts", pending) end
	end)
end
Players.PlayerAdded:Connect(cleanupPending)
for _, p in ipairs(Players:GetPlayers()) do cleanupPending(p) end

local function onSmelterInteract(player, part)
	local dm = _G.DataManager
	local pending = dm and dm.getValue(player, "PendingSmelts") or {}
	for i, entry in ipairs(pending) do
		if entry.smelterName == part.Name then
			if entry.readyAt <= os.time() then
				local inv = _G.InventoryManager
				if inv then inv.addItem(player, entry.itemName, "Material", entry.count) end
				table.remove(pending, i)
				dm.setValue(player, "PendingSmelts", pending)
				notify(player, "Smelting", "Your " .. entry.count .. "x " .. entry.itemName .. " is ready!")
				fireLiveFeed(getCharName(player), "collected " .. entry.count .. "x " .. entry.itemName .. " from " .. part.Name)
				local disc = _G.DiscordManager
				if disc then disc.logInteractable(player, part.Name, "SMELT COLLECTED " .. entry.count .. "x " .. entry.itemName) end
			else
				notify(player, "Smelting", "Still smelting... " .. (entry.readyAt - os.time()) .. "s remaining.")
			end
			return
		end
	end

	if smelterBusy[part] then notify(player, "Smelting", "This smelter is in use."); return end

	local available = {}
	local inv = _G.InventoryManager
	for oreName in pairs(recipes) do
		local cnt = inv and inv.countItem(player, oreName) or 0
		if cnt > 0 then table.insert(available, { itemName = oreName, count = cnt }) end
	end
	if #available == 0 then notify(player, "Smelting", "You have no ore to smelt."); return end
	RE_SmeltingOpenUI:FireClient(player, { smelterPart = part, ores = available })
end

RE_RequestStartSmelt.OnServerEvent:Connect(function(player, part, oreName)
	if typeof(part) ~= "Instance" or not part.Parent then return end
	if smelterBusy[part] then notify(player, "Smelting", "This smelter is in use."); return end
	local recipe = recipes[oreName]; if not recipe then return end
	local inv = _G.InventoryManager
	if not inv or not inv.removeItem(player, oreName, 1) then notify(player, "Smelting", "You don't have that ore."); return end

	smelterBusy[part] = player.UserId
	local tuning = TIER_TUNING[part:GetAttribute("SmelterTier")] or TIER_TUNING.Basic
	activeAttempt[player.UserId] = { part = part, recipe = recipe, oreName = oreName, startedAt = tick() }
	RE_SmeltingQTEStart:FireClient(player, {
		smelterPart = part, greenZoneWidth = tuning.greenZoneWidth,
		whiteBarSpeed = tuning.whiteBarSpeed, greenZoneSpeed = tuning.greenZoneSpeed,
	})
end)

RE_SmeltingQTESubmit.OnServerEvent:Connect(function(player, part, outcome)
	local active = activeAttempt[player.UserId]
	if not active or active.part ~= part then return end
	activeAttempt[player.UserId] = nil
	-- Sanity ceiling matching the 10s window + a little slack for latency -- mirrors
	-- QTEManager's own deadline-enforcement convention rather than trusting the client fully.
	if tick() - active.startedAt > 12 then outcome = "Fail" end
	if outcome ~= "Success" and outcome ~= "Partial" and outcome ~= "Fail" then outcome = "Fail" end

	local recipe = active.recipe
	local count = (outcome == "Success") and recipe.count or (outcome == "Partial" and math.ceil(recipe.count / 2) or 0)
	RE_SmeltingQTEResult:FireClient(player, { outcome = outcome })
	local charName = getCharName(player)
	local disc = _G.DiscordManager

	if count <= 0 then
		smelterBusy[part] = nil
		notify(player, "Smelting", "The smelting failed. The ore is lost.")
		fireLiveFeed(charName, "failed to smelt " .. active.oreName .. " at " .. part.Name)
		if disc then disc.logInteractable(player, part.Name, "SMELT FAIL " .. active.oreName) end
		return
	end

	local dm = _G.DataManager
	local pending = dm and dm.getValue(player, "PendingSmelts") or {}
	table.insert(pending, {
		smelterName = part.Name, itemName = recipe.output, count = count,
		readyAt = os.time() + recipe.timeSeconds, startedAt = os.time(),
	})
	if dm then dm.setValue(player, "PendingSmelts", pending) end
	fireLiveFeed(charName, "began smelting " .. active.oreName .. " (" .. outcome .. ") at " .. part.Name)
	if disc then disc.logInteractable(player, part.Name, "SMELT " .. outcome:upper() .. " -> " .. count .. "x " .. recipe.output) end
	task.delay(recipe.timeSeconds, function()
		smelterBusy[part] = nil -- the smelter itself frees up once the timer completes, even if not yet collected
		if player.Parent then notify(player, "Smelting", "Your " .. count .. "x " .. recipe.output .. " is ready! Return to the smelter to collect it.") end
	end)
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
	prompt.ActionText = part:GetAttribute("InteractPrompt") or "Smelt"
	prompt.MaxActivationDistance = tonumber(part:GetAttribute("InteractRange")) or 8
	prompt.Triggered:Connect(function(player) onSmelterInteract(player, part) end)
end

for _, part in ipairs(CollectionService:GetTagged(SMELTER_TAG)) do setupPrompt(part) end
CollectionService:GetInstanceAddedSignal(SMELTER_TAG):Connect(setupPrompt)

local SmeltingManager = {}
function SmeltingManager.createSmelter(position, tier)
	local part = Instance.new("Part")
	part.Name = "Smelter"
	part.Anchored = true; part.CanCollide = true
	part.Size = Vector3.new(4, 4, 4)
	part.Material = Enum.Material.Concrete
	part.Color = Color3.fromRGB(60, 55, 50)
	part.CFrame = CFrame.new(position)
	part:SetAttribute("IsInteractable", true)
	part:SetAttribute("InteractType", "Smelting")
	part:SetAttribute("InteractPrompt", "Smelt")
	part:SetAttribute("SmelterTier", (tier and tier ~= "") and tier or "Basic")
	local fire = Instance.new("Fire"); fire.Size = 8; fire.Heat = 10; fire.Parent = part
	CollectionService:AddTag(part, SMELTER_TAG)
	return part
end

_G.SmeltingManager = SmeltingManager
print("[SmeltingManager] Init")
