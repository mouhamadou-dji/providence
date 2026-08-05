-- ShadowBoxManager -- design doc PART ONE. The shadow figure, its AI, and every "hit" against
-- it are entirely client-side (see ShadowBoxClient) and never touch real Health/hitboxes at
-- all -- the player's own real M1/M2 still work completely normally while practicing (it's
-- just swinging at a client-only dummy, indistinguishable server-side from swinging at empty
-- air). The server's only job is gating entry (not blocked/in-combat/idle) and holding a
-- ShadowPracticeActive flag (read by the mod panel, and used to auto-end practice the instant
-- the player takes REAL damage from an actual attacker).
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local sbCfg = Config.ShadowBoxing

local function getOrCreate(name, isFunc)
	local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
		local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
	end)()
	local r=folder:FindFirstChild(name); if r then return r end
	r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_ShadowPracticeState = getOrCreate("ShadowPracticeState") -- server -> client: {active=bool, reason=string}
local RE_LiveFeedUpdate      = getOrCreate("LiveFeedUpdate")

local ShadowBoxManager = {}

local healthConns  = {} -- [userId] = RBXScriptConnection
local lastMovedAt  = {} -- [userId] = tick() of last time HRP velocity exceeded the idle threshold

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
			RE_LiveFeedUpdate:FireClient(p, { type = "SHADOWBOX", h = now.hour, m = now.min, zone = "?", charName = charName, message = message })
		end
	end
end

-- Cheap per-player idle tracker (no per-player loop, one shared Heartbeat) purely to satisfy
-- the design doc's "stationary for at least 1 second" trigger requirement.
RunService.Heartbeat:Connect(function()
	for _, p in ipairs(Players:GetPlayers()) do
		local char = p.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and hrp.AssemblyLinearVelocity.Magnitude > 1.5 then
			lastMovedAt[p.UserId] = tick()
		end
	end
end)

local function disconnectHealthWatch(userId)
	local c = healthConns[userId]
	if c then c:Disconnect(); healthConns[userId] = nil end
end

function ShadowBoxManager.stopPractice(player, reason)
	if not player:GetAttribute("ShadowPracticeActive") then return end
	player:SetAttribute("ShadowPracticeActive", false)
	disconnectHealthWatch(player.UserId)
	RE_ShadowPracticeState:FireClient(player, { active = false, reason = reason or "manual" })
	fireLiveFeed(getCharName(player), "ended shadow practice (" .. tostring(reason) .. ")")
end

function ShadowBoxManager.startPractice(player)
	-- Idempotent while already active -- re-firing the state event lets the client spawn a
	-- fresh dummy after the previous one died (design doc: "After death: player can spawn
	-- another with /shadowbox again") without needing a separate stop/start round-trip.
	local maxHits = player:GetAttribute("ShadowBoxMaxHits") or sbCfg.DefaultHitsToDefeat
	if player:GetAttribute("ShadowPracticeActive") then
		RE_ShadowPracticeState:FireClient(player, { active = true, maxHits = maxHits })
		return true
	end
	local cm = _G.CombatManager
	if cm and cm.isActionBlocked and cm.isActionBlocked(player) then
		return false, "Cannot start shadow practice right now."
	end
	local sm = _G.StaminaManager
	if sm and sm.isInCombat and sm.isInCombat(player) then
		return false, "You are in combat."
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return false, "No character." end
	local moved = lastMovedAt[player.UserId]
	if moved and (tick() - moved) < sbCfg.MinIdleSeconds then
		return false, "Stand still for a moment first."
	end

	player:SetAttribute("ShadowPracticeActive", true)
	RE_ShadowPracticeState:FireClient(player, { active = true, maxHits = maxHits })
	fireLiveFeed(getCharName(player), "started shadow practice (" .. maxHits .. " hit" .. (maxHits==1 and "" or "s") .. " to defeat)")

	disconnectHealthWatch(player.UserId)
	local lastHealth = hum.Health
	healthConns[player.UserId] = hum.HealthChanged:Connect(function(newHealth)
		if newHealth < lastHealth then
			ShadowBoxManager.stopPractice(player, "took real damage")
		end
		lastHealth = newHealth
	end)
	return true
end

Players.PlayerRemoving:Connect(function(player)
	disconnectHealthWatch(player.UserId)
	lastMovedAt[player.UserId] = nil
end)

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function()
		-- A fresh spawn always starts clean -- a stale flag from a previous life (e.g. died
		-- mid-practice) must never block real combat on the new body.
		player:SetAttribute("ShadowPracticeActive", false)
		disconnectHealthWatch(player.UserId)
	end)
end)

_G.ShadowBoxManager = ShadowBoxManager
print("[ShadowBoxManager] Init")
