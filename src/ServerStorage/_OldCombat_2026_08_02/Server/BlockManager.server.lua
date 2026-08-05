-- BlockManager(F hold)
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local combatCfg, staminaCfg, postureCfg
do
    local ok, result = pcall(function()
        local shared = RepStorage:WaitForChild("Shared", 5)
        return require(shared:WaitForChild("Config", 3))
    end)
    if ok and result then
        combatCfg  = result.Combat
        staminaCfg = result.Stamina
        postureCfg = result.Posture
    end
end
combatCfg  = combatCfg  or { SpeedBlock = 0.4 }
staminaCfg = staminaCfg or { CostBlockPerSec = 5 }
postureCfg = postureCfg or { FillBlock = 10 }

local FILL_BLOCK = postureCfg.FillBlock or 10

local function getOrCreate(name, isFunc)
    local folder = RepStorage:FindFirstChild("RemoteEvents")
        or (function()
            local f = Instance.new("Folder")
            f.Name = "RemoteEvents"
            f.Parent = RepStorage
            return f
        end)()
    local r = folder:FindFirstChild(name)
    if r then return r end
    r = Instance.new(isFunc and "RemoteFunction" or "RemoteEvent")
    r.Name = name
    r.Parent = folder
    return r
end

local RE_MovState = getOrCreate("UpdateMovementState")

local pState = {}

local function initState(uid)
    pState[uid] = { isBlocking = false, shakyUntil = 0 }
end

local function getPS(player)
    return pState[player.UserId]
end

local function endBlock(player)
    local s = getPS(player); if not s or not s.isBlocking then return end
    s.isBlocking = false
    local cm = _G.CombatManager
    if cm and cm.getCombatState(player) == "Blocking" then
        cm.setCombatState(player, "Idle")
        cm.setSpeed(player, 1)
    end
    RE_MovState:FireClient(player, "BlockEnd")
    print("[BlockManager] " .. player.Name .. " BLOCK end")
end

local function startBlock(player)
    local s = getPS(player); if not s or s.isBlocking then return end
    local cm = _G.CombatManager
    if cm and cm.isActionBlocked(player) then return end
    local _dm2=_G.DataManager
    local _hasFists=cm and cm.isFistsEquipped(player)
    local _hasWeapon=_dm2 and _dm2.getValue(player,"EquippedWeapon")~=nil
    if not _hasFists and not _hasWeapon then return end
    local _mm = _G.MovementManager; if _mm and _mm.stopSprint then _mm.stopSprint(player) end
    local _pm = _G.ParryManager; if _pm and _pm.cancelParry then _pm.cancelParry(player) end
    s.isBlocking = true
    if cm then
        cm.setCombatState(player, "Blocking")
        local tm = _G.TalentManager
        local hasBlockTalent = tm and tm.hasTalent and tm.hasTalent(player, "BlockMovement")
        cm.setSpeed(player, hasBlockTalent and 1 or combatCfg.SpeedBlock)
    end
    RE_MovState:FireClient(player, "Block")
    print("[BlockManager] " .. player.Name .. " BLOCK start (40% speed)")
end

getOrCreate("RequestBlock").OnServerEvent:Connect(function(p)    startBlock(p) end)
getOrCreate("RequestBlockEnd").OnServerEvent:Connect(function(p) endBlock(p)   end)

-- Block no longer drains stamina — posture rises on each hit absorbed (see checkHit)

Players.PlayerAdded:Connect(function(p)
    initState(p.UserId)
    p.CharacterAdded:Connect(function()
        -- Reset on every respawn, not just first join -- dying mid-block (isBlocking=true)
        -- otherwise left BlockManager thinking the fresh character was still blocking with
        -- nothing on the client to match it.
        initState(p.UserId)
    end)
end)
Players.PlayerRemoving:Connect(function(p) pState[p.UserId] = nil end)
for _, p in ipairs(Players:GetPlayers()) do initState(p.UserId) end

local BlockManager = {}

function BlockManager.isBlocking(player)
    local s = getPS(player)
    return s ~= nil and s.isBlocking
end

function BlockManager.checkHit(player, attacker, attackType)
    if attackType ~= "M1" then return false end
    local s = getPS(player)
    if not s or not s.isBlocking then return false end
    local pm = _G.PostureManager
    if pm then pm.fill(player, FILL_BLOCK) end
    if tick() < (s.shakyUntil or 0) then
        print("[BlockManager] " .. player.Name .. " SHAKY BLOCK — 40% dmg leaks")
        return 0.4
    end
    print("[BlockManager] " .. player.Name .. " BLOCKED M1 from " .. attacker.Name)
    local cm = _G.CombatManager
    if cm then
        local pC=player.Character; local aC=attacker.Character
        local pHRP=pC and pC:FindFirstChild("HumanoidRootPart")
        local aHRP=aC and aC:FindFirstChild("HumanoidRootPart")
        if pHRP and aHRP then
            if cm.spawnBlockVFX then cm.spawnBlockVFX((pHRP.Position+aHRP.Position)/2) end
            local snd = Instance.new("Sound")
			snd.SoundId = "rbxassetid://118395473392685"
            snd.Volume = 0.7
            snd.PlaybackSpeed = 0.92 + math.random()*0.16
            snd.Parent = pHRP
            snd:Play()
            game:GetService("Debris"):AddItem(snd, 3)
        end
    end
    return true
end

function BlockManager.startShakyBlock(player, duration)
    local s = getPS(player); if not s then return end
    s.shakyUntil = tick() + (duration or 3)
    print("[BlockManager] " .. player.Name .. " shaky block " .. (duration or 3) .. "s")
end

function BlockManager.endBlock(player)
    endBlock(player)
end

_G.BlockManager = BlockManager

print(string.format("[BlockManager] Init — SpeedBlock=%.0f%% | Cost=%.0f/s | PostureFill=%d per hit",
    combatCfg.SpeedBlock * 100, staminaCfg.CostBlockPerSec, FILL_BLOCK))