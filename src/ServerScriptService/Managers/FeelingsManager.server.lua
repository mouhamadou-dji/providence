-- FeelingsManager -- short-lived emotional states with visual/audio effects (design doc
-- PART FIVE). Purely a trigger router: server decides WHETHER a feeling fires (talent
-- prevention) and tells the owning client WHICH one; all duration/fade/visual timing lives
-- client-side in FeelingsClient, driven by Config.Feelings.
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local triggers = Config.FeelingTriggers
local feelingsCfg = Config.Feelings

local function getOrCreate(name, isFunc)
	local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
		local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
	end)()
	local r=folder:FindFirstChild(name); if r then return r end
	r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_TriggerFeeling = getOrCreate("TriggerFeeling")

local FeelingsManager = {}

-- Duration/fade all live client-side, so the server had no idea what a player was feeling.
-- The mod panel's Player Info Viewer needs to show it, so track what was fired and when, and
-- derive "still active" from Config.Feelings' own duration -- the same number the client is
-- counting down. Session-only, deliberately not persisted: a feeling is a moment, not a stat.
local activeUntil = {} -- [userId] = { [feelingId] = expiryTick }

function FeelingsManager.getActiveFeelings(player)
	local set = activeUntil[player.UserId]
	if not set then return {} end
	local out = {}
	for feelingId, expiry in pairs(set) do
		if tick() < expiry then table.insert(out, feelingId) else set[feelingId] = nil end
	end
	table.sort(out)
	return out
end

-- Talent-based prevention (design doc PART FIVE):
--   ColdBlood  prevents Anxiety on witness/kill
--   IronNerve  prevents Fear
--   Stoicism   prevents ALL feeling triggers
local function isPrevented(player, feelingId)
	local tm = _G.TalentManager
	if not tm then return false end
	if tm.hasTalent(player, "Stoicism") then return true end
	if feelingId == "Anxiety" and tm.hasTalent(player, "ColdBlood") then return true end
	if feelingId == "Fear" and tm.hasTalent(player, "IronNerve") then return true end
	return false
end

-- triggerKey is one of Config.FeelingTriggers' keys (OnWitnessDeath, OnAllyDeath, etc) --
-- can also be called with a feelingId directly (Anxiety/Fear/Rage/Paranoia/Soothing) for
-- mod-panel manual triggers, since those don't map to any of the trigger keys.
function FeelingsManager.trigger(player, triggerKeyOrFeelingId)
	local feelingId = triggers[triggerKeyOrFeelingId] or (feelingsCfg[triggerKeyOrFeelingId] and triggerKeyOrFeelingId)
	if not feelingId then return false end
	if isPrevented(player, feelingId) then return false end
	RE_TriggerFeeling:FireClient(player, {feelingId = feelingId})
	local set = activeUntil[player.UserId]
	if not set then set = {}; activeUntil[player.UserId] = set end
	-- Config.Feelings also holds bare numbers (FadeIn/FadeOut), which the id resolution above
	-- will happily accept as a "feeling" -- so type-check before reading .duration off it.
	local cfg = feelingsCfg[feelingId]
	set[feelingId] = tick() + ((type(cfg) == "table" and cfg.duration) or 10)
	return true
end

-- ── Continuous triggers: Soothing (near ally) and Fear (cliff pull active) aren't one-shot
-- events, they're conditions -- re-fire at half the feeling's duration so the client-side
-- "duration refreshes, doesn't stack" rule (see FeelingsClient) keeps them seamlessly active
-- for as long as the condition holds, with no visible gap.
local accum = {}
RunService.Heartbeat:Connect(function(dt)
	for _, player in ipairs(Players:GetPlayers()) do
		local dm = _G.DataManager
		if dm and dm.isLoaded(player) and player.Character then
			local uid = player.UserId
			accum[uid] = (accum[uid] or 0) + dt
			if accum[uid] >= (feelingsCfg.Soothing.duration / 2) then
				accum[uid] = 0
				local allyM = _G.AllyManager
				if allyM and allyM.isNearAnyAlly(player) then
					FeelingsManager.trigger(player, "OnNearAlly")
				end
				local sanM = _G.SanityManager
				if sanM then
					local tiers = sanM.getTiers(player)
					if tiers.cliffPull then FeelingsManager.trigger(player, "OnCliffPullActive") end
				end
			end
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	accum[player.UserId] = nil
	activeUntil[player.UserId] = nil
end)

_G.FeelingsManager = FeelingsManager
print("[FeelingsManager] Init")
