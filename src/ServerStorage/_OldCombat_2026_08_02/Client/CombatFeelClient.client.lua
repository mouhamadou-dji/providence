-- CombatFeelClient
-- Victim/attacker-only perception effects driven off the server's OnHit payload:
-- concussion mirage + camera flinch (heavy hits taken), kill confirmation sound (heavy
-- hits landed that down the target). Bystanders don't need these — they're personal,
-- so they ride the existing OnHit remote (already fires individually to both sides)
-- instead of a broadcast.

local Players     = game:GetService("Players")
local RepStorage  = game:GetService("ReplicatedStorage")
local RunService  = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Debris      = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local Remotes = require(RepStorage:WaitForChild("Shared",10):WaitForChild("RemoteEvents",10))
local player  = Players.LocalPlayer

-- OnDashDenied isn't in the Shared.RemoteEvents module list, so grab it straight off the
-- RemoteEvents folder the same way InputHandler/MovementController already do for their
-- own movement remotes.
local RE_DashDenied = RepStorage:WaitForChild("RemoteEvents", 10):WaitForChild("OnDashDenied", 10)
local RE_SlideDenied = RepStorage:WaitForChild("RemoteEvents", 10):WaitForChild("OnSlideDenied", 10)

-- ── Concussion Mirage: ghost afterimages of the attacker, heavy hits only ────────
local function spawnMirage(attackerName)
	local attacker = Players:FindFirstChild(attackerName)
	local aChar = attacker and attacker.Character
	local aHRP = aChar and aChar:FindFirstChild("HumanoidRootPart")
	if not aChar or not aHRP then return end

	for _, side in ipairs({-1, 1}) do
		local ok, clone = pcall(function() return aChar:Clone() end)
		if ok and clone then
			clone.Name = "ConcussionMirage"
			for _, d in ipairs(clone:GetDescendants()) do
				if d:IsA("BasePart") then
					d.CanCollide = false; d.CanQuery = false; d.Anchored = true
					d.Transparency = 1 - (1-d.Transparency)*0.45
				elseif d:IsA("Script") or d:IsA("LocalScript") or d:IsA("Highlight") then
					d:Destroy()
				end
			end
			local cloneHRP = clone:FindFirstChild("HumanoidRootPart")
			if cloneHRP then
				clone:PivotTo(aHRP.CFrame + aHRP.CFrame.RightVector * (side * 1.5))
			end
			clone.Parent = workspace
			task.spawn(function()
				local steps = 8
				for i = 1, steps do
					task.wait(0.4/steps)
					for _, d in ipairs(clone:GetDescendants()) do
						if d:IsA("BasePart") then
							d.Transparency = d.Transparency + (1-d.Transparency)*(1/(steps-i+1))
						end
					end
				end
				clone:Destroy()
			end)
		end
	end
end

-- ── Unified camera-feel render step: flinch kick, camera lag, FOV kick ───────────
-- All three live in one RenderStepped binding (after the default camera module runs)
-- so they compose cleanly instead of fighting each other across separate bindings.
local BASE_FOV        = 70
local SPRINT_FOV      = 78
local M2_PUNCHIN_FOV  = 66
local CAMERA_LAG_ALPHA = 0.88 -- 0.85-0.9 per spec: how much of the smoothed CFrame persists each frame

local flinchOffset   = CFrame.new()
local fovPunchUntil  = 0
local fovPunchStart  = 0
local currentFOV     = BASE_FOV
local laggedCFrame   = nil

local UGS = UserSettings():GetService("UserGameSettings")
local function isShiftlocked()
	-- Was previously proxied off Humanoid.AutoRotate==false, but MovementController's
	-- attack turn-cap also disables AutoRotate for an unrelated reason (capping rotation
	-- speed mid-swing), which falsely tripped this and killed camera lag every M1. Check
	-- actual shiftlock state (set by MovementController's setShiftlock) instead.
	return UGS.RotationType == Enum.RotationType.CameraRelative
end

local function isSprinting()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	-- Sprint WalkSpeed is 25 (Config.Speed.Sprint) vs base 16 — all WalkSpeed changes
	-- already route through one place server-side, so this is a reliable proxy.
	return hum ~= nil and hum.WalkSpeed >= 20
end

local function triggerM2PunchIn()
	fovPunchStart = tick()
	fovPunchUntil = tick() + 0.2
end

RunService:BindToRenderStep("CombatFeelCamera", Enum.RenderPriority.Camera.Value + 1, function()
	local camera = workspace.CurrentCamera
	if not camera then return end

	-- Camera lag disabled: it made the out-of-shiftlock camera feel like a sluggish "old"
	-- camera compared to shiftlock (which always ran alpha=0, i.e. the raw Roblox camera) --
	-- always use the true transform now so both modes feel the same snappy way.
	local trueCFrame = camera.CFrame
	if not laggedCFrame then laggedCFrame = trueCFrame end
	local alpha = 0
	laggedCFrame = laggedCFrame:Lerp(trueCFrame, 1 - alpha)
	camera.CFrame = laggedCFrame * flinchOffset

	-- FOV: sprint-momentum widen, dash pulse, slide widen, or M2-hit punch-in (punch-in
	-- wins while active). Dash/slide state comes from MovementController's shared feel
	-- flags so this stays the ONE place FieldOfView is ever written.
	local targetFOV = BASE_FOV
	if tick() < fovPunchUntil then
		local t = (tick()-fovPunchStart)/0.2
		targetFOV = t < 0.5 and BASE_FOV + (M2_PUNCHIN_FOV-BASE_FOV)*(t/0.5)
			or M2_PUNCHIN_FOV + (BASE_FOV-M2_PUNCHIN_FOV)*((t-0.5)/0.5)
	elseif isSprinting() then
		targetFOV = SPRINT_FOV
	end
	if _G.MovementFeelDashUntil and tick() < _G.MovementFeelDashUntil then
		targetFOV = math.max(targetFOV, BASE_FOV + 7) -- quick dash punch-out
	end
	local mc = _G.MovementController
	if mc and mc.isSliding and mc.isSliding() then
		targetFOV = math.max(targetFOV, BASE_FOV + 5) -- slides read faster than they are
	end
	currentFOV = currentFOV + (targetFOV-currentFOV) * 0.18
	camera.FieldOfView = currentFOV
end)

local function triggerFlinch(hitPos)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local camera = workspace.CurrentCamera
	if not hrp or not camera then return end
	local toHit = (hitPos and (hitPos - hrp.Position)) or camera.CFrame.LookVector
	local sign = (toHit:Dot(camera.CFrame.RightVector) >= 0) and 1 or -1
	local kick = CFrame.Angles(math.rad(0.5), math.rad(0.5*sign), 0)
	local startTick = tick()
	local duration = 0.15
	task.spawn(function()
		while true do
			local t = (tick()-startTick)/duration
			if t >= 1 then flinchOffset = CFrame.new(); break end
			flinchOffset = kick:Lerp(CFrame.new(), t)
			task.wait()
		end
	end)
end

-- ── Dash Denied: a quick unmistakable "nope" pulse when dash is silently blocked by
-- cooldown or stamina, so a rejected dash doesn't read as "randomly not working" ──────
local deniedGui, deniedFrame
local function ensureDeniedGui()
	if deniedGui and deniedGui.Parent then return end
	local playerGui = player:WaitForChild("PlayerGui")
	deniedGui = Instance.new("ScreenGui")
	deniedGui.Name = "DashDeniedGui"
	deniedGui.IgnoreGuiInset = true
	deniedGui.ResetOnSpawn = false
	deniedGui.DisplayOrder = 5
	deniedGui.Parent = playerGui
	deniedFrame = Instance.new("Frame")
	deniedFrame.Size = UDim2.fromScale(1, 1)
	deniedFrame.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
	deniedFrame.BackgroundTransparency = 1
	deniedFrame.BorderSizePixel = 0
	deniedFrame.Parent = deniedGui
end

local function playDashDenied()
	ensureDeniedGui()
	deniedFrame.BackgroundTransparency = 0.75
	local tw = TweenService:Create(deniedFrame, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {BackgroundTransparency = 1})
	tw:Play()
end

RE_DashDenied.OnClientEvent:Connect(playDashDenied)
-- Slide's post-slide cooldown reuses the same "nope" flash as dash denial -- same kind of
-- silently-blocked-input problem, no need for a second visual language.
RE_SlideDenied.OnClientEvent:Connect(playDashDenied)

-- ── Kill Confirmation──────────────────
-- ── Parry sounds: metallic ring on Perfect, a duller whiff sound otherwise ───────
local CombatSoundsFolder = RepStorage:WaitForChild("_Sounds", 5)
local CombatSoundsF = CombatSoundsFolder and CombatSoundsFolder:FindFirstChild("Combat")
local function combatSoundId(name)
	local snd = CombatSoundsF and CombatSoundsF:FindFirstChild(name)
	local id = snd and snd.SoundId
	if not id or id == "" or id == "rbxassetid://0" then return nil end
	return id
end

-- Destroy once actually finished, not on a fixed timer -- a fixed Debris delay can destroy
-- the instance before a slower-to-stream asset ever finishes (or even starts) playing,
-- which is what read as parry/kill-confirm sounds "sometimes not playing." task.delay is
-- only a safety net for sounds that never fire Ended (e.g. a failed/unauthorized load).
local function cleanupSoundOnEnded(snd, maxWait)
	local cleaned = false
	local function cleanup() if not cleaned then cleaned = true; if snd.Parent then snd:Destroy() end end end
	snd.Ended:Once(cleanup)
	task.delay(maxWait or 8, cleanup)
end

local function playKillConfirm()
	local id = combatSoundId("kill_confirm")
	if not id then return end
	local snd = Instance.new("Sound")
	snd.SoundId = id
	snd.Volume = 0.5
	snd.RollOffMaxDistance = 0 -- 2D, heard only by the attacker
	snd.Parent = SoundService
	snd:Play()
	cleanupSoundOnEnded(snd)
end

local function play2D(id, volume, pitchVary)
	if not id then return end
	local snd = Instance.new("Sound")
	snd.SoundId = id
	snd.Volume = volume
	if pitchVary then snd.PlaybackSpeed = 0.98 + math.random()*0.1 end
	snd.RollOffMaxDistance = 0
	snd.Parent = SoundService
	snd:Play()
	cleanupSoundOnEnded(snd)
end

-- ── Stagger (got parried, lost a clash, or interrupted mid-air-crit): the server already
-- slows you to 30% speed and blocks M1/M2 for the stagger duration (see CombatManager's
-- applyStagger + isActionBlocked), but nothing ever told the player it happened -- the
-- RE_OnStagger remote fired into the void with zero listeners, so a real stun landed with
-- no flash, nothing. No sound here on purpose -- a parry already has its own sound
-- (Parry_Perfect/Late), so the victim doesn't need a second cue for the same moment.
local staggerGui, staggerFrame
local function ensureStaggerGui()
	if staggerGui and staggerGui.Parent then return end
	local playerGui = player:WaitForChild("PlayerGui")
	staggerGui = Instance.new("ScreenGui")
	staggerGui.Name = "StaggerGui"
	staggerGui.IgnoreGuiInset = true
	staggerGui.ResetOnSpawn = false
	staggerGui.DisplayOrder = 5
	staggerGui.Parent = playerGui
	staggerFrame = Instance.new("Frame")
	staggerFrame.Size = UDim2.fromScale(1, 1)
	staggerFrame.BackgroundColor3 = Color3.fromRGB(160, 30, 20)
	staggerFrame.BackgroundTransparency = 1
	staggerFrame.BorderSizePixel = 0
	staggerFrame.Parent = staggerGui
end

local function playStaggerFeedback(data)
	ensureStaggerGui()
	staggerFrame.BackgroundTransparency = 0.6
	TweenService:Create(staggerFrame, TweenInfo.new(math.clamp((data.duration or 0.5)*0.4, 0.15, 0.5), Enum.EasingStyle.Quad), {BackgroundTransparency = 1}):Play()
	triggerFlinch()
end

Remotes.OnStagger.OnClientEvent:Connect(playStaggerFeedback)

Remotes.OnParryResult.OnClientEvent:Connect(function(data)
	if data.result == "Perfect" then
		play2D(combatSoundId("Parry_Perfect"), 0.5, true)
	elseif data.result == "Whiff" then
		play2D(combatSoundId("Parry_Whiff"), 0.35, true)
	elseif data.result == "Late" then
		play2D(combatSoundId("Parry_Late"), 0.35, true)
	end
end)

Remotes.OnHit.OnClientEvent:Connect(function(data)
	if data.attackerName then
		-- this copy of the event was sent to the victim (me)
		if data.heavy then
			spawnMirage(data.attackerName)
			triggerFlinch(data.hitPosition)
		end
	elseif data.victimName then
		-- this copy of the event was sent to the attacker (me)
		if data.downed then playKillConfirm() end
		if data.attackType == "M2" then triggerM2PunchIn() end
	end
end)

-- Exposed so purely-client-side combat (ShadowBoxClient's practice shadow) can reuse the
-- exact same feel primitives instead of duplicating them. This script stays the sole owner
-- of the camera CFrame/FieldOfView -- callers request an effect, they never write the camera.
_G.CombatFeel = {
	flinch    = triggerFlinch,
	m2PunchIn = triggerM2PunchIn,
	stagger   = playStaggerFeedback,
	mirage    = spawnMirage,
	play2D    = play2D,
	soundId   = combatSoundId,
}

print("[CombatFeelClient] ready")
