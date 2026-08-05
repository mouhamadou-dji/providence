-- QTEManager — central QTE system (Part Five foundation for meditation, pushups,
-- interactables, and mod-triggered QTEs)
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local QTE_TIERS = Config.QTETiers

local function getOrCreate(name, isFunc)
    local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
        local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
    end)()
    local r=folder:FindFirstChild(name); if r then return r end
    r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_QTEStart   = getOrCreate("QTEStart")
local RE_QTESubmit  = getOrCreate("QTESubmitResult")
local RE_QTEOutcome = getOrCreate("QTEOutcome")

local pending = {} -- [instanceId] = {player, tierName, tierCfg, context, callback, startedAt, deadline, minTime, resolved}
local nextId = 0

local function genId()
    nextId += 1
    return tostring(os.time()) .. ":" .. tostring(nextId)
 end

-- Rough plausible time floor per tier type so an instant-fake QTESubmitResult fired directly
-- at the remote can't zero-time every QTE. This is deliberately NOT full server-side
-- keystroke validation (unlike ClashManager's PvP input race) -- meditation/pushups/
-- interactables are cooperative flavor systems, not competitive, so a sanity floor + real
-- deadline is judged sufficient here.
local function computeWindow(tierCfg)
    if tierCfg.type == "SequenceInput" then
        return tierCfg.length * tierCfg.timePerInput, tierCfg.length * 0.15
    elseif tierCfg.type == "MonkeyType" then
        return tierCfg.timeTotal, tierCfg.wordCount * 0.3
    elseif tierCfg.type == "GreenBar" then
        return tierCfg.attempts * (1 / tierCfg.barSpeed) + 2, 0.2
    elseif tierCfg.type == "CircleClose" then
        return tierCfg.circleDuration + tierCfg.toleranceWindow + 1, tierCfg.circleDuration * 0.5
    elseif tierCfg.type == "ReactiveClick" then
        -- Mining (design doc PART TWO): 3s tension build + one ~3s countdown per click,
        -- scaled down by countdownSpeed (rarer ore = faster countdowns).
        local perClick = 3 / (tierCfg.countdownSpeed or 1)
        return tierCfg.clickCount * perClick + 3, tierCfg.clickCount * (perClick * 0.3)
    end
    return 10, 0.2
end

-- Server generates the random content (sequence / words) so both sides agree on what's
-- actually being asked -- client never invents its own answer key.
local function buildContent(tierCfg)
    if tierCfg.type == "SequenceInput" then
        local seq = {}
        for i = 1, tierCfg.length do seq[i] = tierCfg.pool[math.random(1, #tierCfg.pool)] end
        return { sequence = seq }
    elseif tierCfg.type == "MonkeyType" then
        local words = {}
        for i = 1, tierCfg.wordCount do words[i] = tierCfg.wordPool[math.random(1, #tierCfg.wordPool)] end
        return { words = words }
    end
    return {}
end

local QTEManager = {}

-- context: free-form table describing the source (e.g. {source="Meditation"}), echoed back
-- to callback and used for Discord/logging context. callback(player, success, instanceId).
-- overrideCfg (optional): per-attempt field overrides merged onto a COPY of the named
-- tier's config -- lets a caller like MiningManager vary click count/tolerance/speed by ore
-- rarity + player Endurance without mutating the shared Config.QTETiers table (which would
-- race if two players started different-rarity mining QTEs at the same time).
function QTEManager.startQTE(player, tierName, context, callback, overrideCfg)
    local baseCfg = QTE_TIERS[tierName]
    if not baseCfg then warn("[QTEManager] Unknown tier: " .. tostring(tierName)); return nil end
    local tierCfg = baseCfg
    if overrideCfg then
        tierCfg = table.clone(baseCfg)
        for k, v in pairs(overrideCfg) do tierCfg[k] = v end
    end
    if not player.Character then return nil end
    local window, minTime = computeWindow(tierCfg)
    local instanceId = genId()
    local content = buildContent(tierCfg)
    pending[instanceId] = {
        player = player, tierName = tierName, tierCfg = tierCfg, context = context, callback = callback,
        startedAt = tick(), deadline = tick() + window + 1.0, minTime = minTime, resolved = false,
    }
    RE_QTEStart:FireClient(player, {
        instanceId = instanceId, tierName = tierName, tierConfig = tierCfg, content = content,
        window = window, context = context,
    })
    print(string.format("[QTEManager] %s QTE started (%s, tier=%s, window=%.1fs)",
        player.Name, (context and context.source) or "?", tierName, window))
    -- Timeout watchdog: if the client never submits, this settles it as a fail once the
    -- window truly closes. resolve() below is idempotent (guarded by `resolved`), so this
    -- racing harmlessly against a real submission is fine either way.
    task.delay(window + 1.5, function()
        QTEManager._resolve(instanceId, false)
    end)
    return instanceId
end

function QTEManager.cancelQTE(instanceId)
    local p = pending[instanceId]
    if not p or p.resolved then return end
    p.resolved = true
    pending[instanceId] = nil
end

-- Cancels every pending QTE for a player (they moved/died/left mid meditation/pushups).
function QTEManager.cancelAllFor(player)
    for id, p in pairs(pending) do
        if p.player == player and not p.resolved then
            p.resolved = true
            pending[id] = nil
        end
    end
end

function QTEManager._resolve(instanceId, success)
    local p = pending[instanceId]
    if not p or p.resolved then return end
    p.resolved = true
    pending[instanceId] = nil
    RE_QTEOutcome:FireClient(p.player, { instanceId = instanceId, success = success })
    local disc = _G.DiscordManager
    if disc then disc.logQTEResult(p.player, success, (p.context and p.context.source) or p.tierName) end
    if p.callback then
        local ok, err = pcall(p.callback, p.player, success, instanceId)
        if not ok then warn("[QTEManager] callback error: " .. tostring(err)) end
    end
end

RE_QTESubmit.OnServerEvent:Connect(function(player, instanceId, success)
    local p = pending[instanceId]
    if not p or p.player ~= player or p.resolved then return end
    local elapsed = tick() - p.startedAt
    if elapsed < p.minTime or tick() > p.deadline then
        QTEManager._resolve(instanceId, false)
        return
    end
    QTEManager._resolve(instanceId, success == true)
end)

Players.PlayerRemoving:Connect(function(player)
    QTEManager.cancelAllFor(player)
end)

_G.QTEManager = QTEManager

local tierCount = 0
for _ in pairs(QTE_TIERS) do tierCount += 1 end
print(string.format("[QTEManager] Init — %d tiers", tierCount))
