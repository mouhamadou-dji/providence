-- FloatablesManager
-- Makes the parkour "floatable" rock clusters in workspace.'void place' gently bob up and
-- down in place. Every part in a floatable folder is Anchored, so this drives them purely
-- via CFrame (never physics/velocity/BodyMovers) -- that's what keeps a platform players
-- have to jump on perfectly stable while it's moving, instead of jittering or drifting.
local RunService = game:GetService("RunService")

local FLOATABLE_NAMES = {"floatable 1","Floatable 2","floatable 3","floatable 4","Floatable 5"}
local AMPLITUDE = 1.5 -- studs of vertical sway -- small and slow on purpose so it stays safe to land on
local PERIOD    = 6   -- seconds per full up-down cycle

local vp = workspace:WaitForChild("void place")
local rigs = {}

for i, name in ipairs(FLOATABLE_NAMES) do
	local folder = vp:FindFirstChild(name)
	if folder then
		local parts = {}
		for _, p in ipairs(folder:GetChildren()) do
			if p:IsA("BasePart") then
				parts[#parts+1] = {inst = p, base = p.CFrame}
			end
		end
		-- Stagger each floatable's phase so all five don't bob in perfect unison -- purely
		-- cosmetic variety, doesn't affect how stable any single one is to stand on.
		rigs[#rigs+1] = {parts = parts, phase = (i-1) * (math.pi/2)}
	else
		warn("[FloatablesManager] floatable folder not found: "..name)
	end
end

-- Every part in a rig gets the SAME offset every frame, computed from its own captured
-- base CFrame (never re-reading .CFrame each tick) -- that's what keeps every rock in a
-- multi-part floatable moving as one rigid slab instead of drifting apart or jittering.
RunService.Heartbeat:Connect(function()
	local t = tick()
	for _, rig in ipairs(rigs) do
		local yOffset = math.sin(t * (2*math.pi/PERIOD) + rig.phase) * AMPLITUDE
		local delta = Vector3.new(0, yOffset, 0)
		for _, entry in ipairs(rig.parts) do
			entry.inst.CFrame = entry.base + delta
		end
	end
end)

print(string.format("[FloatablesManager] Init — %d floatable(s) bobbing (amp=%.1f period=%.0fs)", #rigs, AMPLITUDE, PERIOD))
