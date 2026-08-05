-- WeatherManager — Module 12
local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local Lighting          = game:GetService("Lighting")
local RepStorage        = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))

local FULL_DAY_SECONDS = Config.DayCycle and Config.DayCycle.FullDayDuration or 1500
local Debris = game:GetService("Debris")

local AURA_PARTS = {"Torso", "Right Leg", "Left Leg", "Right Arm", "Left Arm"}

local function applyLightningAura(character)
	local template = workspace:FindFirstChild(Config.Lightning.AuraTemplateName)
	if not template then return end
	for _, partName in ipairs(AURA_PARTS) do
		local templatePart = template:FindFirstChild(partName)
		local charPart     = character:FindFirstChild(partName)
		local emitterTemplate = templatePart and templatePart:FindFirstChild("Electrecuted")
		if charPart and emitterTemplate then
			local clone = emitterTemplate:Clone()
			clone.Enabled = true
			clone.Parent = charPart
			Debris:AddItem(clone, Config.Lightning.AuraDuration)
		end
	end
end
local CLOCK_RATE              = 24 / FULL_DAY_SECONDS
local WEATHER_UPDATE_INTERVAL = 2
local FOG_CHECK_INTERVAL      = 0.5

local function getOrCreate(name, isFunc)
    local folder = RepStorage:FindFirstChild("RemoteEvents")
        or (function()
            local f = Instance.new("Folder")
            f.Name = "RemoteEvents"
            f.Parent = RepStorage
            return f
        end)()
    local r = folder:FindFirstChild(name)
    if r then return r end
    r = Instance.new(isFunc and "RemoteFunction" or "RemoteEvent")
    r.Name = name
    r.Parent = folder
    return r
end
local updateWeather     = getOrCreate("UpdateWeather")
local updateLighting    = getOrCreate("UpdateLighting")
local applyZoneFog      = getOrCreate("ApplyZoneFog")
local updateZoneWeather = getOrCreate("UpdateZoneWeather")
local updateFrost       = getOrCreate("UpdateFrost")
local updateMitigation  = getOrCreate("UpdateMitigation")
local lightningWarning  = getOrCreate("LightningWarning")
local lightningStrike   = getOrCreate("LightningStrike")
local updateWind        = getOrCreate("UpdateWind")

local baseWeather     = "Clear"
local weatherOverride = nil
local redSkyForced    = false
-- Fresh servers start in the MORNING, not at dawn. 6.0 was hardcoded here and reads as Dawn
-- under this script's own getTimeOfDay ranges (Dawn 5.5-8, Morning 8-11).
local clockTime       = (Config.DayCycle and Config.DayCycle.StartClockTime) or 8.0
Lighting.ClockTime    = clockTime

-- Server-authoritative so every player in the server sees the same gust direction
-- (previously each client rolled its own random wind angle, which looked inconsistent
-- between players standing next to each other). Owning this here also gives a real
-- hook point for a future gameplay wind system (fire spread, projectile drift, sailing,
-- etc) to read/react to without inventing new state.
local windAngle = math.random() * math.pi * 2

local playerZoneFogState  = {}
local playerZoneWeather   = {}
local frostStacks         = {}

local function getCurrentWeather()
    if weatherOverride then
        if tick() < weatherOverride.endTime then
            return weatherOverride.weatherType
        else
            weatherOverride = nil
        end
    end
    if redSkyForced then return "RedSky" end
    return baseWeather
end

local weatherNameLookup = {}
for name in pairs(Config.WeatherProfiles) do
    weatherNameLookup[name:lower()] = name
end

-- Resolves free-form mod input (any case) to the exact canonical Config.WeatherProfiles
-- key, or nil if it doesn't match anything. Without this, a typo/case mismatch used to
-- get silently accepted server-side (no visual profile exists under that name) while
-- still reporting "OK" to the mod menu.
local function resolveWeatherName(input)
    if type(input) ~= "string" then return nil end
    if Config.WeatherProfiles[input] then return input end
    return weatherNameLookup[input:lower()]
end

local function weightedPickExcluding(pool, exclude)
    local total = 0
    for _, entry in ipairs(pool) do
        if entry.weather ~= exclude then total += entry.weight end
    end
    if total <= 0 then return exclude end
    local roll = math.random() * total
    local cum = 0
    for _, entry in ipairs(pool) do
        if entry.weather ~= exclude then
            cum += entry.weight
            if roll <= cum then return entry.weather end
        end
    end
    return exclude
end

local function getClothingProtection(player)
    local dm = _G.DataManager
    local tier = (dm and dm.getValue(player, "EquippedClothing")) or "None"
    return Config.Frost.ClothingProtection[tier] or 1.0
end

local function isIndoors(hrp)
    local result = workspace:Raycast(hrp.Position, Vector3.new(0, Config.Frost.IndoorRaycastHeight, 0))
    return result ~= nil
end

local weatherAccum  = 0
local fogAccum      = 0
local eclipseAccum  = 0
local frostGainAccum  = 0
local frostDecayAccum = 0
local frostFireAccum  = 0

local function setFrostStacks(player, n)
    n = math.clamp(n, 0, Config.Frost.MaxStacks)
    frostStacks[player.UserId] = n
    updateFrost:FireClient(player, n)
end

RunService.Heartbeat:Connect(function(dt)
    clockTime = (clockTime + dt * CLOCK_RATE) % 24
    Lighting.ClockTime = clockTime
    windAngle = (windAngle + dt * 0.05) % (2 * math.pi)

    weatherAccum += dt
    if weatherAccum >= WEATHER_UPDATE_INTERVAL then
        weatherAccum = 0
        updateWeather:FireAllClients(getCurrentWeather(), clockTime)
        updateLighting:FireAllClients(clockTime)
        updateWind:FireAllClients(windAngle)
    end

    fogAccum += dt
    if fogAccum >= FOG_CHECK_INTERVAL then
        fogAccum = 0
        local zm = _G.ZoneManager
        if zm then
            for _, player in ipairs(Players:GetPlayers()) do
                local zone       = zm.getCurrentZone(player)
                local hasFog     = false
                local density    = 0
                local zoneWeather = nil
                if zone and zone.Parent then
                    hasFog       = zone:GetAttribute("ZoneFog") == true
                    density      = zone:GetAttribute("ZoneFogDensity") or 0
                    zoneWeather  = zone:GetAttribute("ZoneWeatherOverride")
                end
                local prevFog = playerZoneFogState[player.UserId]
                if prevFog ~= hasFog then
                    playerZoneFogState[player.UserId] = hasFog
                    applyZoneFog:FireClient(player, hasFog, density)
                end
                local prevZW = playerZoneWeather[player.UserId]
                if prevZW ~= zoneWeather then
                    playerZoneWeather[player.UserId] = zoneWeather
                    updateZoneWeather:FireClient(player, zoneWeather)
                end
            end
        end
    end

    eclipseAccum += dt
    if eclipseAccum >= 2 then
        eclipseAccum = 0
        local lm = _G.LoreManager
        if lm then
            local anyStage5 = false
            for _, player in ipairs(Players:GetPlayers()) do
                if (lm.getStage(player) or 0) >= 5 then anyStage5 = true break end
            end
            if anyStage5 and not redSkyForced then
                redSkyForced = true
                updateWeather:FireAllClients(getCurrentWeather(), clockTime)
                print("[WeatherManager] Eclipse Stage 5 detected -- RedSky forced server-wide")
            elseif (not anyStage5) and redSkyForced then
                redSkyForced = false
                updateWeather:FireAllClients(getCurrentWeather(), clockTime)
                print("[WeatherManager] No player at Stage 5 -- RedSky released")
            end
        end
    end

    local weather = getCurrentWeather()
    local isCold  = weather == "Snow" or weather == "Hail"

    frostGainAccum += dt
    if frostGainAccum >= Config.Frost.StackApplyInterval then
        frostGainAccum = 0
        if isCold then
            for _, player in ipairs(Players:GetPlayers()) do
                local char = player.Character
                local hrp  = char and char:FindFirstChild("HumanoidRootPart")
                if hrp and not isIndoors(hrp) then
                    local protection = getClothingProtection(player)
                    if math.random() <= protection then
                        setFrostStacks(player, (frostStacks[player.UserId] or 0) + 1)
                    end
                end
            end
        end
    end

    frostDecayAccum += dt
    if frostDecayAccum >= Config.Frost.DecayInterval then
        frostDecayAccum = 0
        if not isCold then
            for _, player in ipairs(Players:GetPlayers()) do
                local cur = frostStacks[player.UserId] or 0
                if cur > 0 then setFrostStacks(player, cur - 1) end
            end
        end
    end

    frostFireAccum += dt
    if frostFireAccum >= Config.Frost.FireProximityInterval then
        frostFireAccum = 0
        local fireParts = CollectionService:GetTagged("FireSource")
        if #fireParts > 0 then
            for _, player in ipairs(Players:GetPlayers()) do
                local cur = frostStacks[player.UserId] or 0
                local char = player.Character
                local hrp  = char and char:FindFirstChild("HumanoidRootPart")
                if hrp and cur > 0 then
                    for _, fp in ipairs(fireParts) do
                        if fp:IsA("BasePart") and (fp.Position - hrp.Position).Magnitude <= Config.Frost.FireProximityRadius then
                            setFrostStacks(player, cur - 1)
                            break
                        end
                    end
                end
            end
        end
    end

    for _, player in ipairs(Players:GetPlayers()) do
        local cur = frostStacks[player.UserId] or 0
        if cur > 0 then
            local char = player.Character
            local hum  = char and char:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then
                hum.Health = math.max(0, hum.Health - Config.Frost.DamagePerStackPerSecond * cur * dt)
            end
        end
    end
end)

-- Natural weather rotation: every 4-8 min, rolls a new weather from the weighted pool,
-- skipping the current one. Paused while a mod override or Eclipse RedSky is active.
task.spawn(function()
    while true do
        task.wait(math.random(Config.NaturalWeatherIntervalMin, Config.NaturalWeatherIntervalMax))
        if weatherOverride and tick() < weatherOverride.endTime then continue end
        if redSkyForced then continue end
        baseWeather = weightedPickExcluding(Config.NaturalWeatherRotation, baseWeather)
        updateWeather:FireAllClients(getCurrentWeather(), clockTime)
        print("[WeatherManager] Natural rotation -> " .. baseWeather)
    end
end)

-- Thunderstorm lightning: random strikes every 8-25s while Thunderstorm is the active weather.
task.spawn(function()
    while true do
        task.wait(math.random(Config.Lightning.IntervalMin, Config.Lightning.IntervalMax))
        if getCurrentWeather() ~= "Thunderstorm" then continue end
        local ok, err = pcall(function() _G.WeatherManager.triggerLightningStrike() end)
        if not ok then warn("[WeatherManager] lightning strike error: " .. tostring(err)) end
    end
end)

local WeatherManager = {}

function WeatherManager.getWeather()
    return getCurrentWeather()
end

function WeatherManager.setWeather(weatherType, duration)
    assert(type(weatherType) == "string", "weatherType must be a string")
    local resolved = resolveWeatherName(weatherType)
    assert(resolved, "Unknown weather type: '" .. tostring(weatherType) ..
        "' -- valid: Clear Sunny Cloudy Foggy Rain HeavyRain Thunderstorm Snow Hail Sandstorm BloodRain RedMist RedSky")
    assert(duration == nil or (type(duration) == "number" and duration > 0),
        "duration must be a positive number or nil")
    if duration then
        weatherOverride = { weatherType = resolved, endTime = tick() + duration }
    else
        baseWeather     = resolved
        weatherOverride = nil
    end
    updateWeather:FireAllClients(getCurrentWeather(), clockTime)
    print(string.format("[WeatherManager] Weather -> %s%s",
        resolved, duration and (" for " .. duration .. "s") or " (permanent)"))
end

function WeatherManager.clearWeather()
    weatherOverride = nil
    updateWeather:FireAllClients(getCurrentWeather(), clockTime)
    print("[WeatherManager] Override cleared — base: " .. baseWeather)
end

function WeatherManager.setBaseWeather(weatherType)
    assert(type(weatherType) == "string", "weatherType must be a string")
    baseWeather = weatherType
end

function WeatherManager.getClockTime()
    return clockTime
end

function WeatherManager.setClockTime(time)
    assert(type(time) == "number" and time >= 0 and time < 24,
        "ClockTime must be in range [0, 24)")
    clockTime = time
    Lighting.ClockTime = time
    updateLighting:FireAllClients(clockTime)
end

function WeatherManager.getTimeOfDay()
    if     clockTime >= 5.5 and clockTime < 8  then return "Dawn"
    elseif clockTime >= 8   and clockTime < 11 then return "Morning"
    elseif clockTime >= 11  and clockTime < 14 then return "Midday"
    elseif clockTime >= 14  and clockTime < 17 then return "Afternoon"
    elseif clockTime >= 17  and clockTime < 20 then return "Dusk"
    elseif clockTime >= 20  or  clockTime < 2  then return "Night"
    else                                             return "DeepNight"
    end
end

function WeatherManager.getZoneFogState(player)
    return playerZoneFogState[player.UserId] == true
end

-- Hook point for a future gameplay wind system (fire spread, projectile drift, etc).
function WeatherManager.getWindAngle()
    return windAngle
end

function WeatherManager.getWindDirection()
    return Vector3.new(math.cos(windAngle), 0, math.sin(windAngle))
end

function WeatherManager.getFrostStacks(player)
    return frostStacks[player.UserId] or 0
end

function WeatherManager.forceFrostStacks(player, amount)
    assert(type(amount) == "number", "amount must be a number")
    setFrostStacks(player, amount)
end

function WeatherManager.clearFrostStacks(player)
    setFrostStacks(player, 0)
end

function WeatherManager.syncMitigation(player)
    local dm = _G.DataManager
    local clothing = (dm and dm.getValue(player, "EquippedClothing")) or "None"
    local faceGear = (dm and dm.getValue(player, "EquippedFaceGear")) or "None"
    updateMitigation:FireClient(player, clothing, faceGear)
end

-- position is optional; if omitted, strikes near a random online player.
function WeatherManager.triggerLightningStrike(position)
    local pos = position
    if not pos then
        local plist = Players:GetPlayers()
        if #plist == 0 then return end
        local pick = plist[math.random(1, #plist)]
        local char = pick.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then return end
        local angle = math.random() * math.pi * 2
        local dist  = math.random(0, Config.Lightning.StrikeRadius)
        pos = hrp.Position + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
    end
    lightningWarning:FireAllClients(pos)
    task.delay(Config.Lightning.WarningLeadTime, function()
        lightningStrike:FireAllClients(pos)
        for _, player in ipairs(Players:GetPlayers()) do
            local char = player.Character
            local hrp  = char and char:FindFirstChild("HumanoidRootPart")
            if hrp then
                local dist = (hrp.Position - pos).Magnitude
                if dist <= Config.Lightning.FrostClearRadius then
                    WeatherManager.clearFrostStacks(player)
                end
                if dist <= Config.Lightning.DirectHitRadius then
                    local hum = char:FindFirstChildOfClass("Humanoid")
                    if hum and hum.Health > 0 then
                        hum:TakeDamage(Config.Lightning.DirectHitDamage)
                    end
                    applyLightningAura(char)
                    print("[WeatherManager] " .. player.Name .. " struck by lightning for " .. Config.Lightning.DirectHitDamage .. " dmg")
                end
            end
        end
    end)
    print("[WeatherManager] Lightning strike at " .. tostring(pos))
end

_G.WeatherManager = WeatherManager

Players.PlayerAdded:Connect(function(player)
    playerZoneFogState[player.UserId] = false
    frostStacks[player.UserId]        = 0
    updateWind:FireClient(player, windAngle)
    task.delay(2, function()
        if player.Parent then WeatherManager.syncMitigation(player) end
    end)
end)
Players.PlayerRemoving:Connect(function(player)
    playerZoneFogState[player.UserId] = nil
    playerZoneWeather[player.UserId]  = nil
    frostStacks[player.UserId]        = nil
end)
for _, p in ipairs(Players:GetPlayers()) do
    playerZoneFogState[p.UserId] = false
    frostStacks[p.UserId]        = 0
end

print(string.format("[WeatherManager] Init — DayCycle=%ds | Rate=%.5f hr/s | Base=%s",
    FULL_DAY_SECONDS, CLOCK_RATE, baseWeather))
