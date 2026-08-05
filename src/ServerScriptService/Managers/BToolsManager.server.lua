-- BToolsManager -- Part Four: custom mod BTools for placing world objects
-- All placements are SESSION ONLY: workspace.SessionPlacements, destroyed on shutdown,
-- never touch DataStore.
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local btCfg = Config.BTools
local lightCfg = Config.LightSources

local function getOrCreate(name, isFunc)
    local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
        local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
    end)()
    local r=folder:FindFirstChild(name); if r then return r end
    r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_BToolAction    = getOrCreate("RequestBToolAction")
local RE_BToolFeedback  = getOrCreate("BToolFeedback")
local RE_LiveFeedUpdate = getOrCreate("LiveFeedUpdate")

local PLACEMENTS_FOLDER = "SessionPlacements"
local function getFolder()
    local f = workspace:FindFirstChild(PLACEMENTS_FOLDER)
    if not f then f = Instance.new("Folder"); f.Name = PLACEMENTS_FOLDER; f.Parent = workspace end
    return f
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
            RE_LiveFeedUpdate:FireClient(p, { type = "ACTION", h = now.hour, m = now.min, zone = "?", charName = charName, message = message })
        end
    end
end

local function feedback(mod, ok, message)
    RE_BToolFeedback:FireClient(mod, { ok = ok, message = message, count = #getFolder():GetChildren() })
end

local BToolsManager = {}

-- ================================================================================
-- TOOL 1 -- NPC SPAWNER
-- ================================================================================

local spawnFromSpawner -- forward decl

local function createNPCSpawner(position, name, respawnOnKill, respawnDelay)
    local part = Instance.new("Part")
    part.Name = "NPCSpawner"
    part.Shape = Enum.PartType.Cylinder
    part.Size = Vector3.new(0.2, 4, 4)
    part.Orientation = Vector3.new(0, 0, 90)
    part.Anchored = true; part.CanCollide = false; part.CanQuery = true
    part.Transparency = 0.6
    part.Material = Enum.Material.Neon
    part.Color = Color3.fromRGB(130, 70, 210)
    part.CFrame = CFrame.new(position)
    part:SetAttribute("IsNPCSpawner", true)
    local ok, encoded = pcall(function() return HttpService:JSONEncode({ name = name or "" }) end)
    part:SetAttribute("NPCConfigJSON", ok and encoded or "{}")
    part:SetAttribute("RespawnOnKill", respawnOnKill == true)
    part:SetAttribute("RespawnDelay", respawnDelay or btCfg.DefaultRespawnDelay)
    part:SetAttribute("SpawnedNPCName", "")

    local prompt = Instance.new("ProximityPrompt")
    prompt.ActionText = "Spawn NPC"
    prompt.ObjectText = "NPC Spawner"
    prompt.HoldDuration = 0
    prompt.MaxActivationDistance = 10
    prompt.Parent = part
    prompt.Triggered:Connect(function(player)
        if not (_G.ModManager and _G.ModManager.isMod(player)) then return end
        spawnFromSpawner(part)
    end)

    part.Parent = getFolder()
    return part
end

spawnFromSpawner = function(part)
    local cfg = {}
    pcall(function() cfg = HttpService:JSONDecode(part:GetAttribute("NPCConfigJSON") or "{}") end)
    local npcM = _G.NPCManager
    if not npcM then return end
    local model = npcM.spawnNPC(part.Position + Vector3.new(0, 2, 0), cfg.name or "Unnamed", part)
    if model then part:SetAttribute("SpawnedNPCName", model.Name) end
end

-- Called by NPCManager after a spawner-owned NPC's execute-death despawn timer completes.
function BToolsManager.handleNPCRespawn(spawnerPart)
    if not spawnerPart or not spawnerPart.Parent then return end
    if not spawnerPart:GetAttribute("RespawnOnKill") then return end
    local delay = spawnerPart:GetAttribute("RespawnDelay") or btCfg.DefaultRespawnDelay
    task.delay(delay, function()
        if spawnerPart.Parent then spawnFromSpawner(spawnerPart) end
    end)
end

-- ================================================================================
-- TOOL 3 -- LIGHT SOURCE
-- ================================================================================

local function createLightSource(position, lightType)
    local cfg = lightCfg[lightType]
    if not cfg then return nil end
    local part = Instance.new("Part")
    part.Name = "LightSource_" .. lightType
    -- PLACEHOLDER_ASSET: TorchMesh / CampfireMesh / LanternMesh / BrazierMesh
    part.Size = lightType == "Campfire" and Vector3.new(2, 1, 2) or Vector3.new(0.6, 2, 0.6)
    part.Anchored = true
    part.CanCollide = false
    part.Material = Enum.Material.Wood
    part.Color = Color3.fromRGB(90, 60, 30)
    part.CFrame = CFrame.new(position)
    part:SetAttribute("IsLightSource", true)
    part:SetAttribute("LightType", lightType)
    part:SetAttribute("Range", cfg.range)
    part:SetAttribute("Color", cfg.color)
    part:SetAttribute("FrostClearRate", cfg.frostClearRate)

    local light = Instance.new("PointLight")
    light.Color = cfg.color
    light.Range = cfg.range
    light.Brightness = cfg.brightness
    light.Parent = part

    if cfg.hasFire then
        local fire = Instance.new("Fire")
        fire.Size = cfg.fireSize
        fire.Heat = 8
        fire.Color = cfg.color
        fire.SecondaryColor = Color3.fromRGB(255, 220, 150)
        fire.Parent = part
    end

    part.Parent = getFolder()
    return part
end

-- Frost clearing: every LightSourceFrostCheckInterval seconds, any player within Range of
-- a lit LightSource has 1 Frost stack (scaled by FrostClearRate) pulled off via
-- WeatherManager's existing force/get API (no per-second decrement exists, so this reads
-- current stacks and re-sets them one lower each check).
local frostAccum = 0
RunService.Heartbeat:Connect(function(dt)
    frostAccum += dt
    local interval = Config.LightSourceFrostCheckInterval or 2
    if frostAccum < interval then return end
    frostAccum = 0
    local wm = _G.WeatherManager
    if not wm then return end
    local folder = workspace:FindFirstChild(PLACEMENTS_FOLDER)
    if not folder then return end
    for _, part in ipairs(folder:GetChildren()) do
        if part:GetAttribute("IsLightSource") then
            local range = part:GetAttribute("Range") or 20
            local rate = part:GetAttribute("FrostClearRate") or 1
            for _, p in ipairs(Players:GetPlayers()) do
                local pc = p.Character
                local hrp = pc and pc:FindFirstChild("HumanoidRootPart")
                if hrp and (hrp.Position - part.Position).Magnitude <= range then
                    local cur = wm.getFrostStacks(p)
                    if cur > 0 then wm.forceFrostStacks(p, math.max(0, cur - rate)) end
                end
            end
        end
    end
end)

-- ================================================================================
-- TOOL 4 -- RITUAL CIRCLE MARKER
-- ================================================================================

local function createRitualMarker(position, ritualName)
    local part = Instance.new("Part")
    part.Name = "RitualMarker"
    part.Shape = Enum.PartType.Cylinder
    part.Size = Vector3.new(0.3, 3, 3)
    part.Orientation = Vector3.new(0, 0, 90)
    part.Anchored = true
    part.CanCollide = false
    part.Transparency = 0.4
    part.Material = Enum.Material.Neon
    part.Color = Color3.fromRGB(160, 30, 160)
    part.CFrame = CFrame.new(position)
    part:SetAttribute("IsRitualMarker", true)
    part:SetAttribute("RitualName", (ritualName and ritualName ~= "") and ritualName or "Unnamed Ritual")
    part:SetAttribute("Notes", "")
    part.Parent = getFolder()
    return part
end

-- ================================================================================
-- TOOL 5/6 -- DELETE / MOVE SELECTED, CLEAR ALL
-- ================================================================================

function BToolsManager.deletePlacement(instance)
    if not instance or not instance:IsDescendantOf(getFolder()) then return false end
    if instance:GetAttribute("IsNPCSpawner") then
        instance:SetAttribute("RespawnOnKill", false) -- prevent a respawn firing into a just-deleted spawner
    end
    instance:Destroy()
    return true
end

function BToolsManager.movePlacement(instance, newPosition)
    if not instance or not instance:IsDescendantOf(getFolder()) then return false end
    if instance:IsA("BasePart") then
        instance.CFrame = CFrame.new(newPosition)
        return true
    end
    return false
end

-- ================================================================================
-- LIVE TRANSFORM -- the authoritative half of the client's move/rotate/scale gizmos.
--
-- The client drives these at interactive rates while a mod drags a handle, so this is the
-- one BTool entry point that gets called dozens of times a second. It stays cheap: ownership
-- is a folder-descendant check, and the rest is arithmetic sanity.
--
-- Everything is still session-only (workspace.SessionPlacements, never persisted), and the
-- whole dispatch is already behind an isMod gate -- so validation here is about preventing a
-- malformed or hostile packet from wrecking the running server (a NaN CFrame permanently
-- corrupts a part and can crash physics; a 10^30 stud part hangs the renderer), not about
-- trusting the caller's intent.
-- ================================================================================

local MIN_AXIS   = 0.2      -- Roblox's own minimum part dimension
local MAX_AXIS   = 2048     -- past this a single part is a performance problem on its own
local MAX_COORD  = 100000   -- well outside any real playable area

local function finite(n) return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge end

local function saneCFrame(cf)
    if typeof(cf) ~= "CFrame" then return false end
    local c = { cf:GetComponents() }
    for _, n in ipairs(c) do
        if not finite(n) then return false end
    end
    local p = cf.Position
    if math.abs(p.X) > MAX_COORD or math.abs(p.Y) > MAX_COORD or math.abs(p.Z) > MAX_COORD then return false end
    return true
end

local function clampSize(size)
    if typeof(size) ~= "Vector3" then return nil end
    if not (finite(size.X) and finite(size.Y) and finite(size.Z)) then return nil end
    return Vector3.new(
        math.clamp(size.X, MIN_AXIS, MAX_AXIS),
        math.clamp(size.Y, MIN_AXIS, MAX_AXIS),
        math.clamp(size.Z, MIN_AXIS, MAX_AXIS))
end

-- `size` is optional -- a move/rotate drag sends CFrame only, so a nil size must leave the
-- part's dimensions alone rather than resetting them.
function BToolsManager.transformPlacement(instance, cf, size)
    if not instance or not instance.Parent then return false, "Gone" end
    if not instance:IsDescendantOf(getFolder()) then return false, "Not a session placement" end
    if not saneCFrame(cf) then return false, "Invalid transform" end

    if instance:IsA("BasePart") then
        if size then
            local s = clampSize(size)
            if not s then return false, "Invalid size" end
            instance.Size = s
        end
        instance.CFrame = cf
        return true
    elseif instance:IsA("Model") then
        -- Models (ships, rigs) move by pivot and scale uniformly -- Model has no Size, and
        -- per-axis stretching isn't defined for one.
        if size then
            local cur = instance:GetScale()
            local target = math.clamp(size.X, 0.1, 20) -- client packs uniform scale into X
            if finite(target) and math.abs(target - cur) > 0.001 then
                pcall(function() instance:ScaleTo(target) end)
            end
        end
        instance:PivotTo(cf)
        return true
    end
    return false, "Not a movable placement"
end

function BToolsManager.clearAll()
    getFolder():ClearAllChildren()
end

-- ================================================================================
-- DISPATCH
-- ================================================================================

RE_BToolAction.OnServerEvent:Connect(function(player, action, ...)
    if not (_G.ModManager and _G.ModManager.isMod(player)) then return end
    local args = { ... }
    local charName = getCharName(player)
    local disc = _G.DiscordManager

    if action == "spawnMob" then
        -- Spawn a live mob ON the mod (owner request), routed through its AI manager when it has
        -- one (Config.Mobs), else a bare clone. Not a session placement -- it's a real mob.
        local mobName = args[1]
        if type(mobName) ~= "string" or mobName == "" then feedback(player, false, "No mob selected"); return end
        local char = player.Character
        local hrp = char and char:FindFirstChild("HumanoidRootPart")
        local pos = (hrp and (hrp.Position + Vector3.new(0, 3, 0))) or Vector3.new(0, 10, 0)
        local spawned = false
        for _, entry in ipairs(Config.Mobs or {}) do
            if entry.template == mobName then
                if entry.manager and _G[entry.manager] and _G[entry.manager].spawn then
                    _G[entry.manager].spawn(pos); spawned = true
                end
                break
            end
        end
        if not spawned then
            local tpl = workspace:FindFirstChild(mobName) or RepStorage:FindFirstChild(mobName)
            if tpl then
                local wasArch = tpl.Archivable; tpl.Archivable = true
                local m = tpl:Clone(); tpl.Archivable = wasArch
                m:PivotTo(CFrame.new(pos)); m.Parent = getFolder(); spawned = true
            end
        end
        if spawned then
            fireLiveFeed(charName, "spawned a " .. mobName .. " on themselves")
            if disc then disc.logBTool(charName, "spawned mob " .. mobName .. " (on self)") end
            feedback(player, true, mobName .. " spawned on you")
        else
            feedback(player, false, "Mob not found: " .. mobName)
        end

    elseif action == "placeNPCSpawner" then
        local position, name, respawnOnKill, respawnDelay = args[1], args[2], args[3], args[4]
        if typeof(position) ~= "Vector3" then feedback(player, false, "Invalid position"); return end
        createNPCSpawner(position, name, respawnOnKill, tonumber(respawnDelay))
        fireLiveFeed(charName, "placed an NPC Spawner at " .. tostring(position))
        if disc then disc.logBTool(charName, "placed NPC Spawner at " .. tostring(position)) end
        feedback(player, true, "NPC Spawner placed")

    elseif action == "placeInteractable" then
        local position, tier, prompt, rewardType, rewardValue, cooldown = args[1], args[2], args[3], args[4], args[5], args[6]
        if typeof(position) ~= "Vector3" then feedback(player, false, "Invalid position"); return end
        local im = _G.InteractableManager
        if not im then feedback(player, false, "InteractableManager not ready"); return end
        local part = im.create(position, {
            tier = (tier ~= "" and tier) or nil, prompt = (prompt ~= "" and prompt) or nil,
            rewardType = (rewardType ~= "" and rewardType) or nil, rewardValue = rewardValue,
            cooldown = tonumber(cooldown),
        })
        part.Parent = getFolder()
        fireLiveFeed(charName, "placed an Interactable QTE Point at " .. tostring(position))
        if disc then disc.logBTool(charName, "placed Interactable at " .. tostring(position)) end
        feedback(player, true, "Interactable placed")

    elseif action == "placeLightSource" then
        local position, lightType = args[1], args[2]
        if typeof(position) ~= "Vector3" then feedback(player, false, "Invalid position"); return end
        local part = createLightSource(position, lightType)
        if not part then feedback(player, false, "Unknown light type: " .. tostring(lightType)); return end
        fireLiveFeed(charName, "placed a " .. lightType .. " at " .. tostring(position))
        if disc then disc.logBTool(charName, "placed " .. lightType .. " at " .. tostring(position)) end
        feedback(player, true, lightType .. " placed")

    elseif action == "placeChest" then
        local position, lootPool, respawnTime = args[1], args[2], args[3]
        if typeof(position) ~= "Vector3" then feedback(player, false, "Invalid position"); return end
        local im = _G.InteractableManager
        if not im then feedback(player, false, "InteractableManager not ready"); return end
        local part = im.create(position, {
            name = "Chest", interactType = "Chest", prompt = "Open",
            lootPool = (lootPool ~= "" and lootPool) or nil, respawnTime = tonumber(respawnTime),
        })
        part.Parent = getFolder()
        fireLiveFeed(charName, "placed a Chest at " .. tostring(position))
        if disc then disc.logBTool(charName, "placed Chest at " .. tostring(position)) end
        feedback(player, true, "Chest placed")

    elseif action == "placeOreNode" then
        local position, oreType, oreRarity = args[1], args[2], args[3]
        if typeof(position) ~= "Vector3" then feedback(player, false, "Invalid position"); return end
        local mm = _G.MiningManager
        if not mm then feedback(player, false, "MiningManager not ready"); return end
        local part = mm.createNode(position, (oreType ~= "" and oreType) or nil, (oreRarity ~= "" and oreRarity) or nil)
        part.Parent = getFolder()
        fireLiveFeed(charName, "placed an Ore Node at " .. tostring(position))
        if disc then disc.logBTool(charName, "placed Ore Node at " .. tostring(position)) end
        feedback(player, true, "Ore Node placed")

    elseif action == "placeSmelter" then
        local position, tier = args[1], args[2]
        if typeof(position) ~= "Vector3" then feedback(player, false, "Invalid position"); return end
        local sm = _G.SmeltingManager
        if not sm then feedback(player, false, "SmeltingManager not ready"); return end
        local part = sm.createSmelter(position, (tier ~= "" and tier) or nil)
        part.Parent = getFolder()
        fireLiveFeed(charName, "placed a Smelter at " .. tostring(position))
        if disc then disc.logBTool(charName, "placed Smelter at " .. tostring(position)) end
        feedback(player, true, "Smelter placed")

    elseif action == "placeTailoringStation" then
        local position, tier = args[1], args[2]
        if typeof(position) ~= "Vector3" then feedback(player, false, "Invalid position"); return end
        local tm = _G.TailoringManager
        if not tm then feedback(player, false, "TailoringManager not ready"); return end
        local part = tm.createStation(position, (tier ~= "" and tier) or nil)
        part.Parent = getFolder()
        fireLiveFeed(charName, "placed a Tailoring Station at " .. tostring(position))
        if disc then disc.logBTool(charName, "placed Tailoring Station at " .. tostring(position)) end
        feedback(player, true, "Tailoring Station placed")

    elseif action == "placeForge" then
        local position = args[1]
        if typeof(position) ~= "Vector3" then feedback(player, false, "Invalid position"); return end
        local sm2 = _G.SmithingManager
        if not sm2 then feedback(player, false, "SmithingManager not ready"); return end
        local part = sm2.createForge(position)
        part.Parent = getFolder()
        fireLiveFeed(charName, "placed a Forge at " .. tostring(position))
        if disc then disc.logBTool(charName, "placed Forge at " .. tostring(position)) end
        feedback(player, true, "Forge placed")

    elseif action == "placeFarmingPlot" then
        local position = args[1]
        if typeof(position) ~= "Vector3" then feedback(player, false, "Invalid position"); return end
        local fm = _G.FarmingManager
        if not fm then feedback(player, false, "FarmingManager not ready"); return end
        local part = fm.createPlot(position)
        part.Parent = getFolder()
        fireLiveFeed(charName, "placed a Farming Plot at " .. tostring(position))
        if disc then disc.logBTool(charName, "placed Farming Plot at " .. tostring(position)) end
        feedback(player, true, "Farming Plot placed")

    elseif action == "placeCustomInteractable" then
        local position, customName = args[1], args[2]
        if typeof(position) ~= "Vector3" then feedback(player, false, "Invalid position"); return end
        local im2 = _G.InteractableManager
        if not im2 then feedback(player, false, "InteractableManager not ready"); return end
        local part = im2.create(position, {
            name = (customName ~= "" and customName) or "CustomInteractable",
            interactType = "Custom", prompt = "Interact",
        })
        part.Parent = getFolder()
        fireLiveFeed(charName, "placed a Custom Interactable (" .. part.Name .. ") at " .. tostring(position))
        if disc then disc.logBTool(charName, "placed Custom Interactable " .. part.Name .. " at " .. tostring(position)) end
        feedback(player, true, "Custom Interactable placed")

    elseif action == "placeShip" then
        local position, shipName = args[1], args[2]
        if typeof(position) ~= "Vector3" then feedback(player, false, "Invalid position"); return end
        local bm = _G.BoatManager
        if not bm then feedback(player, false, "BoatManager not ready"); return end
        local model = bm.createShip(position, (shipName ~= "" and shipName) or nil)
        fireLiveFeed(charName, "placed a Ship (" .. model.Name .. ") at " .. tostring(position))
        if disc then disc.logBTool(charName, "placed Ship " .. model.Name .. " at " .. tostring(position)) end
        feedback(player, true, "Ship placed")

    elseif action == "placeSpirit" then
        local position, factionName = args[1], args[2]
        if typeof(position) ~= "Vector3" then feedback(player, false, "Invalid position"); return end
        local sm = _G.SpiritManager
        if not sm then feedback(player, false, "SpiritManager not ready"); return end
        local part = sm.spawnSpirit((factionName ~= "" and factionName) or "Flame", position)
        if not part then feedback(player, false, "Unknown faction: " .. tostring(factionName)); return end
        part.Parent = getFolder()
        fireLiveFeed(charName, "placed a " .. tostring(factionName) .. " Spirit at " .. tostring(position))
        if disc then disc.logBTool(charName, "placed " .. tostring(factionName) .. " Spirit at " .. tostring(position)) end
        feedback(player, true, "Spirit placed (" .. part.Name .. ")")

    elseif action == "placeRitualMarker" then
        local position, ritualName = args[1], args[2]
        if typeof(position) ~= "Vector3" then feedback(player, false, "Invalid position"); return end
        createRitualMarker(position, ritualName)
        fireLiveFeed(charName, "placed a Ritual Circle Marker at " .. tostring(position))
        if disc then disc.logBTool(charName, "placed Ritual Marker at " .. tostring(position)) end
        feedback(player, true, "Ritual Marker placed")

    elseif action == "delete" then
        local instance = args[1]
        local instName = instance and instance.Name or "placement"
        local ok = BToolsManager.deletePlacement(instance)
        if ok then
            fireLiveFeed(charName, "deleted a " .. instName)
            if disc then disc.logBTool(charName, "deleted " .. instName) end
        end
        feedback(player, ok, ok and "Deleted" or "Not a valid placement")

    elseif action == "move" then
        local instance, newPosition = args[1], args[2]
        local ok = BToolsManager.movePlacement(instance, newPosition)
        feedback(player, ok, ok and "Moved" or "Not a valid placement")

    elseif action == "transform" then
        -- Fired continuously while a gizmo handle is being dragged. Deliberately silent: a
        -- feedback packet per frame would spam the panel's status line and the network for no
        -- benefit -- the mod can already see the object moving. Only the terminal
        -- "transformCommit" below reports, and only that one writes to the live feed.
        BToolsManager.transformPlacement(args[1], args[2], args[3])

    elseif action == "transformCommit" then
        local instance, cf, size, verb = args[1], args[2], args[3], args[4]
        local ok, err = BToolsManager.transformPlacement(instance, cf, size)
        if ok then
            local what = instance and instance.Name or "placement"
            fireLiveFeed(charName, (verb or "moved") .. " a " .. what)
            if disc then disc.logBTool(charName, (verb or "moved") .. " " .. what) end
        end
        feedback(player, ok, ok and ("Applied: " .. tostring(verb or "move")) or tostring(err))

    elseif action == "clearAll" then
        BToolsManager.clearAll()
        fireLiveFeed(charName, "cleared all session placements")
        if disc then disc.logBTool(charName, "cleared all session placements") end
        feedback(player, true, "Cleared")
    end
end)

_G.BToolsManager = BToolsManager
print("[BToolsManager] Init")
