-- EdibleManager
-- Food/drink Tools (ConsumeType="Food"/"Water" + ConsumeAmount attributes) that restore
-- Hunger/Water via DataManager when clicked (Activated) and then destroy themselves.
-- Templates live in ServerStorage.EdibleTemplates (not placed in the world -- granted via
-- the mod panel's "Give Food/Drink" command). Granting adds a normal entry to DataManager's
-- Inventory array (same shape InventoryManager/HotbarClient already use for every other
-- item), so edibles show up on the hotbar and equip/unequip through the same number-key/
-- click flow as everything else. Equipping a hotbar slot that resolves to an edible template
-- (InventoryManager.RequestEquipSlot calls EdibleManager.tryEquip/unequipHeld) clones the
-- real Tool into the player's Character so it's actually held, not just a data record.

local Players      = game:GetService("Players")
local RepStorage   = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Config    = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local templates = ServerStorage:WaitForChild("EdibleTemplates")

local function getOrCreate(name, isFunc)
	local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
		local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
	end)()
	local r=folder:FindFirstChild(name); if r then return r end
	r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end
local RE_ShowNotification  = getOrCreate("ShowNotification")
local RE_ApplyIntoxication = getOrCreate("ApplyIntoxication") -- server -> client: {type="Wine"|"Ale", duration}

local MAX_BY_TYPE = {
	Food  = Config.Hunger.Max,
	Water = Config.Water.Max,
}

local DEFAULT_USE_TIME = 2.0 -- seconds to hold the eat/drink pose if a template has no ConsumeUseTime attribute

local function notify(player, title, body)
	RE_ShowNotification:FireClient(player, { title = title, body = body, duration = 4, style = "info" })
end

-- Runs once useTime has elapsed with no interruption -- applies the resource restore, strips
-- the Inventory entry, fires intoxication if applicable, and destroys the held Tool.
local function finishConsume(tool, player)
	if not tool or not tool.Parent then return end
	tool:SetAttribute("Consumed", true)

	local resourceType = tool:GetAttribute("ConsumeType")
	local amount = tool:GetAttribute("ConsumeAmount") or 0
	local dm = _G.DataManager
	if dm and resourceType then
		local max = MAX_BY_TYPE[resourceType] or 100
		local current = dm.getValue(player, resourceType) or max
		dm.setValue(player, resourceType, math.min(max, current + amount))
	end

	-- Consumed for good -- strip the matching Inventory entry so it disappears from the
	-- hotbar too, not just the held Tool. SourceSlot is only ever set on the one physically-
	-- held clone at a time (see tryEquip), and Activated can only fire while held/equipped,
	-- so EquippedSlot is guaranteed to equal this tool's own SourceSlot right now.
	local slotIndex = tool:GetAttribute("SourceSlot")
	if dm and slotIndex then
		local inv = dm.getValue(player, "Inventory") or {}
		if inv[slotIndex] then
			table.remove(inv, slotIndex)
			dm.setValue(player, "Inventory", inv)
			if dm.getValue(player, "EquippedSlot") == slotIndex then
				dm.setValue(player, "EquippedWeapon", nil)
				dm.setValue(player, "EquippedSlot", nil)
			end
			local im = _G.InventoryManager
			if im then im.refresh(player) end
		end
	end

	-- Wine/Ale side effect (design doc PART FOUR) -- IntoxicationClient reads this and applies
	-- the cosmetic sway; StaminaManager reads the same IntoxicatedUntil attribute for the
	-- regen debuff. Purely additive attribute reads on both sides, nothing else touched.
	local intoxType = tool:GetAttribute("IntoxicationType")
	if intoxType then
		local duration = Config.Intoxication["Duration_" .. intoxType] or 30
		player:SetAttribute("IntoxicatedUntil", tick() + duration)
		RE_ApplyIntoxication:FireClient(player, { type = intoxType, duration = duration })
	end

	tool:Destroy()
end

local function consume(tool)
	if tool:GetAttribute("Consumed") or tool:GetAttribute("InProgress") then return end
	local char = tool.Parent
	if not char then return end
	local player = Players:GetPlayerFromCharacter(char)
	if not player then return end

	local sm = _G.StaminaManager
	if sm and sm.isInCombat and sm.isInCombat(player) then
		notify(player, "Can't Eat or Drink", "You cannot consume items while in combat.")
		return
	end

	tool:SetAttribute("InProgress", true)

	local hum = char:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	local animObj = tool:FindFirstChild("ConsumeAnim")
	local track
	if animator and animObj then
		local ok, t = pcall(function() return animator:LoadAnimation(animObj) end)
		if ok and t then
			t.Priority = Enum.AnimationPriority.Action
			t:Play()
			track = t
		end
	end

	-- PLACEHOLDER_SOUND: per-item ConsumeSound child, same "empty SoundId means skip silently"
	-- convention as every other placeholder sound in this codebase. Cleans up on Ended, not a
	-- fixed Debris timer -- a fresh Sound's asset can still be streaming in when Play() is
	-- called, and a flat timer risks destroying it before it ever plays (a real bug hit and
	-- fixed elsewhere in this project, see [[project_abyss]]).
	local sndTemplate = tool:FindFirstChild("ConsumeSound")
	local primary = char.PrimaryPart or char:FindFirstChild("HumanoidRootPart")
	if sndTemplate and sndTemplate.SoundId ~= "" and sndTemplate.SoundId ~= "rbxassetid://0" and primary then
		local snd = sndTemplate:Clone()
		snd.Parent = primary
		snd:Play()
		snd.Ended:Once(function() if snd then snd:Destroy() end end)
		task.delay(8, function() if snd and snd.Parent then snd:Destroy() end end)
	end

	local useTime = tool:GetAttribute("ConsumeUseTime") or DEFAULT_USE_TIME
	local startHealth = hum and hum.Health
	local cancelled = false
	local healthConn
	if hum then
		healthConn = hum.HealthChanged:Connect(function(newHealth)
			if newHealth < startHealth then cancelled = true end
		end)
	end

	task.delay(useTime, function()
		if healthConn then healthConn:Disconnect() end
		if not tool or not tool.Parent then return end
		if cancelled then
			tool:SetAttribute("InProgress", false)
			if track then track:Stop() end
			notify(player, "Interrupted", "You were hit and stopped eating/drinking.")
			return
		end
		finishConsume(tool, player)
	end)
end

local function wireConsumable(tool)
	tool.Activated:Connect(function() consume(tool) end)
end

-- In case a template ever gets manually placed back in the world for touch-pickup.
for _, tool in ipairs(workspace:GetChildren()) do
	if tool:IsA("Tool") and tool:GetAttribute("ConsumeType") then
		wireConsumable(tool)
	end
end

local EdibleManager = {}

-- Marks a physically-held clone as ours so unequipHeld never touches some other Tool a
-- future system might attach to the character.
local HELD_TAG = "EdibleHeld"

-- Adds a normal Inventory entry (same shape giveItem uses) and pushes the hotbar refresh.
-- Returns true, or false+reason.
function EdibleManager.grant(player, itemName)
	if not player or not itemName then return false, "player and itemName required" end
	if not templates:FindFirstChild(itemName) then return false, "no edible template named \"" .. tostring(itemName) .. "\"" end
	local dm = _G.DataManager
	if not dm then return false, "DataManager not ready" end
	local inv = dm.getValue(player, "Inventory") or {}
	if #inv >= 10 then return false, "inventory full (10 slots)" end
	table.insert(inv, {itemName = itemName})
	dm.setValue(player, "Inventory", inv)
	local im = _G.InventoryManager
	if im then im.refresh(player) end
	return true
end

-- Called by InventoryManager when a hotbar slot is equipped. If itemName is a known edible,
-- clones the real Tool into the Character (so it's actually held) and returns true; returns
-- false for anything else so InventoryManager falls back to its normal EquippedWeapon path.
function EdibleManager.tryEquip(player, itemName, slotIndex)
	local template = templates:FindFirstChild(itemName)
	if not template then return false end
	local char = player.Character
	if not char then return false end
	local clone = template:Clone()
	clone:SetAttribute("Consumed", false)
	clone:SetAttribute("SourceSlot", slotIndex)
	clone:SetAttribute(HELD_TAG, true)
	wireConsumable(clone)
	clone.Parent = char
	return true
end

-- Called by InventoryManager before every equip/unequip so switching hotbar slots (or
-- unequipping) always clears whatever edible was physically held before -- otherwise
-- switching from a held Apple straight to a weapon slot would leave the Apple stuck in hand.
function EdibleManager.unequipHeld(player)
	local char = player.Character
	if not char then return end
	for _, tool in ipairs(char:GetChildren()) do
		if tool:IsA("Tool") and tool:GetAttribute(HELD_TAG) then
			tool:Destroy()
		end
	end
end

_G.EdibleManager = EdibleManager

print("[EdibleManager] Init — " .. #templates:GetChildren() .. " edible template(s) ready to grant")
