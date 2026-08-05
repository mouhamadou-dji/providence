-- OceanManager -- design doc PART TWO. "Moving water" is entirely native Roblox Terrain
-- water animation (WaterWaveSize/WaterWaveSpeed) -- there is exactly ONE Terrain instance in
-- the game and its waves animate every frame internally with zero scripting, so this manager's
-- only job is keeping those two properties in sync with the current weather. No wave parts are
-- ever spawned -- per the user's explicit ask, moving water must be the one real Terrain model
-- animating itself, never a spawned-and-replaced wave instance.
local RepStorage = game:GetService("ReplicatedStorage")
local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))

local Terrain = workspace.Terrain
local POLL_INTERVAL = 3

local function applyForWeather(weatherType)
	local wave = Config.OceanWaves[weatherType] or Config.OceanWaves.Clear
	Terrain.WaterWaveSize = wave.WaterWaveSize
	Terrain.WaterWaveSpeed = wave.WaterWaveSpeed
end

local lastWeather = nil
task.spawn(function()
	while true do
		local wm = _G.WeatherManager
		local weather = wm and wm.getWeather and wm.getWeather() or "Clear"
		if weather ~= lastWeather then
			lastWeather = weather
			applyForWeather(weather)
		end
		task.wait(POLL_INTERVAL)
	end
end)

applyForWeather("Clear")

local OceanManager = {}
function OceanManager.getWindStrength()
	local wm = _G.WeatherManager
	local weather = (wm and wm.getWeather and wm.getWeather()) or "Clear"
	return Config.Wind.Speed[weather] or Config.Wind.Speed.Clear
end
function OceanManager.getWindDirection()
	local wm = _G.WeatherManager
	if wm and wm.getWindDirection then return wm.getWindDirection() end
	return Vector3.new(1, 0, 0)
end

_G.OceanManager = OceanManager
print("[OceanManager] Init -- native Terrain wave animation synced to weather")
