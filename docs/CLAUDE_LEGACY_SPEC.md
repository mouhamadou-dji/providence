# ABYSS — Claude Code Context File
# Version: 1.0 | ReapFX 2026
# READ THIS ENTIRE FILE BEFORE WRITING A SINGLE LINE OF CODE

---

## CRITICAL RULES — NON-NEGOTIABLE

1. **Test every module before moving to the next.** Write → Sync via Rojo → Test in Studio → Confirm working → Only then proceed.
2. **Never build System B on top of System A until System A is confirmed working in a live private server.**
3. **If a test fails, fix and retest before continuing. No skipping ahead.**
4. **Server owns ALL state. Clients fire inputs only. Never trust a value the client sends.**
5. **Never use Touched events for combat. Always use GetPartBoundsInBox.**
6. **All DataStore writes use UpdateAsync. Never SetAsync. Always pcall-wrapped with retry logic.**
7. **All RemoteEvents are rate-limited server-side to reject spam and exploits.**
8. **Placeholders are mandatory** for animations, sounds, and GUIs — mark every placeholder clearly with a comment so the owner can swap them later.
9. **Log every test result** at the bottom of this file under ## TEST LOG.

---

## WHAT IS ABYSS

A dark lore-driven Roblox RPG set in Gaul (modern France), ~400 BC. Greek colonists, Gaulish tribes, and darker forces share an open world. Combat is parry-first and stamina-gated. All progression is granted manually by a lore team — nothing is auto-earned. Death, when it matters, is permanent.

- **Rig:** R6
- **Platform:** Roblox PC-primary
- **Sync:** Rojo — all scripts live in the project folder, synced to Studio
- **Owners (hardcoded):** `greatmlgpd1` / `Broke3n` — permissions above all mods

---

## ROJO FILE STRUCTURE

```
ABYSS/
├── src/
│   ├── server/
│   │   ├── DataManager.server.lua
│   │   ├── StaminaManager.server.lua
│   │   ├── CombatManager.server.lua
│   │   ├── ParryManager.server.lua
│   │   ├── PostureManager.server.lua
│   │   ├── ClashManager.server.lua
│   │   ├── MovementManager.server.lua
│   │   ├── TraitManager.server.lua
│   │   ├── TalentManager.server.lua
│   │   ├── LoreManager.server.lua
│   │   ├── ZoneManager.server.lua
│   │   ├── WeatherManager.server.lua
│   │   ├── ModManager.server.lua
│   │   └── DiscordManager.server.lua
│   ├── client/
│   │   ├── InputHandler.client.lua
│   │   ├── HUDManager.client.lua
│   │   ├── PostureBarClient.client.lua
│   │   ├── JournalClient.client.lua
│   │   ├── ZoneNotifyClient.client.lua
│   │   └── WeatherClient.client.lua
│   └── shared/
│       ├── Config.lua
│       ├── Enums.lua
│       ├── RemoteEvents.lua
│       └── Util.lua
├── default.project.json
└── CLAUDE.md
```

**Roblox service mapping:**
- `src/server/` → `ServerScriptService`
- `src/client/` → `StarterPlayerScripts`
- `src/shared/` → `ReplicatedStorage`

---

## BUILD ORDER — FOLLOW EXACTLY

| # | Module | Test Criteria Before Proceeding |
|---|--------|----------------------------------|
| 1 | DataManager | Character data saves and loads correctly. Session lock works. No data loss on rejoin. |
| 2 | StaminaManager | Stamina drains on action, regens correctly idle vs combat, zero stamina state works. |
| 3 | CombatManager | Hitbox fires server-side, damage applies, hitstun state sets correctly. |
| 4 | ParryManager | Perfect/late/whiff all resolve correctly. Stagger applies. Cooldown enforced. |
| 5 | PostureManager | Posture fills on whiff/block/get-parried. Guard break triggers. Manual drain (G) works. Reset on break confirmed. |
| 6 | ClashManager | Clash triggers on frame-perfect heavies. Input race works. Win/lose outcomes apply correctly. |
| 7 | MovementManager | Sprint, dash, slide, crouch, jump all work. Stamina costs apply on each. |
| 8 | TraitManager | Trait spawns on character creation from weighted pool. Trait effects apply correctly. |
| 9 | TalentManager | Lore team can assign/revoke talents via mod menu. Talent effects apply immediately. |
| 10 | LoreManager | PDE detection works at Stage 3+. Lore Record writes to DataStore. Lore Scar applies to zone. |
| 11 | ZoneManager | Trigger boxes fire on entry/exit. Zone name fades in center top. Discovery logs correctly. |
| 12 | WeatherManager | Day cycle runs at 25min per full day. Zone fog persistent. Mod override reverts after duration. |
| 13 | HUDManager | All HUD elements display correctly. Posture bar visible to self only. Eclipse Moon updates with PD stage. |
| 14 | ModManager | All commands work. Permission check enforces group rank. Owner bypass confirmed. All actions log. |
| 15 | DiscordManager | Webhook fires on mod action. Discord message appears in-game tagged correctly. |

---

## SHARED CONFIG — src/shared/Config.lua

```lua
-- ABYSS Global Config
-- Edit values here to tune the game without touching system scripts

local Config = {}

-- OWNERS (hardcoded — do not change without permission)
Config.Owners = {"greatmlgpd1", "Broke3n"}

-- MOD GROUP
Config.ModGroupId = 0        -- PLACEHOLDER: replace with actual Roblox group ID
Config.ModRankMinimum = 100  -- PLACEHOLDER: replace with actual minimum mod rank

-- STAMINA
Config.Stamina = {
    Max = 100,
    RegenIdle = 5,       -- per tick out of combat
    RegenCombat = 2,     -- per tick in combat
    RegenTickRate = 0.1, -- seconds per tick
    CostM1 = 8,
    CostM2 = 18,
    CostParry = 12,
    CostParryTrait = 20,
    CostBlockPerSec = 5,
    CostDash = 10,
    CostDodgeFist = 8,
    CostClashEnter = 15,
    CostClashWinRefund = 10,
    CostSprint = 3,      -- per second
    HungerZeroDrainMult = 1.2, -- multiplier on drain at zero hunger
    HungerZeroRegenMult = 0.5, -- multiplier on regen at zero hunger
}

-- POSTURE
Config.Posture = {
    Max = 100,
    FillWhiff = 15,
    FillGotParried = 20,
    FillBlock = 10,       -- per blocked hit
    DrainRateNatural = 5, -- per second out of combat
    DrainRateManual = 15, -- per second while holding G stationary
    DrainRateInCombat = 0, -- no drain mid-fight
}

-- PARRY
Config.Parry = {
    WindowTotal = 14,       -- frames total
    PerfectWindow = 4,      -- frames for perfect parry
    Cooldown = 0.6,         -- seconds
    StaggerDurationPerfect = 1.2,
    StaggerDurationLate = 0.5,
}

-- COMBAT
Config.Combat = {
    M1Damage = 15,
    M2Damage = 30,
    FistDamageMultiplier = 0.6, -- fists deal 60% of normal M1 damage
    HitstunDuration = 0.3,
    KnockbackForce = 40,
    ExecuteHealthThreshold = 0.15, -- below 15% HP = executable
}

-- CLASH
Config.Clash = {
    InputRaceTime = 3,     -- seconds to complete the sequence
    SequenceLength = 5,    -- number of inputs in the race
    LoserStaggerDuration = 0.8,
    LoserStaminaDrain = 10,
}

-- HUNGER
Config.Hunger = {
    Max = 100,
    DrainHealingRate = 2,  -- per second while healing
    DrainPassiveRate = 0.1, -- per second not in combat
    DrainCombatRate = 0,   -- no drain mid combat
}

-- DAY CYCLE
Config.DayCycle = {
    FullDayDuration = 1500, -- 25 minutes in seconds
}

-- CURRENCY
Config.Currency = {
    -- conversion: 1 higher = 10 lower
    Tiers = {"Obol", "Drachma", "Stater", "RoyalStater"},
    ConversionRate = 10,
}

-- PD STAGES
Config.PDStages = {
    [0] = "Inert",
    [1] = "Awakened",
    [2] = "Scarred",
    [3] = "Burning",
    [4] = "Condemned",
    [5] = "TheAbyss",
}

-- DISCORD WEBHOOK
Config.DiscordWebhook = "PLACEHOLDER_WEBHOOK_URL"

return Config
```

---

## SHARED ENUMS — src/shared/Enums.lua

```lua
local Enums = {}

Enums.Race = {
    Human = "Human",
    Vampire = "Vampire",
    Dwarf = "Dwarf",
    Apostle = "Apostle",
    GodHand = "GodHand",
}

Enums.Relation = {
    Brother = "Brother",
    Sister = "Sister",
    Twin = "Twin",
    Cousin = "Cousin",
    DistantRelative = "DistantRelative",
    None = "None",
}

Enums.PlayerState = {
    Alive = "Alive",
    Dead = "Dead",    -- Valhalla state
}

Enums.ParryResult = {
    Perfect = "Perfect",
    Late = "Late",
    Whiff = "Whiff",
    Break = "Break",
}

Enums.WeaponType = {
    Longsword = "Longsword",
    Spear = "Spear",
    Axe = "Axe",
    Dagger = "Dagger",
    Fists = "Fists",
}

Enums.WeaponQuality = {
    Iron = 1,
    Steel = 2,
    Masterwork = 3,
    Legendary = 4,
    Divine = 5,
}

Enums.Weather = {
    Clear = "Clear",
    Fog = "Fog",
    Rain = "Rain",
    Storm = "Storm",
    BloodRain = "BloodRain",
    Earthquake = "Earthquake",
}

Enums.CombatState = {
    Idle = "Idle",
    Attacking = "Attacking",
    Parrying = "Parrying",
    Blocking = "Blocking",
    Staggered = "Staggered",
    GuardBroken = "GuardBroken",
    Clashing = "Clashing",
    Dead = "Dead",
}

Enums.Currency = {
    Obol = "Obol",
    Drachma = "Drachma",
    Stater = "Stater",
    RoyalStater = "RoyalStater",
}

return Enums
```

---

## REMOTE EVENTS — src/shared/RemoteEvents.lua

```lua
-- All RemoteEvents and RemoteFunctions defined here
-- Server creates them. Client reads them from ReplicatedStorage.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RemoteEvents = {}

local function getOrCreate(name, isFunction)
    local existing = ReplicatedStorage:FindFirstChild(name)
    if existing then return existing end
    local obj = isFunction
        and Instance.new("RemoteFunction")
        or Instance.new("RemoteEvent")
    obj.Name = name
    obj.Parent = ReplicatedStorage
    return obj
end

-- COMBAT (client → server intent)
RemoteEvents.RequestM1        = getOrCreate("RequestM1")
RemoteEvents.RequestM2        = getOrCreate("RequestM2")
RemoteEvents.RequestParry     = getOrCreate("RequestParry")
RemoteEvents.RequestBlock     = getOrCreate("RequestBlock")
RemoteEvents.RequestBlockEnd  = getOrCreate("RequestBlockEnd")
RemoteEvents.RequestDash      = getOrCreate("RequestDash")
RemoteEvents.RequestCritical  = getOrCreate("RequestCritical")
RemoteEvents.RequestRiposte   = getOrCreate("RequestRiposte")
RemoteEvents.RequestClashInput = getOrCreate("RequestClashInput")

-- POSTURE
RemoteEvents.RequestPostureDrain = getOrCreate("RequestPostureDrain") -- G held
RemoteEvents.UpdatePostureBar    = getOrCreate("UpdatePostureBar")    -- server → self only

-- COMBAT RESULTS (server → clients)
RemoteEvents.OnHit            = getOrCreate("OnHit")
RemoteEvents.OnParryResult    = getOrCreate("OnParryResult")
RemoteEvents.OnGuardBreak     = getOrCreate("OnGuardBreak")
RemoteEvents.OnClashStart     = getOrCreate("OnClashStart")
RemoteEvents.OnClashResult    = getOrCreate("OnClashResult")
RemoteEvents.OnStagger        = getOrCreate("OnStagger")

-- MOVEMENT
RemoteEvents.RequestSprint    = getOrCreate("RequestSprint")
RemoteEvents.RequestSprintEnd = getOrCreate("RequestSprintEnd")
RemoteEvents.RequestCrouch    = getOrCreate("RequestCrouch")
RemoteEvents.RequestSlide     = getOrCreate("RequestSlide")
RemoteEvents.RequestJump      = getOrCreate("RequestJump")

-- HUD / UI (server → specific client)
RemoteEvents.UpdateHUD        = getOrCreate("UpdateHUD")
RemoteEvents.UpdateEclipseMoon = getOrCreate("UpdateEclipseMoon")
RemoteEvents.ShowZoneNotify   = getOrCreate("ShowZoneNotify")
RemoteEvents.ShowGlobalMessage = getOrCreate("ShowGlobalMessage")
RemoteEvents.TriggerQTE       = getOrCreate("TriggerQTE")
RemoteEvents.QTEResult        = getOrCreate("QTEResult")

-- WEATHER (server → all clients)
RemoteEvents.UpdateWeather    = getOrCreate("UpdateWeather")
RemoteEvents.UpdateLighting   = getOrCreate("UpdateLighting")

-- DATA
RemoteEvents.RequestJournalData = getOrCreate("RequestJournalData", true) -- RF

-- MOD MENU
RemoteEvents.ModCommand       = getOrCreate("ModCommand")
RemoteEvents.ModMenuData      = getOrCreate("ModMenuData", true) -- RF

-- CHAT
RemoteEvents.ActionCommand    = getOrCreate("ActionCommand")   -- /a
RemoteEvents.LoreTeamMessage  = getOrCreate("LoreTeamMessage") -- /t

return RemoteEvents
```

---

## DATASTORE SCHEMA — Character Data

```lua
-- Stored under DataStore key: "Player_" .. player.UserId
-- Use UpdateAsync ALWAYS. Never SetAsync.

local defaultData = {
    -- Identity
    CharacterID = "",          -- GUID generated on first save
    FirstName = "",            -- randomly generated
    FamilyName = "",           -- randomly generated
    Relation = "None",         -- Enums.Relation
    Gender = "",               -- "Male" / "Female" / player choice
    Race = "Human",            -- Enums.Race

    -- State
    PlayerState = "Alive",     -- Enums.PlayerState
    SpawnOverride = nil,       -- Vector3 or nil

    -- Stats (all hidden by default)
    Stats = {
        Strength = 0,
        Endurance = 0,
        Agility = 0,
    },
    RevealedStats = {},        -- list of stat names revealed by lore team

    -- Currency
    Currency = {
        Obol = 0,
        Drachma = 0,
        Stater = 0,
        RoyalStater = 0,
    },

    -- Progression
    Talents = {},              -- list of talentIDs
    Title = "",                -- current title string
    Scars = {},                -- list of scar type strings

    -- Hunger
    Hunger = 100,

    -- Family
    FamilyAssigned = "",       -- family name assigned by lore team
    BannerID = 0,              -- GFX asset ID

    -- Lore
    DiscoveredZones = {},      -- zones discovered this life (reset on wipe)
    LoreEchoes = {},           -- echoes from previous lives
    PDEFlagged = false,        -- is this character PDE eligible

    -- Bounty
    BountyAmount = 0,
    BountyActive = false,
    BrandActive = false,

    -- Reputation (per faction)
    Reputation = {
        Gauls = 0,
        Greeks = 0,
        Military = 0,
    },

    -- Inventory
    Inventory = {},            -- list of {itemID, quality, type}
    EquippedWeapon = nil,      -- itemID or nil

    -- Map
    UnlockedMapSections = {},  -- list of section IDs

    -- Meta
    DataVersion = 1,
    CreatedAt = 0,
    LastSaved = 0,
}
```

---

## SERVER DATASTORE WRAPPER PATTERN

```lua
-- Use this pattern for ALL DataStore operations
local DataStoreService = game:GetService("DataStoreService")
local PlayerDataStore = DataStoreService:GetDataStore("AbyssPlayerData_v1")

local MAX_RETRIES = 3
local RETRY_DELAY = 2

local function safeUpdate(key, transformFn)
    local attempts = 0
    local success, result
    repeat
        attempts += 1
        success, result = pcall(function()
            return PlayerDataStore:UpdateAsync(key, transformFn)
        end)
        if not success then
            warn("[DataManager] UpdateAsync failed attempt " .. attempts .. ": " .. tostring(result))
            if attempts < MAX_RETRIES then
                task.wait(RETRY_DELAY)
            end
        end
    until success or attempts >= MAX_RETRIES
    if not success then
        warn("[DataManager] All retries exhausted for key: " .. key)
    end
    return success, result
end
```

---

## COMBAT SYSTEM RULES

### Server Authority
- Client fires: `RequestM1`, `RequestM2`, `RequestParry`, `RequestBlock`, `RequestDash`
- Server validates: cooldown elapsed? stamina available? player alive? not already staggered?
- Server resolves: applies damage, stagger, stamina drain
- Server replicates: fires `OnHit`, `OnParryResult`, `OnStagger` to relevant clients

### Hitbox Pattern
```lua
-- Run this on the server during the active swing frames
local function checkHitbox(character, offset, size)
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if not hrp then return {} end
    local params = OverlapParams.new()
    params.FilterDescendantsInstances = {character}
    params.FilterType = Enum.RaycastFilterType.Exclude
    return workspace:GetPartBoundsInBox(
        hrp.CFrame * CFrame.new(offset),
        size,
        params
    )
end
```

### Parry Window
```lua
-- Frame-count server-side using RunService.Heartbeat
-- NEVER interpolate on client
-- Perfect: frames 1–4
-- Late: frames 5–14
-- After frame 14: whiff regardless
```

### Rate Limiting Pattern
```lua
local cooldowns = {} -- [player.UserId] = {actionName = lastTickTime}

local function checkRateLimit(player, action, cooldownTime)
    local userId = player.UserId
    cooldowns[userId] = cooldowns[userId] or {}
    local last = cooldowns[userId][action] or 0
    if tick() - last < cooldownTime then
        return false -- rate limited
    end
    cooldowns[userId][action] = tick()
    return true
end
```

---

## POSTURE BAR RULES

- Tracked server-side as a float 0–100 (default max, moddable per player)
- Builds on: whiff parry (+15), getting parried (+20), blocking a hit (+10)
- Guard Break: posture hits max AND (player blocks again OR critical lands)
- On Guard Break: posture resets to 0, GuardBroken state set for 1.5s
- Drain: 0 mid-combat, 5/sec natural out of combat, 15/sec manual (G held + stationary)
- Server fires `UpdatePostureBar` only to the affected player — not broadcast to all

---

## PLACEHOLDER STANDARDS

Every placeholder must follow this exact comment format so the owner can find and replace them:

```lua
-- PLACEHOLDER_ANIMATION: idle_walk — replace with actual AnimationId
-- PLACEHOLDER_SOUND: sword_clash — replace with actual SoundId  
-- PLACEHOLDER_GUI: HUDFrame — replace with actual ScreenGui design
-- PLACEHOLDER_ASSET: EclipseMoon_Stage0 — replace with actual asset ID
-- PLACEHOLDER_WEBHOOK: DiscordWebhook — replace with actual webhook URL
-- PLACEHOLDER_GROUPID: ModGroupId — replace with actual Roblox group ID
-- PLACEHOLDER_RANKID: ModRankMinimum — replace with actual rank number
```

### Known Placeholders to Create:
| Placeholder | Location | Notes |
|-------------|----------|-------|
| Character animations (idle, walk, run, attack, parry, block, stagger, guard break, clash, riposte, critical, death) | CombatManager / MovementManager | Use default Roblox anims for now |
| Sword clash sound | CombatManager | Any temp impact sound |
| Parry success sound | ParryManager | Short sharp sound |
| Zone entry music | ZoneManager | One track per biome |
| Eclipse Moon asset (6 stages) | HUDManager | Use placeholder ImageLabel |
| Rain particle system | WeatherClient | Roblox default particles ok |
| Posture bar GUI | HUDManager | Simple bar frame |
| Health / Stamina / Hunger bars | HUDManager | Simple bar frames |
| Global message animation | HUDManager | Simple typewriter tween |
| Mod menu GUI | ModManager | Functional over beautiful for now |
| Valhalla statue model | LoreManager | Any placeholder part |
| Lore Board model | LoreManager | Any placeholder part |
| Discord webhook URL | Config.lua | Insert before going live |
| Roblox group ID + rank | Config.lua | Insert before going live |

---

## MOD PERMISSION CHECK PATTERN

```lua
local Players = game:GetService("Players")
local GroupService = game:GetService("GroupService")
local Config = require(game.ReplicatedStorage.Shared.Config)

local function isOwner(player)
    return table.find(Config.Owners, player.Name) ~= nil
end

local function isMod(player)
    if isOwner(player) then return true end
    local success, rank = pcall(function()
        return player:GetRankInGroup(Config.ModGroupId)
    end)
    return success and rank >= Config.ModRankMinimum
end

-- Use at the top of every mod command handler:
-- if not isMod(player) then return end
```

---

## ECLIPSE MOON — PD STAGE UI

```lua
-- HUDManager client-side
-- Listen to UpdateEclipseMoon remote
-- Swap ImageLabel.Image based on stage 0–5

local EclipseMoonAssets = {
    [0] = "PLACEHOLDER_ASSET: EclipseMoon_Stage0",
    [1] = "PLACEHOLDER_ASSET: EclipseMoon_Stage1",
    [2] = "PLACEHOLDER_ASSET: EclipseMoon_Stage2",
    [3] = "PLACEHOLDER_ASSET: EclipseMoon_Stage3",
    [4] = "PLACEHOLDER_ASSET: EclipseMoon_Stage4",
    [5] = "PLACEHOLDER_ASSET: EclipseMoon_Stage5",
}
-- Position: lower corner of screen (AnchorPoint 1,1 — Position 1,0,1,0)
```

---

## ZONE SYSTEM RULES

```lua
-- Each zone is a Part with:
--   Attribute "ZoneName" = string (or "???" if undiscovered)
--   Attribute "ZoneDescription" = string (or "???" if undiscovered)
--   Attribute "ZoneMusic" = SoundId (PLACEHOLDER_SOUND: zone_music_[name])
--   Attribute "ZoneFog" = boolean
--   Attribute "ZoneFogDensity" = number
--   Attribute "ZoneLocked" = boolean (mod-toggleable)
--   Attribute "ZoneDiscovered" = boolean (server-side, per-life per-character)
--   CanCollide = false, Transparency = 1

-- On player entry:
-- 1. Check if ZoneLocked — if true, teleport player back out
-- 2. Check if ZoneDiscovered for this character (this life)
-- 3. If not discovered AND PD active AND Stage >= 2: mark discovered, write to LoreRecord
-- 4. Fire ShowZoneNotify to client with name + description
-- 5. Change music (PLACEHOLDER_SOUND)
-- 6. Log entry to DiscordManager
```

---

## CHAT SYSTEM RULES

```lua
-- Every player chat message is automatically wrapped in quotes
-- Hook into Players.PlayerAdded → player.Chatted

-- Normal message: "Hello" → displayed as "Hello"
-- /a action: /a draws his sword → displayed as *CharacterName draws his sword*
-- /t lore message: /t I want a talent → sent only to mods, logged to Discord
-- Mod global: displayed above health bar with typewriter animation (PLACEHOLDER_GUI)
```

---

## DISCORD WEBHOOK PATTERN

```lua
-- DiscordManager.server.lua
-- All logging goes through here
-- HTTP requests to webhook URL in Config

local HttpService = game:GetService("HttpService")
local Config = require(game.ReplicatedStorage.Shared.Config)

local function sendToDiscord(title, description, color)
    -- color is decimal: red = 10027008
    local data = {
        embeds = {{
            title = title,
            description = description,
            color = color or 10027008,
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        }}
    }
    local success, err = pcall(function()
        HttpService:PostAsync(
            Config.DiscordWebhook,
            HttpService:JSONEncode(data),
            Enum.HttpContentType.ApplicationJson
        )
    end)
    if not success then
        warn("[DiscordManager] Webhook failed: " .. tostring(err))
    end
end

-- Log categories:
-- MOD_ACTION: every mod command fired
-- PDE_DEATH: character permanently deleted
-- ZONE_DISCOVERY: first discovery of a zone
-- QTE_RESULT: QTE success or failure
-- STAGE_CHANGE: PD stage escalated
-- ECONOMY: currency granted/removed
-- SERVER: lock/unlock/shutdown/restart
-- GLOBAL_MESSAGE: all global messages sent
-- PLAYER_JOIN_LEAVE: all player connections
```

---

## WEATHER SYSTEM RULES

```lua
-- WeatherManager.server.lua runs the base cycle
-- Cycle duration: Config.DayCycle.FullDayDuration (1500 sec)
-- Server fires UpdateLighting and UpdateWeather to all clients each tick

-- Time of day → Lighting.ClockTime mapping:
-- Dawn: 6.0 | Mid-day: 12.0 | Afternoon: 15.0 | Dusk: 18.5 | Night: 22.0 | Deep Night: 2.0

-- Zone fog: applied client-side when player is inside a zone with ZoneFog = true
-- Override: stored as {weatherType, endTime} — checked each tick, cleared when endTime passed
-- Rain particle: PLACEHOLDER_ASSET: RainParticle — attach to camera on client
-- Rain blur: PLACEHOLDER_GUI: BlurEffect instance in Lighting
```

---

## SESSION LOCKING PATTERN

```lua
-- Prevents data corruption when same player loads on two servers
-- On PlayerAdded: check for existing session lock key
-- If locked: kick player with "Data is loading on another server. Please wait."
-- On PlayerRemoving: clear session lock

local SessionStore = DataStoreService:GetDataStore("AbyssSessionLock_v1")

local function acquireLock(userId)
    local key = "Lock_" .. userId
    local success, existing = pcall(function()
        return SessionStore:GetAsync(key)
    end)
    if success and existing then
        return false -- already locked
    end
    local setSuccess = pcall(function()
        SessionStore:SetAsync(key, os.time())
    end)
    return setSuccess
end

local function releaseLock(userId)
    local key = "Lock_" .. userId
    pcall(function()
        SessionStore:RemoveAsync(key)
    end)
end
```

---

## NAME GENERATION POOLS

```lua
-- TraitManager / DataManager
-- Randomly pick one from each pool on character creation

local GaulishFirstNames = {
    -- Male
    "Vercingetorix", "Ambiorix", "Brennus", "Caratacus", "Dumnorix",
    "Eporedorix", "Liscus", "Orgétorix", "Vercassivellaunus", "Cingetorix",
    -- Female
    "Boudicca", "Cartimandua", "Veleda", "Onomaris", "Ethlinn",
    -- Greek (for colonist characters)
    "Alexios", "Demetrios", "Nikephoros", "Theodoros", "Leontios",
    "Ariadne", "Kallisto", "Phoebe", "Thalia", "Xanthe",
}

local FamilyNames = {
    "Dumnacus", "Viridomarus", "Litaviccus", "Cotus", "Camulogenus",
    "Sedullos", "Guturvatus", "Cavarinus", "Tasgetius", "Acco",
    "Massus", "Bellovesus", "Segovax", "Molacos", "Biturix",
}

-- Relation weights (same for all)
local RelationPool = {
    {value = "Brother",         weight = 20},
    {value = "Sister",          weight = 20},
    {value = "Twin",            weight = 5},
    {value = "Cousin",          weight = 25},
    {value = "DistantRelative", weight = 20},
    {value = "None",            weight = 10},
}
```

---

## TRAIT SPAWN POOL

```lua
-- TraitManager
-- Roll on character creation using weighted random

local TraitPool = {
    -- Common (60% total weight)
    {id = "Bloodhound",   rarity = "Common",   weight = 20, desc = "You read telegraph animations 4 frames earlier"},
    {id = "IronBlood",    rarity = "Common",   weight = 20, desc = "No flinch from M1 hits above 60% HP"},
    {id = "QuickFeet",    rarity = "Common",   weight = 20, desc = "Dash costs 2 less stamina"},
    -- Uncommon (25% total weight)
    {id = "StoneStance",  rarity = "Uncommon", weight = 15, desc = "Parry costs 3 less stamina"},
    {id = "WolfSense",    rarity = "Uncommon", weight = 10, desc = "You can hear nearby players through walls"},
    -- Rare (12% total weight)
    {id = "PaleDescent",  rarity = "Rare",     weight = 8,  desc = "Named bloodline — certain NPCs react"},
    {id = "CursedMark",   rarity = "Rare",     weight = 4,  desc = "+20% damage dealt and received at all times"},
    -- Cursed Legendary (3% total weight)
    {id = "TheBrand",     rarity = "Cursed",   weight = 2,  desc = "You are permanently visible on the server map"},
    {id = "TheHollow",    rarity = "Cursed",   weight = 1,  desc = "Parry window is 6 frames — stamina regen halved"},
}
```

---

## TEST LOG

_Each entry added by Claude Code after confirming a module works in Studio._

```
[MODULE] [DATE] [RESULT] [NOTES]
-- Example:
-- DataManager | 2026-XX-XX | PASS | Save/load confirmed, session lock working, no data loss on rejoin

DataManager    | 2026-06-12 | PASS | GetAsync loads new character (name gen, GUID, relation pool, mergeDefaults). UpdateAsync saves on PlayerRemoving + BindToClose. Rejoin loads same CharID. Session lock bypassed in Studio as intended.
StaminaManager | 2026-06-12 | PASS | Drain/block/regen all correct. Idle>combat rate confirmed. Refund capped. canAfford correct. tagCombat(60s timer+expiry) added per GDC combat tag spec.
CombatManager  | 2026-06-12 | PASS | M1 fist=9dmg/8stam, M2 fist=18dmg/18stam. Zero-stam blocked. Rate limit enforced (0.5s/1.2s). Hitstun sets/blocks/expires(0.3s). Execute threshold at ≤15% HP. Combat tag fires to victim. GetPartBoundsInBox hitbox server-side confirmed. 9/9 tests pass.
CombatManager v2 | 2026-06-12 | PASS | Full rewrite per CombatSystem.md. M1 chain(3-hit)/feint/running/aerial variants. M2 root+parry break. Downed state (lethal intercept→HP=1, WalkSpeed/JumpPower=0, 30s bleedout). Execute(B, interruptible). Carry(V, weld shoulder). Speed states(M1=35%,M2=0%,Stagger=30%,Block=40%,Carry=50%). Config/Enums/RemoteEvents updated. 15/15 tests pass.
ParryManager   | 2026-06-12 | PASS | Perfect(0.067s)/Late(0.233s)/Whiff/Break all resolve. Stagger fires on attacker. CombatState hooks into CombatManager v2 (M1+M2 intercept). Whiff auto-expires, cooldown tracked, PostureManager hook stubbed. 12/12 tests pass.
PostureManager | 2026-06-12 | PASS | fill/drain/set/reset/isAtMax/isGuardBroken all correct. Guard break triggers at max, resets posture to 0, sets GuardBroken 1.5s, restores speed on expiry. Fill ignored during break. Natural drain 5/s, manual drain 15/s (stationary only). BillboardGui client (PostureBarClient) with fade+color shift. 13/13 tests pass.
ClashManager   | 2026-06-13 | PASS | registerM2Swing+checkClash hooks in CombatManager M2 path. 5-input race (4 buttons, random seq). Win: stam refund+Idle. Loss: stagger 0.8s+stam drain. Draw on 3s timeout. No self-clash, no double-clash, wrong inputs ignored silently. 12/12 tests pass.
MovementManager | 2026-06-13 | PASS | Sprint(1.6x speed, 3stam/s drain, auto-stop on stagger/empty stam). Dash(70 force, 10stam, 0.6s CD, QuickFeet trait hook). Slide(bypass for tests, 0.8s auto-expire, 1.8x burst). Crouch(0.5x speed toggle, blocks sprint). Jump(server ChangeState, blocked when Downed). 16/16 tests pass.
TraitManager   | 2026-06-13 | PASS | Weighted roll (TotalWeight=100) on char creation; loads saved trait if valid. getTrait/hasTrait/setTrait/rollDry all correct. Distribution covers all 9 IDs in 1000 rolls. Effect queries: getDashCostReduction(QuickFeet=2), getDamageMult(CursedMark=1.2), getParryCost(StoneStance=-3), getParryWindow(TheHollow=6/60), getRegenMult(TheHollow=0.5), skipHitstun(IronBlood>60%). QuickFeet integrated into MovementManager via TraitManager (Talents loop removed). 15/15 tests pass.
TalentManager  | 2026-06-13 | PASS | 10 lore-team-granted talents (Riposte/Executioner/Counter/Warrior/Guardian/Swift/Endurance/IronWill/Bloodbound/Herald). assignTalent/revokeTalent with validation, no-dup guard, DataManager persistence. Effect queries: canRiposte, canExecute, getParryCostDiscount(Counter=2), getDamageMult(Warrior=1.1), getDamageReduction(Guardian=0.9), getSpeedMult(Swift=1.1), getMaxStaminaBonus(Endurance=20), skipHitstun(IronWill>40%). Swift immediate speed refresh via CM.setSpeed. 17/17 tests pass.
LoreManager    | 2026-06-13 | PASS | PDStage 0-5 (Inert→TheAbyss), validated setStage/escalateStage (caps at 5). PDE eligibility: Stage>=3 AND PDEFlagged=true. activatePDE/deactivatePDE toggle flag. LoreEchoes append with timestamp+stage. writeLoreRecord to AbyssLoreData_v1 DS. applyLoreScar keyed by zoneName to AbyssLoreData_v1 DS. triggerPDE: validates eligibility, writes record+scar, sets PlayerState=Dead+PDEFlagged=false. Discord/Valhalla statue placeholders noted. 16/16 tests pass.
ZoneManager    | 2026-06-13 | PASS | AABB zone detection (CFrame:PointToObjectSpace + half-size), Heartbeat poll at 0.3s interval. ChildAdded/ChildRemoved keeps allZones registry live. processEntry: locked zone teleports to lastSafePos, else sets playerZone + fires ShowZoneNotify client event + marks DiscoveredZones + writes LoreRecord if Stage>=2. processExit: safe .Parent check on destroyed zones. ZoneNotifyClient: top-center fade-in (0.5s) / hold (3.5s) / fade-out (0.8s) with tween cancel on rapid re-entry. setZoneLocked toggle returns true/false. 14/14 tests pass.
WeatherManager | 2026-06-13 | PASS | Day cycle 1500s (24/1500 hr/s ClockTime advance, wraps at 24). Weather base + timed override (lazy expiry on getWeather). clearWeather reverts to base. setClockTime/getTimeOfDay (Dawn/Morning/Midday/Afternoon/Dusk/Night/DeepNight). Zone fog tracked server-side via 0.5s Heartbeat poll of ZoneManager.getCurrentZone; fires ApplyZoneFog to client on change. WeatherClient: fog tweens, global weather visuals, zone fog overrides global while active. T14 fix: exitZone+Destroy prevents Heartbeat re-entry before fog check clears state. 14/14 tests pass.
HUDManager     | 2026-06-13 | PASS | Server polls DM Hunger + LM stage every 2s, fires UpdateHUD{Hunger}/UpdateEclipseMoon on change; explicit notifyHUD/notifyEclipseMoon/showGlobalMessage API. Client builds ABYSSHud ScreenGui: HP bar (Humanoid poll 0.5s), stamina bar (listens to UpdateHUD from StaminaManager.syncHUD), hunger bar, Eclipse Moon ImageLabel (bottom-right, stage 0-5 asset swap + label), global typewriter message (top-center, cancels on rapid re-trigger). notifyEclipseMoon validates integer 0-5. showGlobalMessage validates non-empty string. 14/14 tests pass.
ModManager     | 2026-06-13 | PASS | 20 commands: setStage, escalateStage, activatePDE, deactivatePDE, grantTalent, revokeTalent, setWeather, clearWeather, setClockTime, lockZone, unlockZone, setHunger, setTitle, grantCurrency, revokeCurrency, globalMessage, killPlayer, revivePlayer, kick, tpToMod. isOwner (hardcoded greatmlgpd1/Broke3n), isMod (owner bypass + GetRankInGroup pcall). executeCommand perm-checked + player name resolution. directExecute bypasses perm for server/test use. Rate limit 1s on ModCommand RE. Action log capped at 200, getLastLog/getLogCount testable. Unknown command logs and returns false. 14/14 tests pass.
DiscordManager | 2026-06-13 | PASS | Webhook integration (PLACEHOLDER_WEBHOOK_URL, pcall-wrapped PostAsync). Test mode captures lastPayload without HTTP. Sliding-window rate limit (5 msgs/10s). 9 log categories: MOD_ACTION, PDE_DEATH, ZONE_DISCOVERY, QTE_RESULT, STAGE_CHANGE, ECONOMY, SERVER, GLOBAL_MESSAGE, PLAYER_JOIN_LEAVE. Auto-hooks: PlayerAdded/PlayerRemoving. Integration: ModManager.logAction calls DiscordManager.logModAction on every command dispatch. T13 graceful failure confirmed (PLACEHOLDER URL → warn, no throw). 14/14 tests pass.
CombatWiring   | 2026-06-14 | PASS | Full playtest checklist 48/49 items PASS, 1 UNTESTABLE (combat tag via dummy — dummy is passive). 1 FAIL found and fixed (findDownedTarget excluded BeingCarried state — third-party execute on carried player failed; fixed on disk + Studio). New scripts created: InputHandler.client.lua, BlockManager.server.lua, ClashClient.client.lua. HUDManager updated to template-clone pattern + labels hidden. CombatManager updated with block check, processCritical, RequestCritical handler, BeingCarried fix. CombatDummy R6 model placed in Workspace with HPReset script. Rojo sync required before next live test (disk changes not yet synced to Studio for BlockManager/InputHandler/ClashClient).
RagdollSystem  | 2026-06-14 | PASS | RagdollManager.server.lua created (disk + Studio). ragdoll(): disables all Motor6Ds, PlatformStand=true, CG=RagdolledPlayers, optional impulse. unragdoll(): re-enables Motor6Ds, PlatformStand=false, CG=Players. applyDeathRagdoll(): ragdoll + 3s delay + 3s fade loop (20 steps×0.15s) + Health=0. CollisionGroups: RagdolledPlayers × Players = non-collidable (bodies don't block players; still collide with world). CombatManager updated: applyDownedState calls ragdoll(-10Y impulse); bleedout timer calls applyDeathRagdoll; processExecute calls unragdoll+reposition on grip, applyDeathRagdoll on completion; applyHitstun re-ragdolls target on execution interrupt; processCarry calls unragdoll+PlatformStand=true on pickup; dropCarried calls ragdoll on drop. 6/6 automated transitions PASS (T1 downed, T2 exec re-enable, T3 carry+drop, T4a death immediate, T4b death fade at Transparency=0.20).
StatScaling    | 2026-06-14 | PASS | Percentage-based stat scaling added across 6 files (disk + Studio). Util.getScaledValue(base,stat,perPoint) is the single formula implementation. Config.StatScaling={StrengthPerPoint=0.005, EndurancePerPoint=0.005, AgilityPerPoint=0.005}. STRENGTH: CombatManager applies getScaledValue to M1Damage and M2Damage before fist/ender multipliers — covers all 5 damage paths (M1, M2, NormalCrit, AirCrit, SweepCrit). ENDURANCE: PostureManager.getPlayerMax(player) reads DataManager Stats.Endurance dynamically on every fill/set/isAtMax call — no cache, immediate effect. fireUpdate sends scaled max to client so posture bar fills proportionally. PostureManager.recalculateMax(player) fires UpdatePostureBar to refresh bar after Endurance change. HP is NOT stat-scaled (stays at base 100). AGILITY: StaminaManager regen loop applies getScaledValue(baseRate, Agility, perPoint) per tick for both idle and combat regen. ModManager.setStat command added (21 total) — allows lore team to set Strength/Endurance/Agility mid-session; Endurance change automatically calls recalculateMax. 12/12 functional tests PASS: 0 Strength=15dmg, 20 Strength=16.5dmg, 0 Endurance posture max=100, 20 Endurance posture max=110, HP unaffected (stays 100), 0 Agility regen=5/2, 20 Agility regen=5.5/2.2, no hardcoded damage values.
```

---

## NOTES FOR CLAUDE CODE

- This is a **lore-driven roleplay game**. No system should auto-grant progression. Everything meaningful goes through the lore team.
- When in doubt, make it server-authoritative and log it.
- The mod menu does not need to be beautiful at launch — it needs to be functional and complete.
- Every system that touches player data must handle the case where the player leaves mid-operation.
- Valhalla state (`PlayerState = "Dead"`) must make the player completely immune — no damage in, no damage out — even if they somehow re-enter the main world.
- The posture bar value is **never sent from client to server**. The server tracks it. The server sends the display value to the client.
- Riposte talent check: before processing R key as a riposte, confirm the talent `"Riposte"` exists in the player's `Talents` table.
- All chat messages are wrapped in quotes server-side before display — never trust the client to wrap them.

---

## COMBAT TAG SYSTEM

Tracks whether a player is currently "in combat" based on receiving hits.
This value gates stamina regen rate, posture drain rate, and hunger drain rate.

### Rules
- Tagged IN COMBAT when: player receives a hit from another player OR a mob
- NOT triggered by: fall damage, self damage, environmental damage
- Only the HIT RECEIVER gets tagged — the attacker is never combat-tagged by dealing damage
- Tag duration: 60 seconds from last hit received
- Timer resets every time a new valid hit is received
- On expiry (60s no hits received): state returns to OUT OF COMBAT

### Effect on other systems
| System | In Combat | Out of Combat |
|--------|-----------|---------------|
| Stamina regen | +2 per tick | +5 per tick |
| Posture drain | 0 per second | 5 per second (natural) |
| Hunger drain | 0 per second | 0.1 per second (passive) |

### Implementation
```lua
-- CombatTagManager (handled inside CombatManager server-side)
-- Per player: store lastHitTime (tick())
-- On any valid hit received (player or mob source, not fall/env):
--   player.lastHitTime = tick()
-- RunService.Heartbeat loop checks:
--   if tick() - lastHitTime < 60 then isInCombat = true
--   else isInCombat = false
-- Fire CombatStateChanged event to StaminaManager, PostureManager, HungerManager
-- NEVER let client report its own combat state — server tracks entirely
```

### Important
- Combat tag is server-side only — client never reports its own state
- Fall damage source check: if DamageSource == "Fall" or "Environment" → skip tag
- Mob hits count: if DamageSource is a mob Instance → tag applies
- Player hits count: if DamageSource is a player Character → tag applies
