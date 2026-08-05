-- PotionManager -- consumable framework: heal HP, clear bleed, clear injuries, restore
-- stamina. Potions are abstract Inventory items (like Ritual Stone/weapons -- no physical
-- Tool), used via the currently-equipped hotbar slot + the RequestUsePotion remote (Z key,
-- see PotionClient). Uses Config.Potions (data) + Config.PotionEffects (behavior).

local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config  = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))
local potionCfg = Config.Potions
local effects   = Config.PotionEffects

local MAX_SLOTS = 10 -- must match InventoryManager.MAX_SLOTS

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

local function notify(player, title, body, duration, style)
	Remotes.ShowNotification:FireClient(player, { title = title, body = body, duration = duration or 5, style = style or "info" })
end

local channeling = {} -- [userId] = { potionId=, startHealth=, startPos=, heartbeatConn= }

local PotionManager = {}

function PotionManager.give(player, potionId, amount)
	if not potionCfg[potionId] then return false end
	local dm = _G.DataManager; if not dm then return false end
	amount = math.max(1, tonumber(amount) or 1)
	local inv = dm.getValue(player, "Inventory") or {}
	for _ = 1, amount do
		if #inv >= MAX_SLOTS then break end -- inventory full: grant as many as fit, matching giveItem's no-special-handling convention
		table.insert(inv, { itemName = potionId, quality = "Potion" })
	end
	dm.setValue(player, "Inventory", inv)
	local im = _G.InventoryManager; if im then im.refresh(player) end
	local charName = getCharName(player)
	fireLiveFeed(charName, "granted " .. amount .. "x " .. potionCfg[potionId].name)
	return true
end

local function isChanneling(player) return channeling[player.UserId] ~= nil end

local function cancelChannel(player, reason)
	local state = channeling[player.UserId]; if not state then return end
	if state.heartbeatConn then state.heartbeatConn:Disconnect() end
	channeling[player.UserId] = nil
	Remotes.PotionUseFeedback:FireClient(player, { ok = false, message = reason, potionId = state.potionId })
end

local function isBlockedForPotionUse(player)
	local cm = _G.CombatManager
	if cm and cm.isActionBlocked(player) then return true end
	if cm and cm.getCombatState(player) == "Attacking" then return true end
	local bm = _G.BlockManager
	if bm and bm.isBlocking(player) then return true end
	local mm = _G.MovementManager
	if mm and mm.isSprinting(player) then return true end
	local rm = _G.RageManager
	if rm and rm.isRaging(player) then return true end -- "cannot use potions during rage"
	return false
end

Remotes.RequestUsePotion.OnServerEvent:Connect(function(player)
	if isChanneling(player) then return end
	local dm = _G.DataManager; if not dm then return end
	local slot = dm.getValue(player, "EquippedSlot")
	if not slot then notify(player, "Potion", "Equip a potion on your hotbar first.", 4, "warning"); return end
	local inv = dm.getValue(player, "Inventory") or {}
	local item = inv[slot]; if not item then return end
	local cfg = potionCfg[item.itemName]; if not cfg then return end -- equipped item isn't a potion

	if isBlockedForPotionUse(player) then
		notify(player, "Potion", "Cannot use a potion right now.", 3, "warning")
		return
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp then return end

	local state = {
		potionId = item.itemName, slot = slot,
		startHealth = hum.Health, startPos = hrp.Position,
	}
	channeling[player.UserId] = state
	Remotes.PotionUseFeedback:FireClient(player, { starting = true, useTime = cfg.useTime, potionId = item.itemName, useAnimation = cfg.useAnimation, useSound = cfg.useSound })

	state.heartbeatConn = RunService.Heartbeat:Connect(function()
		local cur = channeling[player.UserId]; if cur ~= state then return end
		if not char.Parent or not hum.Parent then cancelChannel(player, "Interrupted."); return end
		if hum.Health < state.startHealth then cancelChannel(player, "Potion use cancelled -- you took damage."); return end
		if hum.MoveDirection.Magnitude > 0.1 then cancelChannel(player, "Potion use cancelled -- you moved."); return end
	end)

	task.delay(cfg.useTime, function()
		local cur = channeling[player.UserId]
		if cur ~= state then return end -- already cancelled
		if state.heartbeatConn then state.heartbeatConn:Disconnect() end
		channeling[player.UserId] = nil

		-- Re-validate the item is still actually there (equip slot could've changed/emptied
		-- mid-channel some other way) before consuming it.
		local inv2 = dm.getValue(player, "Inventory") or {}
		if inv2[state.slot] == nil or inv2[state.slot].itemName ~= state.potionId then
			Remotes.PotionUseFeedback:FireClient(player, { ok = false, message = "Potion no longer available.", potionId = state.potionId })
			return
		end

		for _, effectName in ipairs(cfg.effects or {}) do
			local fn = effects[effectName]
			if fn then pcall(fn, player, cfg) end
		end

		table.remove(inv2, state.slot)
		dm.setValue(player, "Inventory", inv2)
		dm.setValue(player, "EquippedWeapon", nil)
		dm.setValue(player, "EquippedSlot", nil)
		local im = _G.InventoryManager; if im then im.refresh(player) end

		Remotes.PotionUseFeedback:FireClient(player, { ok = true, message = "Used " .. cfg.name, potionId = state.potionId })
		local charName = getCharName(player)
		local detail = cfg.healAmount and (cfg.name .. " (healed " .. tostring(cfg.healAmount) .. " HP)") or cfg.name
		fireLiveFeed(charName, "used " .. detail)
		local disc = _G.DiscordManager
		if disc and disc.logPotion then disc.logPotion(charName, detail) end
		print("[PotionManager] " .. player.Name .. " used " .. cfg.name)
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	local state = channeling[player.UserId]
	if state and state.heartbeatConn then state.heartbeatConn:Disconnect() end
	channeling[player.UserId] = nil
end)

_G.PotionManager = PotionManager
print("[PotionManager] Init — " .. (function() local n=0; for _ in pairs(potionCfg) do n+=1 end; return n end)() .. " potions defined")
