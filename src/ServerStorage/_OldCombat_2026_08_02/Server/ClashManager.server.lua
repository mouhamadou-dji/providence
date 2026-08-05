-- ClashManager — Module 6
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")

local clashCfg, staminaCfg
do
    local ok, result = pcall(function()
        local shared = RepStorage:WaitForChild("Shared", 5)
        return require(shared:WaitForChild("Config", 3))
    end)
    if ok and result then
        clashCfg   = result.Clash
        staminaCfg = result.Stamina
    end
end
clashCfg = clashCfg or {
    InputRaceTime = 3, SequenceLength = 5,
    LoserStaggerDuration = 0.8, LoserStaminaDrain = 10,
}
staminaCfg = staminaCfg or { CostClashEnter = 15, CostClashWinRefund = 10 }

local M2_SWING_SEC = 0.8
local INPUT_POOL   = {1, 2, 3, 4}

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

local RE_OnClashStart  = getOrCreate("OnClashStart")
local RE_OnClashResult = getOrCreate("OnClashResult")

local CombatSounds = RepStorage:FindFirstChild("_Sounds") and RepStorage._Sounds:FindFirstChild("Combat")
local function playClashSound(position)
    local snd = CombatSounds and CombatSounds:FindFirstChild("Clash_Start")
    local id = snd and snd.SoundId
    if not id or id == "" or id == "rbxassetid://0" or not position then return end
    local anchor = Instance.new("Part")
    anchor.Anchored=true; anchor.CanCollide=false; anchor.CanQuery=false
    anchor.Transparency=1; anchor.Size=Vector3.new(0.2,0.2,0.2)
    anchor.CFrame=CFrame.new(position); anchor.Parent=workspace
    local s = Instance.new("Sound")
    s.SoundId = id; s.Volume = 0.7
    s.Parent = anchor
    s:Play()
    -- Destroy the anchor once the sound actually finishes, not on a fixed timer -- a fixed
    -- delay can destroy it before a slower-to-stream asset ever finishes (or even starts)
    -- playing. task.delay is only a safety net for sounds that never fire Ended.
    local cleaned = false
    local function cleanup() if not cleaned then cleaned = true; if anchor.Parent then anchor:Destroy() end end end
    s.Ended:Once(cleanup)
    task.delay(8, cleanup)
end

local m2Active = {}
local clashes  = {}

local function getKey(uid1, uid2)
    if uid1 < uid2 then return uid1 .. "_" .. uid2
    else return uid2 .. "_" .. uid1 end
end

local function generateSeq()
    local s = {}
    for i = 1, clashCfg.SequenceLength do
        s[i] = INPUT_POOL[math.random(1, #INPUT_POOL)]
    end
    return s
end

local resolveClash

resolveClash = function(key, winner)
    local clash = clashes[key]
    if not clash or clash.resolved then return end
    clash.resolved = true
    clashes[key] = nil

    local cm = _G.CombatManager
    local sm = _G.StaminaManager
    local p1, p2 = clash.p1, clash.p2

    if winner then
        local loser = (winner.UserId == p1.UserId) and p2 or p1
        if sm then sm.refund(winner, staminaCfg.CostClashWinRefund) end
        if cm then cm.setCombatState(winner, "Idle"); cm.setSpeed(winner, 1) end
        RE_OnClashResult:FireClient(winner, { result = "Win", opponentName = loser.Name })
        if cm then cm.applyStagger(loser, clashCfg.LoserStaggerDuration) end
        if sm then sm.drain(loser, clashCfg.LoserStaminaDrain, true) end
        RE_OnClashResult:FireClient(loser, { result = "Loss", opponentName = winner.Name })
        print(string.format("[ClashManager] %s WINS vs %s", winner.Name, loser.Name))
    else
        if cm then
            cm.setCombatState(p1, "Idle"); cm.setSpeed(p1, 1)
            if p2 ~= p1 then cm.setCombatState(p2, "Idle"); cm.setSpeed(p2, 1) end
        end
        RE_OnClashResult:FireClient(p1, { result = "Draw" })
        if p2 ~= p1 then RE_OnClashResult:FireClient(p2, { result = "Draw" }) end
        print("[ClashManager] Clash DRAW (timeout)")
    end
end

local function startClash(p1, p2)
    local key = getKey(p1.UserId, p2.UserId)
    if clashes[key] then return end

    local seq = generateSeq()
    local sm  = _G.StaminaManager
    if sm then
        sm.drain(p1, staminaCfg.CostClashEnter, true)
        sm.drain(p2, staminaCfg.CostClashEnter, true)
    end

    local cm = _G.CombatManager
    if cm then
        cm.setCombatState(p1, "Clashing")
        cm.setCombatState(p2, "Clashing")
        cm.setSpeed(p1, 0)
        cm.setSpeed(p2, 0)
    end

    clashes[key] = {
        p1 = p1, p2 = p2,
        sequence = seq,
        progress = { [p1.UserId] = 0, [p2.UserId] = 0 },
        resolved = false,
    }

    RE_OnClashStart:FireClient(p1, { sequence=seq, opponentName=p2.Name, duration=clashCfg.InputRaceTime })
    if p2 ~= p1 then
        RE_OnClashStart:FireClient(p2, { sequence=seq, opponentName=p1.Name, duration=clashCfg.InputRaceTime })
    end
    local clashMidpoint = nil
    if cm and cm.spawnClashSpark then
        local c1=p1.Character; local c2=p2.Character
        local h1=c1 and c1:FindFirstChild("HumanoidRootPart")
        local h2=c2 and c2:FindFirstChild("HumanoidRootPart")
        if h1 and h2 then
            clashMidpoint = (h1.Position+h2.Position)/2
            cm.spawnClashSpark(clashMidpoint)
        end
    end
    playClashSound(clashMidpoint)

    -- PLACEHOLDER_ANIMATION: clash_lock — replace with actual AnimationId
    print(string.format("[ClashManager] CLASH: %s vs %s | seq=[%s]",
        p1.Name, p2.Name, table.concat(seq, ",")))

    task.delay(clashCfg.InputRaceTime, function()
        resolveClash(key, nil)
    end)
end

local function handleInput(player, input)
    for key, c in pairs(clashes) do
        if c.resolved then continue end
        if c.p1.UserId ~= player.UserId and c.p2.UserId ~= player.UserId then continue end
        local prog = c.progress[player.UserId]
        if not prog then return end
        if input ~= c.sequence[prog + 1] then return end
        c.progress[player.UserId] = prog + 1
        if c.progress[player.UserId] >= clashCfg.SequenceLength then
            resolveClash(key, player)
        end
        return
    end
end

getOrCreate("RequestClashInput").OnServerEvent:Connect(function(player, data)
    if type(data) == "table" and data.input then
        handleInput(player, data.input)
    end
end)

local function cancelPlayerClashes(player)
    m2Active[player.UserId] = nil
    for key, c in pairs(clashes) do
        if c.p1.UserId == player.UserId or c.p2.UserId == player.UserId then
            resolveClash(key, nil)
        end
    end
end

Players.PlayerRemoving:Connect(cancelPlayerClashes)
-- Dying mid-clash (not just leaving the server) otherwise left the OTHER player locked at
-- speed=0/CombatState="Clashing" until the full 3s input-race timeout expired on its own --
-- resolve immediately as a draw instead so they aren't stuck frozen for however long is left.
Players.PlayerAdded:Connect(function(player)
    player.CharacterRemoving:Connect(function() cancelPlayerClashes(player) end)
end)

local ClashManager = {}

function ClashManager.registerM2Swing(player)
    m2Active[player.UserId] = tick() + M2_SWING_SEC
end

function ClashManager.checkClash(attacker, victim)
    if attacker == victim then return false end
    local swing = m2Active[victim.UserId]
    if not swing or tick() > swing then return false end
    local cm = _G.CombatManager
    if cm then
        if cm.getCombatState(attacker) == "Clashing" then return false end
        if cm.getCombatState(victim) == "Clashing" then return false end
    end
    startClash(attacker, victim)
    return true
end

function ClashManager.startClash(p1, p2)
    startClash(p1, p2)
end

function ClashManager.isClashing(player)
    for _, c in pairs(clashes) do
        if not c.resolved and (c.p1.UserId == player.UserId or c.p2.UserId == player.UserId) then
            return true
        end
    end
    return false
end

function ClashManager.getSequence(player)
    for _, c in pairs(clashes) do
        if c.p1.UserId == player.UserId or c.p2.UserId == player.UserId then
            return c.sequence
        end
    end
    return nil
end

function ClashManager.getProgress(player)
    for _, c in pairs(clashes) do
        if c.p1.UserId == player.UserId or c.p2.UserId == player.UserId then
            return c.progress[player.UserId]
        end
    end
    return nil
end

function ClashManager.submitInput(player, input)
    handleInput(player, input)
end

_G.ClashManager = ClashManager

print(string.format(
    "[ClashManager] Init — RaceTime=%.1fs | Seq=%d | LoserStagger=%.1fs | LoserStam=%d | Enter=%d | WinRefund=%d",
    clashCfg.InputRaceTime, clashCfg.SequenceLength,
    clashCfg.LoserStaggerDuration, clashCfg.LoserStaminaDrain,
    staminaCfg.CostClashEnter, staminaCfg.CostClashWinRefund
))
