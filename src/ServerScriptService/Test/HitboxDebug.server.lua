--[[
	HitboxDebug -- draws combat hitboxes so their size and placement can actually be seen.

	Restores the archived _OldCombat_2026_08_02.Server.HitboxDebug hook. MeleeCombat calls
	_G.DEBUG_HITBOXES(cf, size, key) from inside the overlap query itself, so what you see is
	the exact box that was tested -- not a re-derived guess that can drift from it.

	Studio-only: it returns before defining the hook on a live server, so the global stays nil
	and the call site's `if _G.DEBUG_HITBOXES` costs one nil check per query.

	Off by default. Turn it on from the command bar or a mod command:
	    _G.DEBUG_HITBOXES_ON = true
]]

local RunService = game:GetService("RunService")
local Debris     = game:GetService("Debris")

if not RunService:IsStudio() then return end

local LIFETIME = 0.25

_G.DEBUG_HITBOXES_ON = _G.DEBUG_HITBOXES_ON or false

_G.DEBUG_HITBOXES = function(cf, size, key)
	if not _G.DEBUG_HITBOXES_ON then return end
	local p = Instance.new("Part")
	p.Name = "HitboxDebug_" .. tostring(key or "?")
	p.Size = size
	p.CFrame = cf
	p.Anchored = true
	p.CanCollide = false
	-- CanQuery false is not cosmetic: without it the marker is itself returned by the very
	-- GetPartBoundsInBox call that drew it, and every swing "hits" its own debug part.
	p.CanQuery = false
	p.CanTouch = false
	p.Material = Enum.Material.Neon
	p.Color = Color3.fromRGB(255, 80, 80)
	p.Transparency = 0.75
	p.Parent = workspace
	Debris:AddItem(p, LIFETIME)
end

print("[HitboxDebug] Ready (Studio only) -- set _G.DEBUG_HITBOXES_ON = true to draw hitboxes")
