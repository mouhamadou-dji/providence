-- SurvivalBarsClient
-- Wires the manually-placed Blood/Food/Water vertical vial bars
-- (StarterGui._GUIs."Blood bar") to their real server-side values: BloodBar -> BleedManager's
-- bloodBar (fills on bleed hits, bursts at max), FoodBar -> Hunger, WaterBar -> Water. Each
-- bar's HP_BG1 is the static background/track and HP_BG3 is the fill -- both start at full
-- height (100%) as authored and stay that size; a UIGradient (Rotation=90, vertical)
-- Transparency sequence masks off the top portion instead, so the visible bottom portion
-- reads like a liquid rising in a vial without ever resizing/distorting the fill art.

local Players      = game:GetService("Players")
local RepStorage   = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Remotes   = require(RepStorage:WaitForChild("Shared",10):WaitForChild("RemoteEvents",10))
local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local RE_UpdateBloodBar = RepStorage:WaitForChild("RemoteEvents",10):WaitForChild("UpdateBloodBar",10)

local setBlood, setFood, setWater
local bloodBarFrame -- the BloodBar vial itself, hidden until blood actually rises

local function setupVerticalBar(barFrame)
	if not barFrame then return nil end
	local fill = barFrame:FindFirstChild("HP_BG3")
	if not fill then return nil end

	local grad = fill:FindFirstChildOfClass("UIGradient") or Instance.new("UIGradient")
	grad.Rotation = 90 -- vertical: t=0 top, t=1 bottom (confirmed empirically in Studio)
	grad.Parent = fill

	-- TweenService can't tween an arbitrary Attribute directly -- confirmed live, it threw
	-- "no property named 'FillFraction'" and silently never animated the bar at all -- so
	-- the fraction lives on a real NumberValue child instead, which TweenService supports
	-- natively.
	local nv = fill:FindFirstChild("FillFraction")
	if not nv or not nv:IsA("NumberValue") then
		if nv then nv:Destroy() end
		nv = Instance.new("NumberValue")
		nv.Name = "FillFraction"
		nv.Value = 1
		nv.Parent = fill
	end

	-- Bottom stays fixed/visible as the vial drains, so the hidden portion grows down from
	-- the top (t=0) as the fraction shrinks -- cutoff is how far down that hidden zone reaches.
	local function applyGradient()
		local fraction = math.clamp(nv.Value, 0, 1)
		local cutoff = math.clamp(1 - fraction, 0.001, 0.999)
		grad.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(cutoff, 1),
			NumberSequenceKeypoint.new(cutoff, 0),
			NumberSequenceKeypoint.new(1, 0),
		})
	end
	applyGradient()
	nv:GetPropertyChangedSignal("Value"):Connect(applyGradient)

	return function(fraction)
		fraction = math.clamp(fraction, 0, 1)
		TweenService:Create(nv, TweenInfo.new(0.15), { Value = fraction }):Play()
	end
end

local function acquireBars()
	local guiRoot    = playerGui:WaitForChild("_GUIs", 10)
	local barsFolder = guiRoot:WaitForChild("Blood bar", 10)
	local screenGui  = barsFolder:WaitForChild("ScreenGui", 10)
	local frame      = screenGui:WaitForChild("Frame", 10)
	bloodBarFrame = frame:FindFirstChild("BloodBar")
	setBlood = setupVerticalBar(bloodBarFrame)
	setFood  = setupVerticalBar(frame:FindFirstChild("FoodBar"))
	setWater = setupVerticalBar(frame:FindFirstChild("WaterBar"))
	-- Blood vial starts hidden: an empty blood bar sitting on screen at all times is just
	-- noise. It reveals itself the moment blood actually starts rising (see the remote below)
	-- and hides again once you've stopped bleeding.
	if bloodBarFrame then bloodBarFrame.Visible = false end
end
acquireBars()
-- _GUIs re-clones fresh from StarterGui on every respawn (same as HUDManager's ABYSSHud refs)
player.CharacterAdded:Connect(function() task.wait(0.25); acquireBars() end)

RE_UpdateBloodBar.OnClientEvent:Connect(function(data)
	if setBlood and data.max and data.max > 0 then setBlood(data.blood / data.max) end
	-- Show only while there is blood on the bar. Driven off the same payload that fills it,
	-- so it can never be visible-but-empty or bleeding-but-hidden.
	if bloodBarFrame then bloodBarFrame.Visible = (tonumber(data.blood) or 0) > 0 end
end)

Remotes.UpdateHUD.OnClientEvent:Connect(function(data)
	if setFood  and data.Hunger ~= nil then setFood(data.Hunger / (data.HungerMax or 100)) end
	if setWater and data.Water  ~= nil then setWater(data.Water / (data.WaterMax or 100)) end
end)

print("[SurvivalBarsClient] ready")
