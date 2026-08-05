-- InventoryManager: pushes a player's Inventory to their client (drives HotbarClient)
-- and handles hotbar-slot-based equip requests. Slot index == Inventory array index.
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")

local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))

local MAX_SLOTS = 10

-- EquippedSlot (the Inventory array index) is the source of truth for which hotbar slot
-- is highlighted -- NOT a name lookup against EquippedWeapon, since two inventory items
-- can share the same itemName (e.g. two "Iron Sword"s) and a name search would always
-- resolve to the first match regardless of which slot was actually equipped.
local function pushInventory(player)
	local dm = _G.DataManager
	if not dm or not dm.isLoaded(player) then return end
	local inv = dm.getValue(player, "Inventory") or {}
	local equippedSlot = dm.getValue(player, "EquippedSlot")
	if equippedSlot and not inv[equippedSlot] then equippedSlot = nil end
	Remotes.UpdateInventory:FireClient(player, inv, equippedSlot)
end

Remotes.RequestEquipSlot.OnServerEvent:Connect(function(player, slotIndex)
	if type(slotIndex) ~= "number" then return end
	slotIndex = math.floor(slotIndex)
	if slotIndex < 1 or slotIndex > MAX_SLOTS then return end
	local dm = _G.DataManager
	if not dm then return end
	local inv = dm.getValue(player, "Inventory") or {}
	local item = inv[slotIndex]
	if not item then return end

	-- Edibles (Bread/Apple/etc, see EdibleManager) get physically cloned into the character
	-- when equipped instead of just flipping the abstract EquippedWeapon string every other
	-- item uses -- always clear whatever was physically held before touching either path, so
	-- switching slots (or unequipping) never leaves a stale item stuck in the character's hand.
	local em = _G.EdibleManager
	if em then em.unequipHeld(player) end

	-- Clicking the already-equipped slot again unequips it instead of re-equipping it.
	if dm.getValue(player, "EquippedSlot") == slotIndex then
		dm.setValue(player, "EquippedWeapon", nil)
		dm.setValue(player, "EquippedSlot", nil)
	else
		local isEdible = em and em.tryEquip(player, item.itemName, slotIndex)
		dm.setValue(player, "EquippedWeapon", (not isEdible) and item.itemName or nil)
		dm.setValue(player, "EquippedSlot", slotIndex)
	end
	pushInventory(player)
end)

-- _GUIs (and therefore HotbarClient) rebuilds fresh on every character spawn, so re-push
-- on CharacterAdded too, not just on join.
local function waitAndPush(player)
	while player.Parent and not (_G.DataManager and _G.DataManager.isLoaded(player)) do
		task.wait(0.5)
	end
	if player.Parent then pushInventory(player) end
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(waitAndPush, player)
	player.CharacterAdded:Connect(function()
		task.wait(0.5)
		pushInventory(player)
	end)
end)
for _, p in ipairs(Players:GetPlayers()) do
	task.spawn(waitAndPush, p)
end

local InventoryManager = {}
InventoryManager.refresh = pushInventory

-- Generic add/count/remove, used by the crafting/gathering systems (Mining/Smelting/
-- Tailoring/Smithing/Farming) instead of each reimplementing raw Inventory-array mutation.
-- Items are free-form {itemName=, quality=} entries -- there's no central item registry in
-- this codebase (confirmed: ModManager.commands.giveItem accepts any string), so these do too.
function InventoryManager.addItem(player, itemName, quality, count)
	count = count or 1
	local dm = _G.DataManager; if not dm then return false end
	local inv = dm.getValue(player, "Inventory") or {}
	local added = 0
	for _ = 1, count do
		if #inv >= MAX_SLOTS then break end
		table.insert(inv, { itemName = itemName, quality = quality or "Material" })
		added += 1
	end
	dm.setValue(player, "Inventory", inv)
	pushInventory(player)
	return added
end

function InventoryManager.countItem(player, itemName)
	local dm = _G.DataManager; if not dm then return 0 end
	local inv = dm.getValue(player, "Inventory") or {}
	local n = 0
	for _, it in ipairs(inv) do if it.itemName == itemName then n += 1 end end
	return n
end

-- Atomic: only mutates if the player genuinely has `count` of itemName, otherwise returns
-- false with the inventory untouched (no partial-removal on insufficient stock).
function InventoryManager.removeItem(player, itemName, count)
	count = count or 1
	local dm = _G.DataManager; if not dm then return false end
	local inv = dm.getValue(player, "Inventory") or {}
	local indices = {}
	for i, it in ipairs(inv) do if it.itemName == itemName then table.insert(indices, i) end end
	if #indices < count then return false end
	for i = count, 1, -1 do table.remove(inv, indices[i]) end
	dm.setValue(player, "Inventory", inv)
	pushInventory(player)
	return true
end

_G.InventoryManager = InventoryManager
print("[InventoryManager] Initialized")
