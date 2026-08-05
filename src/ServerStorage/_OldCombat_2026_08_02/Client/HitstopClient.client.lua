-- HitstopClient
-- Server-coordinated freeze: on a landed hit, both attacker and target receive this
-- individually and freeze their OWN character (animation pause + brief anchor). Since
-- Roblox replicates animation/physics state to everyone else automatically, bystanders
-- see the freeze too without needing their own copy of the event.

local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = require(RepStorage:WaitForChild("Shared",10):WaitForChild("RemoteEvents",10))
local player  = Players.LocalPlayer

-- Hitstops can overlap (e.g. multiple hits landing within the same M1 chain window).
-- A depth counter ensures the character is only un-anchored once the LAST overlapping
-- hitstop resolves — otherwise a second hitstop starting mid-freeze would capture
-- Anchored=true as "the original state" and leave the character frozen forever.
local hitstopDepth = 0
local wasAnchoredBeforeHitstop = false
local frozenCameraCFrame = nil
local CAMERA_LOCK_BINDING = "HitstopCameraLock"

-- Locks the camera in place for the duration of the freeze so it can't be spun/panned
-- away mid-hitstop. Does NOT flip CameraType to Scriptable (the previous approach) --
-- Roblox's own default PlayerModule.CameraModule reacts to any CameraType change by
-- force-unlocking the mouse (CameraUtils.restoreMouseBehavior) and disabling/Reset()-ing
-- the active camera controller whenever CameraType becomes Scriptable (see
-- CameraModule:OnCameraTypeChanged/ActivateCameraController) -- that stock behavior is
-- exactly what was breaking shiftlock (mouse went free, camera reset) on every hit.
-- Instead, snapshot the CFrame and re-stomp it every frame just AFTER the default camera
-- script runs (RenderPriority.Camera+1) via BindToRenderStep -- CameraType/MouseBehavior
-- are never touched, so shiftlock's own lock-centered state is left completely alone.
local function applyHitstop(duration)
	local char = player.Character
	if not char then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local hrp = char:FindFirstChild("HumanoidRootPart")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	if not animator or not hrp then return end

	local camera = workspace.CurrentCamera
	if hitstopDepth == 0 then
		wasAnchoredBeforeHitstop = hrp.Anchored
		if camera then
			frozenCameraCFrame = camera.CFrame
			RunService:BindToRenderStep(CAMERA_LOCK_BINDING, Enum.RenderPriority.Camera.Value + 1, function()
				camera.CFrame = frozenCameraCFrame
			end)
		end
	end
	hitstopDepth += 1
	hrp.Anchored = true

	local tracks = animator:GetPlayingAnimationTracks()
	for _, t in ipairs(tracks) do
		pcall(function() t:AdjustSpeed(0) end)
	end

	task.delay(duration, function()
		hitstopDepth = math.max(0, hitstopDepth - 1)
		for _, t in ipairs(tracks) do
			pcall(function() if t.IsPlaying then t:AdjustSpeed(1) end end)
		end
		if hitstopDepth == 0 then
			if hrp and hrp.Parent then
				hrp.Anchored = wasAnchoredBeforeHitstop
			end
			RunService:UnbindFromRenderStep(CAMERA_LOCK_BINDING)
		end
	end)
end

-- Hitstop removed entirely per owner request (2026-07-18, combat polish 4A) -- no longer
-- connected; applyHitstop above is now dead code, left in place only for git-style history
-- rather than editing this whole file down to a stub.
-- Remotes.Hitstop.OnClientEvent:Connect(applyHitstop)

print("[HitstopClient] disabled (hitstop removed)")
