--[[
	MovementFeelClient -- Movement Overhaul feel layer (2026-08-02)

	ADDITIVE BY DESIGN. This script does not replace MovementController or
	MovementManager and does not decide what the player is allowed to do -- the server
	still owns sprint/dash/slide/crouch validation and stamina. This only changes how
	those transitions READ on screen.

	Already handled elsewhere, deliberately NOT duplicated here:
	  * surface-aware footsteps, head bob, landing dip, dash roll kick, turn-in-place,
	    slide facing, anim speed matching -> MovementController
	  * momentum, slope handling, slide/dash physics, jump boost -> MovementManager

	What this adds (MD parts 1,2,3,4,7):
	  1. Acceleration/deceleration ramp on WalkSpeed + slide-to-a-stop
	  2. Sprint FOV widening
	  3. Lean into fast turns
	  4. Coyote time + jump buffering
	  7. Camera follow lag

	KILL SWITCH: Config.MovementFeel.Enabled = false disables everything below and
	restores exact pre-overhaul behaviour with no rollback needed. Each feature also
	has its own flag. If movement ever feels wrong, turn off Accel.StopSlide first --
	it is the only part that briefly drives physics.
]]

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UIS              = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))

local CFG = Config.MovementFeel
if not CFG or not CFG.Enabled then
	print("[MovementFeelClient] disabled via Config.MovementFeel.Enabled")
	return
end

local ACC  = CFG.Accel     or {}
local FOVC = CFG.FOV       or {}
local LEAN = CFG.Lean      or {}
local JMP  = CFG.Jump      or {}
local LAG  = CFG.CameraLag or {}

-- ── Character refs ───────────────────────────────────────────────────────────
local character, hum, hrp

-- ── Server-driven movement state (mirrored off UpdateMovementState) ──────────
-- Read rather than inferred: MovementManager is authoritative for these, and guessing
-- from velocity was the thing that made the old slide/crouch prediction desync.
local isSliding   = false
local isCrouching = false

local remotes = ReplicatedStorage:WaitForChild("RemoteEvents", 10)
local RE_MovState = remotes and remotes:WaitForChild("UpdateMovementState", 10)
local RE_Jump     = remotes and remotes:WaitForChild("RequestJump", 10)

if RE_MovState then
	RE_MovState.OnClientEvent:Connect(function(state)
		if state == "Slide"         then isSliding = true
		elseif state == "SlideEnd"  then isSliding = false
		elseif state == "SlideJump" then isSliding = false
		elseif state == "Crouch"    then isCrouching = true
		elseif state == "CrouchEnd" then isCrouching = false; isSliding = false
		end
	end)
end

-- Something else is driving the root physically (dash/slide BodyVelocity, ragdoll).
-- While true, this layer keeps its hands off speed entirely.
local function externallyDriven()
	if not hrp then return true end
	if isSliding then return true end
	for _, c in ipairs(hrp:GetChildren()) do
		if c:IsA("BodyVelocity") or c:IsA("BodyMover") then return true end
		if c:IsA("LinearVelocity") and c.Name ~= "MF_StopSlide" then return true end
	end
	return false
end

local function horizontalSpeed()
	if not hrp then return 0 end
	local v = hrp.AssemblyLinearVelocity
	return Vector3.new(v.X, 0, v.Z).Magnitude
end

local function isGrounded()
	return hum ~= nil and hum.FloorMaterial ~= Enum.Material.Air
end

--=============================================================================
-- PART ONE -- acceleration / deceleration ramp
--=============================================================================
-- Roblox applies WalkSpeed instantly, which is the whole "sterile test dummy" problem.
-- We ramp toward whatever speed the SERVER last authorised instead of snapping to it.
--
-- The server (and InputHandler's own prediction) writes hum.WalkSpeed directly. We detect
-- any write that wasn't ours by comparing against the last value we wrote, and adopt it as
-- the new target. That keeps every existing multiplier -- injury, rage, caste, low-health,
-- crouch, sprint -- fully authoritative; we only control the approach to the number.
local targetSpeed, currentSpeed, lastWritten

local function resetRamp()
	targetSpeed, currentSpeed, lastWritten = nil, nil, nil
end

-- ── slide-to-a-stop ──
local stopLV, stopAttach, stopVec, stopUntil = nil, nil, Vector3.zero, 0

local function killStopSlide()
	if stopLV then stopLV:Destroy(); stopLV = nil end
	stopVec, stopUntil = Vector3.zero, 0
end

local function beginStopSlide(vel)
	if not (ACC.StopSlide and hrp) then return end
	killStopSlide()
	if not stopAttach or stopAttach.Parent ~= hrp then
		stopAttach = hrp:FindFirstChild("MF_StopAttach")
		if not stopAttach then
			stopAttach = Instance.new("Attachment")
			stopAttach.Name = "MF_StopAttach"
			stopAttach.Parent = hrp
		end
	end
	local lv = Instance.new("LinearVelocity")
	lv.Name = "MF_StopSlide"
	lv.Attachment0 = stopAttach
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.MaxForce = 12000
	lv.VectorVelocity = vel
	lv.Parent = hrp
	stopLV   = lv
	stopVec  = vel
	stopUntil = os.clock() + (ACC.StopSlideMaxTime or 0.35)
end

local wasMoving = false

local function updateSpeedRamp(dt)
	if not (ACC.Enabled and hum and hrp) then return end

	if externallyDriven() then
		-- Slide/dash owns the root; drop our ramp so we re-sync cleanly when it ends.
		resetRamp(); killStopSlide(); wasMoving = false
		return
	end

	local ws = hum.WalkSpeed
	if lastWritten == nil or math.abs(ws - lastWritten) > 0.01 then
		-- Someone else (server / InputHandler prediction) set the speed: that's the new target.
		targetSpeed = ws
		if currentSpeed == nil then currentSpeed = ws end
		-- A big authoritative DROP is a lockout (stagger, guard break, crouch snap). Ramping
		-- through a lockout would let the player glide out of it, so apply those instantly.
		if (currentSpeed - targetSpeed) >= (ACC.HardStopDrop or 8) then
			currentSpeed = targetSpeed
		end
	end
	if targetSpeed == nil or currentSpeed == nil then return end

	local grounded = isGrounded()
	local rising   = currentSpeed < targetSpeed
	local rate
	if grounded then
		rate = rising and (ACC.GroundAcceleration or 80) or (ACC.GroundDeceleration or 60)
	else
		rate = rising and (ACC.AirAcceleration or 25) or (ACC.AirDeceleration or 10)
	end

	local diff = targetSpeed - currentSpeed
	if math.abs(diff) <= (ACC.SnapThreshold or 0.35) then
		currentSpeed = targetSpeed
	else
		currentSpeed = currentSpeed + (diff > 0 and 1 or -1) * math.min(math.abs(diff), rate * dt)
	end

	hum.WalkSpeed = currentSpeed
	lastWritten   = currentSpeed

	-- ── carry-through on release ──
	-- Roblox halts the Humanoid dead the frame MoveDirection hits zero, so the ramp above
	-- can only sell acceleration, never a skid. Apply a short decaying velocity instead.
	if not ACC.StopSlide then return end
	local moving = hum.MoveDirection.Magnitude > 0.05
	local speed  = horizontalSpeed()

	if wasMoving and not moving and grounded and not isCrouching
	   and speed >= (ACC.StopSlideMinSpeed or 18) then
		local v = hrp.AssemblyLinearVelocity
		beginStopSlide(Vector3.new(v.X, 0, v.Z))
	end
	wasMoving = moving

	if stopLV then
		-- Any of these means the skid is no longer wanted -- cancel immediately.
		if moving or not grounded or isSliding or os.clock() >= stopUntil then
			killStopSlide()
		else
			stopVec = stopVec * math.max(0, 1 - (ACC.StopSlideDecay or 9) * dt)
			if stopVec.Magnitude < 2 then
				killStopSlide()
			else
				stopLV.VectorVelocity = stopVec
			end
		end
	end
end

--=============================================================================
-- PART FOUR -- coyote time & jump buffering
--=============================================================================
-- Pure input forgiveness. Neither path grants the client authority: the buffered jump
-- just re-fires the normal RequestJump once actually grounded, and the coyote jump asks
-- the Humanoid to jump locally (the server's own processJump already ran from
-- InputHandler's press and is a harmless no-op while airborne).
local lastGroundedAt = 0
local bufferedUntil  = 0
local coyoteUsed     = false

local function onJumpPressed()
	if not (JMP.Enabled and hum) then return end
	if isGrounded() then return end -- normal path; InputHandler already fired it

	local since = os.clock() - lastGroundedAt
	if not coyoteUsed and since <= (JMP.CoyoteTime or 0.1) then
		coyoteUsed = true
		hum:ChangeState(Enum.HumanoidStateType.Jumping)
	else
		bufferedUntil = os.clock() + (JMP.JumpBuffer or 0.12)
	end
end

UIS.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode == Enum.KeyCode.Space then onJumpPressed() end
end)

local wasGroundedJ = false
local function updateJump()
	if not (JMP.Enabled and hum) then return end
	local grounded = isGrounded()
	if grounded then
		lastGroundedAt = os.clock()
		coyoteUsed = false
		if not wasGroundedJ and os.clock() < bufferedUntil then
			bufferedUntil = 0
			killStopSlide()
			if RE_Jump then RE_Jump:FireServer() end
		end
	end
	wasGroundedJ = grounded
end

--=============================================================================
-- PART TWO/THREE/SEVEN -- camera: sprint FOV, lean, follow lag
--=============================================================================
-- FieldOfView used to be owned by CombatFeelClient, deleted in the combat teardown.
-- This is now the single writer. If the combat revamp wants FOV kicks it should go
-- through MovementFeel.addFOVPulse below rather than writing the camera directly.
local fovCurrent   = FOVC.Base or 70
local fovPulse     = 0
local leanCur      = 0
local lagOffset    = Vector3.zero
local prevDir      = nil

local MovementFeel = {}
function MovementFeel.addFOVPulse(amount, decayPerSec)
	fovPulse = fovPulse + (amount or 0)
	MovementFeel._pulseDecay = decayPerSec or 6
end
MovementFeel._pulseDecay = 6
_G.MovementFeel = MovementFeel

-- Camera.Value + 2 so this stacks AFTER MovementController's bob/dip/roll layer
-- (Camera.Value + 1) instead of fighting it -- same convention SanityEffectsClient
-- and FeelingsClient already use for their own camera passes.
RunService:BindToRenderStep("MovementFeelCamera", Enum.RenderPriority.Camera.Value + 2, function(dt)
	local camera = workspace.CurrentCamera
	if not (camera and hum and hrp) then return end

	local speed = horizontalSpeed()

	-- ── sprint FOV ──
	if FOVC.Enabled then
		local base  = FOVC.Base or 70
		local startS = FOVC.StartSpeed or 20
		local fullS  = FOVC.FullSpeed or 30
		local t = math.clamp((speed - startS) / math.max(0.01, fullS - startS), 0, 1)
		local want = base + (FOVC.SprintIncrease or 8) * t + fovPulse
		local alpha = 1 - math.exp(-(1 / math.max(0.01, FOVC.RampTime or 0.3)) * dt)
		fovCurrent = fovCurrent + (want - fovCurrent) * alpha
		fovPulse = fovPulse * math.max(0, 1 - MovementFeel._pulseDecay * dt)
		camera.FieldOfView = fovCurrent
	end

	-- ── lean into turns ──
	-- Camera roll only. Rolling the character model would fight the AlignOrientation
	-- facing override MovementController runs during slide/attack.
	local leanTarget = 0
	if LEAN.Enabled and speed >= (LEAN.MinSpeed or 14) then
		local v = hrp.AssemblyLinearVelocity
		local flat = Vector3.new(v.X, 0, v.Z)
		if flat.Magnitude > 0.1 then
			local dir = flat.Unit
			if prevDir then
				-- Signed turn rate about Y: positive = turning right.
				local turn = prevDir:Cross(dir).Y / math.max(dt, 1/240)
				local speedFactor = math.clamp(speed / 30, 0, 1)
				leanTarget = math.clamp(-turn * speedFactor * 2.2,
					-(LEAN.MaxLeanAngle or 8), (LEAN.MaxLeanAngle or 8))
			end
			prevDir = dir
		end
	else
		prevDir = nil
	end
	leanCur = leanCur + (leanTarget - leanCur) * math.min(1, (LEAN.Responsiveness or 6) * dt)
	if math.abs(leanCur) < 0.01 then leanCur = 0 end

	-- ── camera follow lag ──
	local wantOffset = Vector3.zero
	if LAG.Enabled and speed > 1 then
		local v = hrp.AssemblyLinearVelocity
		local flat = Vector3.new(v.X, 0, v.Z)
		if flat.Magnitude > 0.1 then
			local mag = math.min(speed * (LAG.FollowLag or 0.05), LAG.MaxOffset or 1.2)
			wantOffset = -flat.Unit * mag
		end
	end
	lagOffset = lagOffset:Lerp(wantOffset, math.min(1, 8 * dt))

	if leanCur ~= 0 or lagOffset.Magnitude > 0.001 then
		camera.CFrame = CFrame.new(camera.CFrame.Position + lagOffset)
			* (camera.CFrame - camera.CFrame.Position)
			* CFrame.Angles(0, 0, math.rad(leanCur))
	end
end)

--=============================================================================
-- Drivers
--=============================================================================
RunService.Heartbeat:Connect(function(dt)
	if not (hum and hrp and hum.Health > 0) then return end
	updateJump()
	updateSpeedRamp(dt)
end)

local function acquire(char)
	character = char
	hum = char:WaitForChild("Humanoid", 10)
	hrp = char:WaitForChild("HumanoidRootPart", 10)
	resetRamp()
	killStopSlide()
	stopAttach = nil
	isSliding, isCrouching = false, false
	leanCur, lagOffset, prevDir = 0, Vector3.zero, nil
	fovCurrent = FOVC.Base or 70
	fovPulse = 0
	coyoteUsed, bufferedUntil, wasMoving, wasGroundedJ = false, 0, false, false

	hum.Died:Connect(function()
		killStopSlide()
		resetRamp()
	end)
end

if player.Character then acquire(player.Character) end
player.CharacterAdded:Connect(acquire)

print("[MovementFeelClient] Loaded -- accel ramp, stop-slide, sprint FOV, lean, coyote+buffer, camera lag")
