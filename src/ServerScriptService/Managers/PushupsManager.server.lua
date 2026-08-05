-- PushupsManager — Part Three (same shape as MeditationManager, no deep stage -- always
-- interruptible -- plus hunger/stamina drain per spec)
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config    = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local pushCfg   = Config.Pushups
local hungerCfg = Config.Hunger

local function getOrCreate(name, isFunc)
    local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
        local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
    end)()
    local r=folder:FindFirstChild(name); if r then return r end
    r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_OnFocusUpdate    = getOrCreate("OnFocusUpdate")
local RE_ShowNotification = getOrCreate("ShowNotification")
local RE_ModActionCard    = getOrCreate("ModActionCard")
local RE_LiveFeedUpdate   = getOrCreate("LiveFeedUpdate")

-- StaminaManager's own Heartbeat already drains Hunger at the base DrainPassiveRate for
-- everyone; pushups only needs to add the extra (multiplier-1)x on top of that baseline
-- while a session is active, rather than duplicating the whole passive-drain system here.
local EXTRA_HUNGER_RATE = math.max(0, pushCfg.HungerDrainMultiplier - 1) * hungerCfg.DrainPassiveRate

local sessions = {} -- [uid] = { player, startedAt, token, healthConn, lastHealth }

local function notify(player, title, body)
    RE_ShowNotification:FireClient(player, title, body, 4, "info")
end

local function fireLiveFeed(player, message)
    local dm = _G.DataManager
    local charName = (dm and dm.getValue(player, "FirstName")) or player.Name
    if not charName or charName == "" then charName = player.Name end
    local now = os.date("*t")
    local mgr = _G.ModManager
    for _, p in ipairs(Players:GetPlayers()) do
        if mgr and mgr.isMod(p) then
            RE_LiveFeedUpdate:FireClient(p, { type = "ACTION", h = now.hour, m = now.min, zone = "?", charName = charName, message = message })
        end
    end
end

local PushupsManager = {}

function PushupsManager.isFocusing(player)
    return sessions[player.UserId] ~= nil
end

local interrupt
interrupt = function(player, reason)
    local s = sessions[player.UserId]
    if not s then return end
    sessions[player.UserId] = nil
    if s.healthConn then s.healthConn:Disconnect() end
    local qte = _G.QTEManager
    if qte then qte.cancelAllFor(player) end
    RE_OnFocusUpdate:FireClient(player, { type = "Pushups", event = "End", reason = reason })
    local elapsed = tick() - s.startedAt
    fireLiveFeed(player, string.format("stopped pushups after %.0fs (%s)", elapsed, tostring(reason)))
    local disc = _G.DiscordManager
    if disc then disc.logPushups(player, "END", string.format("after %.0fs, reason=%s", elapsed, tostring(reason))) end
end

local function checkMilestone(player, count)
    local hit = false
    for _, m in ipairs(pushCfg.Milestones) do if count == m then hit = true end end
    if not hit then return false end
    fireLiveFeed(player, string.format("completed %d pushups QTEs", count))
    local disc = _G.DiscordManager
    if disc then disc.logPushups(player, "MILESTONE", count .. " QTEs passed") end
    return true
end

local function sendMilestoneCard(player, count)
    local dm = _G.DataManager
    local charName = (dm and dm.getValue(player, "FirstName")) or player.Name
    local mgr = _G.ModManager
    local payload = {
        id = "push_" .. player.UserId .. "_" .. tostring(count) .. "_" .. tostring(os.time()),
        category = "Pushups",
        title = "PUSHUPS MILESTONE",
        body = string.format("%s completed %d QTEs of pushups training.", charName, count),
        target = player.Name,
        buttons = {
            { label = "Grant Talent",   cmd = "grantTalent",   arg = "ReinforcedMuscles" },
            { label = "Grant Progress", cmd = "grantProgress", arg = "Pushups" },
            { label = "Dismiss" },
        },
    }
    for _, p in ipairs(Players:GetPlayers()) do
        if mgr and mgr.isMod(p) then RE_ModActionCard:FireClient(p, payload) end
    end
end

local scheduleNextCheck
local function triggerPushupsQTE(player, myToken)
    local s = sessions[player.UserId]
    if not s or s.token ~= myToken then return end
    local sm = _G.StaminaManager
    if sm and not sm.drain(player, pushCfg.StaminaDrainPerCycle) then
        interrupt(player, "ZeroStamina")
        return
    end
    local qte = _G.QTEManager
    if not qte then scheduleNextCheck(player, myToken); return end
    qte.startQTE(player, pushCfg.QTETier, { source = "Pushups" }, function(p, success)
        local cur = sessions[p.UserId]
        if not cur or cur.token ~= myToken then return end
        if success then
            local dmv = _G.DataManager
            local newCount = ((dmv and dmv.getValue(p, "PushupsQTEsPassed")) or 0) + 1
            if dmv then dmv.setValue(p, "PushupsQTEsPassed", newCount) end
            if checkMilestone(p, newCount) then sendMilestoneCard(p, newCount) end
            scheduleNextCheck(p, myToken)
        else
            interrupt(p, "QTEFail")
        end
    end)
end

scheduleNextCheck = function(player, myToken)
    task.delay(pushCfg.QTEInterval, function()
        local cur = sessions[player.UserId]
        if not cur or cur.token ~= myToken then return end
        if not player.Parent then return end
        triggerPushupsQTE(player, myToken)
    end)
end

local nextToken = 0
function PushupsManager.start(player)
    if sessions[player.UserId] then return end
    local char = player.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    local sm = _G.StaminaManager
    if sm and sm.get(player) <= 0 then return end
    local dm = _G.DataManager
    if dm and (dm.getValue(player, "Hunger") or 100) <= 0 then return end
    nextToken += 1
    local myToken = nextToken
    local s = { player = player, startedAt = tick(), token = myToken, lastHealth = hum.Health }
    sessions[player.UserId] = s
    s.healthConn = hum.HealthChanged:Connect(function(newHealth)
        local cur = sessions[player.UserId]
        if not cur or cur.token ~= myToken then return end
        if newHealth < cur.lastHealth then
            cur.lastHealth = newHealth
            interrupt(player, "Damage")
            return
        end
        cur.lastHealth = newHealth
    end)
    RE_OnFocusUpdate:FireClient(player, { type = "Pushups", event = "Start" })
    fireLiveFeed(player, "began pushups")
    local disc = _G.DiscordManager
    if disc then disc.logPushups(player, "START", "") end
    scheduleNextCheck(player, myToken)
end

function PushupsManager.interrupt(player, reason)
    interrupt(player, reason)
end

RunService.Heartbeat:Connect(function(dt)
    if EXTRA_HUNGER_RATE <= 0 then return end
    for uid, s in pairs(sessions) do
        local player = s.player
        if player and player.Parent then
            local dm = _G.DataManager
            if dm then
                local h = math.max(0, (dm.getValue(player, "Hunger") or 100) - EXTRA_HUNGER_RATE * dt)
                dm.setValue(player, "Hunger", h)
                if h <= 0 then interrupt(player, "ZeroHunger") end
            end
        end
    end
end)

Players.PlayerRemoving:Connect(function(player)
    local s = sessions[player.UserId]
    if s and s.healthConn then s.healthConn:Disconnect() end
    sessions[player.UserId] = nil
end)

_G.PushupsManager = PushupsManager
print("[PushupsManager] Init")
