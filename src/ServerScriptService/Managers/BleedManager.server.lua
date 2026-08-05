-- BleedManager
-- Full bleed / blood-bar-burst system: dagger/spear hits (and heavy crits) apply stacking
-- bleed DoTs. Each application also fills a HIDDEN per-player "blood bar" (0-100, never
-- shown to the player) -- at 100 it triggers a big damage-spike "blood burst" that clears
-- every active bleed and resets the bar. ClearBleeds/ReduceBloodBar are public hooks for
-- future items (bandages, healing potions, etc). All tuning values live in Config.Bleed.

local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local bleedCfg
do
    local ok, cfg = pcall(function() return require(RepStorage:WaitForChild("Shared",5):WaitForChild("Config",3)) end)
    if ok and cfg then bleedCfg = cfg.Bleed end
end
bleedCfg = bleedCfg or {
    BloodBarMax = 100, BurstDamage = 30, BloodBarDecayRate = 3,
    Tiers = {
        Light  = { drainPerSec = 1.5, duration = 4, bloodBarFill = 12 },
        Medium = { drainPerSec = 2.5, duration = 5, bloodBarFill = 22 },
        Heavy  = { drainPerSec = 4,   duration = 6, bloodBarFill = 35 },
    },
}

-- Blood bar is no longer purely internal -- a real BloodBar UI now exists client-side,
-- so every change needs to actually replicate instead of staying server-only.
local function getOrCreateRE(name)
    local folder = RepStorage:FindFirstChild("RemoteEvents")
        or (function() local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f end)()
    local r = folder:FindFirstChild(name)
    if r then return r end
    r = Instance.new("RemoteEvent"); r.Name = name; r.Parent = folder
    return r
end
local RE_UpdateBloodBar = getOrCreateRE("UpdateBloodBar")

local pState = {}

local function initState(userId)
    pState[userId] = { bloodBar = 0, activeBleeds = {}, dripEmitter = nil }
end

local CombatSounds = RepStorage:FindFirstChild("_Sounds") and RepStorage._Sounds:FindFirstChild("Combat")
local function playBloodBurstSound(hrp)
    local snd = CombatSounds and CombatSounds:FindFirstChild("Blood_Burst")
    local id = snd and snd.SoundId
    if not id or id == "" or id == "rbxassetid://0" or not hrp then return end
    local s = Instance.new("Sound")
    s.SoundId = id; s.Volume = 0.7
    s.Parent = hrp
    s:Play()
    -- Destroy once actually finished, not on a fixed timer -- see CombatManager.playSound3D
    -- for why a fixed Debris delay can silently eat a slower-to-load sound entirely.
    local cleaned = false
    local function cleanup() if not cleaned then cleaned = true; if s.Parent then s:Destroy() end end end
    s.Ended:Once(cleanup)
    task.delay(8, cleanup)
end

local function getPS(player) return pState[player.UserId] end

local function syncBloodBar(player)
    local s = getPS(player); if not s then return end
    RE_UpdateBloodBar:FireClient(player, { blood = s.bloodBar, max = bleedCfg.BloodBarMax })
end

-- Persistent drip particle, toggled/scaled like MovementManager's momentum-dust convention
local function ensureDripEmitter(player, char)
    local s = getPS(player); if not s then return nil end
    if s.dripEmitter and s.dripEmitter.Parent then return s.dripEmitter end
    local hrp = char and char:FindFirstChild("HumanoidRootPart"); if not hrp then return nil end
    local e = Instance.new("ParticleEmitter")
    e.Name = "BleedDrip"
    e.Color = ColorSequence.new(Color3.fromRGB(120,10,10))
    e.Size = NumberSequence.new(0.15)
    e.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,0.2),NumberSequenceKeypoint.new(1,1)})
    e.Speed = NumberRange.new(0.5,1.5)
    e.Lifetime = NumberRange.new(0.4,0.7)
    e.Rate = 0
    e.Acceleration = Vector3.new(0,-15,0)
    e.Parent = hrp
    s.dripEmitter = e
    return e
end

local function destroyDripEmitter(s)
    if s.dripEmitter then s.dripEmitter:Destroy(); s.dripEmitter=nil end
end

local function triggerBloodBurst(player)
    local s = getPS(player); if not s then return end
    s.activeBleeds = {}
    s.bloodBar = 0
    syncBloodBar(player)
    destroyDripEmitter(s)
    local char = player.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        local hrp = char:FindFirstChild("HumanoidRootPart")
        local cm = _G.CombatManager
        if hum and hum.Health > 0 and cm then
            cm.applyDamage(hum, bleedCfg.BurstDamage, player, "Player")
        end
        if hrp and cm and cm.spawnBloodBurst then
            cm.spawnBloodBurst(hrp.Position, 2.2)
        end
        playBloodBurstSound(hrp)
    end
    print("[BleedManager] "..player.Name.." BLOOD BURST -- "..bleedCfg.BurstDamage.." dmg, all bleeds cleared")
end

local function addBloodBar(player, amount)
    local s = getPS(player); if not s then return end
    s.bloodBar = math.min(bleedCfg.BloodBarMax, s.bloodBar + amount)
    if s.bloodBar >= bleedCfg.BloodBarMax then
        triggerBloodBurst(player)
    else
        syncBloodBar(player)
    end
end

local function applyBleed(player, tierName)
    local tier = bleedCfg.Tiers[tierName]; if not tier then return end
    local s = getPS(player); if not s then return end
    local char = player.Character; if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid"); if not hum or hum.Health<=0 then return end

    table.insert(s.activeBleeds, { drainPerSec = tier.drainPerSec, expiresAt = tick()+tier.duration, tier = tierName })
    ensureDripEmitter(player, char)
    addBloodBar(player, tier.bloodBarFill)
    print(string.format("[BleedManager] %s bleeding (%s) -- bloodBar=%.0f/%.0f", player.Name, tierName, s.bloodBar, bleedCfg.BloodBarMax))
end

RunService.Heartbeat:Connect(function(dt)
    for _, p in ipairs(Players:GetPlayers()) do
        local s = pState[p.UserId]; if not s then continue end
        if #s.activeBleeds == 0 then
            -- Blood bar slowly clots back down over time when not actively bleeding,
            -- instead of sitting wherever it was left until the next burst.
            if s.bloodBar > 0 then
                s.bloodBar = math.max(0, s.bloodBar - (bleedCfg.BloodBarDecayRate or 3) * dt)
                syncBloodBar(p)
            end
            continue
        end

        local now = tick()
        local totalDrain = 0
        for i = #s.activeBleeds, 1, -1 do
            local b = s.activeBleeds[i]
            if now >= b.expiresAt then
                table.remove(s.activeBleeds, i)
            else
                totalDrain += b.drainPerSec
            end
        end

        local char = p.Character
        if #s.activeBleeds == 0 then
            destroyDripEmitter(s)
        else
            local e = ensureDripEmitter(p, char)
            if e then e.Rate = 3 * #s.activeBleeds end
        end

        if totalDrain > 0 then
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 then
                local cm = _G.CombatManager
                if cm then cm.applyDamage(hum, totalDrain*dt, p, "Player") end
            end
        end
    end
end)

Players.PlayerAdded:Connect(function(p)
    initState(p.UserId)
    syncBloodBar(p)
    p.CharacterRemoving:Connect(function()
        local s = getPS(p); if s then destroyDripEmitter(s) end
    end)
end)
Players.PlayerRemoving:Connect(function(p) pState[p.UserId] = nil end)
for _, p in ipairs(Players:GetPlayers()) do initState(p.UserId) end

local BleedManager = {}
function BleedManager.applyBleed(player, tierName) applyBleed(player, tierName) end
function BleedManager.ClearBleeds(player)
    local s = getPS(player); if not s then return end
    s.activeBleeds = {}
    destroyDripEmitter(s)
end
function BleedManager.ReduceBloodBar(player, amount)
    local s = getPS(player); if not s then return end
    s.bloodBar = math.max(0, s.bloodBar - amount)
    syncBloodBar(player)
end
function BleedManager.getBloodBar(player)
    local s = getPS(player); return s and s.bloodBar or 0
end
function BleedManager.getActiveBleedCount(player)
    local s = getPS(player); return s and #s.activeBleeds or 0
end
_G.BleedManager = BleedManager

print(string.format("[BleedManager] Init -- Light/Medium/Heavy tiers | BloodBarMax=%d | Burst=%d dmg",
    bleedCfg.BloodBarMax, bleedCfg.BurstDamage))
