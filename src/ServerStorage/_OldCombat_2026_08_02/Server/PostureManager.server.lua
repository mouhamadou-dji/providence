-- PostureManager — Module 5
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local postureCfg, scalingCfg, combatCfg
do
    local ok, result = pcall(function()
        local shared = RepStorage:WaitForChild("Shared", 5)
        return require(shared:WaitForChild("Config", 3))
    end)
    if ok and result then
        postureCfg = result.Posture
        scalingCfg = result.StatScaling
        combatCfg = result.Combat
    end
end
postureCfg = postureCfg or {
    Max = 100,
    FillWhiff = 15,
    FillGotParried = 20,
    FillBlock = 10,
    DrainRateNatural = 5,
    DrainRateManual = 15,
    DrainRateInCombat = 0,
    GuardBreakDuration = 1.5,
}
scalingCfg = scalingCfg or { EndurancePerPoint = 0.005 }
combatCfg = combatCfg or { SpeedGuardBreak = 0 }

local GUARD_BREAK_DURATION = postureCfg.GuardBreakDuration or 1.5
local Util; pcall(function() Util=require(RepStorage:WaitForChild("Shared",3):WaitForChild("Util",3)) end)
local function getScaledValue(b,s,r) if Util then return Util.getScaledValue(b,s,r) end;return b+(b*(s*r)) end
-- Endurance scales the base max multiplicatively; the Belgae caste's MaxPostureBonus is a
-- flat purity-scaled addition on top (+10 at Purity 100). Read fresh every call, never
-- cached, so a mod-panel purity change lands on the next posture tick.
local function getPlayerMax(player)
    local dm=_G.DataManager;if not dm then return postureCfg.Max end
    local stats=dm.getValue(player,"Stats")
    local end_=(type(stats)=="table" and stats.Endurance) or 0
    local cm=_G.CasteManager
    return getScaledValue(postureCfg.Max,end_,scalingCfg.EndurancePerPoint)
        + (cm and cm.getMaxPostureBonus(player) or 0)
end

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

local RE_UpdatePostureBar    = getOrCreate("UpdatePostureBar")
local RE_OnGuardBreak        = getOrCreate("OnGuardBreak")
local RE_RequestPostureDrain = getOrCreate("RequestPostureDrain")
local RE_PlayCombatAnim      = getOrCreate("PlayCombatAnim")

local pState = {}

local function initState(userId)
    pState[userId] = {
        posture          = 0,
        guardBrokenUntil = 0,
        manualDraining   = false,
    }
end

local function getPS(player) return pState[player.UserId] end

local function fireUpdate(player, value)
    RE_UpdatePostureBar:FireClient(player, { posture = value, max = getPlayerMax(player) })
end

local function triggerGuardBreak(player)
    local s = getPS(player)
    if not s then return end
    s.posture = 0
    s.guardBrokenUntil = tick() + GUARD_BREAK_DURATION
    local cm = _G.CombatManager
    if cm then
        cm.setCombatState(player, "GuardBroken")
        cm.setSpeed(player, combatCfg.SpeedGuardBreak)
    end
    fireUpdate(player, 0)
    RE_OnGuardBreak:FireClient(player, { duration = GUARD_BREAK_DURATION })
    RE_PlayCombatAnim:FireClient(player, "GuardBroken", 1)
    print(string.format("[PostureManager] %s GUARD BREAK — stunned %.1fs", player.Name, GUARD_BREAK_DURATION))
    task.delay(GUARD_BREAK_DURATION, function()
        local cur = getPS(player)
        if not cur then return end
        local cm2 = _G.CombatManager
        if cm2 and cm2.getCombatState(player) == "GuardBroken" then
            cm2.setCombatState(player, "Idle")
            cm2.setSpeed(player, 1)
        end
    end)
end

local PostureManager = {}

function PostureManager.get(player)
    local s = getPS(player)
    return s and s.posture or 0
end

function PostureManager.set(player, value)
    local s = getPS(player)
    if not s then return end
    s.posture = math.clamp(value, 0, getPlayerMax(player))
    fireUpdate(player, s.posture)
end

function PostureManager.reset(player)
    local s = getPS(player)
    if not s then return end
    s.posture = 0
    fireUpdate(player, 0)
end

function PostureManager.fill(player, amount)
    local s = getPS(player)
    if not s then return end
    if tick() < s.guardBrokenUntil then return end
    local newValue = s.posture + amount
    if newValue >= getPlayerMax(player) then
        triggerGuardBreak(player)
    else
        s.posture = newValue
        fireUpdate(player, s.posture)
    end
end

function PostureManager.drain(player, amount)
    local s = getPS(player)
    if not s then return end
    s.posture = math.max(0, s.posture - amount)
    fireUpdate(player, s.posture)
end

-- Public read of the same formula fill/isAtMax use -- the mod panel's Player Info Viewer needs
-- the number, and must never re-derive it independently or the two can silently drift.
function PostureManager.getMax(player)
    return getPlayerMax(player)
end

function PostureManager.isAtMax(player)
    local s = getPS(player)
    return s ~= nil and s.posture >= getPlayerMax(player)
end

function PostureManager.isGuardBroken(player)
    local s = getPS(player)
    return s ~= nil and tick() < s.guardBrokenUntil
end

function PostureManager.triggerGuardBreak(player)
    triggerGuardBreak(player)
end

function PostureManager.getMax(player)
    return getPlayerMax(player)
end

function PostureManager.recalculateMax(player)
    local s = getPS(player)
    if not s then return end
    fireUpdate(player, s.posture)
end

function PostureManager.setManualDrain(player, active)
    local s = getPS(player)
    if s then s.manualDraining = active end
end

_G.PostureManager = PostureManager

RE_RequestPostureDrain.OnServerEvent:Connect(function(player, active)
    local s = getPS(player)
    if not s then return end
    s.manualDraining = (active == true)
end)

RunService.Heartbeat:Connect(function(dt)
    for _, player in ipairs(Players:GetPlayers()) do
        local s = getPS(player)
        if not s then continue end
        if s.posture <= 0 then continue end
        if tick() < s.guardBrokenUntil then continue end

        local sm = _G.StaminaManager
        local inCombat = sm and sm.isInCombat and sm.isInCombat(player)

        local drainRate
        if s.manualDraining then
            local char = player.Character
            local hum  = char and char:FindFirstChildOfClass("Humanoid")
            local moving = hum and hum.MoveDirection.Magnitude > 0.1
            if moving then
                drainRate = inCombat and postureCfg.DrainRateInCombat or postureCfg.DrainRateNatural
            else
                drainRate = postureCfg.DrainRateManual
            end
        else
            drainRate = inCombat and postureCfg.DrainRateInCombat or postureCfg.DrainRateNatural
        end

        if drainRate <= 0 then continue end

        local newPosture = math.max(0, s.posture - drainRate * dt)
        if math.abs(newPosture - s.posture) > 0.01 then
            s.posture = newPosture
            fireUpdate(player, s.posture)
        end
    end
end)

Players.PlayerAdded:Connect(function(player)
    initState(player.UserId)
    player.CharacterAdded:Connect(function()
        -- Reset on every respawn, not just first join -- dying with leftover posture,
        -- mid-guard-break, or with manual drain still flagged active otherwise carried that
        -- stale state onto the fresh character (e.g. the posture bar showing leftover fill
        -- or guard-break gating fill() for up to 1.5s on a body that never actually broke).
        initState(player.UserId)
        fireUpdate(player, 0)
    end)
end)
Players.PlayerRemoving:Connect(function(player)
    pState[player.UserId] = nil
end)
for _, p in ipairs(Players:GetPlayers()) do
    initState(p.UserId)
end

print(string.format(
    "[PostureManager] Init — Max=%d | Whiff+%d | GotParried+%d | Block+%d | Natural-%.0f/s | Manual-%.0f/s | BreakDur=%.1fs",
    postureCfg.Max, postureCfg.FillWhiff, postureCfg.FillGotParried,
    postureCfg.FillBlock, postureCfg.DrainRateNatural,
    postureCfg.DrainRateManual, GUARD_BREAK_DURATION
))
