-- EmoteManager — Part One: validates & broadcasts wheel emotes; routes the two special
-- emotes (meditate/pushups) to MeditationManager/PushupsManager instead of a plain anim.
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))

local function getOrCreate(name, isFunc)
    local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
        local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
    end)()
    local r=folder:FindFirstChild(name); if r then return r end
    r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_RequestPlayEmote = getOrCreate("RequestPlayEmote")
local RE_OnPlayEmote      = getOrCreate("OnPlayEmote")
local RE_RequestStopEmote = getOrCreate("RequestStopEmote")

local EMOTE_LOOKUP = {}
for _, page in pairs(Config.EmoteWheel) do
    for _, def in ipairs(page) do
        EMOTE_LOOKUP[def.id] = def
    end
end

-- Cannot start an emote while: in a blocked combat state, downed, guard broken, carrying,
-- dashing, attacking. isActionBlocked already covers Dead/Staggered/GuardBroken/Clashing/
-- Downed/BeingCarried/BeingExecuted/Executing/carrying(combatLocked); "Attacking" and
-- "dashing" aren't in that blocked-state list (both deliberately still allow movement
-- elsewhere), so they're checked separately here.
local function isEmoteBlocked(player)
    local cm = _G.CombatManager
    if cm then
        if cm.isActionBlocked(player) then return true end
        if cm.getCombatState(player) == "Attacking" then return true end
    end
    local mm = _G.MovementManager
    if mm and mm.isDashing and mm.isDashing(player) then return true end
    -- Rage: "cannot enter meditation, sleep, or use potions during rage" (see RageManager).
    local rm = _G.RageManager
    if rm and rm.isRaging(player) then return true end
    return false
end

local EmoteManager = {}
function EmoteManager.isEmoteBlocked(player) return isEmoteBlocked(player) end

-- Sleep isn't QTE-driven like meditate/pushups, but it does need a real server-tracked
-- loop so Config.SanityRecovery.Sleep can tick per real minute and stop the instant the
-- player moves (see the RequestStopEmote handler below and EmoteWheelClient's matching
-- movement check for the non-special/currentEmoteId=="sleep" case).
local sleepingSince = {} -- [userId] = tick() token; doubles as a cancellation generation id

local function stopSleeping(player) sleepingSince[player.UserId] = nil end
function EmoteManager.isSleeping(player) return sleepingSince[player.UserId] ~= nil end

local function startSleeping(player)
    local token = tick()
    sleepingSince[player.UserId] = token
    task.spawn(function()
        local uid = player.UserId
        while sleepingSince[uid] == token do
            task.wait(60)
            if sleepingSince[uid] ~= token then break end
            local sanM = _G.SanityManager
            if sanM then sanM.recoverPerMinuteTick(player, "Sleep") end
        end
    end)
end

RE_RequestPlayEmote.OnServerEvent:Connect(function(player, emoteId)
    if type(emoteId) ~= "string" then return end
    local def = EMOTE_LOOKUP[emoteId]
    if not def then return end
    if isEmoteBlocked(player) then return end

    if emoteId ~= "sleep" then stopSleeping(player) end

    if def.special then
        if emoteId == "meditate" then
            local medM = _G.MeditationManager
            if medM then medM.start(player) end
        elseif emoteId == "pushups" then
            local pushM = _G.PushupsManager
            if pushM then pushM.start(player) end
        end
        return
    end

    if emoteId == "sleep" then startSleeping(player) end

    -- Cosmetic broadcast so nearby players see it play on this character. anim may be the
    -- placeholder "" -- client just skips loading in that case. Sleep loops (see
    -- EmoteWheelClient); every other cosmetic emote is a one-shot.
    RE_OnPlayEmote:FireAllClients(player, def.anim, emoteId=="sleep", emoteId)
    print(string.format("[EmoteManager] %s played emote: %s", player.Name, emoteId))
end)

-- Movement cancelling a looping special emote: EmoteWheelClient fires this; whichever
-- manager currently owns this player's focus state (at most one at a time) handles it.
RE_RequestStopEmote.OnServerEvent:Connect(function(player)
    local medM = _G.MeditationManager
    if medM and medM.isFocusing(player) then medM.interrupt(player, "Movement"); return end
    local pushM = _G.PushupsManager
    if pushM and pushM.isFocusing(player) then pushM.interrupt(player, "Movement"); return end
    stopSleeping(player)
end)

Players.PlayerRemoving:Connect(function(player) stopSleeping(player) end)

_G.EmoteManager = EmoteManager
print("[EmoteManager] Init")
