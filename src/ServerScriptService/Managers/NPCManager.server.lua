-- NPCManager -- Parts One-Three: spawning, customization, AI behavior
-- Session-only: NPCs live in workspace.NPCs, never touch DataStore, gone on shutdown.
local Players     = game:GetService("Players")
local RepStorage  = game:GetService("ReplicatedStorage")
local RunService  = game:GetService("RunService")
local InsertService = game:GetService("InsertService")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local Util   = require(RepStorage:WaitForChild("Shared"):WaitForChild("Util"))
local npcCfg = Config.NPC
local combatCfg = Config.Combat
local parryCfg = Config.Parry
local STRENGTH_PER_POINT = 0.005 -- matches CombatManager/PostureManager's own fallback (Config.StatScaling doesn't exist)

local function getOrCreate(name, isFunc)
    local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
        local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
    end)()
    local r=folder:FindFirstChild(name); if r then return r end
    r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_NPCSpeak       = getOrCreate("NPCSpeak")
local RE_LiveFeedUpdate = getOrCreate("LiveFeedUpdate")

-- 2026-08-02 combat teardown: these four remotes died with the combat stack. They are
-- looked up, never created, so this script does not resurrect them as orphan instances
-- nothing listens to. The call sites below are NOT nil-guarded (they use `:FireClient`
-- and `.OnServerEvent:Connect` directly), so a missing remote is swapped for an inert
-- stand-in with the same shape rather than nil -- otherwise this script errors on init.
-- When the revamp re-declares these remotes, the real instances are picked up again with
-- no further edits here.
local DEAD_REMOTE = {
    FireClient     = function() end,
    FireAllClients = function() end,
    OnServerEvent  = { Connect = function() return { Disconnect = function() end } end },
}
local function findRE(name)
    local folder = RepStorage:FindFirstChild("RemoteEvents")
    local r = folder and folder:FindFirstChild(name)
    if r then return r end
    warn("[NPCManager] remote '"..name.."' absent (combat removed) -- using inert stand-in")
    return DEAD_REMOTE
end
local RE_OnHit          = findRE("OnHit")
local RE_RequestExecute = findRE("RequestExecute")
local RE_OnParryResult  = findRE("OnParryResult")
local RE_PlayCombatAnim = findRE("PlayCombatAnim")

local NPCS_FOLDER_NAME = "NPCs"
local function getFolder()
    local f = workspace:FindFirstChild(NPCS_FOLDER_NAME)
    if not f then f = Instance.new("Folder"); f.Name = NPCS_FOLDER_NAME; f.Parent = workspace end
    return f
end

local npcs = {}        -- [model] = state
local npcsByName = {}  -- [uniqueName] = model

local function getCharName(player)
    local dm = _G.DataManager
    local n = dm and dm.getValue(player, "FirstName")
    if not n or n == "" then n = player.Name end
    return n
end

local function fireLiveFeed(charName, message)
    local now = os.date("*t")
    local mgr = _G.ModManager
    for _, p in ipairs(Players:GetPlayers()) do
        if mgr and mgr.isMod(p) then
            RE_LiveFeedUpdate:FireClient(p, { type = "ACTION", h = now.hour, m = now.min, zone = "?", charName = charName, message = message })
        end
    end
end

-- ================================================================================
-- PART ONE -- SPAWNING
-- ================================================================================

-- Classic default Roblox R6 animations (idle/walk) -- the same IDs a totally vanilla R6
-- character uses when nothing is overridden. Not a PLACEHOLDER_ANIMATION in the usual
-- sense (those mark custom combat/emote clips still to be authored); these are real,
-- long-stable default Roblox assets, used here because NPCs have no client to run the
-- normal Animate LocalScript (LocalScripts only execute for the client that owns the
-- character, and nothing owns an NPC) -- so playback has to be driven server-side instead.
local NPC_ANIM_IDS = {
    Idle = "rbxassetid://180435571",
    Walk = "rbxassetid://180426354",
}

local function setupAnimations(hum)
    local animator = hum:FindFirstChildOfClass("Animator") or Instance.new("Animator", hum)
    local tracks = {}
    for name, id in pairs(NPC_ANIM_IDS) do
        local anim = Instance.new("Animation")
        anim.AnimationId = id
        local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
        if ok and track then
            track.Priority = Enum.AnimationPriority.Idle
            track.Looped = true
            tracks[name] = track
        end
    end
    if tracks.Idle then tracks.Idle:Play() end
    hum.Running:Connect(function(speed)
        if hum.Health <= 0 then return end
        if speed > 0.75 then
            if tracks.Idle and tracks.Idle.IsPlaying then tracks.Idle:Stop(0.15) end
            if tracks.Walk and not tracks.Walk.IsPlaying then tracks.Walk:Play(0.15) end
        else
            if tracks.Walk and tracks.Walk.IsPlaying then tracks.Walk:Stop(0.15) end
            if tracks.Idle and not tracks.Idle.IsPlaying then tracks.Idle:Play(0.15) end
        end
    end)
    return tracks
end

-- A genuine Roblox R6 rig built via the same API the engine itself uses to build player
-- characters (Players:CreateHumanoidModelFromDescription) -- correct proportions, a real
-- face, standard skin, all Motor6D joints wired -- rather than cloning a hand-built dummy
-- Part model that doesn't actually look like a real R6 character.
local function createRig(position, name)
    local desc = Instance.new("HumanoidDescription") -- blank = classic default R6 dummy look
    local ok, model = pcall(function()
        return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R6)
    end)
    if not ok or not model then
        warn("[NPCManager] Failed to build R6 rig: " .. tostring(model))
        return nil
    end
    local animate = model:FindFirstChild("Animate")
    if animate then animate:Destroy() end -- NPCs are driven by our own AI, not the default character animate script

    local displayName = (name and name ~= "") and name or "Unnamed"
    local uniqueName = "NPC_" .. displayName .. "_" .. tostring(math.floor(tick() * 1000))
    model.Name = uniqueName
    model.Parent = getFolder()

    local hum = model:FindFirstChildOfClass("Humanoid")
    local hrp = model:FindFirstChild("HumanoidRootPart")
    if hrp then hrp.CFrame = CFrame.new(position + Vector3.new(0, 3, 0)) end
    if hum then
        hum.WalkSpeed = npcCfg.WalkSpeed
        hum.MaxHealth = npcCfg.DefaultMaxHealth
        hum.Health = npcCfg.DefaultMaxHealth
        -- NPCs show NO name at all, ever -- DisplayDistanceType=None suppresses Roblox's
        -- entire built-in floating nameplate/health billboard outright (unlike the
        -- NameDisplayDistance=0/HealthDisplayDistance=0/HealthDisplayType=AlwaysOff
        -- combination tried in an earlier session, which left the nameplate rendering at
        -- any distance -- DisplayDistanceType is the actual on/off switch, not a distance
        -- falloff tweak). NPCName is still tracked as an attribute for mod tooling/logs;
        -- it's just never displayed over the NPC's head anymore.
        hum.DisplayName = displayName
        hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
        hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
        setupAnimations(hum)
    end

    model:SetAttribute("IsNPC", true)
    model:SetAttribute("NPCName", displayName)
    model:SetAttribute("AggroType", "None")
    model:SetAttribute("LeaderPlayerUserId", 0)
    model:SetAttribute("GripAllowed", true)
    model:SetAttribute("Strength", 0)
    model:SetAttribute("Endurance", 0)
    model:SetAttribute("Agility", 0)
    model:SetAttribute("MaxHealth", npcCfg.DefaultMaxHealth)
    model:SetAttribute("PhrasesJSON", "[]")
    model:SetAttribute("SightRange", npcCfg.DefaultSightRange)
    model:SetAttribute("LeashRange", npcCfg.DefaultLeashRange)
    model:SetAttribute("ImmuneToFrost", false)
    model:SetAttribute("EquippedWeapon", "None")

    return model
end

local nextDecisionOffset = 0

local function newState(model, position)
    return {
        model = model,
        spawnPosition = position,
        aggroType = "None",
        leaderUserId = 0,
        gripAllowed = true,
        maxHealth = npcCfg.DefaultMaxHealth,
        phrases = {}, -- [trigger] = {text, text, ...}
        sightRange = npcCfg.DefaultSightRange,
        leashRange = npcCfg.DefaultLeashRange,
        target = nil, -- Player
        combatState = "Idle", -- Idle/Attacking/Staggered/GuardBroken/Downed/Dead
        posture = 0,
        isBlocking = false,
        isParrying = false,
        parryStartTime = 0,
        parryCooldownUntil = 0,
        staggerUntil = 0,
        guardBrokenUntil = 0,
        downed = false,
        dead = false,
        lastM1 = 0, lastM2 = 0, lastDash = 0,
        nextIdlePhraseAt = tick() + math.random(npcCfg.IdlePhraseIntervalMin, npcCfg.IdlePhraseIntervalMax),
        decisionOffset = (function() nextDecisionOffset = (nextDecisionOffset + 0.03) % npcCfg.DecisionInterval; return nextDecisionOffset end)(),
        attackedBy = {}, -- [player] = true, for OnAttacked aggro type
        respawnSpawnerPart = nil, -- set by BToolsManager if spawned via an NPC Spawner placement
    }
end

local NPCManager = {}

function NPCManager.getNPC(model)
    if not model then return nil end
    return npcs[model]
end

function NPCManager.getByName(name)
    return npcsByName[name]
end

function NPCManager.getAll()
    local list = {}
    for model in pairs(npcs) do table.insert(list, model) end
    return list
end

function NPCManager.spawnNPC(position, name, spawnerPart)
    local model = createRig(position, name)
    if not model then return nil end
    local state = newState(model, position)
    state.respawnSpawnerPart = spawnerPart
    npcs[model] = state
    npcsByName[model.Name] = model

    model.Destroying:Connect(function()
        npcs[model] = nil
        npcsByName[model.Name] = nil
    end)

    fireLiveFeed("SYSTEM", "spawned NPC " .. state.model:GetAttribute("NPCName") .. " (" .. model.Name .. ")")
    local disc = _G.DiscordManager
    if disc then disc.logNPC("SPAWN", model:GetAttribute("NPCName") .. " spawned at " .. tostring(position)) end
    print("[NPCManager] Spawned " .. model.Name)
    NPCManager.speak(model, "OnSpawn") -- no-op silently if no OnSpawn phrase configured yet
    return model
end

function NPCManager.deleteNPC(model)
    local state = npcs[model]
    if not state then return false end
    npcs[model] = nil
    npcsByName[model.Name] = nil
    model:Destroy()
    return true
end

-- ================================================================================
-- PART TWO -- CUSTOMIZATION
-- ================================================================================

local FALLBACK_SKIN_TONES = {
    Color3.fromRGB(255,220,185), Color3.fromRGB(240,200,160), Color3.fromRGB(210,170,130),
    Color3.fromRGB(185,145,105), Color3.fromRGB(160,120,80),  Color3.fromRGB(140,100,65),
}
local FALLBACK_FACES = {
    "rbxasset://textures/face.png","rbxasset://textures/face.png","rbxasset://textures/face.png",
    "rbxasset://textures/face.png","rbxasset://textures/face.png",
}
local VALID_WEAPONS = { None=true, Sword=true, Axe=true, Spear=true, Dagger=true, Bow=true, Fists=true }
local VALID_AGGRO = { None=true, OnSight=true, OnAttacked=true, PlayerLed=true }
local VALID_PHRASE_TRIGGERS = { OnSpawn=true, OnAggro=true, OnDamage=true, OnKill=true, OnDeath=true, Idle=true, Custom=true }

function NPCManager.setName(model, name)
    local state = npcs[model]; if not state then return false end
    name = (name and name ~= "") and name or "Unnamed"
    model:SetAttribute("NPCName", name)
    local hum = model:FindFirstChildOfClass("Humanoid")
    if hum then hum.DisplayName = name end
    return true
end

function NPCManager.setShirtPants(model, shirtId, pantsId)
    local state = npcs[model]; if not state then return false end
    if shirtId and tonumber(shirtId) then
        local ok, m = pcall(function() return InsertService:LoadAsset(tonumber(shirtId)) end)
        if ok and m then
            local item = m:FindFirstChildOfClass("Shirt")
            local template = item and item.ShirtTemplate
            m:Destroy()
            if template and template ~= "" then
                local shirt = model:FindFirstChildOfClass("Shirt") or Instance.new("Shirt", model)
                shirt.ShirtTemplate = template
            end
        end
    end
    if pantsId and tonumber(pantsId) then
        local ok, m = pcall(function() return InsertService:LoadAsset(tonumber(pantsId)) end)
        if ok and m then
            local item = m:FindFirstChildOfClass("Pants")
            local template = item and item.PantsTemplate
            m:Destroy()
            if template and template ~= "" then
                local pants = model:FindFirstChildOfClass("Pants") or Instance.new("Pants", model)
                pants.PantsTemplate = template
            end
        end
    end
    return true
end

function NPCManager.setSkinTone(model, index)
    local state = npcs[model]; if not state then return false end
    index = math.clamp(tonumber(index) or 1, 1, 6)
    local im = _G.IdentityManager
    local pool = (im and im.SkinTones) or FALLBACK_SKIN_TONES
    local color = pool[index] or pool[1]
    local bc = model:FindFirstChildOfClass("BodyColors") or Instance.new("BodyColors", model)
    bc.HeadColor3 = color; bc.TorsoColor3 = color
    bc.LeftArmColor3 = color; bc.RightArmColor3 = color
    bc.LeftLegColor3 = color; bc.RightLegColor3 = color
    return true
end

function NPCManager.setFace(model, index)
    local state = npcs[model]; if not state then return false end
    index = math.clamp(tonumber(index) or 1, 1, 5)
    local im = _G.IdentityManager
    local pool = (im and im.FacePool) or FALLBACK_FACES
    local head = model:FindFirstChild("Head"); if not head then return false end
    local decal = head:FindFirstChild("face") or Instance.new("Decal", head)
    decal.Name = "face"
    decal.Texture = pool[index] or pool[1]
    return true
end

function NPCManager.setHair(model, assetId)
    local state = npcs[model]; if not state then return false end
    -- Only clears the hair slot -- gear pieces (helmets/shoulder pads/etc, added via
    -- addGear) are tagged NPCGearPiece and deliberately left alone here, so re-rolling
    -- hair doesn't strip armor and vice versa (clearGear below is the mirror image).
    for _, acc in ipairs(model:GetChildren()) do
        if acc:IsA("Accessory") and not acc:GetAttribute("NPCGearPiece") then acc:Destroy() end
    end
    assetId = tonumber(assetId)
    if not assetId or assetId == 0 then return true end
    local ok, m = pcall(function() return InsertService:LoadAsset(assetId) end)
    if not ok or not m then return false end
    local hum = model:FindFirstChildOfClass("Humanoid")
    for _, acc in ipairs(m:GetChildren()) do
        if acc:IsA("Accessory") then
            if hum then hum:AddAccessory(acc) else acc.Parent = model end
        end
    end
    m:Destroy()
    return true
end

-- Armor/gear accessories (helmets, shoulder pads, capes, belts, etc) -- catalog Accessory
-- items work fine on R6 via Humanoid:AddAccessory just like hair does, so this reuses the
-- exact same load-and-attach pattern. Unlike setHair (one slot, always replaced whole),
-- gear stacks: each call adds another piece without touching what's already equipped, so
-- a full loadout is built up via several addGear calls (helmet, then shoulder pads, etc).
function NPCManager.addGear(model, assetId)
    local state = npcs[model]; if not state then return false end
    assetId = tonumber(assetId)
    if not assetId or assetId == 0 then return false end
    local ok, m = pcall(function() return InsertService:LoadAsset(assetId) end)
    if not ok or not m then return false end
    local hum = model:FindFirstChildOfClass("Humanoid")
    local added = false
    for _, acc in ipairs(m:GetChildren()) do
        if acc:IsA("Accessory") then
            acc:SetAttribute("NPCGearPiece", true)
            if hum then hum:AddAccessory(acc) else acc.Parent = model end
            added = true
        end
    end
    m:Destroy()
    return added
end

function NPCManager.clearGear(model)
    local state = npcs[model]; if not state then return false end
    for _, acc in ipairs(model:GetChildren()) do
        if acc:IsA("Accessory") and acc:GetAttribute("NPCGearPiece") then acc:Destroy() end
    end
    return true
end

function NPCManager.setWeapon(model, weaponType)
    local state = npcs[model]; if not state then return false end
    if not VALID_WEAPONS[weaponType] then return false end
    model:SetAttribute("EquippedWeapon", weaponType)
    return true
end

function NPCManager.setAggroType(model, aggroType)
    local state = npcs[model]; if not state then return false end
    if not VALID_AGGRO[aggroType] then return false end
    state.aggroType = aggroType
    model:SetAttribute("AggroType", aggroType)
    if aggroType ~= "OnAttacked" then state.attackedBy = {} end
    if aggroType ~= "OnSight" and aggroType ~= "OnAttacked" and aggroType ~= "PlayerLed" then
        state.target = nil
    end
    return true
end

function NPCManager.setSightRange(model, range)
    local state = npcs[model]; if not state then return false end
    state.sightRange = math.clamp(tonumber(range) or npcCfg.DefaultSightRange, 0, 100)
    model:SetAttribute("SightRange", state.sightRange)
    return true
end

function NPCManager.setLeashRange(model, range)
    local state = npcs[model]; if not state then return false end
    state.leashRange = math.clamp(tonumber(range) or npcCfg.DefaultLeashRange, 0, 200)
    model:SetAttribute("LeashRange", state.leashRange)
    return true
end

function NPCManager.setLeader(model, player)
    local state = npcs[model]; if not state then return false end
    state.leaderUserId = player and player.UserId or 0
    model:SetAttribute("LeaderPlayerUserId", state.leaderUserId)
    return true
end

function NPCManager.setStats(model, strength, endurance, agility)
    local state = npcs[model]; if not state then return false end
    if strength then model:SetAttribute("Strength", math.clamp(tonumber(strength) or 0, 0, 100)) end
    if endurance then model:SetAttribute("Endurance", math.clamp(tonumber(endurance) or 0, 0, 100)) end
    if agility then model:SetAttribute("Agility", math.clamp(tonumber(agility) or 0, 0, 100)) end
    return true
end

function NPCManager.setMaxHealth(model, hp)
    local state = npcs[model]; if not state then return false end
    hp = math.clamp(tonumber(hp) or npcCfg.DefaultMaxHealth, 1, 500)
    state.maxHealth = hp
    model:SetAttribute("MaxHealth", hp)
    local hum = model:FindFirstChildOfClass("Humanoid")
    if hum then
        local frac = hum.MaxHealth > 0 and hum.Health / hum.MaxHealth or 1
        hum.MaxHealth = hp
        hum.Health = hp * frac
    end
    return true
end

function NPCManager.setGripAllowed(model, allowed)
    local state = npcs[model]; if not state then return false end
    state.gripAllowed = allowed == true
    model:SetAttribute("GripAllowed", state.gripAllowed)
    -- Toggling grip back on for an ungrippable NPC that's already sitting at the 1-HP
    -- floor doesn't retroactively down it -- matches the checklist's "cannot drop below 1
    -- HP" being a live clamp, not a state transition trigger.
    return true
end

local function syncPhrasesAttribute(model, state)
    local HttpService = game:GetService("HttpService")
    local ok, encoded = pcall(function() return HttpService:JSONEncode(state.phrases) end)
    if ok then model:SetAttribute("PhrasesJSON", encoded) end
end

function NPCManager.addPhrase(model, trigger, text)
    local state = npcs[model]; if not state then return false end
    if not VALID_PHRASE_TRIGGERS[trigger] then return false end
    if type(text) ~= "string" or text == "" then return false end
    state.phrases[trigger] = state.phrases[trigger] or {}
    table.insert(state.phrases[trigger], text)
    syncPhrasesAttribute(model, state)
    return true
end

function NPCManager.removePhrase(model, trigger, index)
    local state = npcs[model]; if not state then return false end
    local list = state.phrases[trigger]; if not list then return false end
    index = tonumber(index)
    if not index or not list[index] then return false end
    table.remove(list, index)
    syncPhrasesAttribute(model, state)
    return true
end

function NPCManager.getPhrases(model)
    local state = npcs[model]; if not state then return {} end
    return state.phrases
end

-- ================================================================================
-- PART THREE -- COMBAT STATE (NPC as victim) + AI BEHAVIOR (NPC as attacker)
-- ================================================================================

-- Server-driven mirror of InputHandler's client-side playCombatAnim (same Config.CombatAnims
-- table, same Action2 priority, same M1Attack windup-freeze quirk) -- NPCs have no client to
-- predict their own swing/reaction animations, so the server has to drive the Animator
-- directly. Tracked per-NPC on its own state table (not one shared global like the client
-- uses) since NPCManager is driving many NPCs' Animators at once, not just one character.
local M1_WINDUP_PAUSE_SECS = 0.18 -- must match InputHandler's own M1_WINDUP_PAUSE_SECS
function NPCManager.playAnim(model, animType, hitNum)
    local state = npcs[model]; if not state then return end
    local ids = Config.CombatAnims[animType]
    if not ids then return end -- e.g. M2 has no dedicated clip, matching player parity
    local n = math.clamp(tonumber(hitNum) or 1, 1, #ids)
    local hum = model:FindFirstChildOfClass("Humanoid"); if not hum then return end
    local animator = hum:FindFirstChildOfClass("Animator"); if not animator then return end
    local anim = Instance.new("Animation")
    anim.AnimationId = ids[n]
    local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
    if not ok or not track then return end
    if state.activeCombatTrack and state.activeCombatTrack.IsPlaying then
        state.activeCombatTrack:Stop(0.05)
    end
    state.activeCombatTrack = track
    track.Priority = Enum.AnimationPriority.Action2
    track:Play()
    if animType == "M1Attack" then
        track:AdjustSpeed(0)
        task.delay(M1_WINDUP_PAUSE_SECS, function()
            if state.activeCombatTrack == track and track.IsPlaying then
                track:AdjustSpeed(1)
            end
        end)
    end
end

function NPCManager.speak(model, trigger)
    local state = npcs[model]; if not state then return end
    local list = state.phrases[trigger]
    if not list or #list == 0 then return end
    local text = list[math.random(1, #list)]
    local head = model:FindFirstChild("Head"); if not head then return end
    local npcName = model:GetAttribute("NPCName") or "NPC"
    RE_NPCSpeak:FireAllClients(head, npcName, text)
    fireLiveFeed(npcName, string.format("(%s): \"%s\"", trigger, text))
    local disc = _G.DiscordManager
    if disc then disc.logNPC("SPEECH", string.format("%s (%s): \"%s\"", npcName, trigger, text)) end
end

-- Speak an arbitrary line rather than one drawn from the configured phrase pool. Used by
-- systems that generate dialogue at runtime from live data (RevealManager's oracles), where
-- there is no fixed phrase list to pick from.
function NPCManager.speakText(model, text, tag)
    if not npcs[model] or not text or text == "" then return end
    local head = model:FindFirstChild("Head"); if not head then return end
    local npcName = model:GetAttribute("NPCName") or "NPC"
    RE_NPCSpeak:FireAllClients(head, npcName, text)
    fireLiveFeed(npcName, string.format("(%s): \"%s\"", tag or "Say", text))
    local disc = _G.DiscordManager
    if disc then disc.logNPC("SPEECH", string.format("%s (%s): \"%s\"", npcName, tag or "Say", text)) end
end

-- ---- NPC-as-victim combat state (called from CombatManager hooks) ----
function NPCManager.isBlocking(state) return state ~= nil and state.isBlocking == true end
function NPCManager.isParrying(state) return state ~= nil and state.isParrying == true end

-- Mirrors ParryManager.checkHit's Perfect/Late/Break window logic, keyed off the NPC's
-- own state table instead of a Player -- the NPC fills the "parryingPlayer" role here.
function NPCManager.checkParry(state, attacker, attackType)
    if not state.isParrying then return nil end
    local WINDOW_SEC = (parryCfg.WindowTotal or 20) / 60
    local PERFECT_SEC = (parryCfg.PerfectWindow or 10) / 60

    if attackType == "M2" then
        state.isParrying = false
        state.staggerUntil = tick() + parryCfg.StaggerDurationPerfect
        state.combatState = "Staggered"
        return "Break"
    end
    local elapsed = tick() - state.parryStartTime
    if elapsed >= WINDOW_SEC then return nil end
    local result = elapsed < PERFECT_SEC and "Perfect" or "Late"
    state.isParrying = false
    -- Perfect/Late parry staggers the ATTACKING PLAYER, matching player-vs-player parity.
    local cm = _G.CombatManager
    if cm then
        local staggerDur = result == "Perfect" and parryCfg.StaggerDurationPerfect or parryCfg.StaggerDurationLate
        cm.applyStagger(attacker, staggerDur)
        if cm.getCombatState(attacker) == "Attacking" then cm.setCombatState(attacker, "Idle") end
    end
    RE_OnParryResult:FireClient(attacker, { result = result, victimName = state.model:GetAttribute("NPCName") })
    fireLiveFeed(getCharName(attacker), "was parried by " .. state.model:GetAttribute("NPCName"))
    -- Attacker's own M1Parried reaction is already fired by the CombatManager call site
    -- (mirrors player-vs-player parity); this is the NPC's OWN parry pose, which needs a
    -- direct server-driven Animator call since the NPC has no client to play it itself.
    NPCManager.playAnim(state.model, "M1Parry", 1)
    return result
end

function NPCManager.checkBlock(state, attacker, attackType)
    if attackType ~= "M1" then return false end
    if not state.isBlocking then return false end
    NPCManager.fillPosture(state, Config.Posture.FillBlock)
    return true
end

function NPCManager.fillPosture(state, amount)
    if tick() < state.guardBrokenUntil then return end
    state.posture = math.min((state.posture or 0) + amount, Config.Posture.Max)
    if state.posture >= Config.Posture.Max then
        NPCManager.triggerGuardBreak(state)
    end
end

function NPCManager.triggerGuardBreak(state)
    state.posture = 0
    state.guardBrokenUntil = tick() + (Config.Posture.GuardBreakDuration or 1.5)
    state.combatState = "GuardBroken"
    local hum = state.model:FindFirstChildOfClass("Humanoid")
    if hum then hum.WalkSpeed = 0 end
    fireLiveFeed(state.model:GetAttribute("NPCName"), "was guard broken")
    task.delay(Config.Posture.GuardBreakDuration or 1.5, function()
        if npcs[state.model] == state and state.combatState == "GuardBroken" then
            state.combatState = "Idle"
            local h = state.model:FindFirstChildOfClass("Humanoid")
            if h then h.WalkSpeed = npcCfg.WalkSpeed end
        end
    end)
end

function NPCManager.enterDowned(model, state)
    state = state or npcs[model]; if not state then return end
    state.downed = true
    state.combatState = "Downed"
    state.target = nil
    local rm = _G.RagdollManager
    if rm then rm.ragdoll(model, Vector3.new(0, -5, 0)) end
    fireLiveFeed(model:GetAttribute("NPCName"), "was downed")
end

-- Mirrors CombatManager.applyDamage's player-parity clamp logic (grip lock, downed
-- entry) since applyDamage itself only understands Players, never NPC Models.
function NPCManager.applyDamageToNPC(model, damage, attacker, sourceTag)
    local state = npcs[model]; if not state then return 0 end
    if state.dead then return 0 end
    local hum = model:FindFirstChildOfClass("Humanoid"); if not hum then return 0 end
    if state.downed then return hum.Health end -- absorbed entirely while already downed

    if state.aggroType == "OnAttacked" and attacker and not state.target then
        state.target = attacker
        state.combatState = "Attacking"
        NPCManager.speak(model, "OnAggro")
    end
    if attacker then state.attackedBy[attacker] = true end
    NPCManager.speak(model, "OnDamage")

    if not state.gripAllowed then
        hum.Health = math.max(1, hum.Health - damage)
        return hum.Health
    end
    if hum.Health - damage <= 0 then
        hum.Health = 1
        NPCManager.enterDowned(model, state)
        return 1
    end
    hum.Health -= damage
    return hum.Health
end

-- ---- Execute (B key) ----
local function executeNPC(player, model, state)
    state.dead = true
    state.combatState = "Dead"
    NPCManager.speak(model, "OnDeath")
    local rm = _G.RagdollManager
    if rm then rm.applyDeathRagdoll(model) end
    local npcName = model:GetAttribute("NPCName")
    local charName = getCharName(player)
    fireLiveFeed(charName, "executed NPC " .. npcName)
    local disc = _G.DiscordManager
    if disc then disc.logNPC("DEATH", npcName .. " killed by " .. charName) end
    task.delay(npcCfg.RagdollDespawnDelay, function()
        if model.Parent then
            local spawnerPart = state.respawnSpawnerPart
            NPCManager.deleteNPC(model)
            local btm = _G.BToolsManager
            if spawnerPart and btm and btm.handleNPCRespawn then btm.handleNPCRespawn(spawnerPart) end
        end
    end)
end

RE_RequestExecute.OnServerEvent:Connect(function(player)
    local char = player.Character; if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
    local best, bestDist = nil, npcCfg.ExecuteRange
    for model, state in pairs(npcs) do
        if state.downed and not state.dead and state.gripAllowed and model.Parent then
            local nhrp = model:FindFirstChild("HumanoidRootPart")
            if nhrp then
                local d = (nhrp.Position - hrp.Position).Magnitude
                if d < bestDist then best = model; bestDist = d end
            end
        end
    end
    if not best then return end
    executeNPC(player, best, npcs[best])
end)

-- ---- AI: sight detection ----
local function isInSightCone(npcModel, targetHRP, range, coneAngleDeg)
    local hrp = npcModel:FindFirstChild("HumanoidRootPart"); if not hrp then return false end
    local toTarget = targetHRP.Position - hrp.Position
    local dist = toTarget.Magnitude
    if dist > range then return false end
    if dist > 0.1 then
        local look = hrp.CFrame.LookVector
        local angle = math.deg(math.acos(math.clamp(look.Unit:Dot(toTarget.Unit), -1, 1)))
        if angle > coneAngleDeg then return false end
    end
    local params = RaycastParams.new()
    params.FilterDescendantsInstances = { npcModel, targetHRP.Parent }
    params.FilterType = Enum.RaycastFilterType.Exclude
    local hit = workspace:Raycast(hrp.Position, toTarget, params)
    if hit then return false end
    return true
end

local function findNearestValidPlayer(npcModel, range, coneAngle)
    local hrp = npcModel:FindFirstChild("HumanoidRootPart"); if not hrp then return nil end
    local dm = _G.DataManager
    local best, bestDist = nil, range
    for _, p in ipairs(Players:GetPlayers()) do
        local pc = p.Character
        if pc then
            local phum = pc:FindFirstChildOfClass("Humanoid")
            local phrp = pc:FindFirstChild("HumanoidRootPart")
            if phum and phrp and phum.Health > 0 and not (dm and dm.getValue(p, "PlayerState") == "Dead") then
                if isInSightCone(npcModel, phrp, range, coneAngle) then
                    local d = (phrp.Position - hrp.Position).Magnitude
                    if d < bestDist then best = p; bestDist = d end
                end
            end
        end
    end
    return best
end

-- ---- AI: attack resolution against a player target ----
local NPC_HITBOX_M1 = combatCfg.HitboxM1 or { 3, 6, 5, 4 }
local NPC_HITBOX_M2 = combatCfg.HitboxM2 or { 2, 7, 5, 2.5 }

local function checkHitboxNPC(npcModel, box)
    local hrp = npcModel:FindFirstChild("HumanoidRootPart"); if not hrp then return {} end
    local params = OverlapParams.new()
    params.FilterDescendantsInstances = { npcModel }
    params.FilterType = Enum.RaycastFilterType.Exclude
    return workspace:GetPartBoundsInBox(hrp.CFrame * CFrame.new(box[1], 0, 0), Vector3.new(box[2], box[3], box[4]), params)
end

local function npcAttackPlayer(model, state, target, attackType)
    -- Plays the same client-predicted swing anim a real player would see on themselves, but
    -- server-driven here -- fires the instant the NPC commits to the swing regardless of
    -- whiff, matching a player's own click-time prediction. M2 has no dedicated clip for
    -- players either (playAnim no-ops silently), so nothing plays here for M2 -- parity, not a gap.
    if attackType == "M1" then NPCManager.playAnim(model, "M1Attack", 1) end
    local hits = checkHitboxNPC(model, attackType == "M2" and NPC_HITBOX_M2 or NPC_HITBOX_M1)
    local landed = false
    for _, part in ipairs(hits) do
        local vc = part:FindFirstAncestorOfClass("Model")
        if vc and target.Character and vc == target.Character then landed = true; break end
    end
    if not landed then return end

    local strength = model:GetAttribute("Strength") or 0
    local baseDmg = attackType == "M2" and combatCfg.M2Damage or combatCfg.M1Damage
    local damage = Util.getScaledValue(baseDmg, strength, STRENGTH_PER_POINT)
    local npcName = model:GetAttribute("NPCName")

    local pm = _G.ParryManager
    if pm and pm.isParrying(target) then
        local elapsed = pm.getElapsed(target) or 999
        local WINDOW_SEC = (parryCfg.WindowTotal or 20) / 60
        local PERFECT_SEC = (parryCfg.PerfectWindow or 10) / 60
        if attackType == "M2" then
            pm.cancelParry(target)
            local cm = _G.CombatManager
            if cm then cm.setCombatState(target, "Idle"); cm.applyStagger(target, parryCfg.StaggerDurationPerfect) end
            RE_OnParryResult:FireClient(target, { result = "Break", attackerName = npcName })
            return
        elseif elapsed < WINDOW_SEC then
            local result = elapsed < PERFECT_SEC and "Perfect" or "Late"
            pm.cancelParry(target)
            state.staggerUntil = tick() + (result == "Perfect" and parryCfg.StaggerDurationPerfect or parryCfg.StaggerDurationLate)
            state.combatState = "Staggered"
            RE_OnParryResult:FireClient(target, { result = result, attackerName = npcName })
            fireLiveFeed(npcName, "was parried by " .. getCharName(target))
            return
        end
    end

    if attackType == "M1" then
        local bm = _G.BlockManager
        if bm and bm.isBlocking(target) then
            -- BlockManager.checkHit reads attacker.Name and attacker.Character -- a real
            -- Model Instance has no .Character property and ERRORS on access (unlike a
            -- plain Lua table, which just returns nil), so the raw NPC Model can't be
            -- passed directly. A small duck-typed table gives it exactly the two fields
            -- it actually reads without needing a real Player.
            local fakeAttacker = { Name = npcName, Character = nil }
            local bResult = bm.checkHit(target, fakeAttacker, "M1")
            if bResult == true then return end
            if type(bResult) == "number" then damage = damage * bResult end
        end
    end

    local cm = _G.CombatManager
    local tc = target.Character
    local hum = tc and tc:FindFirstChildOfClass("Humanoid")
    if cm and hum then
        cm.applyDamage(hum, damage, target, "Mob")
        local hrpT = tc:FindFirstChild("HumanoidRootPart")
        if cm.spawnHitVFX and hrpT then cm.spawnHitVFX(hrpT.Position) end
        -- Only M1 gets a GotHit reaction anim on the victim, mirroring player-vs-player
        -- parity exactly (CombatManager's own M1 hit-loop only fires this for M1, never M2/
        -- DownSlam either) -- players hit by an NPC's M2 get knockback/flash but no clip,
        -- same as players hit by another player's M2.
        if attackType == "M1" then RE_PlayCombatAnim:FireClient(target, "M1GotHit", 1) end
        RE_OnHit:FireClient(target, { attackerName = npcName, damage = damage, attackType = attackType, newHealth = hum.Health })
        if hum.Health <= 1 then NPCManager.speak(model, "OnKill") end
    end
end

-- ---- AI: main decision loop ----
local function decideAction(model, state)
    if state.dead or state.downed then return end
    if tick() < state.staggerUntil then return end
    if tick() < state.guardBrokenUntil then return end
    if state.combatState == "Staggered" then state.combatState = "Idle" end

    local hum = model:FindFirstChildOfClass("Humanoid")
    local hrp = model:FindFirstChild("HumanoidRootPart")
    if not hum or not hrp or hum.Health <= 0 then return end

    if state.aggroType == "None" and tick() > state.nextIdlePhraseAt then
        NPCManager.speak(model, "Idle")
        state.nextIdlePhraseAt = tick() + math.random(npcCfg.IdlePhraseIntervalMin, npcCfg.IdlePhraseIntervalMax)
    end

    if state.aggroType == "None" then return end -- idle only, never attacks

    if state.aggroType == "OnSight" and not state.target then
        -- A freshly spawned/idle NPC has no reason to already face a player -- without
        -- some idle scan, the sight cone would only ever catch someone who happens to
        -- approach from whichever direction the rig originally spawned facing. Slowly
        -- rotating in place while idle (full sweep every ~6s) mirrors a guard scanning
        -- their surroundings and lets the cone actually do its job.
        -- Directly writing hrp.CFrame's rotation does NOT replicate to remote clients for
        -- a Humanoid-driven root part -- confirmed live: the server-side value rotated
        -- correctly every tick while every client stayed frozen at the spawn orientation.
        -- Remote clients reconstruct a Humanoid's facing from AutoRotate + actual
        -- movement, not from a raw CFrame snapshot, so the turn has to happen via a real
        -- (tiny) Humanoid:MoveTo() rather than a manual CFrame multiply.
        state.scanAngle = ((state.scanAngle or 0) + math.rad(60 * npcCfg.DecisionInterval)) % (2 * math.pi)
        local sweepDir = CFrame.Angles(0, state.scanAngle, 0).LookVector
        hum:MoveTo(hrp.Position + sweepDir * 3)
        local found = findNearestValidPlayer(model, state.sightRange, npcCfg.SightConeAngle)
        if found then
            state.target = found
            state.combatState = "Attacking"
            NPCManager.speak(model, "OnAggro")
        end
    elseif state.aggroType == "PlayerLed" then
        local leader = Players:GetPlayerByUserId(state.leaderUserId)
        if not leader or not leader.Character then
            -- leader offline/no character: just idle in place
        else
            local leaderChar = leader.Character
            local leaderCS = leaderChar:GetAttribute("CombatState")
            if leaderCS == "Dead" then
                state.aggroType = "OnSight"
                model:SetAttribute("AggroType", "OnSight")
                NPCManager.speak(model, "OnDeath")
            elseif not state.target then
                if leaderCS == "Downed" then
                    state.target = findNearestValidPlayer(model, state.sightRange, 360)
                    if state.target then state.combatState = "Attacking" end
                else
                    local leaderHRP = leaderChar:FindFirstChild("HumanoidRootPart")
                    if leaderHRP and (hrp.Position - leaderHRP.Position).Magnitude > npcCfg.PlayerLedFollowDist then
                        hum:MoveTo(leaderHRP.Position)
                    end
                end
            end
        end
    end

    if state.target then
        local tp = state.target
        local tc = tp.Character
        local thum = tc and tc:FindFirstChildOfClass("Humanoid")
        local thrp = tc and tc:FindFirstChild("HumanoidRootPart")
        local dm = _G.DataManager
        local invalid = (not tc) or (not thum) or thum.Health <= 0 or (dm and dm.getValue(tp, "PlayerState") == "Dead")
        if invalid then
            state.target = nil
            state.combatState = "Idle"
            return
        end
        if (hrp.Position - state.spawnPosition).Magnitude > state.leashRange then
            state.target = nil
            state.combatState = "Idle"
            hum:MoveTo(state.spawnPosition)
            return
        end
        local hpFrac = hum.Health / math.max(1, hum.MaxHealth)
        if hpFrac < npcCfg.LowHPThreshold and math.random() < npcCfg.RetreatChance then
            hum:MoveTo(state.spawnPosition)
            return
        end
        local dist = (thrp.Position - hrp.Position).Magnitude
        if dist > npcCfg.ApproachTriggerDist then
            hum:MoveTo(thrp.Position)
        else
            hum:MoveTo(hrp.Position)
            local lookPos = Vector3.new(thrp.Position.X, hrp.Position.Y, thrp.Position.Z)
            if (lookPos - hrp.Position).Magnitude > 0.1 then
                hrp.CFrame = CFrame.lookAt(hrp.Position, lookPos)
            end
            local w = npcCfg.ActionWeights
            local roll = math.random()
            if roll < w.M1 and tick() - state.lastM1 > npcCfg.M1Cooldown then
                state.lastM1 = tick()
                npcAttackPlayer(model, state, tp, "M1")
            elseif roll < w.M1 + w.M2 and tick() - state.lastM2 > npcCfg.M2Cooldown then
                state.lastM2 = tick()
                npcAttackPlayer(model, state, tp, "M2")
            elseif roll < w.M1 + w.M2 + w.Parry and not state.isParrying and tick() > state.parryCooldownUntil then
                state.isParrying = true
                state.parryStartTime = tick()
                state.parryCooldownUntil = tick() + npcCfg.ParryCooldown
                local myModel = model
                task.delay((parryCfg.WindowTotal or 20) / 60, function()
                    local cur = npcs[myModel]
                    if cur == state and state.isParrying then state.isParrying = false end
                end)
            end
        end
    end
end

RunService.Heartbeat:Connect(function(dt)
    for model, state in pairs(npcs) do
        if model.Parent then
            state.decisionAccum = (state.decisionAccum or 0) + dt
            if state.decisionAccum >= npcCfg.DecisionInterval then
                state.decisionAccum = 0
                local ok, err = pcall(decideAction, model, state)
                if not ok then warn("[NPCManager] AI error for " .. model.Name .. ": " .. tostring(err)) end
            end
        end
    end
end)

_G.NPCManager = NPCManager
