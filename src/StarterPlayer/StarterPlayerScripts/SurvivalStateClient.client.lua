-- SurvivalStateClient
-- Continuous state-driven screen/audio feedback: Stamina Exhaustion (Part Seven) and
-- Low HP (Part Eight). Both are threshold effects, not per-hit reactions, so they live
-- separately from CombatFeelClient (hit-reactive) and HUDManager (bar numbers).

local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local Lighting   = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Remotes = require(RepStorage:WaitForChild("Shared",10):WaitForChild("RemoteEvents",10))
local player  = Players.LocalPlayer

-- PLACEHOLDER_GUI: SurvivalVignette — approximated with ColorCorrectionEffect saturation
-- dip (whole-screen) until a real radial vignette texture/shader is authored.
local cc = Instance.new("ColorCorrectionEffect")
cc.Name = "SurvivalStateCC"
cc.Brightness = 0
cc.Contrast = 0
cc.Saturation = 0
cc.Parent = Lighting

-- Exhaustion: a flickering blur (blurs in, unblurs, blurs again) rather than a steady
-- vignette — reads as disorientation/gasping-for-breath instead of a static overlay.
local exhaustBlur = Instance.new("BlurEffect")
exhaustBlur.Name = "ExhaustionBlur"
exhaustBlur.Size = 0
exhaustBlur.Parent = Lighting

-- Starvation/dehydration: a brief blur pulse every 30s while Hunger AND Water are both
-- fully depleted (the same condition that also zeroes HP regen entirely, see StaminaManager's
-- healMultiplier) -- distinct from the exhaustion flicker above (a one-shot "a bit blurry"
-- pulse, not a continuous strobe).
local starveBlur = Instance.new("BlurEffect")
starveBlur.Name = "StarvationBlur"
starveBlur.Size = 0
starveBlur.Parent = Lighting

local hunger, water = 100, 100
local nextStarvePulse = 0
local starvePulseActive = false

local function pulseStarveBlur()
	if starvePulseActive then return end
	starvePulseActive = true
	TweenService:Create(starveBlur, TweenInfo.new(0.4), {Size = 14}):Play()
	task.delay(0.6, function()
		local tw = TweenService:Create(starveBlur, TweenInfo.new(1.2), {Size = 0})
		tw:Play()
		tw.Completed:Once(function() starvePulseActive = false end)
	end)
end

local blurOn = false
local nextFlicker = 0

local MovementSounds = RepStorage:WaitForChild("_Sounds", 5):WaitForChild("Movement", 5)
local function movementSoundId(name)
	local snd = MovementSounds:FindFirstChild(name)
	local id = snd and snd.SoundId
	if not id or id == "" or id == "rbxassetid://0" then return "" end
	return id
end

local breathingSound = Instance.new("Sound")
breathingSound.Name = "ExhaustionBreathing"
breathingSound.SoundId = movementSoundId("exhausted_breathing")
breathingSound.Looped = true
breathingSound.Volume = 0.4
breathingSound.Parent = SoundService

local heartbeatSound = Instance.new("Sound")
heartbeatSound.Name = "LowHPHeartbeat"
heartbeatSound.SoundId = movementSoundId("heartbeat_low")
heartbeatSound.Looped = true
heartbeatSound.Volume = 0.3
heartbeatSound.Parent = SoundService

local isExhausted = false
local hpFrac = 1

Remotes.UpdateHUD.OnClientEvent:Connect(function(data)
	if data.Hunger ~= nil then hunger = data.Hunger end
	if data.Water  ~= nil then water  = data.Water end
	if data.Stamina ~= nil then
		local wasExhausted = isExhausted
		-- Mirrors StaminaManager's thresholds: drain() refuses unaffordable actions, so stamina
		-- realistically bottoms out near the cheapest action cost rather than exactly 0.
		if data.Stamina < 4 then isExhausted = true
		elseif isExhausted and data.Stamina > 15 then isExhausted = false end
		if isExhausted and not wasExhausted then
			if breathingSound.SoundId ~= "" then breathingSound:Play() end
			-- PLACEHOLDER_ANIMATION: exhaustion_hunch — replace with actual AnimationId
		elseif wasExhausted and not isExhausted then
			breathingSound:Stop()
		end
	end
end)

local hpAccum = 0
RunService.Heartbeat:Connect(function(dt)
	hpAccum += dt
	if hpAccum < 0.2 then return end
	hpAccum = 0

	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.MaxHealth <= 0 then return end
	local targetFrac = hum.Health / hum.MaxHealth
	hpFrac = hpFrac + (targetFrac - hpFrac) * 0.3 -- smooth so bar jitter doesn't flicker the effect

	local lowHP = hpFrac < 0.2
	if lowHP and heartbeatSound.SoundId ~= "" and not heartbeatSound.Playing then heartbeatSound:Play() end
	if not lowHP and heartbeatSound.Playing then heartbeatSound:Stop() end

	-- Fade the low-HP effect smoothly around its threshold rather than a hard cut
	local lowHPAmount = lowHP and (1 - hpFrac/0.2) or 0 -- 0..1 as HP drops toward 0 below the 20% line
	cc.Saturation = -0.35 * lowHPAmount -- no red vignette per spec, just desaturation

	-- Exhaustion flicker blur: irregular strobing between blurred and clear
	if isExhausted then
		if tick() >= nextFlicker then
			blurOn = not blurOn
			nextFlicker = tick() + (blurOn and (0.08 + math.random()*0.10) or (0.15 + math.random()*0.15))
		end
		exhaustBlur.Size = blurOn and (10 + math.random()*4) or 0
	else
		blurOn = false
		exhaustBlur.Size = 0
	end

	-- Starvation blur pulse: fires immediately on entering the state, then every 30s
	if hunger <= 0 and water <= 0 then
		if tick() >= nextStarvePulse then
			nextStarvePulse = tick() + 30
			pulseStarveBlur()
		end
	else
		nextStarvePulse = 0
	end
end)

print("[SurvivalStateClient] ready")
