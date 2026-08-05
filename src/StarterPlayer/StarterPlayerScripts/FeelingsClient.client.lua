-- FeelingsClient.client.lua -- renders the 5 short-lived emotional states (design doc PART
-- FIVE). Server only ever says "which feeling, right now" (TriggerFeeling); all duration/
-- fade timing lives here, driven by Config.Feelings so it can never drift from the numbers
-- FeelingsManager used to decide whether to fire it at all.

local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting   = game:GetService("Lighting")

local localPlayer = Players.LocalPlayer
local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))
local feelingsCfg = Config.Feelings

local playerGui = localPlayer:WaitForChild("PlayerGui")
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "FeelingsEffectsGui"
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 52
screenGui.ResetOnSpawn = false
screenGui.Parent = playerGui

-- ── State machine: per feeling, startedAt (fade-in anchor) + endsAt (duration expiry,
-- refreshed on re-trigger without restarting the fade-in -- see FeelingsManager's comment
-- on continuous conditions like Soothing/cliff-pull Fear). ───────────────────────────
local startedAt = {}
local endsAt = {}

local function intensityOf(feelingId)
	local ends = endsAt[feelingId]; if not ends then return 0 end
	local cfg = feelingsCfg[feelingId]; if not cfg then return 0 end
	local now = tick()
	local started = startedAt[feelingId] or now
	if now < started + feelingsCfg.FadeIn then
		return math.clamp((now - started) / feelingsCfg.FadeIn, 0, 1)
	elseif now < ends then
		return 1
	elseif now < ends + feelingsCfg.FadeOut then
		return math.clamp(1 - (now - ends) / feelingsCfg.FadeOut, 0, 1)
	else
		return 0
	end
end

local function playPlaceholderSound(soundId)
	if not soundId or soundId == "" then return end
	local char = localPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	local snd = Instance.new("Sound"); snd.SoundId = "rbxassetid://0" -- PLACEHOLDER_SOUND (see soundId arg for which)
	snd.Parent = hrp; snd:Play()
	snd.Ended:Once(function() snd:Destroy() end)
	task.delay(8, function() if snd.Parent then snd:Destroy() end end)
end

-- ── Screen flash (Anxiety / Fear / Rage-feeling) ─────────────────────────────────────
-- One shared vignette rig for ALL five feelings, built the same way RageClient builds its
-- rage overlay: a faint colored wash across the middle, and dark bands pressing in from every
-- border. Only the center COLOR changes per feeling. This replaces both the old per-feeling
-- full-screen flash frames and the old two-off Fear/Soothing vignettes.
--
-- Feelings can overlap (Fear + Paranoia, etc). Stacking several washes turns the screen to
-- mud, so each frame picks the single strongest active feeling and renders only that one.
local FEELING_COLOR = {
	Anxiety  = Color3.fromRGB(170,  85,  10), -- sickly amber, kept clear of Rage's red
	Fear     = Color3.fromRGB( 25,  35,  95), -- cold deep blue
	Rage     = Color3.fromRGB(200,  20,  20), -- red
	Paranoia = Color3.fromRGB(115,  25, 155), -- violet
	Soothing = Color3.fromRGB(255, 250, 240), -- white -- the one positive state
}
-- Soothing is a calm state, so it breathes slowly and its borders stay lighter than the
-- ominous feelings', which crush in hard.
local PULSE_PERIOD  = { Anxiety = 0.5, Fear = 0.8, Rage = 0.3, Paranoia = 1.6, Soothing = 3.0 }
local CENTER_REST   = { Soothing = 0.93 }
local EDGE_REST     = { Soothing = 0.62 }
local EDGE_PEAK     = { Soothing = 0.12 }

local centerWash = Instance.new("Frame")
centerWash.Name = "FeelingCenterWash"
centerWash.Size = UDim2.new(1, 0, 1, 0)
centerWash.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
centerWash.BackgroundTransparency = 1
centerWash.BorderSizePixel = 0
centerWash.ZIndex = 1
centerWash.Parent = screenGui

local function makeEdge(anchor, size, position, gradRotation)
	local f = Instance.new("Frame")
	f.BackgroundColor3 = Color3.fromRGB(0, 0, 0) -- borders are flat black for every feeling
	f.BorderSizePixel = 0
	f.AnchorPoint = anchor
	f.Size = size
	f.Position = position
	f.BackgroundTransparency = 1
	f.ZIndex = 2
	f.Parent = screenGui
	local grad = Instance.new("UIGradient")
	grad.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,0),NumberSequenceKeypoint.new(1,1)})
	grad.Rotation = gradRotation
	grad.Parent = f
	return f
end
local edges = {
	makeEdge(Vector2.new(0,0), UDim2.new(1,0,0.42,0), UDim2.new(0,0,0,0),  90),
	makeEdge(Vector2.new(0,1), UDim2.new(1,0,0.42,0), UDim2.new(0,0,1,0), -90),
	makeEdge(Vector2.new(0,0), UDim2.new(0.32,0,1,0), UDim2.new(0,0,0,0),   0),
	makeEdge(Vector2.new(1,0), UDim2.new(0.32,0,1,0), UDim2.new(1,0,0,0), 180),
}



-- ── Per-frame render loop: flashes, vignettes, screen shake, camera turns ─────────────
local paranoiaNextTurn = 0
local lastSoundPlayedAt = {}

RunService:BindToRenderStep("FeelingsCameraFX", Enum.RenderPriority.Camera.Value + 1, function()
	local now = tick()
	local cam = workspace.CurrentCamera
	local camOffset = CFrame.new()
	local domId, domIntensity = nil, 0 -- strongest active feeling wins the screen this frame

	for feelingId, cfg in pairs(feelingsCfg) do
		if type(cfg) == "table" then
			local intensity = intensityOf(feelingId)
			if FEELING_COLOR[feelingId] and intensity > domIntensity then
				domId, domIntensity = feelingId, intensity
			end
			if cfg.screenShake and intensity > 0 then
				local amp = math.rad(cfg.screenShake.intensity * 6 * intensity)
				local f = cfg.screenShake.frequency
				camOffset = camOffset * CFrame.Angles(
					math.sin(now*f) * amp, math.cos(now*f*1.3) * amp, math.sin(now*f*0.7) * amp)
			end
			if feelingId == "Paranoia" and cfg.cameraSubtleTurns and intensity > 0 then
				if now >= paranoiaNextTurn then
					paranoiaNextTurn = now + math.random(3,7)
					if cam then
						local jerk = CFrame.Angles(0, math.rad(math.random(-6,6)) * intensity, 0)
						local original = cam.CFrame
						cam.CFrame = original * jerk
						task.delay(0.2, function() if cam.CFrame == original*jerk then cam.CFrame = original end end)
					end
				end
				if cfg.soundOccasional and (now - (lastSoundPlayedAt[feelingId] or 0)) > math.random(8,15) then
					lastSoundPlayedAt[feelingId] = now
					playPlaceholderSound(cfg.soundOccasional)
				end
			end
		end
	end

	-- Render the winning feeling: colored middle, black borders, heartbeat-style pulse.
	if domId then
		local period = PULSE_PERIOD[domId] or 1.0
		local phase = (now % period) / period
		-- Same lub-dub envelope RageClient uses, so every feeling reads as a pulse rather than
		-- a flat wash. Soothing's long period turns the same curve into a slow breath.
		local beat = math.clamp(math.exp(-12 * phase) + 0.55 * math.exp(-12 * math.max(0, phase - 0.28)), 0, 1)
		centerWash.BackgroundColor3 = FEELING_COLOR[domId]
		local cRest = CENTER_REST[domId] or 0.90
		centerWash.BackgroundTransparency = 1 - ((1 - (cRest - 0.12 * beat)) * domIntensity)
		local eRest = EDGE_REST[domId] or 0.35
		local ePeak = EDGE_PEAK[domId] or 0.10
		local edgeT = eRest - (eRest - ePeak) * beat
		for _, e in ipairs(edges) do e.BackgroundTransparency = 1 - ((1 - edgeT) * domIntensity) end
	else
		centerWash.BackgroundTransparency = 1
		for _, e in ipairs(edges) do e.BackgroundTransparency = 1 end
	end

	if cam and camOffset ~= CFrame.new() then
		cam.CFrame = cam.CFrame * camOffset
	end
end)

-- Trigger handling.
-- The old blocky "hooded figure" silhouette GUI (head/shoulder/robe rectangles plus drifting
-- dots) that flickered in over the screen has been removed entirely, along with the
-- BlurEffect that sold its flicker. The vignette above is now the whole visual language for
-- feelings: colored middle, black borders.

Remotes.TriggerFeeling.OnClientEvent:Connect(function(payload)
	if not payload or not payload.feelingId then return end
	local feelingId = payload.feelingId
	local cfg = feelingsCfg[feelingId]; if not cfg then return end
	local now = tick()
	-- Same feeling refreshes duration, does not stack magnitude (design doc PART FIVE) --
	-- only replay the fade-in if it had actually fully faded out since the last trigger.
	local wasFullyFaded = (endsAt[feelingId] == nil) or (now > endsAt[feelingId] + feelingsCfg.FadeOut)
	if wasFullyFaded then startedAt[feelingId] = now end
	endsAt[feelingId] = now + cfg.duration
	if cfg.sound then playPlaceholderSound(cfg.sound) end
end)

print("[FeelingsClient] Loaded")
