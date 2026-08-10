-- TalentManager — Module 9
-- Extended for the "ABYSS Full Talents Integration" design doc: the 8 legacy-only talents
-- (Executioner/Counter/Warrior/Guardian/Swift/Endurance/IronWill/Bloodbound) and the 7 talents
-- Talent_TestHarness/ATTRIBUTE_MIRRORED already fully own (AwakenedEyes/ReinforcedMind/
-- BlindSight/BloodInsight/ColdBlood/IronNerve/Stoicism) keep their exact original hardcoded
-- behavior below, untouched, so Talent_TestHarness's T1-T17 keep passing unmodified. Every
-- other compendium talent (111 of them, including a genuinely-new mechanical ReinforcedMuscles
-- effect layered on top of its existing attribute-mirror) is driven generically by
-- ReplicatedStorage.Shared.TalentEffects -- see that module's header comment for the full
-- design.
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")

local TalentEffects = require(RepStorage:WaitForChild("Shared"):WaitForChild("TalentEffects"))

local function getOrCreate(name, isFunc)
    local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
        local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
    end)()
    local r=folder:FindFirstChild(name); if r then return r end
    r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end
local RE_TalentGranted   = getOrCreate("TalentGranted")   -- server -> client: {id, type, description}
local RE_LiveFeedUpdate  = getOrCreate("LiveFeedUpdate")

-- Fallback description table for the 8 legacy talents that predate the compendium and have
-- no TalentEffects entry (their behavior is intentionally left untouched below).
local LEGACY_INFO = {
    Executioner = { type = "Combat", description = "Enables the execute action on downed enemies." },
    Counter     = { type = "Combat", description = "Parries cost 2 less stamina." },
    Warrior     = { type = "Passive", description = "+10% damage dealt." },
    Guardian    = { type = "Passive", description = "-10% damage taken." },
    Swift       = { type = "Passive", description = "+10% movement speed while idle." },
    Endurance   = { type = "Passive", description = "+20 max stamina." },
    IronWill    = { type = "Passive", description = "Skip hitstun above 40% HP." },
    Bloodbound  = { type = "Roleplay", description = "A bond sealed in blood." },
}

local VALID_TALENTS = {
    "Riposte","Executioner","Counter","Warrior","Guardian",
    "Swift","Endurance","IronWill","Bloodbound","Herald",
    "AwakenedEyes","ReinforcedMind","ReinforcedMuscles",
    "BlindSight",   -- reveals red silhouettes of nearby entities to Full Blind characters
    "BloodInsight", -- reveals the character's own DNA (Clan/Purity) in their journal; also may reveal Sanity (lore team decision)
    "ColdBlood",    -- prevents the Anxiety feeling on witness/kill
    "IronNerve",    -- prevents the Fear feeling
    "Stoicism",     -- prevents ALL feeling triggers
}
-- Union in every compendium talent from TalentEffects that isn't already listed above.
do
    local existing = {}
    for _, id in ipairs(VALID_TALENTS) do existing[id] = true end
    for id in pairs(TalentEffects) do
        if not existing[id] then table.insert(VALID_TALENTS, id); existing[id] = true end
    end
end

-- Talents mirrored onto the character as a "Talent_<id>" boolean Attribute (same replication
-- pattern as CombatManager's CombatState / MovementManager's CrouchActive) so client scripts
-- (SpiritClient's visibility gate, meditation/pushups perks) can read them without a remote
-- round-trip. Only talents an actual client script needs to check locally are listed here.
local ATTRIBUTE_MIRRORED = { AwakenedEyes = true, ReinforcedMind = true, ReinforcedMuscles = true, BlindSight = true }

local VALID_SET = {}
for _, v in ipairs(VALID_TALENTS) do VALID_SET[v] = true end

local playerTalents = {}

local function getSet(player)
    return playerTalents[player.UserId] or {}
end

local function persistTalents(player)
    local set = playerTalents[player.UserId] or {}
    local list = {}
    for id in pairs(set) do table.insert(list, id) end
    local dm = _G.DataManager
    if dm then dm.setValue(player, "Talents", list) end
end

local function applyEffect(player, talentId, isGrant)
    if talentId == "Swift" then
        -- Swift is a MULTIPLIER now, not a speed state. As a setter at 1.1 it occupied the
        -- one shared slot, so the next crouch/guard/swing destroyed it permanently -- and it
        -- was gated on being Idle purely to dodge that collision. As a scalar it simply
        -- scales whatever you are doing, which is what getSpeedMult was always written for.
        local mf = _G.MovementFlow
        if mf and mf.refreshScalars then mf.refreshScalars(player) end
    end
    if ATTRIBUTE_MIRRORED[talentId] then
        local char = player.Character
        if char then char:SetAttribute("Talent_"..talentId, isGrant) end
    end
    -- Generic compendium dispatch (additive to whatever legacy handling ran above -- see the
    -- header comment on why ReinforcedMuscles safely gets both).
    local effect = TalentEffects[talentId]
    if effect then
        local fn = isGrant and effect.onApply or effect.onRemove
        if fn then
            local ok, err = pcall(fn, player)
            if not ok then warn("[TalentManager] "..talentId.." "..(isGrant and "onApply" or "onRemove").." errored: "..tostring(err)) end
        end
    end
    print(string.format("[TalentManager] %s %s: %s",
        player.Name, isGrant and "GRANT" or "REVOKE", talentId))
end

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
            RE_LiveFeedUpdate:FireClient(p, { type = "TALENT", h = now.hour, m = now.min, zone = "?", charName = charName, message = message })
        end
    end
end

-- Player-facing notification (design doc PART SIX) -- fired only on a real fresh grant, never
-- during the CharacterAdded/loadPlayer reapplication pass (that would re-show the popup every
-- single respawn, which is not what "a talent awakens" is supposed to mean).
local function notifyGrant(player, talentId)
    local info = TalentEffects[talentId] or LEGACY_INFO[talentId] or { type = "Talent", description = "" }
    RE_TalentGranted:FireClient(player, { id = talentId, type = info.type, description = info.description })
end

-- Re-stamps all ATTRIBUTE_MIRRORED talents onto a fresh character -- attributes live on the
-- Character instance, which is destroyed and replaced on every respawn, so a talent granted
-- in a prior life would otherwise silently stop being readable client-side after death.
local function mirrorTalentAttributes(player, char)
    local set = playerTalents[player.UserId]; if not set then return end
    for talentId in pairs(ATTRIBUTE_MIRRORED) do
        char:SetAttribute("Talent_"..talentId, set[talentId] == true)
    end
end

local TalentManager = {}

function TalentManager.hasTalent(player, talentId)
    return getSet(player)[talentId] == true
end

function TalentManager.getTalents(player)
    local result = {}
    for id in pairs(getSet(player)) do table.insert(result, id) end
    return result
end

function TalentManager.assignTalent(player, talentId)
    assert(VALID_SET[talentId], "Unknown talentId: " .. tostring(talentId))
    if not playerTalents[player.UserId] then
        playerTalents[player.UserId] = {}
    end
    if playerTalents[player.UserId][talentId] then return false end
    playerTalents[player.UserId][talentId] = true
    persistTalents(player)
    applyEffect(player, talentId, true)
    notifyGrant(player, talentId)
    fireLiveFeed(getCharName(player), "was granted the talent: " .. talentId)
    return true
end

function TalentManager.revokeTalent(player, talentId)
    assert(VALID_SET[talentId], "Unknown talentId: " .. tostring(talentId))
    local set = playerTalents[player.UserId]
    if not set or not set[talentId] then return false end
    set[talentId] = nil
    persistTalents(player)
    applyEffect(player, talentId, false)
    fireLiveFeed(getCharName(player), "had the talent revoked: " .. talentId)
    return true
end

function TalentManager.canRiposte(player)
    return TalentManager.hasTalent(player, "Riposte")
end

function TalentManager.canExecute(player)
    return TalentManager.hasTalent(player, "Executioner")
end

function TalentManager.getParryCostDiscount(player)
    return TalentManager.hasTalent(player, "Counter") and 2 or 0
end

function TalentManager.getDamageMult(player)
    return TalentManager.hasTalent(player, "Warrior") and 1.1 or 1.0
end

function TalentManager.getDamageReduction(player)
    return TalentManager.hasTalent(player, "Guardian") and 0.9 or 1.0
end

function TalentManager.getSpeedMult(player)
    return TalentManager.hasTalent(player, "Swift") and 1.1 or 1.0
end

function TalentManager.getMaxStaminaBonus(player)
    return TalentManager.hasTalent(player, "Endurance") and 20 or 0
end

-- ================================================================================
-- COMPENDIUM MODIFIER AGGREGATION (design doc "StatModifiers") -- keys ending in "Add" sum
-- (additive, default 0); every other key multiplies (default 1.0). This one naming
-- convention lets a single function serve both semantics correctly -- see TalentEffects'
-- own key names (MaxStaminaAdd, ExecuteRangeAdd, etc. vs AllDamageDealt, SprintStaminaDrain).
-- Style talents use `getModifier(player)` (a function, re-evaluated every call so a
-- FightingStyle change takes effect immediately) instead of a static `passiveModifier` table;
-- both shapes are supported transparently here.
-- ================================================================================

function TalentManager.getModifier(player, key)
    local additive = key:sub(-3) == "Add"
    local total = additive and 0 or 1.0
    for talentId in pairs(getSet(player)) do
        local effect = TalentEffects[talentId]
        if effect then
            local mod
            if effect.getModifier then
                local ok, result = pcall(effect.getModifier, player)
                if ok and type(result) == "table" then mod = result end
            elseif effect.passiveModifier then
                mod = effect.passiveModifier
            end
            if mod and mod[key] ~= nil then
                if additive then total += mod[key] else total *= mod[key] end
            end
        end
    end
    return total
end

function TalentManager.getDamageMultiplier(player)
    return TalentManager.getModifier(player, "AllDamageDealt")
end

function TalentManager.getDamageTakenMultiplier(player)
    return TalentManager.getModifier(player, "AllDamageTaken")
end

-- Generic hook dispatch for any TalentEffects entry's named lifecycle function (onDamageTake,
-- onLowHPState, onZoneEnter, etc.) that isn't a passiveModifier/getModifier. Returns an array
-- of {talentId, result} for every granted talent that defines that hook -- callers decide how
-- to interpret/combine results, since the shapes vary per hook (see TalentEffects' own
-- comments for which systems are expected to eventually call which hooks).
function TalentManager.fireHook(player, hookName, ...)
    local results = {}
    for talentId in pairs(getSet(player)) do
        local effect = TalentEffects[talentId]
        local fn = effect and effect[hookName]
        if type(fn) == "function" then
            local ok, result = pcall(fn, player, ...)
            if ok then table.insert(results, { talentId = talentId, result = result }) end
        end
    end
    return results
end

function TalentManager.getTalentInfo(talentId)
    local effect = TalentEffects[talentId]
    if effect then return { type = effect.type, description = effect.description or "" } end
    local legacy = LEGACY_INFO[talentId]
    if legacy then return legacy end
    return { type = "Talent", description = "" }
end

function TalentManager.getAllTalentIds()
    local ids = {}
    for id in pairs(VALID_SET) do table.insert(ids, id) end
    table.sort(ids)
    return ids
end

function TalentManager.skipHitstun(player, hpFraction)
    if not TalentManager.hasTalent(player, "IronWill") then return false end
    return hpFraction > 0.40
end

_G.TalentManager = TalentManager

local function loadPlayer(p)
    p.CharacterAdded:Connect(function(char)
        mirrorTalentAttributes(p, char)
        -- onSpawn hooks (design doc: "Re-apply all active talent effects on spawn") -- separate
        -- from onApply, which only fires on a genuine new grant/revoke, not every respawn.
        for talentId in pairs(playerTalents[p.UserId] or {}) do
            local effect = TalentEffects[talentId]
            if effect and effect.onSpawn then
                local ok, err = pcall(effect.onSpawn, p)
                if not ok then warn("[TalentManager] "..talentId.." onSpawn errored: "..tostring(err)) end
            end
        end
    end)
    task.wait(1)
    playerTalents[p.UserId] = {}
    local dm = _G.DataManager
    local saved = dm and dm.getValue(p, "Talents") or {}
    for _, id in ipairs(saved) do
        if VALID_SET[id] then
            playerTalents[p.UserId][id] = true
        end
    end
    local count = 0
    for _ in pairs(playerTalents[p.UserId]) do count += 1 end
    print(string.format("[TalentManager] %s loaded %d talent(s)", p.Name, count))
    for id in pairs(playerTalents[p.UserId]) do
        applyEffect(p, id, true)
    end
    if p.Character then mirrorTalentAttributes(p, p.Character) end
end

Players.PlayerAdded:Connect(loadPlayer)

Players.PlayerRemoving:Connect(function(player)
    playerTalents[player.UserId] = nil
end)

for _, p in ipairs(Players:GetPlayers()) do
    task.spawn(function() loadPlayer(p) end)
end

print(string.format("[TalentManager] Init — %d talents defined", #VALID_TALENTS))
