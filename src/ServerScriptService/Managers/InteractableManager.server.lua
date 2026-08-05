-- InteractableManager — Part Six
local Players           = game:GetService("Players")
local RepStorage        = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))

local function getOrCreate(name, isFunc)
    local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
        local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
    end)()
    local r=folder:FindFirstChild(name); if r then return r end
    r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_ShowNotification = getOrCreate("ShowNotification")
local RE_LiveFeedUpdate   = getOrCreate("LiveFeedUpdate")
local RE_ShowChestUI      = getOrCreate("ShowChestUI")
local RE_TakeChestItem    = getOrCreate("RequestTakeChestItem")
local RE_ShowWorldJournal = getOrCreate("ShowWorldJournal")
local RE_CustomTriggered  = getOrCreate("CustomInteractTriggered")

local INTERACTABLE_TAG  = "ABYSSInteractable"
local DEFAULT_TIER      = "Tier2"
local DEFAULT_COOLDOWN  = 60
local DEFAULT_CHEST_RESPAWN = 3600
local DEFAULT_RANGE     = 6

local cooldowns = {} -- ["uid_partId"] = tick() the cooldown clears

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

local function notify(player, title, body)
    RE_ShowNotification:FireClient(player, title, body, 4, "info")
end

local function cooldownKey(player, part) return player.UserId .. "_" .. tostring(part) end

local function isOnCooldown(player, part)
    local until_ = cooldowns[cooldownKey(player, part)]
    return until_ ~= nil and tick() < until_
end

-- InteractCooldown is the design-doc-spec'd attribute name; Cooldown is the name the
-- original QTE-only version of this system already used (and BTools' "Place Interactable"
-- tool still writes) -- checking both keeps every already-placed interactable working.
local function getCooldownSec(part)
    return tonumber(part:GetAttribute("InteractCooldown")) or tonumber(part:GetAttribute("Cooldown")) or DEFAULT_COOLDOWN
end

local function setCooldown(player, part)
    local cd = getCooldownSec(part)
    if cd <= 0 then return end -- design doc: InteractCooldown=0 means no cooldown
    cooldowns[cooldownKey(player, part)] = tick() + cd
end

local function getInteractType(part)
    local t = part:GetAttribute("InteractType")
    return (t and t ~= "") and t or "QTE" -- backward-compatible default: every interactable placed before this session was QTE-only
end

-- RewardValue formats: Item = "itemName" or "itemName:quality"; Currency = "Type:Amount"
-- (e.g. "Obol:15"); LoreNotify/None ignore RewardValue. Reuses ModManager's existing
-- giveItem/grantCurrency commands rather than re-implementing inventory/currency mutation.
local function dispatchReward(player, part)
    local rewardType = part:GetAttribute("RewardType") or "None"
    local rewardValue = part:GetAttribute("RewardValue") or ""
    local mgr = _G.ModManager
    if rewardType == "Item" then
        local itemName, quality = rewardValue:match("^([^:]+):?(.*)$")
        if itemName and itemName ~= "" and mgr then
            mgr.directExecute("giveItem", nil, player, itemName, quality ~= "" and quality or nil)
        end
    elseif rewardType == "Currency" then
        local ct, amount = rewardValue:match("^([%a]+):(%d+)$")
        if ct and amount and mgr then
            mgr.directExecute("grantCurrency", nil, player, ct, tonumber(amount))
        end
    elseif rewardType == "LoreNotify" then
        fireLiveFeed(getCharName(player), "triggered a lore notification at " .. part.Name)
        local disc = _G.DiscordManager
        if disc then disc.logInteractable(player, part.Name, "LoreNotify") end
    end
end

local function handleQTE(player, part)
    local tier = part:GetAttribute("QTETier")
    tier = (tier and tier ~= "") and tier or DEFAULT_TIER

    local charName = getCharName(player)
    fireLiveFeed(charName, "interacted with " .. part.Name)
    local disc = _G.DiscordManager
    if disc then disc.logInteractable(player, part.Name, "attempt") end

    local qte = _G.QTEManager
    if not qte then return end
    qte.startQTE(player, tier, { source = "Interactable", interactableName = part.Name }, function(p, success)
        local d2 = _G.DiscordManager
        if success then
            dispatchReward(p, part)
            fireLiveFeed(getCharName(p), "succeeded at " .. part.Name)
            if d2 then d2.logInteractable(p, part.Name, "SUCCESS reward=" .. tostring(part:GetAttribute("RewardType"))) end
        else
            fireLiveFeed(getCharName(p), "failed " .. part.Name)
            if d2 then d2.logInteractable(p, part.Name, "FAIL") end
        end
    end)
end

-- ── Chest ─────────────────────────────────────────────────────────────────────
-- Per-part rolled contents, kept in memory only (session-scoped, matches every other
-- BTools placement in this codebase). {itemName=,quality=,count=} slots; a slot becomes
-- nil once taken. Respawns (re-rolls) once every slot is empty AND RespawnTime has passed.
local chestContents = {} -- [part] = {slot1, slot2, ...} (up to 6)
local chestEmptiedAt = {} -- [part] = tick() when the last slot was taken
local CHEST_SLOTS = 6

local function rollChestContents(pool)
    local slots = {}
    for i = 1, CHEST_SLOTS do
        local entry = Config.Util.weightedPick(pool)
        slots[i] = { itemName = entry.item, quality = "Material", count = Config.Util.rollRange(entry.count) }
    end
    return slots
end

local function handleChest(player, part)
    local poolName = part:GetAttribute("LootPool")
    local pool = poolName and poolName ~= "" and Config.LootPools[poolName]
    if not pool then notify(player, "Chest", "This chest has nothing in it."); return end

    local respawnAfter = tonumber(part:GetAttribute("RespawnTime")) or DEFAULT_CHEST_RESPAWN
    local emptiedAt = chestEmptiedAt[part]
    local allEmpty = chestContents[part] ~= nil
    if allEmpty then
        for _, s in ipairs(chestContents[part]) do if s then allEmpty = false; break end end
    end
    if not chestContents[part] or (allEmpty and emptiedAt and (tick() - emptiedAt) >= respawnAfter) then
        chestContents[part] = rollChestContents(pool)
        chestEmptiedAt[part] = nil
    end

    RE_ShowChestUI:FireClient(player, { chestName = part.Name, chestPart = part, slots = chestContents[part] })
end

RE_TakeChestItem.OnServerEvent:Connect(function(player, part, slotIndex)
    if typeof(part) ~= "Instance" or not part:IsDescendantOf(workspace) then return end
    if type(slotIndex) ~= "number" then return end
    local char = player.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if not hrp or (hrp.Position - part.Position).Magnitude > (tonumber(part:GetAttribute("InteractRange")) or DEFAULT_RANGE) + 2 then return end
    local slots = chestContents[part]; if not slots then return end
    local slot = slots[slotIndex]; if not slot then return end
    slots[slotIndex] = nil
    local inv = _G.InventoryManager
    if inv then inv.addItem(player, slot.itemName, slot.quality, slot.count) end
    local stillHasLoot = false
    for _, s in ipairs(slots) do if s then stillHasLoot = true; break end end
    if not stillHasLoot then chestEmptiedAt[part] = tick() end
    fireLiveFeed(getCharName(player), "took " .. slot.count .. "x " .. slot.itemName .. " from " .. part.Name)
    local disc = _G.DiscordManager
    if disc then disc.logInteractable(player, part.Name, "took " .. slot.count .. "x " .. slot.itemName) end
    RE_ShowChestUI:FireClient(player, { chestName = part.Name, chestPart = part, slots = slots })
end)

-- ── Journal (world book/notice board) ────────────────────────────────────────
local function handleJournal(player, part)
    local content = part:GetAttribute("JournalContent")
    if content and content ~= "" then
        RE_ShowWorldJournal:FireClient(player, { title = part.Name, text = content })
    else
        -- No character Journal UI exists anywhere in this codebase yet (confirmed while
        -- building the Sanity/Ally system's journal data hooks) -- graceful fallback
        -- instead of silently doing nothing.
        notify(player, part.Name, "There is nothing written here.")
    end
    fireLiveFeed(getCharName(player), "read " .. part.Name)
end

-- ── Ritual ────────────────────────────────────────────────────────────────────
-- The real ritual-placement flow already exists (RitualClient's T key + RitualManager) and
-- requires a physical Ritual Stone item -- this type is a signpost pointing at that existing
-- flow, not a second parallel ritual system.
local function handleRitual(player, part)
    notify(player, part.Name, "A place of power. Bring a Ritual Stone and press T nearby to begin a ritual.")
end

-- ── Custom ────────────────────────────────────────────────────────────────────
-- Lore-team-defined unique interactions: other managers register a handler by the
-- interactable's exact Name; unregistered names just log + notify the client so a lore
-- team member can see something actually fired even before real logic exists for it.
local customHandlers = {} -- [name] = function(player, part)
local function handleCustom(player, part)
    local handler = customHandlers[part.Name]
    if handler then
        local ok, err = pcall(handler, player, part)
        if not ok then warn("[InteractableManager] custom handler error for " .. part.Name .. ": " .. tostring(err)) end
    else
        RE_CustomTriggered:FireClient(player, { name = part.Name })
        local disc = _G.DiscordManager
        if disc then disc.logInteractable(player, part.Name, "CUSTOM (no handler registered)") end
    end
    fireLiveFeed(getCharName(player), "triggered custom interactable " .. part.Name)
end

local function onInteract(player, part)
    if isOnCooldown(player, part) then
        notify(player, "Interactable", "You must wait to try again.")
        return
    end
    -- Applies regardless of pass/fail (spec: fail keeps the cooldown; a success shouldn't be
    -- instantly re-spammable either), so it's set up front rather than only on a specific
    -- outcome branch below.
    setCooldown(player, part)

    local itype = getInteractType(part)
    if itype == "Chest" then handleChest(player, part)
    elseif itype == "Journal" then handleJournal(player, part)
    elseif itype == "Ritual" then handleRitual(player, part)
    elseif itype == "Custom" then handleCustom(player, part)
    else handleQTE(player, part) -- "QTE" (default)
    end
end

local function setupPrompt(part)
    if not part:IsA("BasePart") then return end
    local prompt = part:FindFirstChildOfClass("ProximityPrompt")
    if not prompt then
        prompt = Instance.new("ProximityPrompt")
        prompt.HoldDuration = 0
        prompt.RequiresLineOfSight = true
        prompt.KeyboardKeyCode = Enum.KeyCode.E
        prompt.Style = Enum.ProximityPromptStyle.Custom
        prompt.Parent = part
    end
    prompt.ActionText = part:GetAttribute("InteractPrompt") or "Search"
    prompt.MaxActivationDistance = tonumber(part:GetAttribute("InteractRange")) or DEFAULT_RANGE
    prompt.Triggered:Connect(function(player) onInteract(player, part) end)
end

for _, part in ipairs(CollectionService:GetTagged(INTERACTABLE_TAG)) do
    setupPrompt(part)
end
CollectionService:GetInstanceAddedSignal(INTERACTABLE_TAG):Connect(setupPrompt)

local InteractableManager = {}

function InteractableManager.create(position, opts)
    opts = opts or {}
    local part = Instance.new("Part")
    part.Name = opts.name or "Interactable"
    part.Anchored = true
    part.CanCollide = true
    part.Size = Vector3.new(2, 2, 2)
    part.Material = Enum.Material.Wood
    part.Color = Color3.fromRGB(120, 90, 55)
    part.CFrame = CFrame.new(position)
    part:SetAttribute("IsInteractable", true)
    part:SetAttribute("InteractType", opts.interactType or "QTE")
    part:SetAttribute("QTETier", opts.tier or DEFAULT_TIER)
    part:SetAttribute("InteractPrompt", opts.prompt or "Search")
    part:SetAttribute("RewardType", opts.rewardType or "None")
    part:SetAttribute("RewardValue", opts.rewardValue or "")
    part:SetAttribute("InteractCooldown", opts.cooldown or DEFAULT_COOLDOWN)
    part:SetAttribute("LootPool", opts.lootPool or "")
    part:SetAttribute("RespawnTime", opts.respawnTime or DEFAULT_CHEST_RESPAWN)
    part:SetAttribute("JournalContent", opts.journalContent or "")
    part:SetAttribute("ExtraKey", opts.extraKey or "K")
    part.Parent = workspace
    CollectionService:AddTag(part, INTERACTABLE_TAG)
    return part
end

function InteractableManager.configure(part, opts)
    if not part then return false end
    opts = opts or {}
    if opts.tier then part:SetAttribute("QTETier", opts.tier) end
    if opts.prompt then part:SetAttribute("InteractPrompt", opts.prompt) end
    if opts.rewardType then part:SetAttribute("RewardType", opts.rewardType) end
    if opts.rewardValue ~= nil then part:SetAttribute("RewardValue", opts.rewardValue) end
    if opts.cooldown then part:SetAttribute("Cooldown", opts.cooldown) end
    local prompt = part:FindFirstChildOfClass("ProximityPrompt")
    if prompt and opts.prompt then prompt.ActionText = opts.prompt end
    return true
end

function InteractableManager.findByName(name)
    for _, part in ipairs(CollectionService:GetTagged(INTERACTABLE_TAG)) do
        if part.Name == name then return part end
    end
    return nil
end

-- For other managers to hook a Custom-type interactable by exact part Name (see handleCustom).
function InteractableManager.registerCustomHandler(name, fn)
    customHandlers[name] = fn
end

function InteractableManager.getAttributesSummary(part)
    return {
        InteractType = getInteractType(part),
        InteractPrompt = part:GetAttribute("InteractPrompt") or "",
        InteractRange = tonumber(part:GetAttribute("InteractRange")) or DEFAULT_RANGE,
        InteractCooldown = getCooldownSec(part),
        LootPool = part:GetAttribute("LootPool") or "",
        QTETier = part:GetAttribute("QTETier") or "",
        RewardType = part:GetAttribute("RewardType") or "",
        RewardValue = part:GetAttribute("RewardValue") or "",
        JournalContent = part:GetAttribute("JournalContent") or "",
        ExtraKey = part:GetAttribute("ExtraKey") or "",
    }
end

_G.InteractableManager = InteractableManager
print("[InteractableManager] Init")
