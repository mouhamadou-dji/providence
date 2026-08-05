-- LightingManager -- applies the small set of Lighting properties WeatherClient never
-- touches (verified by grep -- see Config.LightingMood's comment). Everything WeatherClient
-- DOES own (Ambient/OutdoorAmbient/Brightness/Fog/Atmosphere*/ColorCorrection) lives in
-- Config.WeatherProfiles.Clear instead, deliberately NOT duplicated here to avoid two
-- systems fighting over the same properties (the exact bug already hit once with
-- WeatherClient vs SurvivalStateClient's ColorCorrection, see WeatherClient's comment).
local RepStorage = game:GetService("ReplicatedStorage")
local Lighting   = game:GetService("Lighting")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local moodCfg  = Config.LightingMood
local bloomCfg = Config.BloomMood
local raysCfg  = Config.SunRaysMood

for prop, value in pairs(moodCfg) do
	Lighting[prop] = value
end

-- Real bug found while verifying this live: Lighting.Ambient/OutdoorAmbient/Brightness
-- (the raw Lighting SERVICE properties) are NEVER actually written by WeatherClient --
-- confirmed by grep, the only other Lighting.Brightness write in the whole codebase is an
-- unrelated one-off proximity-brightness effect. WeatherClient only ever tweens the
-- ColorCorrectionEffect's own Brightness/Contrast/Saturation/TintColor and the Atmosphere
-- instance's Density/Color/Haze/Glare -- it does NOT touch these 3 despite
-- Config.WeatherProfiles having fields with the same names. So retuning
-- Config.WeatherProfiles.Clear's Ambient/OutdoorAmbient/Brightness (see Config's comment)
-- had zero visible effect on its own -- these 3 need a real, static owner. Since nothing
-- else ever writes them, applying them once here is safe (no property-fighting risk).
local clearProfile = Config.WeatherProfiles.Clear
Lighting.Ambient = clearProfile.Ambient
Lighting.OutdoorAmbient = clearProfile.OutdoorAmbient
Lighting.Brightness = clearProfile.Brightness

local bloom = Lighting:FindFirstChildOfClass("BloomEffect")
if bloom then
	bloom.Intensity = bloomCfg.Intensity
	bloom.Size = bloomCfg.Size
	bloom.Threshold = bloomCfg.Threshold
end

local sunRays = Lighting:FindFirstChildOfClass("SunRaysEffect")
if sunRays then
	sunRays.Intensity = raysCfg.Intensity
	sunRays.Spread = raysCfg.Spread
end

-- PLACEHOLDER_ASSET: MoodySkybox -- Lighting.Sky's 6 cubemap texture ids + moon/sun textures
-- are currently whatever was originally authored on the map (a bright default-feeling skybox
-- per the owner's reference image). Roblox's Sky class has no tint/color-grade property to
-- darken it programmatically -- swapping to an actually moodier skybox requires real
-- overcast/dusk cubemap asset ids, which weren't provided. Left untouched rather than
-- guessing at asset ids; replace Lighting.Sky's Skybox* properties once real ones are picked.

print("[LightingManager] Init -- base mood applied")
