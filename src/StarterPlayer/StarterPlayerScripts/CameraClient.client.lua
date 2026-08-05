--[[
	CameraClient -- tight over-the-shoulder FRAMING for Providence (2026-08-05).

	READ THIS BEFORE ADDING TO IT. The 2026-08-04 teardown deliberately removed every camera
	EFFECT from movement -- head bob, landing dip, dash roll, sprint FOV, lean-into-turns,
	follow lag, shiftlock. None of that is coming back here, and this script must not grow
	into a replacement for it.

	This only sets FRAMING: how far back the camera sits, how far off the shoulder, and whether
	the body is locked to the camera. It does it through properties Roblox's own camera already
	respects --
	  * Player.CameraMaxZoomDistance     (distance)
	  * Humanoid.CameraOffset            (shoulder offset)
	  * UserGameSettings.RotationType    (shiftlock facing)
	  * UserInputService.MouseBehavior   (shiftlock cursor)
	-- and never writes Camera.CFrame. That is the whole reason it composes cleanly with
	SanityEffectsClient's cliff tilt, FeelingsClient's shake, InjuryEffectsClient,
	IntoxicationClient and WeatherClient, all of which DO write CFrame or FOV. A per-frame
	CFrame writer here would fight every one of them.

	WHY THE SHOULDER OFFSET IS SHIFTLOCK-ONLY (2026-08-05 pt3, the "camera isn't set correctly"
	bug): Humanoid.CameraOffset is applied in HUMANOIDROOTPART space --
	`BaseCamera:GetSubjectPosition` does
	`bodyPart.CFrame:vectorToWorldSpace(heightOffset + humanoid.CameraOffset)`. With AutoRotate
	on, the body faces wherever it is moving, so a fixed +X offset SWINGS the camera bodily
	around you every time you turn -- it reads as the camera drifting on its own. Under
	RotationType.CameraRelative the body's yaw IS the camera's yaw, so root-part X becomes
	camera-right and the identical property becomes exactly correct. That is why Roblox's own
	shiftlock uses this property and nothing else. So the offset applies while locked and the
	camera sits dead centre while not: correct in both modes rather than wrong in one.

	Config.Camera.Enabled = false restores stock Roblox framing entirely.
]]

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UIS               = game:GetService("UserInputService")
local UGS               = UserSettings():GetService("UserGameSettings")

local player = Players.LocalPlayer
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local CFG = Config.Camera

if not CFG or not CFG.Enabled then
	print("[CameraClient] disabled via Config.Camera.Enabled -- stock Roblox framing")
	return
end

local SLCFG = CFG.Shiftlock or {}

local character, hum
local currentDistance = CFG.DefaultDistance or 10
local currentOffset   = 0

-- ── Shiftlock ─────────────────────────────────────────────────────────────
-- Default OFF, and that is a deliberate call rather than an oversight: MouseBehavior.LockCenter
-- pins the cursor to screen centre and nothing else in ABYSS releases it (only EmoteWheelClient
-- saves and restores it), so an always-on lock would make the mod menu, inventory, hotbar,
-- BTools, trade and ritual UI unclickable. Alt toggles it.
local shiftlocked = false
-- True once the player has deliberately turned shiftlock OFF themselves. A manual toggle-off is
-- a real choice and must stick even if some later system would like to auto-engage it; only
-- another manual press clears it. (Same contract the pre-teardown shiftlock had.)
local manuallyDisabled = false

local function setShiftlock(enabled)
	if not SLCFG.Enabled then return end
	shiftlocked = enabled
	-- CameraRelative is what actually locks the body to the camera -- it drives the facing
	-- through the Humanoid's own AutoRotate, which is why MovementClient must not switch
	-- AutoRotate off mid-dash while this is on.
	UGS.RotationType     = enabled and Enum.RotationType.CameraRelative or Enum.RotationType.MovementRelative
	UIS.MouseBehavior    = enabled and Enum.MouseBehavior.LockCenter    or Enum.MouseBehavior.Default
	UIS.MouseIconEnabled = not enabled
	local gui = player:FindFirstChild("PlayerGui")
	local cur = gui and gui:FindFirstChild(SLCFG.CursorGui or "ShiftlockCursor")
	if cur then cur.Enabled = enabled end
end

-- Cross-LocalScript access, same convention the pre-teardown _G.MovementController used.
-- MovementClient reads isShiftlocked() to decide whether it owns the character's facing.
_G.CameraController = {
	setShiftlock  = setShiftlock,
	isShiftlocked = function() return shiftlocked end,
}

if SLCFG.Enabled then
	UIS.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		if input.KeyCode ~= (SLCFG.Key or Enum.KeyCode.LeftAlt) then return end
		local turningOn = not shiftlocked
		manuallyDisabled = not turningOn
		setShiftlock(turningOn)
	end)
end

-- Combat framing pulls in tighter. CombatState is mirrored onto the character by CombatCore
-- and currently never leaves "Idle" (combat is mid-revamp), so this simply stays at the
-- default distance until the new combat system starts setting it -- no special-casing
-- needed when it lands.
local function wantsCombatFraming()
	if not character then return false end
	local cs = character:GetAttribute("CombatState")
	if cs and cs ~= "Idle" then return true end
	return character:GetAttribute("CombatStance") == true
end

RunService.RenderStepped:Connect(function(dt)
	if not character or not hum or hum.Health <= 0 then return end

	local combat = wantsCombatFraming()
	local targetDistance = combat and (CFG.CombatDistance or 8) or (CFG.DefaultDistance or 10)
	currentDistance = currentDistance + (targetDistance - currentDistance) * math.min(1, (CFG.DistanceLerp or 6) * dt)

	-- MaxZoomDistance is the ceiling the default camera eases toward, so writing only the max
	-- can push the camera IN but can never push it back OUT -- the combat framing was a
	-- one-way ratchet that tightened to 8 studs and stayed there forever. While combat framing
	-- is engaged we pin BOTH ends to the eased distance (the camera is committed, and the
	-- scroll wheel has no business in a fight); on release the min goes back to the configured
	-- floor, which lets the camera ease out again and hands scrolling back to the player.
	local wantMin = combat and currentDistance or (CFG.MinZoomDistance or 0.5)
	if math.abs(player.CameraMinZoomDistance - wantMin) > 0.01 then
		-- Min must never be written above the current max, or the assignment throws.
		player.CameraMaxZoomDistance = math.max(player.CameraMaxZoomDistance, wantMin)
		player.CameraMinZoomDistance = wantMin
	end
	if math.abs(player.CameraMaxZoomDistance - currentDistance) > 0.01 then
		player.CameraMaxZoomDistance = math.max(currentDistance, player.CameraMinZoomDistance)
	end

	-- Shoulder offset -- ONLY while the body is locked to the camera. See the header: outside
	-- shiftlock this property is measured against a body that turns, so any non-zero value
	-- swings the camera around you. Lerped rather than snapped so engaging Alt reads as a
	-- push to the shoulder, not a jump cut.
	local targetOffset = shiftlocked and (SLCFG.ShoulderOffset or 0) or 0
	currentOffset = currentOffset + (targetOffset - currentOffset) * math.min(1, (CFG.OffsetLerp or 8) * dt)
	-- Only the X component is ours. Anything that wants a vertical or forward camera nudge
	-- should go through its own layer, not by fighting us for this property.
	local existing = hum.CameraOffset
	if math.abs(existing.X - currentOffset) > 0.005 then
		hum.CameraOffset = Vector3.new(currentOffset, existing.Y, existing.Z)
	end
end)

local function acquire(char)
	character = char
	hum = char:WaitForChild("Humanoid", 10)
	currentDistance = CFG.DefaultDistance or 10
	currentOffset = 0
	player.CameraMinZoomDistance = CFG.MinZoomDistance or 0.5
	player.CameraMaxZoomDistance = currentDistance
	-- Respawning must not silently drop the lock (or silently restore one the player turned
	-- off): re-apply whatever state they were actually in.
	if SLCFG.Enabled then setShiftlock(shiftlocked) end
end

if player.Character then acquire(player.Character) end
player.CharacterAdded:Connect(acquire)

if SLCFG.Enabled and SLCFG.DefaultOn and not manuallyDisabled then
	setShiftlock(true)
else
	-- Explicitly establish the unlocked state rather than assuming the defaults: another
	-- script (or a previous session's settings) may have left RotationType somewhere else.
	setShiftlock(false)
end

print(string.format("[CameraClient] Framing -- %.0f studs (%.0f in combat) | shiftlock %s on %s, shoulder +%.1f",
	CFG.DefaultDistance or 10, CFG.CombatDistance or 8,
	SLCFG.Enabled and (SLCFG.DefaultOn and "default-on" or "default-off") or "disabled",
	tostring((SLCFG.Key or Enum.KeyCode.LeftAlt).Name), SLCFG.ShoulderOffset or 0))
