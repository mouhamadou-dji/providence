--[[
	CombatCore -- seam left behind by the 2026-08-02 combat teardown.

	The old combat stack (CombatManager / ParryManager / BlockManager / ClashManager /
	PostureManager) was ripped out for a full revamp. It is archived, inert, at
		ServerStorage._OldCombat_2026_08_02

	Fourteen non-combat systems still call into that stack. Rather than edit all of them,
	this script keeps the SAME global names alive and splits their surface in two:

	  * REAL   -- concerns that were living inside CombatManager but are not combat:
	             the WalkSpeed pipeline and generic damage application. Injuries, rage,
	             caste, bleed and low-health slowdown all depend on these, so they are
	             implemented here exactly as the old CombatManager implemented them.

	  * INERT  -- genuine combat questions (is this player parrying / blocked / staggered).
	             These answer "no" until a new combat system registers itself.

	PLUGGING IN THE REVAMP:
		Set _G.CombatSystem = <your module> anywhere, at any time. Every inert method below
		delegates to it when present, so the new system does not need to re-thread a single
		call site. Implement only what you need; anything you omit keeps the inert default.
		Do NOT overwrite _G.CombatManager -- that name stays pointed at CombatCore.
]]

local Players    = game:GetService("Players")
local RunService  = game:GetService("RunService")

local BASE_WALK_SPEED            = 16
local LOW_HEALTH_SPEED_THRESHOLD = 0.3
local LOW_HEALTH_MIN_MULT        = 0.6

-- Per-player state. Deliberately tiny: only what the surviving systems actually read.
local pState = {}
local function initState(uid)
	pState[uid] = { speedMult = 1, combatState = "Idle", isSprinting = false, iframesUntil = 0 }
end
local function getPS(player) return player and pState[player.UserId] end

for _, p in ipairs(Players:GetPlayers()) do initState(p.UserId) end
Players.PlayerAdded:Connect(function(p) initState(p.UserId) end)
-- recentDamage is cleared alongside pState further down (it is declared below this point,
-- with the damage funnel it belongs to).
Players.PlayerRemoving:Connect(function(p) pState[p.UserId] = nil end)

-- Delegate helper: route to the new combat system if one has registered.
local function sys(method)
	local cs = _G.CombatSystem
	if cs and type(cs[method]) == "function" then return cs[method] end
	return nil
end

--=============================================================================
-- REAL -- speed pipeline (carried over verbatim from the old CombatManager)
--=============================================================================

local function healthSpeedMult(player)
	local char = player.Character; if not char then return 1 end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.MaxHealth <= 0 then return 1 end
	local frac = hum.Health / hum.MaxHealth
	if frac >= LOW_HEALTH_SPEED_THRESHOLD then return 1 end
	local t = math.max(0, frac) / LOW_HEALTH_SPEED_THRESHOLD
	return LOW_HEALTH_MIN_MULT + (1 - LOW_HEALTH_MIN_MULT) * t
end

local function injurySpeedMult(player) local im=_G.InjuryManager; return im and im.getSpeedMultiplier(player) or 1 end
local function rageSpeedMult(player)   local rm=_G.RageManager;   return rm and rm.getSpeedMult(player) or 1 end
local function casteSpeedMult(player)  local cm=_G.CasteManager;  return cm and cm.getMassaliaMovementMultiplier(player) or 1 end

local function setSpeed(player, mult)
	local char = player and player.Character; if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid"); if not hum then return end
	local s = pState[player.UserId]; if s then s.speedMult = mult end
	hum.WalkSpeed = BASE_WALK_SPEED * mult
		* healthSpeedMult(player) * injurySpeedMult(player)
		* rageSpeedMult(player)   * casteSpeedMult(player)
end

--=============================================================================
-- REAL -- damage application
--=============================================================================
-- Kept because BleedManager (bleed ticks, burst damage) and NPCManager (mob hits) are
-- survival systems, not combat, and both route their damage through here. Godmode and
-- deep-meditation immunity are preserved. The old downed/execute path is gone with the
-- rest of combat, so lethal damage now simply kills.
-- Short rolling history of damage each player actually took, for the movement system's
-- lag-compensated dodge (see refundRecentDamage below). Bounded to DAMAGE_HISTORY_SECONDS
-- and pruned on every write, so it can never grow -- a window, not a log.
local DAMAGE_HISTORY_SECONDS = 1.0
local recentDamage = {} -- [userId] = { {amount=, time=}, ... }

local function recordDamage(player, amount)
	local uid = player.UserId
	local list = recentDamage[uid]
	if not list then list = {}; recentDamage[uid] = list end
	local now = os.clock()
	local keep = {}
	for _, entry in ipairs(list) do
		if now - entry.time <= DAMAGE_HISTORY_SECONDS then keep[#keep + 1] = entry end
	end
	keep[#keep + 1] = { amount = amount, time = now }
	recentDamage[uid] = keep
end

local function applyDamage(humanoid, damage, victimPlayer, sourceTag)
	if not humanoid then return 0 end
	local override = sys("applyDamage")
	if override then return override(humanoid, damage, victimPlayer, sourceTag) end

	if victimPlayer then
		local mm = _G.ModManager
		if mm and mm.isInvincible and mm.isInvincible(victimPlayer) then return humanoid.Health end
		local medM = _G.MeditationManager
		if medM and medM.isDeepMeditating and medM.isDeepMeditating(victimPlayer) then return humanoid.Health end
		-- I-FRAME GATE (movement revamp, 2026-08-04). Storage for i-frames has existed here
		-- since the combat teardown, but nothing ever CHECKED it -- so dash invincibility
		-- silently did nothing. The gate lives in applyDamage deliberately: every damage
		-- source in the game (Shroom/Wolf/NPC mobs, BleedManager, and whatever the combat
		-- revamp brings) funnels through this one function, so one check covers all of them.
		-- Never a ForceField (visible, and interacts oddly with explosions) and never a
		-- client-writable attribute.
		local iS = pState[victimPlayer.UserId]
		if iS and os.clock() < (iS.iframesUntil or 0) then return humanoid.Health end
		recordDamage(victimPlayer, damage)
	end
	humanoid:TakeDamage(damage)
	if victimPlayer and (sourceTag == "Player" or sourceTag == "Mob") then
		local sm = _G.StaminaManager
		if sm and sm.tagCombat then sm.tagCombat(victimPlayer) end
	end
	return humanoid.Health
end

--=============================================================================
-- CombatCore public surface (published as _G.CombatManager)
--=============================================================================

local CombatCore = {}

-- REAL --------------------------------------------------------------------
function CombatCore.setSpeed(player, mult) setSpeed(player, mult) end
function CombatCore.refreshSpeed(player) local s = getPS(player); setSpeed(player, s and s.speedMult or 1) end
function CombatCore.applyDamage(hum, dmg, victimPlayer, sourceTag) return applyDamage(hum, dmg, victimPlayer, sourceTag) end

-- Combat state: still replicated to the character as an Attribute, because client scripts
-- (MovementController's fidget/tilt gating) read it. Stays "Idle" while combat is absent.
function CombatCore.getCombatState(player)
	local f = sys("getCombatState"); if f then return f(player) end
	local s = getPS(player); return s and s.combatState or "Idle"
end
function CombatCore.setCombatState(player, state)
	local f = sys("setCombatState"); if f then return f(player, state) end
	local s = getPS(player); if s then s.combatState = state or "Idle" end
end

-- Sprint bookkeeping is movement's, not combat's -- kept real so the Movement overhaul
-- has somewhere to read/write it.
function CombatCore.setSprinting(player, bool) local s = getPS(player); if s then s.isSprinting = bool end end
function CombatCore.isFistsEquipped(player)
	local char = player and player.Character
	return char ~= nil and char:GetAttribute("FistsEquipped") == true
end

-- i-frames: real storage (dash i-frames belong to movement), but nothing grants them
-- until either the Movement overhaul or the new combat system does.
-- os.clock() throughout, NOT tick(): applyDamage's gate above and refundRecentDamage below
-- both compare against these timestamps, and mixing the two clocks makes every comparison
-- silently meaningless (tick() is a Unix epoch, os.clock() is process time).
function CombatCore.grantIframes(player, duration) local s = getPS(player); if s then s.iframesUntil = os.clock() + duration end end
function CombatCore.grantBonusIframes(player, duration) local s = getPS(player); if s then s.iframesUntil = math.max(s.iframesUntil or 0, os.clock()) + duration end end
function CombatCore.hasIframes(player)
	local f = sys("hasIframes"); if f then return f(player) end
	local s = getPS(player); return s ~= nil and os.clock() < (s.iframesUntil or 0)
end

--[[
	refundRecentDamage(player, window, maxRefund) -> refunded

	Lag compensation for dodges. A player on 150ms ping presses dodge, but a hit already in
	flight lands before their i-frames reach the server -- on their screen they dodged
	cleanly and still took damage. Rather than moving damage to the client (which hands
	exploiters invincibility), we look BACKWARD: damage inside the player's own measured
	latency window is refunded, because it would have been dodged.

	Safe against a spoofed-latency client because `window` is derived by the CALLER from
	player:GetNetworkPing() -- a server-side measurement -- and capped there, and because
	maxRefund bounds the total regardless. Refunded entries are consumed, so the same hit can
	never be refunded twice.
]]
function CombatCore.refundRecentDamage(player, window, maxRefund)
	local char = player and player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return 0 end
	local list = recentDamage[player.UserId]
	if not list or #list == 0 then return 0 end

	local now = os.clock()
	local refunded = 0
	local keep = {}
	for _, entry in ipairs(list) do
		if (now - entry.time) <= window and refunded < (maxRefund or math.huge) then
			refunded = refunded + entry.amount
		elseif (now - entry.time) <= DAMAGE_HISTORY_SECONDS then
			keep[#keep + 1] = entry -- outside the dodge window, still inside the history
		end
	end
	recentDamage[player.UserId] = keep
	if refunded <= 0 then return 0 end
	refunded = math.min(refunded, maxRefund or refunded)
	hum.Health = math.min(hum.MaxHealth, hum.Health + refunded)
	return refunded
end

-- INERT -- genuine combat questions; answer "no" until _G.CombatSystem registers -------
function CombatCore.isActionBlocked(player)   local f = sys("isActionBlocked");   if f then return f(player) end return false end
function CombatCore.isSprintLocked(player)    local f = sys("isSprintLocked");    if f then return f(player) end return false end
function CombatCore.isLandingRecovery(player) local f = sys("isLandingRecovery"); if f then return f(player) end return false end
function CombatCore.isTurnCapped(player)      local f = sys("isTurnCapped");      if f then return f(player) end return false end
function CombatCore.applyStagger(...)         local f = sys("applyStagger");         if f then return f(...) end end
function CombatCore.clearHitstun(...)         local f = sys("clearHitstun");         if f then return f(...) end end
function CombatCore.recoverFromDowned(...)    local f = sys("recoverFromDowned");    if f then return f(...) end end
function CombatCore.applyDashFeintRecovery(...) local f = sys("applyDashFeintRecovery"); if f then return f(...) end end
function CombatCore.removeBloodPool(...)      local f = sys("removeBloodPool");      if f then return f(...) end end

-- VFX spawners: cosmetic, owned by the revamp. BleedManager still calls spawnBloodBurst,
-- so bleeding is currently damage-without-visuals until the new system supplies these.
function CombatCore.spawnHitVFX(...)     local f = sys("spawnHitVFX");     if f then return f(...) end end
function CombatCore.spawnBloodBurst(...) local f = sys("spawnBloodBurst"); if f then return f(...) end end
function CombatCore.spawnWallImpact(...) local f = sys("spawnWallImpact"); if f then return f(...) end end
function CombatCore.spawnBlockVFX(...)   local f = sys("spawnBlockVFX");   if f then return f(...) end end
function CombatCore.spawnParryVFX(...)   local f = sys("spawnParryVFX");   if f then return f(...) end end
function CombatCore.spawnClashSpark(...) local f = sys("spawnClashSpark"); if f then return f(...) end end

--=============================================================================
-- Inert stand-ins for the other deleted managers
--=============================================================================
-- NPCManager and ModManager call these WITHOUT nil-guards, so the globals must exist or
-- those scripts throw. Return shapes match the originals exactly (checkHit returned false
-- when not blocking; getElapsed returned nil when not parrying).

local ParryStub = {}
function ParryStub.isParrying(player)      local f = sys("isParrying");      if f then return f(player) end return false end
function ParryStub.getElapsed(player)      local f = sys("getParryElapsed"); if f then return f(player) end return nil end
function ParryStub.cancelParry(player)     local f = sys("cancelParry");     if f then return f(player) end end
function ParryStub.tryCancelToDash(player) local f = sys("tryCancelToDash"); if f then return f(player) end return false end

local BlockStub = {}
function BlockStub.isBlocking(player) local f = sys("isBlocking"); if f then return f(player) end return false end
function BlockStub.checkHit(player, attacker, attackType)
	local f = sys("checkBlockHit"); if f then return f(player, attacker, attackType) end
	return false
end

local PostureStub = {}
function PostureStub.getMax(player)             local f = sys("getPostureMax"); if f then return f(player) end return 100 end
function PostureStub.give(...)                  local f = sys("givePosture");   if f then return f(...) end end
function PostureStub.fill(...)                  local f = sys("fillPosture");   if f then return f(...) end end
function PostureStub.recalculateMax(...)        local f = sys("recalculatePostureMax"); if f then return f(...) end end
function PostureStub.setPlayerMax(...)          local f = sys("setPostureMax"); if f then return f(...) end end

--=============================================================================
-- Publish
--=============================================================================
-- Keeping the old global names means none of the 14 surviving systems needed an edit.
Players.PlayerRemoving:Connect(function(p) recentDamage[p.UserId] = nil end)

_G.CombatCore     = CombatCore
_G.CombatManager  = CombatCore
_G.ParryManager   = ParryStub
_G.BlockManager   = BlockStub
_G.PostureManager = PostureStub

-- Mirror combat state onto the character, same as the old CombatManager did, so client
-- scripts reading the CombatState attribute keep working instead of seeing a stale value.
RunService.Heartbeat:Connect(function()
	for uid, s in pairs(pState) do
		local player = Players:GetPlayerByUserId(uid)
		local char = player and player.Character
		if char and char:GetAttribute("CombatState") ~= s.combatState then
			char:SetAttribute("CombatState", s.combatState)
		end
	end
end)

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(char)
		char:SetAttribute("CombatState", "Idle")
		char:SetAttribute("CombatStance", false)
	end)
end)

print("[CombatCore] Combat stack removed 2026-08-02. Seam active -- set _G.CombatSystem to plug in the revamp.")
