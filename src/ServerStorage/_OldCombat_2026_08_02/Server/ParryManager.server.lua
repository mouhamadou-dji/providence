local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")

local parryCfg, staminaCfg, postureCfg, combatCfg
do
    local ok, result = pcall(function()
        local shared = RepStorage:WaitForChild("Shared", 5)
        return require(shared:WaitForChild("Config", 3))
    end)
    if ok and result then
        parryCfg   = result.Parry
        staminaCfg = result.Stamina
        postureCfg = result.Posture
        combatCfg  = result.Combat
    end
end
parryCfg   = parryCfg   or { WindowTotal=24, PerfectWindow=10, Cooldown=1.0, StaggerDurationPerfect=1.2, StaggerDurationLate=0.5 }
staminaCfg = staminaCfg or { CostParry=12, CostParryTrait=20 }
postureCfg = postureCfg or { FillWhiff=15, FillGotParried=20 }
combatCfg  = combatCfg  or { ParryToDashCancel=true, CancelWindowFrames=4 }

-- PERFECT_SEC moved inside checkHit (below) so Corvid's per-player DNA frame bonus can apply.
local WINDOW_SEC  = (parryCfg.WindowTotal or 24) / 60  -- config-driven (was a hardcoded 20/60 ignoring parryCfg.WindowTotal entirely)
-- Whiffing (no hit intercepted during the window) is a guess that didn't pay off, so it
-- eats a harsher cooldown than a landed parry — otherwise spam-tapping F costs nothing
-- extra over precise timing and there's no reason not to just mash it every swing.
local WHIFF_COOLDOWN = (parryCfg.Cooldown or 0.6) * 2

local pState = {}

local function initState(userId)
    pState[userId] = { active=false, startTime=0, cooldownUntil=0 }
end

local function getPS(player) return pState[player.UserId] end

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

local RE_OnParryResult = getOrCreate("OnParryResult")
-- Fired to the player whenever a client-predicted parry (InputHandler plays the parry anim
-- optimistically on F press) gets rejected server-side for a reason the client didn't
-- already pre-check (stamina, exhaustion, landing recovery, no weapon/fists, etc.).
local RE_ParryDenied   = getOrCreate("OnParryDenied")

local function checkHit(parryingPlayer, attacker, attackType)
    local s = getPS(parryingPlayer)
    if not s or not s.active then return nil end
    local elapsed = tick() - s.startTime
    local cm = _G.CombatManager
    -- Corvid's DNA buff (+1 Perfect-parry frame) is additive on the base PerfectWindow --
    -- recomputed per parry attempt so it never drifts from a live DNA change.
    local dnaM = _G.DNAManager
    local PERFECT_SEC = (parryCfg.PerfectWindow + (dnaM and dnaM.getParryWindowBonusFrames(parryingPlayer) or 0)) / 60

    if attackType == "M2" then
        s.active = false
        if cm then
            cm.setCombatState(parryingPlayer, "Idle")
            cm.applyStagger(parryingPlayer, parryCfg.StaggerDurationPerfect)
        end
        RE_OnParryResult:FireClient(parryingPlayer, { result="Break", attackerName=attacker.Name })
        RE_OnParryResult:FireClient(attacker,        { result="Break", victimName=parryingPlayer.Name })
        print("[ParryManager] "..parryingPlayer.Name.." PARRY BREAK by M2 from "..attacker.Name)
        return "Break"
    end

    if elapsed >= WINDOW_SEC then return nil end

    local result = elapsed < PERFECT_SEC and "Perfect" or "Late"
    s.active = false

    if cm then
        cm.setCombatState(parryingPlayer, "Idle")
        local staggerDur = result=="Perfect" and parryCfg.StaggerDurationPerfect or parryCfg.StaggerDurationLate
        cm.applyStagger(attacker, staggerDur)
        if cm.getCombatState(attacker) == "Attacking" then cm.setCombatState(attacker, "Idle") end
    end

    local postureM = _G.PostureManager
    if postureM and postureM.fill then postureM.fill(attacker, postureCfg.FillGotParried) end
    if cm then cm.clearHitstun(parryingPlayer) end  -- parry escapes combo stun

    if result == "Perfect" and cm then
        -- The Perfect Parry moment: a spark burst at the contact point and a ring sound
        -- (played client-side off this same OnParryResult event). Hitstop removed entirely
        -- per owner request (2026-07-18, combat polish 4A).
        cm.setSpeed(parryingPlayer, 0.5)
        task.delay(0.2, function()
            if cm.getCombatState(parryingPlayer)=="Idle" then cm.setSpeed(parryingPlayer,1) end
        end)
        local aC=attacker.Character; local pC=parryingPlayer.Character
        local aHRP=aC and aC:FindFirstChild("HumanoidRootPart")
        local pHRP=pC and pC:FindFirstChild("HumanoidRootPart")
        if aHRP and pHRP and cm.spawnParryVFX then cm.spawnParryVFX((aHRP.Position+pHRP.Position)/2) end
    end

    RE_OnParryResult:FireClient(parryingPlayer, { result=result, attackerName=attacker.Name })
    RE_OnParryResult:FireClient(attacker,        { result=result, victimName=parryingPlayer.Name })

    print(string.format("[ParryManager] %s parried %s — %s (%.3fs)", parryingPlayer.Name, attacker.Name, result, elapsed))
    return result
end

local function activateParry(player, bypassChecks)
    local s = getPS(player); if not s then return false end
    -- Combat polish 4E: Dash->Parry cancel -- if the player is in the last few frames of a
    -- dash, cut it short first so its remaining travel doesn't fight the parry stance. Every
    -- normal check below (cooldown/stamina/equip/etc) still applies as usual afterward.
    local mm = _G.MovementManager
    if mm and mm.tryCancelDashToParry then mm.tryCancelDashToParry(player) end
    if not bypassChecks then
        if tick() < s.cooldownUntil then return false end
        local cm = _G.CombatManager
        if cm then
            local cs = cm.getCombatState(player)
            -- Hitstun is intentionally NOT blocked — parry is the escape from combo stun
            if cs=="Dead" or cs=="Staggered" or cs=="GuardBroken" or cs=="Clashing"
                or cs=="Downed" or cs=="BeingCarried" or cs=="BeingExecuted" or cs=="Executing" then
                return false
            end
        end
        local sm = _G.StaminaManager
        if sm and sm.isExhausted(player) then return false end -- exhaustion: walk-only
        if cm and cm.isLandingRecovery(player) then return false end -- landing recovery: walk-only
    end
    -- Require fists or weapon equipped
    local _fcm=_G.CombatManager; local _dm2=_G.DataManager
    local _hasFists=_fcm and _fcm.isFistsEquipped(player)
    local _hasWeapon=_dm2 and _dm2.getValue(player,"EquippedWeapon")~=nil
    if not _hasFists and not _hasWeapon then return false end
    -- Stop sprint when parrying
    local _mm=_G.MovementManager; if _mm then _mm.stopSprint(player) end
    -- Parry no longer drains stamina (blocking already doesn't either)
    s.active        = true
    s.startTime     = tick()
    s.cooldownUntil = tick() + parryCfg.Cooldown
    local cm = _G.CombatManager
    if cm then cm.setCombatState(player, "Parrying") end
    task.delay(WINDOW_SEC, function()
        local cur = getPS(player)
        if not cur or not cur.active then return end
        cur.active = false
        cur.cooldownUntil = math.max(cur.cooldownUntil, tick() + WHIFF_COOLDOWN)
        local _bm=_G.BlockManager; if _bm and _bm.startShakyBlock then _bm.startShakyBlock(player,3) end
        local cm2 = _G.CombatManager
        if cm2 and cm2.getCombatState(player)=="Parrying" then cm2.setCombatState(player,"Idle") end
        -- Whiff: no posture penalty. Posture only builds from real blocked hits,
        -- getting parried, or aerial M1 bonuses. Stamina cost already paid.
        RE_OnParryResult:FireClient(player, { result="Whiff" })
        print("[ParryManager] "..player.Name.." parry WHIFF")
    end)
    print("[ParryManager] "..player.Name.." parry window opened")
    return true
end

getOrCreate("RequestParry").OnServerEvent:Connect(function(player)
    if not activateParry(player, false) then
        RE_ParryDenied:FireClient(player)
    end
end)

Players.PlayerAdded:Connect(function(player)
    initState(player.UserId)
    player.CharacterAdded:Connect(function()
        -- Reset on every respawn, not just first join -- dying mid-parry-window (active=true)
        -- or right after a whiff (cooldownUntil in the future) otherwise left the fresh
        -- character unable to parry at all until that stale timer/flag happened to clear.
        initState(player.UserId)
    end)
end)
Players.PlayerRemoving:Connect(function(player) pState[player.UserId] = nil end)
for _,p in ipairs(Players:GetPlayers()) do initState(p.UserId) end

local ParryManager = {}
function ParryManager.checkHit(pp, attacker, attackType) return checkHit(pp, attacker, attackType) end
-- Combat polish 4E: Parry->Dash cancel. Mid-window, once the Perfect chance has passed but
-- before the natural whiff timeout, bailing into a dash clears the parry's active state
-- cleanly (instead of it lingering to whiff on its own timer while the player has already
-- moved away) and returns true so MovementManager's processDash knows it can proceed.
function ParryManager.tryCancelToDash(player)
    if not combatCfg.ParryToDashCancel then return false end
    local s = getPS(player); if not s or not s.active then return false end
    local elapsed = tick() - s.startTime
    local dnaM = _G.DNAManager
    local PERFECT_SEC = (parryCfg.PerfectWindow + (dnaM and dnaM.getParryWindowBonusFrames(player) or 0)) / 60
    if elapsed < PERFECT_SEC or elapsed >= WINDOW_SEC then return false end
    s.active = false
    local cm = _G.CombatManager
    if cm then cm.setCombatState(player, "Idle") end
    return true
end
function ParryManager.isParrying(player) local s=getPS(player); return s~=nil and s.active end
function ParryManager.getElapsed(player) local s=getPS(player); if not s or not s.active then return nil end; return tick()-s.startTime end
function ParryManager.activate(player) return activateParry(player, true) end
function ParryManager.cancelParry(player)
    local s = getPS(player); if not s then return end
    s.active = false
end
_G.ParryManager = ParryManager

print(string.format("[ParryManager] Init — Perfect=%.3fs | Window=%.3fs | Cooldown=%.1fs | Cost=free",
    parryCfg.PerfectWindow/60, WINDOW_SEC, parryCfg.Cooldown))
