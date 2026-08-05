-- MeditationManager — Part Two
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local medCfg = Config.Meditation

local function getOrCreate(name, isFunc)
    local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
        local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
    end)()
    local r=folder:FindFirstChild(name); if r then return r end
    r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_OnFocusUpdate     = getOrCreate("OnFocusUpdate")
local RE_ShowNotification  = getOrCreate("ShowNotification")
local RE_ModActionCard     = getOrCreate("ModActionCard")
local RE_LiveFeedUpdate    = getOrCreate("LiveFeedUpdate")

local MOB_CHECK_RADIUS = 15

local sessions = {} -- [uid] = { player, startedAt, stage, token, healthConn, lastHealth }

local function notify(player, title, body)
    RE_ShowNotification:FireClient(player, title, body, 5, "info")
end

-- Live feed goes to every currently-open mod menu, same as ChatManager's broadcast pattern.
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

local function isMobNearby(char)
    local hrp = char:FindFirstChild("HumanoidRootPart"); if not hrp then return false end
    for _, obj in ipairs(workspace:GetChildren()) do
        if obj:IsA("Model") and obj ~= char then
            local hum = obj:FindFirstChildOfClass("Humanoid")
            if hum and hum.Health > 0 and not Players:GetPlayerFromCharacter(obj) then
                local mhrp = obj:FindFirstChild("HumanoidRootPart")
                if mhrp and (mhrp.Position - hrp.Position).Magnitude <= MOB_CHECK_RADIUS then
                    return true
                end
            end
        end
    end
    return false
end

local MeditationManager = {}

function MeditationManager.isFocusing(player)
    return sessions[player.UserId] ~= nil
end

function MeditationManager.isDeepMeditating(player)
    local s = sessions[player.UserId]
    return s ~= nil and s.stage == "Deep"
end

local interrupt -- forward decl
local scheduleNextCheck -- forward decl

local INTERRUPT_MESSAGES = {
    Damage = "Your meditation was disturbed.",
    QTEFail = "Your focus wavered.",
    Mob = "Something approached.",
}

interrupt = function(player, reason)
    local s = sessions[player.UserId]
    if not s then return end
    sessions[player.UserId] = nil
    if s.healthConn then s.healthConn:Disconnect() end
    local qte = _G.QTEManager
    if qte then qte.cancelAllFor(player) end
    RE_OnFocusUpdate:FireClient(player, { type = "Meditation", event = "End", reason = reason })
    local msg = INTERRUPT_MESSAGES[reason]
    if msg then notify(player, "Meditation", msg) end
    local elapsed = tick() - s.startedAt
    fireLiveFeed(player, string.format("meditation ended after %.0fs (%s)", elapsed, tostring(reason)))
    local disc = _G.DiscordManager
    if disc then disc.logMeditation(player, "END", string.format("after %.0fs, reason=%s", elapsed, tostring(reason))) end
end

local function checkMilestone(player, count)
    local hit = false
    for _, m in ipairs(medCfg.Milestones) do if count == m then hit = true end end
    if not hit then return false end
    fireLiveFeed(player, string.format("reached %d meditation QTEs", count))
    local disc = _G.DiscordManager
    if disc then disc.logMeditation(player, "MILESTONE", count .. " QTEs passed") end
    return true
end

-- Broadcasts the milestone card to every mod, with Grant Talent / Grant Progress / Dismiss
-- buttons that fire the existing ModCommand pipeline client-side (see ModMenuClient).
local function sendMilestoneCard(player, count)
    local dm = _G.DataManager
    local charName = (dm and dm.getValue(player, "FirstName")) or player.Name
    local mgr = _G.ModManager
    local payload = {
        id = "med_" .. player.UserId .. "_" .. tostring(count) .. "_" .. tostring(os.time()),
        category = "Meditation",
        title = "MEDITATION MILESTONE",
        body = string.format("%s reached %d QTEs of focused meditation.", charName, count),
        target = player.Name,
        buttons = {
            { label = "Grant Talent",    cmd = "grantTalent",   arg = "ReinforcedMind" },
            { label = "Grant Progress",  cmd = "grantProgress", arg = "Meditation" },
            { label = "Dismiss" },
        },
    }
    for _, p in ipairs(Players:GetPlayers()) do
        if mgr and mgr.isMod(p) then RE_ModActionCard:FireClient(p, payload) end
    end
end

-- Caste progress scaling (Aquitani +25% meditation, Belgae -10% non-combat) applied to what
-- is fundamentally an integer counter: the fractional part carries in `progressRemainder`
-- until it rolls over into a whole QTE. At +25% that means every fourth passed QTE awards 2,
-- rather than silently rounding the bonus away to nothing on every single one.
local progressRemainder = {} -- [userId] = 0..1
Players.PlayerRemoving:Connect(function(p) progressRemainder[p.UserId] = nil end)

local function casteScaledGain(player)
    local cm = _G.CasteManager
    local mult = cm and cm.getMeditationProgressMultiplier(player) or 1
    local raw = 1 * mult + (progressRemainder[player.UserId] or 0)
    local whole = math.floor(raw)
    progressRemainder[player.UserId] = raw - whole
    return whole
end

local function triggerMeditationQTE(player, myToken)
    local s = sessions[player.UserId]
    if not s or s.token ~= myToken then return end
    local qte = _G.QTEManager
    if not qte then scheduleNextCheck(player, myToken); return end
    qte.startQTE(player, medCfg.QTETier, { source = "Meditation" }, function(p, success)
        local cur = sessions[p.UserId]
        if not cur or cur.token ~= myToken then return end -- session ended/replaced since
        if success then
            local dmv = _G.DataManager
            local newCount = ((dmv and dmv.getValue(p, "MeditationQTEsPassed")) or 0) + casteScaledGain(p)
            if dmv then dmv.setValue(p, "MeditationQTEsPassed", newCount) end
            if checkMilestone(p, newCount) then sendMilestoneCard(p, newCount) end
            scheduleNextCheck(p, myToken)
        else
            -- Deep stage: "none of the above interrupt" (spec) -- a failed QTE just doesn't
            -- award progress; only Early stage treats a fail as a full interruption.
            if cur.stage == "Early" then
                interrupt(p, "QTEFail")
            else
                scheduleNextCheck(p, myToken)
            end
        end
    end)
end

scheduleNextCheck = function(player, myToken)
    local s = sessions[player.UserId]
    if not s or s.token ~= myToken then return end
    local interval = (s.stage == "Early") and medCfg.EarlyStageQTEInterval or medCfg.DeepStageQTEInterval
    task.delay(interval, function()
        local cur = sessions[player.UserId]
        if not cur or cur.token ~= myToken then return end
        if not player.Parent then return end
        -- Early-stage passive interruption checks (mob proximity, combat tag) -- damage is
        -- caught by the HealthChanged hook instead, and movement/QTE-fail have their own
        -- direct call sites.
        if cur.stage == "Early" then
            local char = player.Character
            if char and isMobNearby(char) then interrupt(player, "Mob"); return end
            local sm = _G.StaminaManager
            if sm and sm.isInCombat and sm.isInCombat(player) then interrupt(player, "CombatTag"); return end
        end
        triggerMeditationQTE(player, myToken)
    end)
end

local nextToken = 0
function MeditationManager.start(player)
    if sessions[player.UserId] then return end
    local char = player.Character
    if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    nextToken += 1
    local myToken = nextToken
    local s = {
        player = player, startedAt = tick(), stage = "Early", token = myToken,
        lastHealth = hum.Health,
    }
    sessions[player.UserId] = s
    s.healthConn = hum.HealthChanged:Connect(function(newHealth)
        local cur = sessions[player.UserId]
        if not cur or cur.token ~= myToken then return end
        if cur.stage == "Early" and newHealth < cur.lastHealth then
            cur.lastHealth = newHealth
            interrupt(player, "Damage")
            return
        end
        cur.lastHealth = newHealth
    end)
    RE_OnFocusUpdate:FireClient(player, { type = "Meditation", event = "Start" })
    fireLiveFeed(player, "began meditating")
    local disc = _G.DiscordManager
    if disc then disc.logMeditation(player, "START", "") end
    -- Deep-stage transition at EarlyStageDuration (3 min)
    task.delay(medCfg.EarlyStageDuration, function()
        local cur = sessions[player.UserId]
        if not cur or cur.token ~= myToken then return end
        cur.stage = "Deep"
        RE_OnFocusUpdate:FireClient(player, { type = "Meditation", event = "DeepEnter" })
        fireLiveFeed(player, "entered deep meditation (3 min mark)")
        local d2 = _G.DiscordManager
        if d2 then d2.logMeditation(player, "DEEP", "entered deep stage") end
    end)
    scheduleNextCheck(player, myToken)
end

function MeditationManager.interrupt(player, reason)
    interrupt(player, reason)
end

Players.PlayerRemoving:Connect(function(player)
    local s = sessions[player.UserId]
    if s and s.healthConn then s.healthConn:Disconnect() end
    sessions[player.UserId] = nil
end)

_G.MeditationManager = MeditationManager
print("[MeditationManager] Init")
