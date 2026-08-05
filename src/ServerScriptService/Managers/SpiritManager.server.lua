-- SpiritManager — Part Four
local Players            = game:GetService("Players")
local RepStorage         = game:GetService("ReplicatedStorage")
local RunService         = game:GetService("RunService")
local CollectionService  = game:GetService("CollectionService")
local Debris             = game:GetService("Debris")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local factions = Config.SpiritFactions

local function getOrCreate(name, isFunc)
    local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
        local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
    end)()
    local r=folder:FindFirstChild(name); if r then return r end
    r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_ModActionCard  = getOrCreate("ModActionCard")
local RE_LiveFeedUpdate = getOrCreate("LiveFeedUpdate")
local RE_NPCSpeak       = getOrCreate("NPCSpeak")

local SPIRIT_TAG          = "ABYSSSpirit"
local DRIFT_RADIUS        = 5
local SIGHT_RADIUS        = 20
local INTERACT_RADIUS     = 8
local HOSTILE_DRAIN_RADIUS= 8
local HOSTILE_DRAIN_RATE  = 2 -- HP/sec while Rep < -50 and nearby

local spirits = {} -- [part] = {faction=, baseCFrame=, phase=}
local lastSighted = {} -- ["uid_partId"] = tick

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

local SpiritManager = {}

function SpiritManager.handleInteract(player, part)
    local info = spirits[part]; if not info then return end
    local tm = _G.TalentManager
    -- Defensive re-check: the client already hides/disables the ProximityPrompt locally for
    -- non-Awakened players (see SpiritClient), but a modified client could still fire
    -- Triggered, so the server is the real gate.
    if not (tm and tm.hasTalent(player, "AwakenedEyes")) then return end
    local dm = _G.DataManager
    local rep = dm and (dm.getValue(player, "SpiritReputation") or {})[info.faction] or 0
    local charName = getCharName(player)
    local pos = part.Position

    local soundsFolder = RepStorage:FindFirstChild("_Sounds")
    local function playCue(name)
        local snd = soundsFolder and soundsFolder:FindFirstChild(name)
        local id = snd and snd.SoundId
        if id and id ~= "" and id ~= "rbxassetid://0" then
            local s = Instance.new("Sound"); s.SoundId = id; s.Volume = 0.6; s.Parent = part; s:Play()
            local cleaned = false
            local function cleanup() if not cleaned then cleaned = true; if s.Parent then s:Destroy() end end end
            s.Ended:Once(cleanup)
            task.delay(6, cleanup)
        end
    end
    if rep > 50 then
        playCue("spirit_welcome")
    elseif rep < 0 then
        playCue("spirit_warning")
    end

    -- Speak a random phrase (if the lore team/mods have given this spirit any) as a real
    -- floating speech bubble via the same NPCSpeak pipeline NPCs already use -- part itself
    -- stands in for "head" since a spirit orb has no rigged head to anchor to.
    if #info.phrases > 0 then
        local text = info.phrases[math.random(#info.phrases)]
        RE_NPCSpeak:FireAllClients(part, info.faction .. " Spirit", text)
    end

    fireLiveFeed(charName, string.format("interacted with a %s Spirit (Rep: %d)", info.faction, rep))
    local disc = _G.DiscordManager
    if disc then disc.logSpiritInteraction(player, info.faction, rep, pos) end

    local mgr = _G.ModManager
    local payload = {
        id = "spirit_" .. player.UserId .. "_" .. tostring(os.time()),
        category = "Spirit",
        title = "SPIRIT INTERACTION",
        body = string.format("%s (Rep: %d with %s) interacted with a %s Spirit at (%.0f,%.0f,%.0f)",
            charName, rep, info.faction, info.faction, pos.X, pos.Y, pos.Z),
        target = player.Name,
        buttons = {
            { label = "Bless",   cmd = "spiritBless", arg = info.faction },
            { label = "Warn",    cmd = "spiritWarn",  arg = info.faction },
            { label = "Ignore" },
            { label = "Dismiss" },
        },
    }
    for _, p in ipairs(Players:GetPlayers()) do
        if mgr and mgr.isMod(p) then RE_ModActionCard:FireClient(p, payload) end
    end
end

function SpiritManager.spawnSpirit(factionName, position)
    local def = factions[factionName]
    if not def then return nil end
    local part = Instance.new("Part")
    part.Name = "Spirit_" .. factionName
    part.Shape = Enum.PartType.Ball
    part.Anchored = true
    part.CanCollide = false
    part.Transparency = 0.3
    part.Material = Enum.Material.Neon
    part.Color = def.color
    part.Size = Vector3.new(def.size, def.size, def.size)
    part.CFrame = CFrame.new(position)
    part:SetAttribute("Faction", factionName)
    part.Parent = workspace

    local light = Instance.new("PointLight")
    light.Color = def.color; light.Range = 12; light.Brightness = 2
    light.Parent = part

    -- PLACEHOLDER_ASSET: SpiritOrbEffect
    local pe = Instance.new("ParticleEmitter")
    pe.Color = ColorSequence.new(def.color)
    pe.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 0)})
    pe.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1)})
    pe.Lifetime = NumberRange.new(1, 2)
    pe.Rate = 4
    pe.Speed = NumberRange.new(0.2, 0.5)
    pe.Parent = part

    local prompt = Instance.new("ProximityPrompt")
    prompt.ActionText = "Commune"
    prompt.ObjectText = factionName .. " Spirit"
    prompt.HoldDuration = 0
    prompt.MaxActivationDistance = INTERACT_RADIUS
    prompt.RequiresLineOfSight = true
    prompt.Parent = part

    prompt.Style = Enum.ProximityPromptStyle.Custom -- "E - Commune", matches the custom
    -- "E - <ActionText>" HUD prompt InteractPromptClient already renders for every other
    -- Custom-style prompt in the game (Mining/Boat/Trade/etc), instead of the default gamepad-
    -- style Roblox prompt spirits were using before.

    CollectionService:AddTag(part, SPIRIT_TAG)
    spirits[part] = { faction = factionName, baseCFrame = part.CFrame, phase = math.random() * math.pi * 2, phrases = {} }

    prompt.Triggered:Connect(function(player)
        SpiritManager.handleInteract(player, part)
    end)
    part.Destroying:Connect(function() spirits[part] = nil end)

    print(string.format("[SpiritManager] Spawned %s spirit at %s", factionName, tostring(position)))
    return part
end

-- Phrase management (design doc: "spirits can have phrases to tell people") -- same
-- add/remove/list shape as NPCManager's own phrase system, just flat (no trigger buckets --
-- spirits only ever speak on Commune, unlike NPCs' OnSpawn/OnAggro/OnDamage/etc range).
function SpiritManager.addPhrase(part, text)
    local info = spirits[part]; if not info then return false end
    if type(text) ~= "string" or text == "" then return false end
    table.insert(info.phrases, text)
    return true
end

function SpiritManager.removePhrase(part, index)
    local info = spirits[part]; if not info then return false end
    index = tonumber(index)
    if not index or not info.phrases[index] then return false end
    table.remove(info.phrases, index)
    return true
end

function SpiritManager.getPhrases(part)
    local info = spirits[part]; if not info then return {} end
    return info.phrases
end

-- Finds a spirit part by its ShipManagement/BTools-style Name ("Spirit_<Faction>" is the
-- default from spawnSpirit, but the mod may have renamed the placement) -- used by the mod
-- panel and BTools' "Add Phrase to Selected" so callers don't need to hold a live part
-- reference across a remote round-trip.
function SpiritManager.findSpiritByName(name)
    for part in pairs(spirits) do
        if part.Name == name then return part end
    end
    return nil
end

function SpiritManager.setReputation(player, factionName, amount)
    if not factions[factionName] then return false end
    local dm = _G.DataManager
    if not dm then return false end
    local rep = dm.getValue(player, "SpiritReputation") or {}
    rep[factionName] = math.clamp(tonumber(amount) or 0, -100, 100)
    dm.setValue(player, "SpiritReputation", rep)
    return true
end

-- Idle float/drift + sighting feed (throttled) + hostile-rep HP drain, all on one Heartbeat.
local accum = 0
RunService.Heartbeat:Connect(function(dt)
    local t = tick()
    for part, info in pairs(spirits) do
        if part.Parent then
            local ox = math.sin(t * 0.3 + info.phase) * DRIFT_RADIUS
            local oz = math.cos(t * 0.25 + info.phase) * DRIFT_RADIUS
            local oy = math.sin(t * 0.6 + info.phase) * 0.4
            part.CFrame = info.baseCFrame + Vector3.new(ox, oy, oz)
        end
    end
    accum += dt
    if accum < 2 then return end
    accum = 0
    local tm = _G.TalentManager
    local dm = _G.DataManager
    for _, player in ipairs(Players:GetPlayers()) do
        if tm and tm.hasTalent(player, "AwakenedEyes") and player.Character then
            local hrp = player.Character:FindFirstChild("HumanoidRootPart")
            if hrp then
                for part, info in pairs(spirits) do
                    if part.Parent then
                        local dist = (part.Position - hrp.Position).Magnitude
                        if dist <= SIGHT_RADIUS then
                            local key = player.UserId .. "_" .. tostring(part)
                            if (t - (lastSighted[key] or 0)) > 60 then
                                lastSighted[key] = t
                                fireLiveFeed(getCharName(player), "saw a " .. info.faction .. " Spirit")
                            end
                        end
                        if dist <= HOSTILE_DRAIN_RADIUS then
                            local rep = dm and (dm.getValue(player, "SpiritReputation") or {})[info.faction] or 0
                            if rep < -50 then
                                local hum = player.Character:FindFirstChildOfClass("Humanoid")
                                if hum then hum.Health = math.max(1, hum.Health - HOSTILE_DRAIN_RATE * 2) end
                                local sanM = _G.SanityManager
                                if sanM then sanM.trackHostileSpiritExposure(player) end
                            end
                        end
                    end
                end
            end
        end
    end
end)

_G.SpiritManager = SpiritManager
print("[SpiritManager] Init")
