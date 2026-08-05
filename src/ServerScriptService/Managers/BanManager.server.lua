-- BanManager: persistent, duration-based player bans (survives server restarts via
-- DataStore) enforced on join. Mirrors DataManager's DataStore naming convention.
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")

local BanStore = DataStoreService:GetDataStore("AbyssBans_v1")

local function getBan(userId)
	local ok, data = pcall(function() return BanStore:GetAsync("Ban_"..userId) end)
	if not ok or not data then return nil end
	if data.expiresAt and os.time() >= data.expiresAt then return nil end -- expired
	return data
end

local function formatRemaining(expiresAt)
	local secs = math.max(0, expiresAt - os.time())
	local mins = math.ceil(secs/60)
	if mins < 60 then return mins.." minute(s)" end
	local hours = math.floor(mins/60)
	if hours < 24 then return hours.." hour(s)" end
	return math.floor(hours/24).." day(s)"
end

local function checkAndKick(player)
	local ban = getBan(player.UserId)
	if ban then
		player:Kick(("You are banned. Reason: %s. Time remaining: %s"):format(ban.reason or "No reason given", formatRemaining(ban.expiresAt)))
	end
end

Players.PlayerAdded:Connect(checkAndKick)
for _, p in ipairs(Players:GetPlayers()) do task.spawn(checkAndKick, p) end

local BanManager = {}

function BanManager.banPlayer(target, durationMinutes, reason, modName)
	local dur = math.max(1, tonumber(durationMinutes) or 0)
	local expiresAt = os.time() + dur*60
	local data = { expiresAt=expiresAt, reason=(reason and #reason>0) and reason or "No reason given", bannedBy=modName or "SYSTEM" }
	local ok, err = pcall(function() BanStore:SetAsync("Ban_"..target.UserId, data) end)
	if not ok then warn("[BanManager] Failed to save ban: "..tostring(err)); return false end
	print(string.format("[BanManager] %s banned by %s for %d min (%s)", target.Name, data.bannedBy, dur, data.reason))
	target:Kick(("You have been banned. Reason: %s. Time remaining: %s"):format(data.reason, formatRemaining(expiresAt)))
	return true
end

function BanManager.unbanUserId(userId)
	local ok = pcall(function() BanStore:RemoveAsync("Ban_"..userId) end)
	if ok then print("[BanManager] Unbanned userId "..tostring(userId)) end
	return ok
end

function BanManager.getBan(userId) return getBan(userId) end

_G.BanManager = BanManager
print("[BanManager] Initialized")
