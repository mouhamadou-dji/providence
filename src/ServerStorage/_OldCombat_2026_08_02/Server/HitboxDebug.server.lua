-- HitboxDebug.server.lua
-- Toggle hitbox visualization in Studio.
-- DISABLE this script (right-click → Disable) to turn off. No code changes needed.
-- Colors: orange=M1, yellow=M1Running, cyan=M1Aerial, red=M2

local Debris = game:GetService("Debris")

local COLORS = {
    M1        = Color3.fromRGB(255, 165, 0),
    M1Running = Color3.fromRGB(255, 220, 0),
    M1Aerial  = Color3.fromRGB(0, 200, 255),
    M2        = Color3.fromRGB(255, 50,  50),
}

_G.DEBUG_HITBOXES = function(boxCF, size, key)
    local p = Instance.new("Part")
    p.Size        = size
    p.CFrame      = boxCF
    p.Anchored    = true
    p.CanCollide  = false
    p.CanQuery    = false -- must not be detected by the very hitbox query it's visualizing
    p.Material    = Enum.Material.Neon
    p.Color       = COLORS[key] or Color3.fromRGB(200, 200, 200)
    p.Transparency = 0.55
    p.Parent      = workspace
    Debris:AddItem(p, 0.25)
end

print("[HitboxDebug] ON — orange=M1  yellow=M1Run  cyan=M1Air  red=M2 | disable script to turn off")