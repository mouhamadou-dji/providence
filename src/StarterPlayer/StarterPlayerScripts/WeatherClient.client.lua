-- WeatherClient — Module 12 client (expanded: full weather palette, particles, frost, lightning, sandstorm)
local RepStorage   = game:GetService("ReplicatedStorage")
local Lighting     = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local RunService   = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Players      = game:GetService("Players")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local TWEEN_DURATION = Config.WeatherTransitionDuration or 5
local PROFILE_TWEEN  = TweenInfo.new(TWEEN_DURATION, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
local FOG_TWEEN      = TweenInfo.new(2.0, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
-- Time-of-day ticks arrive every ~2s from the server's ever-advancing day cycle (independent
-- of weather changes). Reusing the full 5s PROFILE_TWEEN for those would restart a fresh
-- 5s tween every 2s forever -- the value perpetually chases its target and never actually
-- settles. This shorter tween (~matching the tick cadence) converges instead of chasing.
local CLOCK_TWEEN    = TweenInfo.new(2.5, Enum.EasingStyle.Linear)

local WeatherFolder = RepStorage:WaitForChild("_Sounds", 5):WaitForChild("Weather", 5)
local FrostSoundFolder = RepStorage:WaitForChild("_Sounds", 5):FindFirstChild("Frost")
local WEATHER_FADE  = 2
local currentWeatherSound = nil

local function playWeatherSound(weatherType)
	local soundName = Config.WeatherAmbientSounds[weatherType]
	local soundInst  = soundName and WeatherFolder:FindFirstChild(soundName)
	local id = soundInst and soundInst.SoundId
	local previous = currentWeatherSound

	if previous then
		TweenService:Create(previous, TweenInfo.new(WEATHER_FADE), { Volume = 0 }):Play()
		task.delay(WEATHER_FADE, function() previous:Destroy() end)
		currentWeatherSound = nil
	end

	if not id or id == "" or id == "rbxassetid://0" then return end

	local snd = Instance.new("Sound")
	snd.SoundId = id
	snd.Looped = true
	snd.Volume = 0
	snd.Parent = SoundService
	snd:Play()
	currentWeatherSound = snd
	TweenService:Create(snd, TweenInfo.new(WEATHER_FADE), { Volume = 0.35 }):Play()
end

-- ==================== LIGHTING / ATMOSPHERE / COLOR CORRECTION ====================

local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
-- Look up by NAME, not FindFirstChildOfClass -- other systems (e.g. SurvivalStateClient's
-- own "SurvivalStateCC" for its low-HP desaturation vignette) also create their own
-- ColorCorrectionEffect instances in Lighting. Grabbing "any" one of that class risks
-- silently hijacking a different system's instance and fighting over the same
-- properties (this actually happened: Saturation was oscillating because this script
-- and SurvivalStateClient's Heartbeat were both writing to the SAME instance).
local colorCorrection = Lighting:FindFirstChild("WeatherColorCorrection")
if not colorCorrection then
	colorCorrection = Instance.new("ColorCorrectionEffect")
	colorCorrection.Name = "WeatherColorCorrection"
	colorCorrection.Parent = Lighting
end
-- Already authored on the map (real Sun/Moon textures, star count, etc) -- only their
-- Intensity is driven here, nothing else about them is touched.
local sunRaysEffect = Lighting:FindFirstChildOfClass("SunRaysEffect")
local bloomEffect    = Lighting:FindFirstChildOfClass("BloomEffect")

-- Shadows should always be on; only ShadowSoftness varies per weather (see
-- applyWeatherProfile). Defensive in case anything else in the game ever disables it.
Lighting.GlobalShadows = Config.Shadows.GlobalShadowsEnabled

-- Very slight depth of field: NearIntensity stays 0 (never blur anything close -- that's
-- where combat happens) and InFocusRadius is generous, so only distant background
-- scenery gets a gentle cinematic softening. Was disabled by default; enabling it here.
local dofEffect = Lighting:FindFirstChildOfClass("DepthOfFieldEffect")
if dofEffect then
	dofEffect.Enabled = true
	dofEffect.FocusDistance = Config.DepthOfField.FocusDistance
	dofEffect.InFocusRadius = Config.DepthOfField.InFocusRadius
	dofEffect.NearIntensity = Config.DepthOfField.NearIntensity
end

-- ==================== TIME OF DAY BLENDING ====================
-- Weather profiles define an absolute "clear noon" baseline; blend continuously against
-- Config.TimeOfDayProfiles by ClockTime so the same weather actually looks different at
-- dawn/dusk/night instead of rendering identically at any hour.

local currentClockTime = 12

local function tintColor(base, tint)
	return Color3.new(base.R * tint.R, base.G * tint.G, base.B * tint.B)
end

local function blendTimeOfDay(clockTime)
	local checkpoints = Config.TimeOfDayCheckpoints
	local n = #checkpoints
	local idx = n
	for i = 1, n do
		if clockTime < checkpoints[i].t then idx = i - 1; break end
	end
	if idx == 0 then idx = n end
	local cur = checkpoints[idx]
	local nxt = checkpoints[(idx % n) + 1]
	local t0, t1 = cur.t, nxt.t
	if t1 <= t0 then t1 += 24 end
	local ct = clockTime
	if ct < t0 then ct += 24 end
	local alpha = math.clamp((ct - t0) / (t1 - t0), 0, 1)
	local a = Config.TimeOfDayProfiles[cur.name]
	local b = Config.TimeOfDayProfiles[nxt.name]
	return {
		BrightnessMult = a.BrightnessMult + (b.BrightnessMult - a.BrightnessMult) * alpha,
		AmbientTint = a.AmbientTint:Lerp(b.AmbientTint, alpha),
		ColorCorrectionTint = a.ColorCorrectionTint:Lerp(b.ColorCorrectionTint, alpha),
		FogColorTint = a.FogColorTint:Lerp(b.FogColorTint, alpha),
		CloudColorTint = a.CloudColorTint:Lerp(b.CloudColorTint, alpha),
		SunRaysIntensity = a.SunRaysIntensity + (b.SunRaysIntensity - a.SunRaysIntensity) * alpha,
		MoonGlowIntensity = a.MoonGlowIntensity + (b.MoonGlowIntensity - a.MoonGlowIntensity) * alpha,
		BloomIntensity = a.BloomIntensity + (b.BloomIntensity - a.BloomIntensity) * alpha,
		BloomSize = a.BloomSize + (b.BloomSize - a.BloomSize) * alpha,
		CCBrightnessDelta = a.CCBrightnessDelta + (b.CCBrightnessDelta - a.CCBrightnessDelta) * alpha,
		CCContrastDelta = a.CCContrastDelta + (b.CCContrastDelta - a.CCContrastDelta) * alpha,
		CCSaturationDelta = a.CCSaturationDelta + (b.CCSaturationDelta - a.CCSaturationDelta) * alpha,
	}
end

local function setFogOnly(active, density, colorOverride)
	density = density or 0.3
	if active then
		local fogEnd = math.clamp(200 / math.max(density, 0.01), 50, 2000)
		TweenService:Create(Lighting, FOG_TWEEN, { FogEnd = fogEnd, FogStart = 0 }):Play()
		Lighting.FogColor = colorOverride or Color3.fromRGB(180, 180, 200)
	else
		TweenService:Create(Lighting, FOG_TWEEN, { FogEnd = 100000, FogStart = 0 }):Play()
	end
end

-- ==================== PARTICLES (camera-anchored, envelop the player) ====================
-- Positioned above the camera with identity rotation (position-only follow) so "falling
-- down" reads correctly in world space no matter which way the camera is looking --
-- rotating the anchor with the camera (as a naive CFrame follow would) makes rain/snow
-- appear to pour sideways whenever the camera pitches.

local FALL_TYPES = { Rain = true, HeavyRain = true, Thunderstorm = true, Storm = true, Snow = true, Hail = true }
local DRIFT_TYPES = { Snow = true, Hail = true }

local particleAnchor = Instance.new("Part")
particleAnchor.Name = "WeatherParticleAnchor"
particleAnchor.Anchored = true
particleAnchor.CanCollide = false
particleAnchor.CanQuery = false
particleAnchor.CanTouch = false
particleAnchor.CastShadow = false
particleAnchor.Transparency = 1
particleAnchor.Size = Vector3.new(30, 1, 30) -- kept tight so emitRate actually reads as dense weather, not a sparse sprinkle over a huge area
particleAnchor.Parent = workspace

RunService.RenderStepped:Connect(function()
	if not camera then return end
	local camPos = camera.CFrame.Position
	particleAnchor.CFrame = CFrame.new(camPos + Vector3.new(0, 14, 0))
end)

local particleEmitters = {}
local activeEmitter = nil

local function switchParticles(weatherType)
	local cfg = Config.WeatherParticles[weatherType]
	if activeEmitter then
		local old = activeEmitter
		TweenService:Create(old, TweenInfo.new(TWEEN_DURATION), { Rate = 0 }):Play()
		task.delay(TWEEN_DURATION, function() if old then old.Enabled = false end end)
		activeEmitter = nil
	end
	if not cfg then return end
	local isFalling = FALL_TYPES[weatherType]
	local isDrifting = DRIFT_TYPES[weatherType]
	local emitter = particleEmitters[weatherType]
	if not emitter then
		emitter = Instance.new("ParticleEmitter")
		emitter.Name = weatherType
		emitter.Shape = Enum.ParticleEmitterShape.Box
		emitter.ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward
		emitter.Parent = particleAnchor
		particleEmitters[weatherType] = emitter
	end

	if isFalling then
		-- Rain/hail: thin, fast, nearly-vertical streaks falling straight past the player.
		-- Snow: slow, wide drifting cone with gentle tumble.
		-- PLACEHOLDER_ASSET: real streak/snowflake textures -- sparkles reads better than smoke for snow
		emitter.Texture = isDrifting and "rbxasset://textures/particles/sparkles_main.dds"
			or "rbxasset://textures/particles/smoke_main.dds"
		emitter.EmissionDirection = Enum.NormalId.Bottom
		emitter.SpreadAngle = isDrifting and Vector2.new(25, 25) or Vector2.new(3, 3)
		emitter.RotSpeed = isDrifting and NumberRange.new(-90, 90) or NumberRange.new(0, 0)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.VelocityInheritance = 0
		emitter.LightEmission = isDrifting and 0.15 or 0.05
		emitter.Acceleration = isDrifting
			and Vector3.new((math.random() - 0.5) * 4, -6, (math.random() - 0.5) * 4)
			or Vector3.new(0, -math.min(workspace.Gravity * 0.9, 90), 0)
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(0.85, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		})
	else
		-- Enveloping atmosphere (sandstorm dust, blood rain haze, red mist) -- swirls around
		-- the player from all sides rather than falling in a single direction.
		emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
		emitter.EmissionDirection = Enum.NormalId.Top
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.RotSpeed = NumberRange.new(-40, 40)
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.VelocityInheritance = 0
		emitter.LightEmission = 0
		emitter.Acceleration = Vector3.new(0, -math.min(workspace.Gravity * 0.3, 30), 0)
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.2, 0.15),
			NumberSequenceKeypoint.new(0.8, 0.15),
			NumberSequenceKeypoint.new(1, 1),
		})
	end

	emitter.Color = ColorSequence.new(cfg.color)
	emitter.Size = NumberSequence.new(cfg.size)
	emitter.Lifetime = NumberRange.new(cfg.lifetime * 0.8, cfg.lifetime * 1.2)
	emitter.Speed = NumberRange.new(cfg.speed * 0.85, cfg.speed * 1.15)
	emitter.Rate = 0
	emitter.Enabled = true
	activeEmitter = emitter
	TweenService:Create(emitter, TweenInfo.new(TWEEN_DURATION), { Rate = cfg.emitRate }):Play()
end

-- ==================== SKY CLOUDS (Terrain.Clouds) ====================
-- Roblox's built-in Clouds instance renders a real animated sky layer (drifts on its
-- own) -- far better than faking cloud parts. Client-only, same as the rest of this
-- script's visual state, so each player's sky matches their own weather view.

local clouds = workspace.Terrain:FindFirstChildOfClass("Clouds")
if not clouds then
	clouds = Instance.new("Clouds")
	clouds.Cover = 0.35
	clouds.Density = 0.5
	clouds.Color = Color3.fromRGB(255, 255, 255)
	clouds.Parent = workspace.Terrain
end

local function refreshClouds(weatherType, cloudColorTint, tweenInfo)
	local cloudCfg = Config.WeatherClouds[weatherType]
	if not cloudCfg then return end
	local tint = cloudColorTint or Color3.fromRGB(255, 255, 255)
	TweenService:Create(clouds, tweenInfo or PROFILE_TWEEN, {
		Cover = cloudCfg.Cover,
		Density = cloudCfg.Density,
		Color = tintColor(cloudCfg.Color, tint),
	}):Play()
end

-- ==================== MOON GLOW ====================
-- SunRaysEffect is hardcoded to the Sun's own direction (Lighting:GetSunDirection() and
-- GetMoonDirection() are different vectors -- confirmed live in Studio: cranking
-- SunRaysEffect at night while facing the actual moon direction produced nothing), so it
-- physically cannot react to the Moon. This tracks the Moon's real screen position every
-- frame instead and draws a soft multi-ring glow there -- a genuine "where the moon
-- actually is" effect, not a fixed decoration.

local moonGlowGui = Instance.new("ScreenGui")
moonGlowGui.Name = "MoonGlow"
moonGlowGui.ResetOnSpawn = false
moonGlowGui.IgnoreGuiInset = true
moonGlowGui.DisplayOrder = -5 -- behind normal HUD, it's a background sky effect
moonGlowGui.Parent = player:WaitForChild("PlayerGui")

local moonGlowRings = {}
for i, scale in ipairs({ 1.0, 0.55, 0.25 }) do
	local ring = Instance.new("Frame")
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Size = UDim2.new(0, Config.MoonGlow.BaseSize * scale, 0, Config.MoonGlow.BaseSize * scale)
	ring.BackgroundColor3 = Config.MoonGlow.Color
	ring.BackgroundTransparency = 1
	ring.BorderSizePixel = 0
	ring.Visible = false
	ring.Parent = moonGlowGui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = ring
	moonGlowRings[i] = ring
end
-- Outer ring stays the most transparent, inner ring the brightest -- approximates a
-- radial falloff without needing an actual gradient texture asset.
local MOON_RING_BASE_TRANSPARENCY = { 0.9, 0.8, 0.65 }

local currentMoonGlowIntensity = 0

RunService.RenderStepped:Connect(function()
	if currentMoonGlowIntensity <= 0.01 then
		for _, ring in ipairs(moonGlowRings) do ring.Visible = false end
		return
	end
	local moonDir = Lighting:GetMoonDirection()
	local camPos = camera.CFrame.Position
	local screenPos, onScreen = camera:WorldToViewportPoint(camPos + moonDir * 1000)
	if not onScreen then
		for _, ring in ipairs(moonGlowRings) do ring.Visible = false end
		return
	end
	for i, ring in ipairs(moonGlowRings) do
		ring.Visible = true
		ring.Position = UDim2.new(0, screenPos.X, 0, screenPos.Y)
		ring.BackgroundTransparency = 1 - ((1 - MOON_RING_BASE_TRANSPARENCY[i]) * currentMoonGlowIntensity)
	end
end)

local function refreshMoonGlow(weatherType, moonGlowIntensity)
	local skyMod = Config.WeatherSkyMods[weatherType] or { MoonGlowMult = 1 }
	currentMoonGlowIntensity = math.clamp(moonGlowIntensity * (skyMod.MoonGlowMult or 1), 0, 1)
end

-- ==================== SANDSTORM BLUR ====================

local sandBlur = Instance.new("BlurEffect")
sandBlur.Name = "SandstormBlur"
sandBlur.Size = 0
sandBlur.Parent = Lighting

local mitigation = { clothing = "None", faceGear = "None" }

local function refreshSandstormBlur(weatherType)
	local target = 0
	if weatherType == "Sandstorm" then
		local mult = Config.Sandstorm.Mitigation[mitigation.faceGear] or 1.0
		target = Config.Sandstorm.BlurBase * mult
	end
	TweenService:Create(sandBlur, TweenInfo.new(TWEEN_DURATION), { Size = target }):Play()
	if weatherType == "Sandstorm" then
		TweenService:Create(colorCorrection, TweenInfo.new(TWEEN_DURATION), { TintColor = Color3.fromRGB(240, 200, 140) }):Play()
	end
end

-- ==================== HUD: weather icon + frost icon ====================

local hudGui = Instance.new("ScreenGui")
hudGui.Name = "WeatherHUD"
hudGui.ResetOnSpawn = false
hudGui.IgnoreGuiInset = true
hudGui.Parent = player:WaitForChild("PlayerGui")

local weatherIconLbl = Instance.new("TextLabel")
weatherIconLbl.Name = "WeatherIcon"
weatherIconLbl.AnchorPoint = Vector2.new(1, 0)
weatherIconLbl.Position = UDim2.new(1, -16, 0, 16)
weatherIconLbl.Size = UDim2.new(0, 120, 0, 26)
weatherIconLbl.BackgroundTransparency = 1
weatherIconLbl.TextColor3 = Color3.fromRGB(230, 225, 210)
weatherIconLbl.Font = Enum.Font.GothamMedium
weatherIconLbl.TextSize = 14
weatherIconLbl.TextXAlignment = Enum.TextXAlignment.Right
weatherIconLbl.TextTransparency = 1
weatherIconLbl.Text = ""
weatherIconLbl.Parent = hudGui
-- PLACEHOLDER_ASSET: WeatherIcon_<Type> images -- using text label until icon set exists

local function updateWeatherIcon(weatherType)
	weatherIconLbl.Text = "  " .. weatherType
	weatherIconLbl.TextTransparency = 1
	TweenService:Create(weatherIconLbl, TweenInfo.new(0.6), { TextTransparency = 0 }):Play()
	task.delay(4, function()
		TweenService:Create(weatherIconLbl, TweenInfo.new(1.0), { TextTransparency = 1 }):Play()
	end)
end

local frostIconLbl = Instance.new("TextLabel")
frostIconLbl.Name = "FrostIcon"
frostIconLbl.AnchorPoint = Vector2.new(1, 0)
frostIconLbl.Position = UDim2.new(1, -16, 0, 46)
frostIconLbl.Size = UDim2.new(0, 120, 0, 22)
frostIconLbl.BackgroundTransparency = 1
frostIconLbl.TextColor3 = Color3.fromRGB(150, 210, 255)
frostIconLbl.Font = Enum.Font.GothamBold
frostIconLbl.TextSize = 13
frostIconLbl.TextXAlignment = Enum.TextXAlignment.Right
frostIconLbl.Visible = false
frostIconLbl.Text = ""
frostIconLbl.Parent = hudGui
-- PLACEHOLDER_GUI: FrostIndicator icon asset -- using text label until icon set exists

local function updateFrostIcon(stacks)
	frostIconLbl.Visible = stacks >= Config.Frost.WarnHighStacks + 2 or stacks >= 8
	frostIconLbl.Text = "  FROST " .. stacks .. "/" .. Config.Frost.MaxStacks
end

-- ==================== CHARACTER-ATTACHED EFFECTS ====================
-- Wet (rain), snow accumulation, sandstorm dust, cold breath -- all attached to the
-- local character so they only need to exist client-side.

local char, hrp, head
local dripEmitter, sandEmitter, breathEmitter

local function setupCharacterEffects(character)
	char = character
	hrp  = char:WaitForChild("HumanoidRootPart", 5)
	head = char:WaitForChild("Head", 5)
	if not hrp or not head then return end

	dripEmitter = Instance.new("ParticleEmitter")
	dripEmitter.Name = "RainDrip"
	dripEmitter.Texture = "rbxasset://textures/particles/smoke_main.dds" -- PLACEHOLDER_ASSET: water drip
	dripEmitter.Color = ColorSequence.new(Color3.fromRGB(160, 180, 210))
	dripEmitter.Size = NumberSequence.new(0.06)
	dripEmitter.Lifetime = NumberRange.new(0.6, 1.0)
	dripEmitter.Speed = NumberRange.new(1, 2)
	dripEmitter.Rate = 0
	dripEmitter.Parent = head

	sandEmitter = Instance.new("ParticleEmitter")
	sandEmitter.Name = "SandCling"
	sandEmitter.Texture = "rbxasset://textures/particles/smoke_main.dds" -- PLACEHOLDER_ASSET: dust
	sandEmitter.Color = ColorSequence.new(Color3.fromRGB(200, 160, 100))
	sandEmitter.Size = NumberSequence.new(0.1)
	sandEmitter.Lifetime = NumberRange.new(0.8, 1.2)
	sandEmitter.Speed = NumberRange.new(0.5, 1)
	sandEmitter.Rate = 0
	sandEmitter.Parent = hrp

	breathEmitter = Instance.new("ParticleEmitter")
	breathEmitter.Name = "ColdBreath"
	breathEmitter.Texture = "rbxasset://textures/particles/smoke_main.dds" -- PLACEHOLDER_ASSET: cold breath
	breathEmitter.Color = ColorSequence.new(Color3.fromRGB(235, 240, 245))
	breathEmitter.Size = NumberSequence.new(0.2)
	breathEmitter.Lifetime = NumberRange.new(0.8, 1.2)
	breathEmitter.Speed = NumberRange.new(1, 2)
	breathEmitter.Rate = 0
	breathEmitter.Parent = head
end

if player.Character then setupCharacterEffects(player.Character) end
player.CharacterAdded:Connect(setupCharacterEffects)

-- Wet effect: after 30s continuously in Rain/HeavyRain/Thunderstorm, start drip particles;
-- fades over 20s after leaving rain.
local rainTimer = 0
local wetActive = false
local function updateWetEffect(dt, isRainy)
	if isRainy then
		rainTimer += dt
		if rainTimer >= 30 and not wetActive and dripEmitter then
			wetActive = true
			dripEmitter.Rate = 4
		end
	else
		rainTimer = 0
		if wetActive and dripEmitter then
			wetActive = false
			TweenService:Create(dripEmitter, TweenInfo.new(20), { Rate = 0 }):Play()
		end
	end
end

-- Snow accumulation: purely visual ground overlay while Snow is active. Built ONCE as a
-- grid of static tiles covering the whole map (not tracked to any player -- the previous
-- version re-anchored a single part under the local HumanoidRootPart every Heartbeat,
-- which is wasted per-frame work repeated on every client and reads as snow "following"
-- the player instead of actually covering the world). Each tile is raycast-snapped to
-- real ground height once at creation so it follows terrain contours without any
-- per-frame cost afterward.
local snowTiles = nil
local SNOW_GRID_RADIUS = 3   -- tiles out from center each axis (7x7 grid)
local SNOW_TILE_SPACING = 300
local SNOW_TILE_SIZE = 320   -- slightly larger than spacing so tiles overlap, no gaps
local SNOW_APPEAR_TIME = 45  -- slow, map-wide accumulation rather than an instant snap
local SNOW_FADE_TIME = 60

local function buildSnowTiles()
	if snowTiles then return end
	snowTiles = {}
	local center = hrp and hrp.Position or Vector3.new(0, 0, 0)
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { workspace:FindFirstChild("WeatherParticleAnchor") }
	for gx = -SNOW_GRID_RADIUS, SNOW_GRID_RADIUS do
		for gz = -SNOW_GRID_RADIUS, SNOW_GRID_RADIUS do
			local x = center.X + gx * SNOW_TILE_SPACING
			local z = center.Z + gz * SNOW_TILE_SPACING
			local origin = Vector3.new(x, center.Y + 400, z)
			local result = workspace:Raycast(origin, Vector3.new(0, -1500, 0), rayParams)
			local groundY = result and result.Position.Y or center.Y
			local tile = Instance.new("Part")
			tile.Name = "SnowGroundOverlay"
			tile.Anchored = true
			tile.CanCollide = false
			tile.CanQuery = false
			tile.CastShadow = false
			tile.Material = Enum.Material.Snow
			tile.Color = Color3.fromRGB(250, 250, 255)
			tile.Transparency = 1
			tile.Size = Vector3.new(SNOW_TILE_SIZE, 0.05, SNOW_TILE_SIZE)
			tile.CFrame = CFrame.new(x, groundY + 0.05, z)
			tile.Parent = workspace
			table.insert(snowTiles, tile)
		end
	end
end

local function updateSnowOverlay(isSnowing)
	buildSnowTiles()
	local targetTransparency = isSnowing and 0.3 or 1
	local duration = isSnowing and SNOW_APPEAR_TIME or SNOW_FADE_TIME
	for _, tile in ipairs(snowTiles) do
		TweenService:Create(tile, TweenInfo.new(duration), { Transparency = targetTransparency }):Play()
	end
end

-- ==================== WIND (drifting leaf/dust debris) ====================
-- A separate anchor from the rain/snow one, since this one needs to slowly ROTATE to
-- simulate a shifting breeze direction -- rotating the main particleAnchor would break
-- rain/snow's "always falls straight down in world space" assumption.

-- Tracks camera position + a slowly rotating direction -- used as the origin/heading
-- each wind line sweeps along, so gusts always travel a shifting-but-consistent way
-- rather than a random direction every time.
local windAnchor = Instance.new("Part")
windAnchor.Name = "WindAnchor"
windAnchor.Anchored = true
windAnchor.CanCollide = false
windAnchor.CanQuery = false
windAnchor.CanTouch = false
windAnchor.CastShadow = false
windAnchor.Transparency = 1
windAnchor.Size = Vector3.new(0.1, 0.1, 0.1)
windAnchor.Parent = workspace

-- Synced from the server (WeatherManager owns windAngle) so every player sees the same
-- gust direction, rather than each client rolling its own independent random drift.
local windAngle = 0
RunService.RenderStepped:Connect(function()
	if not camera then return end
	windAnchor.CFrame = CFrame.new(camera.CFrame.Position + Vector3.new(0, 6, 0)) * CFrame.Angles(0, windAngle, 0)
end)

-- "Wind lines" -- curved, fading Beams that sweep past the player, like the classic
-- wind-gust VFX in stylized action games. A Beam's CurveSize0/CurveSize1 bend it into an
-- S-curve/wave shape; both of its Attachments live on one small moving part, so
-- translating that part sweeps the whole wavy line through space.
local WIND_LINE_COLOR = Color3.fromRGB(235, 235, 240)
local currentWindCfg = nil

local function spawnWindLine()
	if not currentWindCfg or currentWindCfg.DebrisRate <= 0 then return end

	local lineAnchor = Instance.new("Part")
	lineAnchor.Anchored = true
	lineAnchor.CanCollide = false
	lineAnchor.CanQuery = false
	lineAnchor.CanTouch = false
	lineAnchor.CastShadow = false
	lineAnchor.Transparency = 1
	lineAnchor.Size = Vector3.new(0.1, 0.1, 0.1)
	-- Spawn somewhere in front of the camera, offset sideways/vertically, facing the
	-- current wind heading.
	local sideOffset = (math.random() - 0.5) * 24
	local heightOffset = math.random(-2, 5)
	lineAnchor.CFrame = windAnchor.CFrame * CFrame.new(sideOffset, heightOffset, -math.random(8, 16))
	lineAnchor.Parent = workspace

	local length = math.random(10, 18)
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, 0, length / 2)
	a0.Parent = lineAnchor
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, 0, -length / 2)
	a1.Parent = lineAnchor

	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Width0 = 0.02
	beam.Width1 = 0.25
	beam.CurveSize0 = math.random(-5, 5)
	beam.CurveSize1 = math.random(-5, 5)
	beam.Color = ColorSequence.new(currentWindCfg.Color or WIND_LINE_COLOR)
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.5),
		NumberSequenceKeypoint.new(0.8, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	beam.FaceCamera = true
	beam.LightEmission = 0.6
	beam.Segments = 16
	beam.Parent = lineAnchor

	-- Sweeps forward along the wind heading and past the player.
	local duration = 1.0 + math.random()
	local endCFrame = lineAnchor.CFrame * CFrame.new(0, 0, -math.random(20, 30))
	TweenService:Create(lineAnchor, TweenInfo.new(duration, Enum.EasingStyle.Linear), { CFrame = endCFrame }):Play()
	game:GetService("Debris"):AddItem(lineAnchor, duration + 0.1)
end

task.spawn(function()
	while true do
		local rate = currentWindCfg and currentWindCfg.DebrisRate or 0
		if rate <= 0 then
			task.wait(1)
		else
			task.wait(math.clamp(10 / rate, 1.2, 8))
			spawnWindLine()
		end
	end
end)

local function refreshWind(weatherType)
	currentWindCfg = Config.WeatherWind[weatherType]
end

-- ==================== EARTHQUAKE SCREEN SHAKE (legacy weather, kept working) ====================

local function triggerScreenShake()
	if not camera then return end
	task.spawn(function()
		for _ = 1, 20 do
			local offset = Vector3.new((math.random() - 0.5), (math.random() - 0.5), 0) * 0.3
			camera.CFrame = camera.CFrame * CFrame.new(offset)
			task.wait(0.05)
		end
	end)
end

-- ==================== WEATHER APPLICATION ====================

local globalWeather       = "Clear"
local zoneWeatherOverride = nil
local zoneFogActive       = false
local zoneFogDensity      = 0
local lastAppliedWeather  = nil

local function getEffectiveWeather()
	return zoneWeatherOverride or globalWeather
end

local function applyWeatherProfile(weatherType, tweenInfo)
	local profile = Config.WeatherProfiles[weatherType]
	if not profile then return end
	tweenInfo = tweenInfo or PROFILE_TWEEN
	local skyMod = Config.WeatherSkyMods[weatherType] or { SunRaysMult = 1, BloomMult = 1, MoonGlowMult = 1, ShadowSoftness = 0.2 }
	local tod = blendTimeOfDay(currentClockTime)

	TweenService:Create(Lighting, tweenInfo, {
		Ambient = tintColor(profile.Ambient, tod.AmbientTint),
		OutdoorAmbient = tintColor(profile.OutdoorAmbient, tod.AmbientTint),
		Brightness = profile.Brightness * tod.BrightnessMult,
		FogEnd = profile.FogEnd,
		FogStart = profile.FogStart,
		FogColor = tintColor(profile.FogColor, tod.FogColorTint),
		ShadowSoftness = skyMod.ShadowSoftness or 0.2,
	}):Play()

	if atmosphere then
		TweenService:Create(atmosphere, tweenInfo, {
			Density = profile.AtmosphereDensity,
			Color = tintColor(profile.AtmosphereColor, tod.FogColorTint),
			Haze = profile.AtmosphereHaze,
			Glare = profile.AtmosphereGlare,
		}):Play()
	end

	TweenService:Create(colorCorrection, tweenInfo, {
		Brightness = profile.ColorCorrection.Brightness + tod.CCBrightnessDelta,
		Contrast = profile.ColorCorrection.Contrast + tod.CCContrastDelta,
		Saturation = profile.ColorCorrection.Saturation + tod.CCSaturationDelta,
		TintColor = tintColor(profile.ColorCorrection.TintColor, tod.ColorCorrectionTint),
	}):Play()

	if sunRaysEffect then
		TweenService:Create(sunRaysEffect, tweenInfo, { Intensity = tod.SunRaysIntensity * skyMod.SunRaysMult }):Play()
	end
	if bloomEffect then
		TweenService:Create(bloomEffect, tweenInfo, { Intensity = tod.BloomIntensity * skyMod.BloomMult, Size = tod.BloomSize }):Play()
	end
	if dofEffect then
		local dofMult = Config.WeatherDOFMult[weatherType] or 1
		TweenService:Create(dofEffect, tweenInfo, { FarIntensity = Config.DepthOfField.BaseFarIntensity * dofMult }):Play()
	end

	switchParticles(weatherType)
	playWeatherSound(weatherType)
	updateWeatherIcon(weatherType)
	refreshSandstormBlur(weatherType)
	refreshClouds(weatherType, tod.CloudColorTint, tweenInfo)
	refreshWind(weatherType)
	refreshMoonGlow(weatherType, tod.MoonGlowIntensity)

	if weatherType == "Earthquake" and lastAppliedWeather ~= "Earthquake" then
		triggerScreenShake()
	end

	updateSnowOverlay(weatherType == "Snow")

	if sandEmitter then
		sandEmitter.Rate = (weatherType == "Sandstorm") and 6 or 0
	end

	lastAppliedWeather = weatherType
	print("[WeatherClient] Weather: " .. weatherType)
end

local function refreshVisuals(tweenInfo)
	local w = getEffectiveWeather()
	applyWeatherProfile(w, tweenInfo)
	if zoneFogActive and not zoneWeatherOverride then
		setFogOnly(true, zoneFogDensity)
	end
end

RunService.Heartbeat:Connect(function(dt)
	local w = getEffectiveWeather()
	local isRainy = w == "Rain" or w == "HeavyRain" or w == "Thunderstorm" or w == "Storm"
	updateWetEffect(dt, isRainy)
end)

-- ==================== FROST (server-authoritative stacks, client visuals only) ====================

local frostStacks = 0

local function playFrostWarning(soundName)
	local inst = FrostSoundFolder and FrostSoundFolder:FindFirstChild(soundName)
	local id = inst and inst.SoundId
	if not id or id == "" or id == "rbxassetid://0" then return end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = 0.6
	s.Parent = SoundService
	s:Play()
	local cleaned = false
	local function cleanup() if not cleaned then cleaned = true; if s.Parent then s:Destroy() end end end
	s.Ended:Once(cleanup)
	task.delay(8, cleanup)
end

local function onFrostUpdate(stacks)
	local prev = frostStacks
	frostStacks = stacks
	updateFrostIcon(stacks)
	if breathEmitter then breathEmitter.Rate = stacks > 0 and 3 or 0 end
	-- PLACEHOLDER_ANIMATION: shiver -- play at stacks >= 5 once a real AnimationId exists
	if stacks >= Config.Frost.WarnLowStacks and prev < Config.Frost.WarnLowStacks then
		playFrostWarning("Warning_Low")
	end
	if stacks >= Config.Frost.WarnHighStacks and prev < Config.Frost.WarnHighStacks then
		playFrostWarning("Warning_High")
	end
end

-- ==================== LIGHTNING ====================

local function playThunder(strikePos)
	if not hrp then return end
	local distance = (hrp.Position - strikePos).Magnitude
	local delay = distance / Config.Lightning.SpeedOfSound
	task.delay(delay, function()
		local inst = WeatherFolder:FindFirstChild("Thunder")
		local id = inst and inst.SoundId
		if not id or id == "" or id == "rbxassetid://0" then return end
		local volume = math.clamp(1 - (distance / 800), 0.1, 1)
		local s = Instance.new("Sound")
		s.SoundId = id
		s.Volume = volume
		s.Parent = SoundService
		s:Play()
		local cleaned = false
		local function cleanup() if not cleaned then cleaned = true; if s.Parent then s:Destroy() end end end
		s.Ended:Once(cleanup)
		task.delay(8, cleanup)
	end)
end

local function onLightningWarning(_strikePos)
	local inst = WeatherFolder:FindFirstChild("Thunder_Rumble")
	local id = inst and inst.SoundId
	if not id or id == "" or id == "rbxassetid://0" then return end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = 0.3
	s.Parent = SoundService
	s:Play()
	local cleaned = false
	local function cleanup() if not cleaned then cleaned = true; if s.Parent then s:Destroy() end end end
	s.Ended:Once(cleanup)
	task.delay(6, cleanup)
end

local Debris = game:GetService("Debris")
local BOLT_COLOR = Color3.fromRGB(220, 232, 255)
local BOLT_CORE_COLOR = Color3.fromRGB(255, 255, 255)

-- One shared, per-bolt invisible anchor at the world origin with identity rotation --
-- Attachment.Position is a LOCAL offset from its parent, so with the parent sitting at
-- (0,0,0) with no rotation, Attachment.Position can just be the real world-space point
-- directly. Destroying this one part cleans up every Attachment/Beam parented to it.
local function newBoltRoot()
	local root = Instance.new("Part")
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.Transparency = 1
	root.Size = Vector3.new(0.1, 0.1, 0.1)
	root.CFrame = CFrame.new(0, 0, 0)
	root.Parent = workspace
	return root
end

-- A bright, thin "core" Beam plus a wider, softer, more transparent "glow" Beam behind
-- it sharing the same two Attachments -- a cheap bloom-halo trick since Roblox Beams
-- don't get real post-process bloom applied to arbitrary parts consistently.
local function createBoltSegment(root, p0, p1, t)
	local dist = (p1 - p0).Magnitude
	if dist < 0.05 then return end
	local a0 = Instance.new("Attachment")
	a0.Position = p0
	a0.Parent = root
	local a1 = Instance.new("Attachment")
	a1.Position = p1
	a1.Parent = root

	local coreWidth = 0.5 * (1 - t * 0.6)
	local core = Instance.new("Beam")
	core.Attachment0 = a0
	core.Attachment1 = a1
	core.Width0 = coreWidth
	core.Width1 = coreWidth * 0.7
	core.Color = ColorSequence.new(BOLT_CORE_COLOR)
	core.Transparency = NumberSequence.new(0.05)
	core.FaceCamera = true
	core.LightEmission = 1
	core.LightInfluence = 0
	core.Segments = 1
	core.Parent = root

	local glow = Instance.new("Beam")
	glow.Attachment0 = a0
	glow.Attachment1 = a1
	glow.Width0 = coreWidth * 3.2
	glow.Width1 = coreWidth * 2.4
	glow.Color = ColorSequence.new(BOLT_COLOR)
	glow.Transparency = NumberSequence.new(0.55)
	glow.FaceCamera = true
	glow.LightEmission = 1
	glow.LightInfluence = 0
	glow.Segments = 1
	glow.ZOffset = -0.1
	glow.Parent = root
end

-- One level of "sub-branches" off the main branch forks reads noticeably more organic
-- than single-level forking.
local function addBranch(root, from, maxLen, depth)
	local branchEnd = from + Vector3.new((math.random() - 0.5) * maxLen, -math.random(maxLen * 0.4, maxLen), (math.random() - 0.5) * maxLen)
	createBoltSegment(root, from, branchEnd, 0.7)
	if depth > 0 and math.random() < 0.5 then
		addBranch(root, from + (branchEnd - from) * 0.5, maxLen * 0.55, depth - 1)
	end
end

-- Builds a jagged, tapering bolt from the strike point up into the sky, with branch
-- forks (some with their own sub-forks) peeling off partway up -- reads far more like
-- real lightning than a single straight beam.
local function buildLightningBolt(strikePos)
	local root = newBoltRoot()
	local segments = math.random(10, 15)
	local topY = strikePos.Y + math.random(110, 170)
	local prev = strikePos
	local maxJitter = 7
	for i = 1, segments do
		local t = i / segments
		local targetY = strikePos.Y + (topY - strikePos.Y) * t
		local jitter = maxJitter * (1 - t * 0.5)
		local nextPoint = Vector3.new(
			strikePos.X + (math.random() - 0.5) * jitter * 2,
			targetY,
			strikePos.Z + (math.random() - 0.5) * jitter * 2
		)
		createBoltSegment(root, prev, nextPoint, t)
		if i > 2 and i < segments - 1 and math.random() < 0.3 then
			addBranch(root, prev, 24, 1)
		end
		prev = nextPoint
	end
	return root
end

-- Full-screen white flash overlay -- the classic cinematic "camera flash" technique.
-- Built once and reused; intensity/duration scale with distance so a strike across the
-- map barely registers while one right overhead is genuinely blinding for an instant.
local flashGui = Instance.new("ScreenGui")
flashGui.Name = "LightningFlash"
flashGui.ResetOnSpawn = false
flashGui.IgnoreGuiInset = true
flashGui.DisplayOrder = 50
flashGui.Parent = player:WaitForChild("PlayerGui")

local flashFrame = Instance.new("Frame")
flashFrame.Size = UDim2.new(1, 0, 1, 0)
flashFrame.BackgroundColor3 = Color3.fromRGB(235, 240, 255)
flashFrame.BorderSizePixel = 0
flashFrame.BackgroundTransparency = 1
flashFrame.Parent = flashGui

local function screenFlash(peakTransparency, fadeTime)
	flashFrame.BackgroundTransparency = peakTransparency
	TweenService:Create(flashFrame, TweenInfo.new(fadeTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { BackgroundTransparency = 1 }):Play()
end

local function cameraShake(intensity, duration)
	if not camera then return end
	task.spawn(function()
		local elapsed = 0
		while elapsed < duration do
			local falloff = 1 - (elapsed / duration)
			local offset = Vector3.new((math.random() - 0.5), (math.random() - 0.5) * 0.6, 0) * intensity * falloff
			camera.CFrame = camera.CFrame * CFrame.new(offset)
			local step = 0.03
			task.wait(step)
			elapsed += step
		end
	end)
end

local function onLightningStrike(strikePos)
	local distance = hrp and (hrp.Position - strikePos).Magnitude or 1000
	-- 0 studs away = 1 (max), fades out to 0 by 400 studs.
	local proximity = math.clamp(1 - (distance / 400), 0, 1)

	local originalBrightness = Lighting.Brightness
	Lighting.Brightness = originalBrightness + (2 + proximity * 4)
	task.delay(0.08, function()
		TweenService:Create(Lighting, TweenInfo.new(0.35), { Brightness = originalBrightness }):Play()
	end)

	screenFlash(1 - proximity * 0.55, 0.25 + proximity * 0.25)
	if proximity > 0.5 then
		cameraShake(proximity * 0.4, 0.35)
	end

	-- Brief point light at the strike so nearby terrain/characters actually get lit up.
	local lightAnchor = Instance.new("Part")
	lightAnchor.Anchored = true
	lightAnchor.CanCollide = false
	lightAnchor.CanQuery = false
	lightAnchor.CastShadow = false
	lightAnchor.Transparency = 1
	lightAnchor.Size = Vector3.new(0.2, 0.2, 0.2)
	lightAnchor.CFrame = CFrame.new(strikePos)
	lightAnchor.Parent = workspace
	local strikeLight = Instance.new("PointLight")
	strikeLight.Color = BOLT_COLOR
	strikeLight.Range = 70
	strikeLight.Brightness = 12
	strikeLight.Parent = lightAnchor
	TweenService:Create(strikeLight, TweenInfo.new(0.4), { Brightness = 0 }):Play()
	Debris:AddItem(lightAnchor, 0.5)

	-- Ground impact burst -- quick bright particle flash at the strike point.
	local burstEmitter = Instance.new("ParticleEmitter")
	burstEmitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	burstEmitter.Color = ColorSequence.new(BOLT_COLOR)
	burstEmitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 0) })
	burstEmitter.Transparency = NumberSequence.new(0.1)
	burstEmitter.Lifetime = NumberRange.new(0.3, 0.4)
	burstEmitter.Speed = NumberRange.new(15, 25)
	burstEmitter.SpreadAngle = Vector2.new(180, 180)
	burstEmitter.LightEmission = 1
	burstEmitter.Rate = 0
	burstEmitter.Parent = lightAnchor
	burstEmitter:Emit(30)

	-- Bolt flickers: real lightning often strikes 1-2 more times in quick succession.
	local function flash()
		local root = buildLightningBolt(strikePos)
		Debris:AddItem(root, 0.16)
	end
	flash()
	if math.random() < 0.5 then
		task.delay(0.09, flash)
	end
	if math.random() < 0.25 then
		task.delay(0.18, flash)
	end

	playThunder(strikePos)
end

-- ==================== REMOTE WIRING ====================

local reFolder          = RepStorage:WaitForChild("RemoteEvents", 10)
local updateWeatherRE   = reFolder:WaitForChild("UpdateWeather", 10)
local updateLightingRE  = reFolder:WaitForChild("UpdateLighting", 10)
local applyZoneFogRE    = reFolder:WaitForChild("ApplyZoneFog", 10)
local updateZoneWeatherRE = reFolder:WaitForChild("UpdateZoneWeather", 10)
local updateFrostRE     = reFolder:WaitForChild("UpdateFrost", 10)
local updateMitigationRE = reFolder:WaitForChild("UpdateMitigation", 10)
local lightningWarningRE = reFolder:WaitForChild("LightningWarning", 10)
local lightningStrikeRE  = reFolder:WaitForChild("LightningStrike", 10)
local updateWindRE       = reFolder:WaitForChild("UpdateWind", 10)

if updateWeatherRE then
	updateWeatherRE.OnClientEvent:Connect(function(weatherType)
		globalWeather = weatherType
		refreshVisuals()
	end)
end

if updateZoneWeatherRE then
	updateZoneWeatherRE.OnClientEvent:Connect(function(weatherType)
		zoneWeatherOverride = weatherType
		refreshVisuals()
	end)
end

if updateLightingRE then
	updateLightingRE.OnClientEvent:Connect(function(clockTime)
		currentClockTime = clockTime
		-- Re-drives the lighting blend on every clock tick (not just weather changes) so
		-- ambiance keeps drifting smoothly through dawn/day/dusk/night on its own. Uses the
		-- short CLOCK_TWEEN, not the full weather-change PROFILE_TWEEN -- see CLOCK_TWEEN's
		-- comment for why reusing the long one here would never let values settle.
		refreshVisuals(CLOCK_TWEEN)
	end)
end

if applyZoneFogRE then
	applyZoneFogRE.OnClientEvent:Connect(function(active, density)
		zoneFogActive = active
		zoneFogDensity = density
		if active and not zoneWeatherOverride then
			setFogOnly(true, density)
		else
			refreshVisuals()
		end
		print("[WeatherClient] ZoneFog: " .. tostring(active))
	end)
end

if updateFrostRE then
	updateFrostRE.OnClientEvent:Connect(onFrostUpdate)
end

if updateWindRE then
	updateWindRE.OnClientEvent:Connect(function(angle)
		windAngle = angle
	end)
end

if updateMitigationRE then
	updateMitigationRE.OnClientEvent:Connect(function(clothing, faceGear)
		mitigation.clothing = clothing
		mitigation.faceGear = faceGear
		refreshSandstormBlur(getEffectiveWeather())
	end)
end

if lightningWarningRE then
	lightningWarningRE.OnClientEvent:Connect(onLightningWarning)
end

if lightningStrikeRE then
	lightningStrikeRE.OnClientEvent:Connect(onLightningStrike)
end

print("[WeatherClient] Ready")
