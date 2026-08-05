-- TradeManager -- design doc PART THREE. Backspace-drop of the currently equipped hotbar
-- item as a physical world pickup, plus currency dropping (loose coins, or a single Coin_Pouch
-- item if the player owns one). Currency lives on DataManager's Currency={Obol,Drachma,Stater,
-- RoyalStater} fields, NOT as Inventory array entries -- unlike the design doc's assumption
-- that currency is hotbar-selectable like any other item, so dropping currency is its own
-- chat command (/dropcoins) rather than reusing the item-backspace path.
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local dropCfg = Config.ItemDrop
local pouchCfg = Config.CoinPouch

local function getOrCreate(name, isFunc)
	local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
		local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
	end)()
	local r=folder:FindFirstChild(name); if r then return r end
	r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_RequestDrop = getOrCreate("RequestDropItem") -- client -> server, no args (drops the equipped hotbar slot)
local RE_ShowNotification = getOrCreate("ShowNotification")
local RE_LiveFeedUpdate   = getOrCreate("LiveFeedUpdate")

local CURRENCY_TYPES = { Obol = true, Drachma = true, Stater = true, RoyalStater = true }
local MAX_SCATTERED_COINS = 20 -- visual cap -- large drops split into fewer, bigger piles rather than spamming hundreds of parts

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
			RE_LiveFeedUpdate:FireClient(p, { type = "TRADE", h = now.hour, m = now.min, zone = "?", charName = charName, message = message })
		end
	end
end

local function notify(player, title, body)
	RE_ShowNotification:FireClient(player, { title = title, body = body, duration = 4, style = "info" })
end

local TradeManager = {}

-- PLACEHOLDER_ASSET: ItemDropModel -- generic bag/crate stand-in until real per-item drop
-- models exist. Every dropped-item pickup (regular item, loose coin, or coin pouch) shares
-- this same look, distinguished only by the label the ProximityPrompt shows.
local function makeDropPart(name, position)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.new(1.2, 1, 1.2)
	part.Material = Enum.Material.Wood
	part.Color = Color3.fromRGB(140, 110, 70)
	part.Anchored = true
	part.CanCollide = false
	part.CFrame = CFrame.new(position)
	part.Parent = workspace
	return part
end

local function addPickupPrompt(part, actionText, onTake)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = actionText
	prompt.HoldDuration = 0
	prompt.RequiresLineOfSight = false
	prompt.MaxActivationDistance = 8
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.Parent = part
	prompt.Triggered:Connect(function(player)
		if not part.Parent then return end
		onTake(player)
		if part.Parent then part:Destroy() end
	end)
	task.delay(dropCfg.DespawnAfter, function()
		if part.Parent then part:Destroy() end
	end)
end

function TradeManager.dropItem(player)
	local dm = _G.DataManager; if not dm then return false, "DataManager not ready" end
	local slot = dm.getValue(player, "EquippedSlot")
	if not slot then return false, "No item selected." end
	local inv = dm.getValue(player, "Inventory") or {}
	local item = inv[slot]
	if not item then return false, "No item selected." end
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return false, "No character." end

	table.remove(inv, slot)
	dm.setValue(player, "Inventory", inv)
	dm.setValue(player, "EquippedWeapon", nil)
	dm.setValue(player, "EquippedSlot", nil)
	local em = _G.EdibleManager; if em then em.unequipHeld(player) end
	local im = _G.InventoryManager; if im then im.refresh(player) end

	local dropPos = hrp.Position + hrp.CFrame.LookVector * 2 - Vector3.new(0, 2, 0)
	local part = makeDropPart("Dropped_" .. item.itemName, dropPos)
	part:SetAttribute("IsDroppedItem", true)
	part:SetAttribute("ItemName", item.itemName)
	part:SetAttribute("Quality", item.quality or "Material")
	part:SetAttribute("ItemCount", 1)
	part:SetAttribute("DroppedByUserId", player.UserId)
	part:SetAttribute("DroppedAt", tick())
	addPickupPrompt(part, "Take " .. item.itemName, function(taker)
		local im2 = _G.InventoryManager
		if im2 then im2.addItem(taker, item.itemName, item.quality, 1) end
		fireLiveFeed(getCharName(taker), "picked up " .. item.itemName)
	end)

	fireLiveFeed(getCharName(player), "dropped " .. item.itemName)
	return true
end

RE_RequestDrop.OnServerEvent:Connect(function(player)
	TradeManager.dropItem(player)
end)

-- Currency drop -- see header comment for why this is a chat command rather than reusing
-- the item-backspace path.
function TradeManager.dropCoins(player, currencyType, amount)
	if not CURRENCY_TYPES[currencyType] then return false, "currency must be Obol, Drachma, Stater, or RoyalStater" end
	amount = math.floor(tonumber(amount) or 0)
	if amount <= 0 then return false, "amount must be a positive whole number" end
	local dm = _G.DataManager; if not dm then return false, "DataManager not ready" end
	local cur = dm.getValue(player, "Currency") or {}
	local have = cur[currencyType] or 0
	if amount > have then return false, "you don't have that much " .. currencyType end
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return false, "No character." end

	local im = _G.InventoryManager
	local hasPouch = im and im.countItem(player, pouchCfg.Item) > 0

	cur[currencyType] = have - amount
	dm.setValue(player, "Currency", cur)

	if hasPouch then
		im.removeItem(player, pouchCfg.Item, 1)
		local part = makeDropPart("CoinPouch", hrp.Position + hrp.CFrame.LookVector * 2 - Vector3.new(0, 2, 0))
		part.Color = Color3.fromRGB(150, 120, 60)
		part:SetAttribute("IsDroppedItem", true)
		part:SetAttribute("IsCoinPouch", true)
		part:SetAttribute("CoinType", currencyType)
		part:SetAttribute("CoinsInside", amount)
		part:SetAttribute("DroppedByUserId", player.UserId)
		addPickupPrompt(part, "Take Pouch (" .. amount .. " " .. currencyType .. ")", function(taker)
			local dm2 = _G.DataManager
			local cur2 = dm2.getValue(taker, "Currency") or {}
			cur2[currencyType] = (cur2[currencyType] or 0) + amount
			dm2.setValue(taker, "Currency", cur2)
			fireLiveFeed(getCharName(taker), "picked up a pouch of " .. amount .. " " .. currencyType)
		end)
		fireLiveFeed(getCharName(player), "dropped a pouch of " .. amount .. " " .. currencyType)
	else
		-- No pouch: scatter individual coin piles, each pickable for its own share -- capped at
		-- MAX_SCATTERED_COINS piles so a huge drop doesn't spam hundreds of parts (the full
		-- amount is still fully recoverable, just split across fewer/bigger piles).
		local pileCount = math.min(amount, MAX_SCATTERED_COINS)
		local base = amount // pileCount
		local remainder = amount % pileCount
		for i = 1, pileCount do
			local pileAmount = base + (i <= remainder and 1 or 0)
			if pileAmount > 0 then
				local angle = (i / pileCount) * math.pi * 2
				local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * 3
				local part = makeDropPart("Coin_" .. currencyType, hrp.Position + offset - Vector3.new(0, 2, 0))
				part.Size = Vector3.new(0.6, 0.2, 0.6)
				part.Shape = Enum.PartType.Cylinder
				part.Color = Color3.fromRGB(200, 170, 60)
				part:SetAttribute("IsDroppedItem", true)
				part:SetAttribute("CoinType", currencyType)
				part:SetAttribute("CoinsInside", pileAmount)
				part:SetAttribute("DroppedByUserId", player.UserId)
				addPickupPrompt(part, "Take " .. pileAmount .. " " .. currencyType, function(taker)
					local dm2 = _G.DataManager
					local cur2 = dm2.getValue(taker, "Currency") or {}
					cur2[currencyType] = (cur2[currencyType] or 0) + pileAmount
					dm2.setValue(taker, "Currency", cur2)
					fireLiveFeed(getCharName(taker), "picked up " .. pileAmount .. " " .. currencyType)
				end)
			end
		end
		fireLiveFeed(getCharName(player), "scattered " .. amount .. " " .. currencyType)
	end
	return true
end

_G.TradeManager = TradeManager
print("[TradeManager] Init")
