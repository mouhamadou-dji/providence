--[[
	MovementManager -- seam left behind by the 2026-08-04 movement teardown.

	UPDATE 2026-08-04 (later the same day): the revamp landed. Sprint, dash, the dodge
	economy and i-frames now live in ServerScriptService.Managers.MovementSystem, which
	registers _G.MovementSystem -- so every inert stub at the bottom of this file is now
	live by delegation, exactly as the seam intended. Crouch still lives HERE. Slide,
	parkour and the Flow HUD are still pass-2.

	The old movement stack (sprint, momentum, slopes, dash, dash-feint, slide, slide
	smoke, slide-jump, jump boost, momentum particles) and its entire client feel/camera
	layer were ripped out for a full revamp. They are archived, inert, at
		ServerStorage._OldMovement_2026_08_04
		  .Server  -- MovementManager, Movement_TestHarness
		  .Client  -- MovementController, MovementFeelClient
		  .Remotes -- RequestDash / RequestSprint / RequestSprintEnd / RequestSlide / RequestJump
		  .Gui     -- ShiftlockCursor

	WHAT SURVIVES: crouch, and only crouch. Ctrl toggles it, WalkSpeed drops to the
	crouch multiplier, CrouchActive replicates to the character, and the client plays
	the crouch clips. Nothing else here decides how the player moves -- base WalkSpeed
	is a flat 16 until the revamp lands.

	The camera is deliberately untouched by this script and by MovementController now.
	No shiftlock, no head bob, no landing dip, no dash roll, no sprint FOV, no lean, no
	follow lag, no facing/AlignOrientation overrides. Roblox's stock camera is the only
	thing driving it. (Sanity / Feelings / Injury / Intoxication / Weather / Boat keep
	their own camera passes -- those are not movement.)

	PLUGGING IN THE REVAMP:
		Set _G.MovementSystem = <your module> anywhere, at any time. Every inert method
		below delegates to it when present, so the surviving callers (PotionManager,
		EmoteManager, the test harnesses) do not need re-threading. Do NOT overwrite
		_G.MovementManager -- that name stays pointed here.

	ONE RULE, UNCHANGED: all WalkSpeed changes go through setMovementState(), which
	routes to CombatCore.setSpeed so injury / rage / caste / low-health multipliers
	still compose correctly. Never write hum.WalkSpeed directly elsewhere.
]]

local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")

local BASE_WALK_SPEED = 16

local movementCfg
do
	local ok, cfg = pcall(function()
		local shared = RepStorage:WaitForChild("Shared", 5)
		return require(shared:WaitForChild("Config", 3))
	end)
	if ok and cfg then movementCfg = cfg.Movement end
end
movementCfg = movementCfg or { BaseWalkSpeed = 16, SpeedMult = { Normal = 1.0, Crouch = 0.5, Sprint = 26/16 } }
BASE_WALK_SPEED = movementCfg.BaseWalkSpeed or 16

-- The authorised-ceiling multipliers. Sprint was added back by the movement revamp
-- (2026-08-04) -- MovementSystem raises the ceiling through here rather than writing
-- WalkSpeed itself, so the injury/rage/caste/health product still composes on top.
local SPEED_MULT = {
	Normal = (movementCfg.SpeedMult and movementCfg.SpeedMult.Normal) or 1.0,
	Crouch = (movementCfg.SpeedMult and movementCfg.SpeedMult.Crouch) or 0.5,
	Sprint = (movementCfg.SpeedMult and movementCfg.SpeedMult.Sprint) or (26/16),
}

-- Delegate helper: route to the new movement system once one has registered.
local function sys(method)
	local ms = _G.MovementSystem
	if ms and type(ms[method]) == "function" then return ms[method] end
	return nil
end

-- ─── Remote events ───────────────────────────────────────────────────────────
-- Only the two crouch needs. RequestDash / RequestSprint / RequestSprintEnd /
-- RequestSlide / RequestJump were archived with the stack -- they must NOT be
-- recreated here, or they come back as orphans nothing fires or listens to.
local function getOrCreateRE(name)
	local folder = RepStorage:FindFirstChild("RemoteEvents")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "RemoteEvents"
		folder.Parent = RepStorage
	end
	local r = folder:FindFirstChild(name)
	if r then return r end
	r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = folder
	return r
end

local RE_Crouch   = getOrCreateRE("RequestCrouch")
local RE_MovState = getOrCreateRE("UpdateMovementState") -- server → client

-- ─── Per-player state ────────────────────────────────────────────────────────
local pState = {}
local function initState(uid) pState[uid] = { isCrouching = false } end
local function getPS(player) return player and pState[player.UserId] end

-- ─── CENTRAL SPEED SETTER — all WalkSpeed changes go here ────────────────────
local function setMovementState(player, stateName, customMult)
	local mult = customMult or SPEED_MULT[stateName] or 1.0
	local cm = _G.CombatManager -- CombatCore: owns the multiplier stack (injury/rage/caste/health)
	if cm and cm.setSpeed then
		cm.setSpeed(player, mult)
	else
		local char = player.Character
		local hum  = char and char:FindFirstChildOfClass("Humanoid")
		if hum then hum.WalkSpeed = BASE_WALK_SPEED * mult end
	end
end

-- ─── CROUCH ──────────────────────────────────────────────────────────────────
local function processCrouch(player, s)
	s = s or getPS(player)
	if not s then return end
	local cm = _G.CombatManager
	-- Blocked during GuardBreak / Stagger / Downed etc. once a combat system registers;
	-- CombatCore answers false while none is present.
	if cm and cm.isActionBlocked and cm.isActionBlocked(player) then return end

	s.isCrouching = not s.isCrouching
	local char = player.Character
	if char then char:SetAttribute("CrouchActive", s.isCrouching) end

	if s.isCrouching then
		setMovementState(player, "Crouch")
		RE_MovState:FireClient(player, "Crouch")
	else
		setMovementState(player, "Normal")
		RE_MovState:FireClient(player, "CrouchEnd")
	end
end

RE_Crouch.OnServerEvent:Connect(function(p) processCrouch(p) end)

-- ─── PLAYER SETUP ────────────────────────────────────────────────────────────
local function setupPlayer(player)
	initState(player.UserId)
	player.CharacterAdded:Connect(function(char)
		local s = getPS(player)
		if s then s.isCrouching = false end
		char:SetAttribute("CrouchActive", false)
		local hum = char:WaitForChild("Humanoid", 5)
		if hum then
			hum.WalkSpeed = BASE_WALK_SPEED
			-- Jump left entirely on Roblox's own defaults: the momentum-scaled JumpPower
			-- and slide-jump shove that needed UseJumpPower=true went with the teardown.
		end
	end)
end

Players.PlayerAdded:Connect(setupPlayer)
for _, p in ipairs(Players:GetPlayers()) do setupPlayer(p) end
Players.PlayerRemoving:Connect(function(player) pState[player.UserId] = nil end)

-- ─── PUBLIC API ──────────────────────────────────────────────────────────────
local MovementManager = {}

-- REAL ---------------------------------------------------------------------
MovementManager.setMovementState = setMovementState
MovementManager.crouch           = processCrouch
MovementManager.isCrouching      = function(p) local s = getPS(p); return s ~= nil and s.isCrouching end

-- INERT -- genuine movement questions; answer "not doing that" until _G.MovementSystem
-- registers. Kept because PotionManager calls isSprinting WITHOUT a nil-guard and
-- EmoteManager calls isDashing, exactly the CombatCore stub convention.
MovementManager.isSprinting      = function(p) local f = sys("isSprinting");      if f then return f(p) end return false end
MovementManager.isSliding        = function(p) local f = sys("isSliding");        if f then return f(p) end return false end
MovementManager.isDashing        = function(p) local f = sys("isDashing");        if f then return f(p) end return false end
MovementManager.isDashOnCooldown = function(p) local f = sys("isDashOnCooldown"); if f then return f(p) end return false end
MovementManager.getMomentum      = function(p) local f = sys("getMomentum");      if f then return f(p) end return 0 end
MovementManager.startSprint      = function(...) local f = sys("startSprint"); if f then return f(...) end end
MovementManager.stopSprint       = function(...) local f = sys("stopSprint");  if f then return f(...) end end
MovementManager.consumeSlideJump = function(p) local f = sys("consumeSlideJump"); if f then return f(p) end return false end

_G.MovementManager = MovementManager

print("[MovementManager] Movement stack removed 2026-08-04. Crouch only -- set _G.MovementSystem to plug in the revamp.")
