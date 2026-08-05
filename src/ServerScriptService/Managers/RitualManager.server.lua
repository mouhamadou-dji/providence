-- RitualManager -- player-driven ritual circles: draw a circle (Ritual Stone item), place
-- items in it, submit for lore team judgement. Every ritual's actual effect is invented by
-- the lore team at approval time (free-text), not scripted per-ritual. Session-only, like
-- BToolsManager's placements -- circles live in workspace.RitualCircles, never touch DataStore.

local Players     = game:GetService("Players")
local RepStorage  = game:GetService("ReplicatedStorage")
local RunService  = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")

local Config  = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))
local ritualCfg = Config.Ritual

local function getOrCreate(name, isFunc)
	local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
		local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
	end)()
	local r=folder:FindFirstChild(name); if r then return r end
	r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_PlaceCircle = getOrCreate("RequestPlaceRitualCircle")
local RE_PlaceItem   = getOrCreate("RequestPlaceRitualItem")
local RE_RemoveItem  = getOrCreate("RequestRemoveRitualItem")
local RE_Submit      = getOrCreate("RequestSubmitRitual")
local RE_ShowNotif   = getOrCreate("ShowNotification")
local RE_LiveFeed    = getOrCreate("LiveFeedUpdate")

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
			RE_LiveFeed:FireClient(p, { type = "ACTION", h = now.hour, m = now.min, zone = "?", charName = charName, message = message })
		end
	end
end

local function notifyMods(title, body, duration, style)
	local mgr = _G.ModManager
	for _, p in ipairs(Players:GetPlayers()) do
		if mgr and mgr.isMod(p) then
			RE_ShowNotif:FireClient(p, { title = title, body = body, duration = duration or 8, style = style or "info" })
		end
	end
end

local function notify(player, title, body, duration, style)
	RE_ShowNotif:FireClient(player, { title = title, body = body, duration = duration or 5, style = style or "info" })
end

local FOLDER_NAME = "RitualCircles"
local function getFolder()
	local f = workspace:FindFirstChild(FOLDER_NAME)
	if not f then f = Instance.new("Folder"); f.Name = FOLDER_NAME; f.Parent = workspace end
	return f
end

local circles = {}      -- [part] = state
local circlesByName = {} -- [name] = part

local function syncItemsAttribute(part, state)
	local list = {}
	for _, it in ipairs(state.items) do table.insert(list, it.itemName) end
	local ok, encoded = pcall(function() return HttpService:JSONEncode(list) end)
	if ok then part:SetAttribute("ContainedItemsJSON", encoded) end
end

-- Floating item labels above the circle -- PLACEHOLDER_ANIMATION: item_place_ritual (no
-- real per-item mesh/animation exists yet, so each placed item is a simple floating
-- name-tag rather than a physical model).
local function rebuildItemDisplay(part, state)
	local disp = part:FindFirstChild("ItemDisplay")
	if disp then disp:Destroy() end
	if #state.items == 0 then return end
	local bb = Instance.new("BillboardGui")
	bb.Name = "ItemDisplay"
	bb.Size = UDim2.new(0, 200, 0, 18 * #state.items)
	bb.StudsOffset = Vector3.new(0, 4, 0)
	bb.AlwaysOnTop = true
	bb.Parent = part
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = bb
	for i, it in ipairs(state.items) do
		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.new(1, 0, 0, 18)
		lbl.BackgroundTransparency = 1
		lbl.Font = Enum.Font.GothamBold
		lbl.TextSize = 14
		lbl.TextColor3 = Color3.fromRGB(198, 156, 55)
		lbl.TextStrokeTransparency = 0.3
		lbl.Text = it.itemName
		lbl.LayoutOrder = i
		lbl.Parent = bb
	end
end

local RitualManager = {}

function RitualManager.getByName(name)
	return circlesByName[name]
end

function RitualManager.getState(part)
	return circles[part]
end

local despawnCircle -- forward decl

local function createCircle(player)
	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then return nil end
	local part = Instance.new("Part")
	local uniqueName = "Ritual_" .. player.Name .. "_" .. tostring(os.time())
	part.Name = uniqueName
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(0.2, ritualCfg.CircleRadius * 2, ritualCfg.CircleRadius * 2)
	part.Orientation = Vector3.new(0, 0, 90)
	part.Anchored = true; part.CanCollide = false; part.CanQuery = true
	part.Transparency = 0.5
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(150, 40, 200)
	part.CFrame = CFrame.new(hrp.Position - Vector3.new(0, 3, 0))
	-- PLACEHOLDER_ASSET: RitualCircleDecal (a real authored texture on the flat cylinder
	-- face would go here; the Neon-purple disc is the placeholder look for now)
	part:SetAttribute("IsRitualCircle", true)
	part:SetAttribute("OwnerUserId", player.UserId)
	part:SetAttribute("PlacedAt", os.time())
	part:SetAttribute("ContainedItemsJSON", "[]")
	part:SetAttribute("State", "Drawn")
	part.Parent = getFolder()

	local state = { owner = player, items = {}, state = "Drawn", rotAngle = 0 }
	circles[part] = state
	circlesByName[uniqueName] = part

	part.Destroying:Connect(function()
		circles[part] = nil
		circlesByName[uniqueName] = nil
	end)

	task.delay(ritualCfg.AutoDespawnMinutes * 60, function()
		local cur = circles[part]
		if cur and cur.state ~= "Submitted" then despawnCircle(part, false) end
	end)

	return part
end

despawnCircle = function(part, wasResolved)
	local state = circles[part]; if not state then return end
	if not wasResolved then
		local charName = getCharName(state.owner)
		fireLiveFeed(charName, "ritual circle despawned unresolved (items lost)")
	end
	part:Destroy()
end

RE_PlaceCircle.OnServerEvent:Connect(function(player)
	local dm = _G.DataManager
	if not dm or dm.getValue(player, "EquippedWeapon") ~= "Ritual Stone" then return end
	local part = createCircle(player)
	if not part then return end
	local charName = getCharName(player)
	fireLiveFeed(charName, "drew a ritual circle (" .. part.Name .. ")")
	local disc = _G.DiscordManager
	if disc and disc.logRitual then disc.logRitual(charName, "Circle drawn: " .. part.Name) end
	print("[RitualManager] " .. player.Name .. " placed circle " .. part.Name)
end)

RE_PlaceItem.OnServerEvent:Connect(function(player, circlePart, slotIndex)
	if typeof(circlePart) ~= "Instance" or not circlePart:GetAttribute("IsRitualCircle") then return end
	local state = circles[circlePart]; if not state then return end
	if state.state == "Submitted" then return end -- no changes once submitted
	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	if (hrp.Position - circlePart.Position).Magnitude > ritualCfg.PlaceItemRange then return end
	if type(slotIndex) ~= "number" then return end
	local dm = _G.DataManager; if not dm then return end
	local inv = dm.getValue(player, "Inventory") or {}
	local item = inv[slotIndex]; if not item then return end
	table.remove(inv, slotIndex)
	dm.setValue(player, "Inventory", inv)
	local im = _G.InventoryManager; if im then im.refresh(player) end

	table.insert(state.items, { itemName = item.itemName, fromPlayer = player.Name })
	state.state = "ItemsPlaced"
	circlePart:SetAttribute("State", "ItemsPlaced")
	syncItemsAttribute(circlePart, state)
	rebuildItemDisplay(circlePart, state)

	local charName = getCharName(player)
	fireLiveFeed(charName, "placed " .. item.itemName .. " in ritual circle " .. circlePart.Name)
end)

RE_RemoveItem.OnServerEvent:Connect(function(player, circlePart, itemIndex)
	if typeof(circlePart) ~= "Instance" or not circlePart:GetAttribute("IsRitualCircle") then return end
	local state = circles[circlePart]; if not state then return end
	if state.state == "Submitted" then return end
	if state.owner ~= player then return end -- only the owner can remove items pre-submission
	if type(itemIndex) ~= "number" or not state.items[itemIndex] then return end
	local it = table.remove(state.items, itemIndex)
	local dm = _G.DataManager
	if dm then
		local inv = dm.getValue(player, "Inventory") or {}
		table.insert(inv, { itemName = it.itemName, quality = "Iron" })
		dm.setValue(player, "Inventory", inv)
		local im = _G.InventoryManager; if im then im.refresh(player) end
	end
	if #state.items == 0 then state.state = "Drawn"; circlePart:SetAttribute("State", "Drawn") end
	syncItemsAttribute(circlePart, state)
	rebuildItemDisplay(circlePart, state)
end)

-- Shared by both the RequestSubmitRitual remote AND ChatManager's /submitritual command --
-- one real implementation, two entry points.
local function submitCircle(player, circlePart)
	local state = circles[circlePart]; if not state then return false, "No active ritual circle." end
	if state.owner ~= player then return false, "You don't own that ritual circle." end
	if state.state == "Submitted" then return false, "Already submitted -- awaiting the lore team." end
	if #state.items == 0 then return false, "Place at least one item before submitting." end

	state.state = "Submitted"
	circlePart:SetAttribute("State", "Submitted")

	local charName = getCharName(player)
	local itemNames = {}
	for _, it in ipairs(state.items) do table.insert(itemNames, it.itemName) end
	local pos = circlePart.Position
	notifyMods("RITUAL SUBMITTED",
		string.format("Player: %s\nCircle: %s\nLocation: (%.0f, %.0f, %.0f)\nItems: %s\nUse the RITUAL MANAGEMENT panel to decide.",
			charName, circlePart.Name, pos.X, pos.Y, pos.Z, table.concat(itemNames, ", ")),
		15, "lore")
	fireLiveFeed(charName, "submitted ritual " .. circlePart.Name .. " (" .. table.concat(itemNames, ", ") .. ")")
	local disc = _G.DiscordManager
	if disc and disc.logRitual then disc.logRitual(charName, "Submitted " .. circlePart.Name .. ": " .. table.concat(itemNames, ", ")) end
	print("[RitualManager] " .. player.Name .. " submitted ritual " .. circlePart.Name)
	return true
end

RE_Submit.OnServerEvent:Connect(function(player, circlePart)
	if typeof(circlePart) ~= "Instance" or not circlePart:GetAttribute("IsRitualCircle") then return end
	submitCircle(player, circlePart)
end)

-- Finds the nearest circle OWNED by player within a reasonable radius and submits it --
-- backs ChatManager's /submitritual (chat command per the design doc's three suggested
-- submit UIs; emote-wheel/proximity-prompt were the other two options, not built).
function RitualManager.trySubmitNearest(player)
	local hrp = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not hrp then return false, "No character." end
	local best, bestDist = nil, 15
	for part, state in pairs(circles) do
		if state.owner == player and part.Parent then
			local d = (part.Position - hrp.Position).Magnitude
			if d < bestDist then best = part; bestDist = d end
		end
	end
	if not best then return false, "No ritual circle of yours nearby." end
	return submitCircle(player, best)
end

-- ── Lore team decision (called from ModManager commands) ───────────────────────
-- PLACEHOLDER_ASSET: RitualCompleteEffect (a real authored VFX would replace this simple
-- particle burst)
local function spawnCompleteBurst(position)
	local attachPart = Instance.new("Part")
	attachPart.Anchored = true; attachPart.CanCollide = false; attachPart.Transparency = 1
	attachPart.Size = Vector3.new(0.2,0.2,0.2)
	attachPart.CFrame = CFrame.new(position)
	attachPart.Parent = workspace
	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(Color3.fromRGB(230, 200, 120))
	emitter.Size = NumberSequence.new(1.2)
	emitter.Lifetime = NumberRange.new(0.6, 1.2)
	emitter.Speed = NumberRange.new(8, 16)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rate = 0
	emitter.Parent = attachPart
	emitter:Emit(60)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(230,200,120); light.Range = 20; light.Brightness = 4
	light.Parent = attachPart
	game:GetService("Debris"):AddItem(attachPart, 2)
end

function RitualManager.approve(circlePart, effectText)
	local state = circles[circlePart]; if not state then return false end
	local owner = state.owner
	spawnCompleteBurst(circlePart.Position)
	notify(owner, "Ritual Approved", effectText or "The ritual takes hold.", 10, "lore")
	local charName = getCharName(owner)
	fireLiveFeed(charName, "ritual " .. circlePart.Name .. " APPROVED: " .. tostring(effectText))
	local disc = _G.DiscordManager
	if disc and disc.logRitual then disc.logRitual(charName, "APPROVED " .. circlePart.Name .. ": " .. tostring(effectText)) end
	task.delay(3, function() despawnCircle(circlePart, true) end)
	return true
end

function RitualManager.reject(circlePart)
	local state = circles[circlePart]; if not state then return false end
	local owner = state.owner
	TweenService:Create(circlePart, TweenInfo.new(1.5), { Transparency = 1, Color = Color3.fromRGB(20,20,20) }):Play()
	notify(owner, "Ritual Failed", "The ritual failed. Something was wrong.", 6, "warning")
	local sanM = _G.SanityManager
	if sanM then sanM.notifyRitualFailure(circlePart.Position) end
	-- Small negative effect per the design doc (drain hunger a bit)
	local dm = _G.DataManager
	if dm then dm.setValue(owner, "Hunger", math.max(0, (dm.getValue(owner, "Hunger") or 100) - 10)) end
	local charName = getCharName(owner)
	fireLiveFeed(charName, "ritual " .. circlePart.Name .. " REJECTED")
	local disc = _G.DiscordManager
	if disc and disc.logRitual then disc.logRitual(charName, "REJECTED " .. circlePart.Name) end
	task.delay(1.6, function() despawnCircle(circlePart, true) end)
	return true
end

function RitualManager.ignore(circlePart)
	-- Notification dismissed, circle remains active, resubmittable -- nothing to actually
	-- change server-side beyond logging, since "Submitted" already just sits until a real decision.
	local state = circles[circlePart]; if not state then return false end
	state.state = "ItemsPlaced" -- allow re-submission
	circlePart:SetAttribute("State", "ItemsPlaced")
	return true
end

-- ── Slow rotation + owner-disconnect grace ──────────────────────────────────────
RunService.Heartbeat:Connect(function(dt)
	for part, state in pairs(circles) do
		if part.Parent then
			state.rotAngle = (state.rotAngle + math.rad(6 * dt)) % (2 * math.pi)
			-- fromOrientation (not CFrame.Angles) matches the Orientation property's own
			-- rotation order -- CFrame.Angles would tip the disc up onto its edge instead
			-- of keeping it flat once this overwrites the CFrame every frame.
			part.CFrame = CFrame.new(part.Position) * CFrame.fromOrientation(0, state.rotAngle, math.rad(90))
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	for part, state in pairs(circles) do
		if state.owner == player and state.state ~= "Submitted" then
			task.delay(ritualCfg.OwnerDisconnectGraceMinutes * 60, function()
				if circles[part] then despawnCircle(part, false) end
			end)
		end
	end
end)

_G.RitualManager = RitualManager
print("[RitualManager] Init — circle radius=" .. ritualCfg.CircleRadius .. " | auto-despawn=" .. ritualCfg.AutoDespawnMinutes .. "min")
