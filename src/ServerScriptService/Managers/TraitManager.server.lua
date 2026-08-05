-- TraitManager — Module 8
-- Weighted trait roll on character creation; exposes per-trait effect queries

local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")

-- ── Trait pool (from CLAUDE.md) ───────────────────────────────────────────────
local TraitPool = {
    {id = "Bloodhound",  rarity = "Common",   weight = 20, desc = "You read telegraph animations 4 frames earlier"},
    {id = "IronBlood",   rarity = "Common",   weight = 20, desc = "No flinch from M1 hits above 60% HP"},
    {id = "QuickFeet",   rarity = "Common",   weight = 20, desc = "Dash costs 2 less stamina"},
    {id = "StoneStance", rarity = "Uncommon", weight = 15, desc = "Parry costs 3 less stamina"},
    {id = "WolfSense",   rarity = "Uncommon", weight = 10, desc = "You can hear nearby players through walls"},
    {id = "PaleDescent", rarity = "Rare",     weight = 8,  desc = "Named bloodline — certain NPCs react"},
    {id = "CursedMark",  rarity = "Rare",     weight = 4,  desc = "+20% damage dealt and received at all times"},
    {id = "TheBrand",    rarity = "Cursed",   weight = 2,  desc = "You are permanently visible on the server map"},
    {id = "TheHollow",   rarity = "Cursed",   weight = 1,  desc = "Parry window is 6 frames — stamina regen halved"},
}

local TOTAL_WEIGHT = 0
for _, t in ipairs(TraitPool) do TOTAL_WEIGHT += t.weight end

local VALID_IDS = {}
for _, t in ipairs(TraitPool) do VALID_IDS[t.id] = true end

-- ── Config constants used by effect queries ───────────────────────────────────
local BASE_PARRY_COST      = 12
local STONE_STANCE_REDUCTION = 3
local HOLLOW_WINDOW_FRAMES = 6
local HOLLOW_REGEN_MULT    = 0.5
local CURSED_DAMAGE_MULT   = 1.2
local IRON_BLOOD_HP_THRESH = 0.60

-- ── Per-player state ──────────────────────────────────────────────────────────
local activeTrait = {}

-- ── Weighted random ───────────────────────────────────────────────────────────
local function weightedRoll()
    local roll = math.random(1, TOTAL_WEIGHT)
    local cumulative = 0
    for _, entry in ipairs(TraitPool) do
        cumulative += entry.weight
        if roll <= cumulative then return entry end
    end
    return TraitPool[#TraitPool]
end

-- ── Effect application ────────────────────────────────────────────────────────
local function applyEffects(player)
    local id = activeTrait[player.UserId]
    if not id then return end
    -- WolfSense: PLACEHOLDER — client audio system hooks in future
    -- TheBrand: PLACEHOLDER — map visibility system hooks in future
    -- PaleDescent: PLACEHOLDER — NPC reaction system hooks in future
    print(string.format("[TraitManager] %s active trait: %s", player.Name, id))
end

-- ── Public API ────────────────────────────────────────────────────────────────
local TraitManager = {}

function TraitManager.getTrait(player)
    return activeTrait[player.UserId]
end

function TraitManager.hasTrait(player, traitId)
    return activeTrait[player.UserId] == traitId
end

function TraitManager.setTrait(player, traitId)
    assert(VALID_IDS[traitId], "Unknown traitId: " .. tostring(traitId))
    activeTrait[player.UserId] = traitId
    local dm = _G.DataManager
    if dm then dm.setValue(player, "Trait", traitId) end
    applyEffects(player)
end

function TraitManager.reroll(player)
    local rolled = weightedRoll()
    activeTrait[player.UserId] = rolled.id
    local dm = _G.DataManager
    if dm then dm.setValue(player, "Trait", rolled.id) end
    applyEffects(player)
    return rolled
end

function TraitManager.rollDry()
    return weightedRoll()
end

-- Effect queries
function TraitManager.getDamageMult(player, role)
    if activeTrait[player.UserId] ~= "CursedMark" then return 1.0 end
    return CURSED_DAMAGE_MULT
end

function TraitManager.getParryCost(player, baseCost)
    local base = baseCost or BASE_PARRY_COST
    if activeTrait[player.UserId] == "StoneStance" then
        return math.max(0, base - STONE_STANCE_REDUCTION)
    end
    return base
end

function TraitManager.getParryWindow(player, defaultWindow)
    if activeTrait[player.UserId] == "TheHollow" then
        return HOLLOW_WINDOW_FRAMES / 60
    end
    return defaultWindow
end

function TraitManager.getRegenMult(player)
    if activeTrait[player.UserId] == "TheHollow" then
        return HOLLOW_REGEN_MULT
    end
    return 1.0
end

function TraitManager.skipHitstun(player, hpFraction)
    if activeTrait[player.UserId] ~= "IronBlood" then return false end
    return hpFraction > IRON_BLOOD_HP_THRESH
end

function TraitManager.getDashCostReduction(player)
    if activeTrait[player.UserId] == "QuickFeet" then return 2 end
    return 0
end

_G.TraitManager = TraitManager

-- ── Player lifecycle ──────────────────────────────────────────────────────────
Players.PlayerAdded:Connect(function(player)
    task.wait(1)
    local dm = _G.DataManager
    local existing = dm and dm.getValue(player, "Trait")
    if existing and VALID_IDS[existing] then
        activeTrait[player.UserId] = existing
        print(string.format("[TraitManager] %s loaded saved trait: %s", player.Name, existing))
    else
        local rolled = weightedRoll()
        activeTrait[player.UserId] = rolled.id
        if dm then dm.setValue(player, "Trait", rolled.id) end
        print(string.format("[TraitManager] %s rolled new trait: %s (%s)", player.Name, rolled.id, rolled.rarity))
    end
    applyEffects(player)
end)

Players.PlayerRemoving:Connect(function(player)
    activeTrait[player.UserId] = nil
end)

for _, p in ipairs(Players:GetPlayers()) do
    task.spawn(function()
        task.wait(1)
        local dm = _G.DataManager
        local existing = dm and dm.getValue(p, "Trait")
        if existing and VALID_IDS[existing] then
            activeTrait[p.UserId] = existing
        else
            local rolled = weightedRoll()
            activeTrait[p.UserId] = rolled.id
            if dm then dm.setValue(p, "Trait", rolled.id) end
            print(string.format("[TraitManager] %s rolled trait: %s (%s)", p.Name, rolled.id, rolled.rarity))
        end
        applyEffects(p)
    end)
end

print(string.format("[TraitManager] Init — %d traits | TotalWeight=%d", #TraitPool, TOTAL_WEIGHT))
