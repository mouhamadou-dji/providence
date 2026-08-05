local Players     = game:GetService("Players")
local RepStorage  = game:GetService("ReplicatedStorage")
local RunService  = game:GetService("RunService")

local combatCfg, parryCfg, staminaCfg, scalingCfg
do
    local ok, result = pcall(function()
        local shared = RepStorage:WaitForChild("Shared", 5)
        return require(shared:WaitForChild("Config", 3))
    end)
    if ok and result then
        combatCfg  = result.Combat
        parryCfg   = result.Parry
        staminaCfg = result.Stamina
        scalingCfg = result.StatScaling
    end
end
combatCfg = combatCfg or {}
do
    local _d = {
        M1Damage=7, M2Damage=15, CriticalDamage=45, FistDamageMultiplier=0.6,
        HitstunDuration=0.3, KnockbackForce=40, KnockbackRunningM1=50,
        ExecuteHealthThreshold=0.15, ExecuteRange=5, CarryRange=4,
        BleedoutDuration=30,
        M1ChainMax=5, M1ChainWindow=1.2, M1EndLagDuration=1.5, M1EnderDamageMultiplier=1.35,
        M2SwingDuration=0.8, M2Cooldown=7.0, CostFeint=4,
        AerialM1BonusPosture=3, AerialM1BonusStagger=0.3,
        SpeedM1Chain=0.25, SpeedM2Swing=0.10, SpeedStagger=0.3,
        SpeedGuardBreak=0, SpeedBlock=0.4, SpeedCarrying=0.5,
    }
    for k, v in pairs(_d) do
        if combatCfg[k] == nil then combatCfg[k] = v end
    end
    -- Config field name aliases
    combatCfg.KnockbackRunningM1 = combatCfg.KnockbackRunningM1 or combatCfg.KnockbackRunningForce or 50
    combatCfg.BleedoutDuration   = combatCfg.BleedoutDuration   or combatCfg.BleedOutTime           or 30
    combatCfg.ChainResetTime     = combatCfg.ChainResetTime     or 2
    combatCfg.LandingRecovery    = combatCfg.LandingRecovery    or 0.93
    combatCfg.M1Startup          = combatCfg.M1Startup          or 32
    combatCfg.M2Startup          = combatCfg.M2Startup          or 36
    combatCfg.AttackTurnSpeed    = combatCfg.AttackTurnSpeed    or 120
end
parryCfg = parryCfg or { Cooldown=0.6, StaggerDurationPerfect=1.2, StaggerDurationLate=0.5, WindowTotal=20, PerfectWindow=4 }
staminaCfg = staminaCfg or { CostM1=0, CostM2=18, CostDash=6 }
scalingCfg = scalingCfg or { StrengthPerPoint=0.005, EndurancePerPoint=0.005, AgilityPerPoint=0.005 }
local Util; pcall(function() Util=require(RepStorage:WaitForChild("Shared",3):WaitForChild("Util",3)) end)
local function getStat(p,k) local dm=_G.DataManager;if not dm then return 0 end;local st=dm.getValue(p,"Stats");return (type(st)=="table" and st[k]) or 0 end
local function getScaledValue(b,s,r) if Util then return Util.getScaledValue(b,s,r) end;return b+(b*(s*r)) end
-- LostArm (-50%) and BrokenTissue (-25%) damage-output injuries stack multiplicatively;
-- InjuryManager owns the actual math, this is just the per-call-site hook.
local function injuryDamageMult(p) local im=_G.InjuryManager; return im and im.getDamageMultiplier(p) or 1 end
-- Bloodline damage: the lore-clan multiplier (House Verkanos' +5% M1, etc.) times the caste's
-- purity-scaled DamageBonus (Belgae +8% at Purity 100, Sequani +4%). Folded into this one
-- helper rather than added at each of the six damage sites -- both are "who your blood says
-- you are", and every call site already multiplies by it.
local function dnaDamageMult(p,damageType)
    local dnaM=_G.DNAManager
    local cm=_G.CasteManager
    return (dnaM and dnaM.getDamageMultiplier(p,damageType) or 1) * (cm and cm.getDamageMultiplier(p) or 1)
end

local BASE_WALK_SPEED   = 16
local EXECUTE_ANIM_TIME = 3.0
local CD = { M1=combatCfg.M1Cooldown, M2=combatCfg.M2Cooldown, Critical=combatCfg.CriticalCooldown, AerialSlam=combatCfg.AerialSlamCooldown, Feint=combatCfg.FeintCooldown } -- all now Config-sourced (config audit); Feint was 1.0, bumped to make feinting a real commitment, not a near-free option
-- {offset, sizeX, sizeY, sizeZ} arrays from Config.Combat, falling back to defaults matching
-- the same shape if Config is somehow unavailable.
local function hitboxFromCfg(arr, fallbackOffset, fallbackSize)
    if type(arr) ~= "table" or #arr < 4 then
        return { offset=fallbackOffset, size=fallbackSize }
    end
    return { offset=Vector3.new(0,0,-arr[1]), size=Vector3.new(arr[2],arr[3],arr[4]) }
end
local HITBOX = {
    M1        = hitboxFromCfg(combatCfg.HitboxM1, Vector3.new(0,0,-3), Vector3.new(6,5,4)),
    M1Running = { offset=Vector3.new(0,0,-3.5), size=Vector3.new(6,5,6) },
    M1Aerial  = { offset=Vector3.new(0,0,-3),   size=Vector3.new(4,5,4) },
    DownSlam  = { offset=Vector3.new(0,-8,0), size=Vector3.new(7,22,7) },
    M2        = hitboxFromCfg(combatCfg.HitboxM2, Vector3.new(0,0,-2), Vector3.new(7,5,2.5)),
    Sweep     = { offset=Vector3.new(0,-2,-2.5), size=Vector3.new(5,2,5) },
}

local ANIMS = RepStorage:FindFirstChild("_Animations")
local SOUNDS = RepStorage:FindFirstChild("_Sounds")
local CombatSounds = SOUNDS and SOUNDS:FindFirstChild("Combat")

-- Looks up a Sound instance's SoundId by name in ReplicatedStorage._Sounds.Combat.
-- Returns nil (caller skips playing) for unset placeholders so silence beats a broken clip.
local function soundId(name)
    if not name then return nil end
    local snd = CombatSounds and CombatSounds:FindFirstChild(name)
    local id = snd and snd.SoundId
    if not id or id == "" or id == "rbxassetid://0" then return nil end
    return id
end

local function playAndWaitForHit(char, animObj, fallbackSec, onHit)
    local hum = char:FindFirstChildOfClass("Humanoid")
    local animator = hum and hum:FindFirstChildOfClass("Animator")
    if not animator or not animObj then
        task.delay(fallbackSec, onHit); return
    end
    local ok, track = pcall(function() return animator:LoadAnimation(animObj) end)
    if not ok or not track then
        task.delay(fallbackSec, onHit); return
    end
    -- Default track.Priority (no explicit override, no authored priority on the asset) is
    -- Action -- exactly the priority MovementController's own walk/run/dash tracks use, and
    -- its suppressForeignTracks() stops any FOREIGN track at Action priority or below on
    -- every RenderStepped frame. Without this, the crit swing plays for a single frame and
    -- is immediately killed. Action2 matches every other combat animation in the game
    -- (InputHandler's playCombatAnim, NPCManager's server-driven anims).
    track.Priority = Enum.AnimationPriority.Action2
    local fired = false
    local conn
    conn = track:GetMarkerReachedSignal("Hit"):Connect(function()
        if fired then return end
        fired = true; conn:Disconnect(); onHit()
    end)
    track:Play()
    task.delay(fallbackSec, function()
        if fired then return end
        fired = true
        if conn then conn:Disconnect() end
        onHit()
    end)
end

local pState = {}

local function initState(userId)
    pState[userId] = {
        combatState="Idle", hitstunUntil=0, endLagUntil=0,
        chainCount=0, chainWindowUntil=0, lastSwingTick=0, fistsEquipped=true, cooldowns={},
        isSprinting=false, combatLocked=false,
        carryingPlayer=nil, beingCarriedBy=nil,
        isExecuting=false, executionTarget=nil,
        airCritWindup=false, isCritting=false, isSweeping=false, isDownSlamming=false, critHighlight=nil,
        sprintLockUntil=0,
        isM2Swinging=false,
        bloodPool=nil, bloodPoolConn=nil,
        iframesUntil=0,
        m1Buffered=false,
        landingRecoveryUntil=0,
        dashFeintRecoveryUntil=0,
        activeSwingSound=nil,
        turnCapUntil=0, -- separate from combatState: only caps turning for the active swing itself, not the whole post-swing chain-reset grace window
        speedMult=1, -- last mult passed to setSpeed, remembered so a HealthChanged tick can recompute WalkSpeed with the current low-health penalty
        swingToken=0, -- bumped each new M1 swing; invalidates that swing's in-flight hitbox coroutine if feinted
        m1FeintWindowUntil=0, -- tick() deadline: M2 pressed before this cancels the current M1 instead of firing its own M2
    }
end

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

local RE_OnHit     = getOrCreate("OnHit")
local RE_OnStagger = getOrCreate("OnStagger")
local RE_OnDowned       = getOrCreate("OnDowned")
local RE_PlayCombatAnim = getOrCreate("PlayCombatAnim")
local RE_EquipFists     = getOrCreate("RequestEquipFists")
-- Fired to the attacker whenever a client-predicted M1 swing (InputHandler plays the anim
-- optimistically on click) gets rejected server-side for a reason the client didn't already
-- pre-check (landing recovery, exhaustion, M2-lock, end lag, etc.) -- lets the client cancel
-- the in-flight animation instead of it playing out with nothing actually happening.
local RE_M1Denied       = getOrCreate("OnM1Denied")

-- Low-health run-speed penalty: matches MovementController's existing scaredy_run
-- animation threshold (<30% HP) so the slowdown kicks in exactly when that animation does.
-- Tapers linearly from no penalty at the threshold down to a floor multiplier near 0 HP,
-- rather than a single abrupt jump.
local LOW_HEALTH_SPEED_THRESHOLD = 0.3
local LOW_HEALTH_MIN_MULT        = 0.6

-- Landing recovery (the brief walk-only lockout after touching down) only kicks in past
-- this many studs of actual fall -- a small hop/step down used to trigger the full lockout
-- same as a real fall, which silently blocked dash/M1/M2/slide for nothing.
local LANDING_RECOVERY_MIN_FALL = 12

local function healthSpeedMult(player)
    local char = player.Character; if not char then return 1 end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.MaxHealth <= 0 then return 1 end
    local frac = hum.Health / hum.MaxHealth
    if frac >= LOW_HEALTH_SPEED_THRESHOLD then return 1 end
    local t = math.max(0, frac) / LOW_HEALTH_SPEED_THRESHOLD
    return LOW_HEALTH_MIN_MULT + (1 - LOW_HEALTH_MIN_MULT) * t
end

local function injurySpeedMult(player) local im=_G.InjuryManager; return im and im.getSpeedMultiplier(player) or 1 end
local function rageSpeedMult(player) local rm=_G.RageManager; return rm and rm.getSpeedMult(player) or 1 end
-- Parisii "knows the streets": +10% (purity-scaled) but ONLY inside Massalia -- CasteManager
-- checks the live ZoneManager zone, so this returns 1 the moment they leave the city.
local function casteSpeedMult(player) local cm=_G.CasteManager; return cm and cm.getMassaliaMovementMultiplier(player) or 1 end
local function setSpeed(player, mult)
    local char = player.Character; if not char then return end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    -- pState indexed directly (not via getPS) since getPS isn't declared until below this
    -- point in the file and a local declared later can't be an upvalue here.
    local s = pState[player.UserId]; if s then s.speedMult = mult end
    hum.WalkSpeed = BASE_WALK_SPEED * mult * healthSpeedMult(player) * injurySpeedMult(player) * rageSpeedMult(player) * casteSpeedMult(player)
end
local function restoreSpeed(player) setSpeed(player, 1) end
local function getPS(player) return pState[player.UserId] end

-- Replicates combatState onto the character as an Attribute so client scripts (fidget/
-- tilt gating in MovementController, and the client-side attack/parry animation predictor
-- in InputHandler) can read whether the player is currently blocked from acting, without a
-- dedicated remote. combatState is written in many places across this file (and by other
-- managers via the public setCombatState API below) -- diffing every frame here is simpler
-- and safer than instrumenting every write site individually.
RunService.Heartbeat:Connect(function()
    for uid, s in pairs(pState) do
        local player = Players:GetPlayerByUserId(uid)
        local char = player and player.Character
        if char and char:GetAttribute("CombatState") ~= s.combatState then
            char:SetAttribute("CombatState", s.combatState)
        end
    end
end)

local function applyWindupHighlight(player)
    local char = player.Character; if not char then return end
    local s = getPS(player); if not s then return end
    local hl = Instance.new("Highlight")
    hl.FillTransparency = 1
    hl.OutlineColor = Color3.fromRGB(200, 0, 0)
    hl.OutlineTransparency = 0
    hl.Parent = char
    s.critHighlight = hl
end
local function removeWindupHighlight(player)
    local s = getPS(player); if not s then return end
    if s.critHighlight then s.critHighlight:Destroy(); s.critHighlight = nil end
end

local function hasIframes(player)
    local s = getPS(player); return s ~= nil and tick() < s.iframesUntil
end

local function isTurnCapped(player)
    local s = getPS(player); return s ~= nil and tick() < (s.turnCapUntil or 0)
end

local function isAirborne(player)
    local char = player.Character; if not char then return false end
    local hum = char:FindFirstChildOfClass("Humanoid"); if not hum then return false end
    -- Freefall only — Jumping state means the Humanoid is still applying its upward jump
    -- force each physics step, which overrides any AssemblyLinearVelocity we set.
    local _st=hum:GetState()
    return _st==Enum.HumanoidStateType.Freefall or _st==Enum.HumanoidStateType.Jumping
end

-- ignoreExhaustion lets fist M1 (which costs no stamina, see processM1) stay usable while
-- exhausted -- every other caller omits it and keeps the normal exhaustion gate.
-- ignoreLandingRecovery lets slide bypass the post-landing lockout specifically (user:
-- slide should take priority over landing recovery -- sliding right as you touch down
-- was silently getting refused otherwise). Every other caller omits it and keeps the
-- normal landing-recovery gate (dash, M1/M2, etc. all still walk-only right after landing).
local function isActionBlocked(player, ignoreExhaustion, ignoreLandingRecovery)
    local s = getPS(player); if not s then return true end
    if s.combatLocked then return true end
    local cs = s.combatState
    if cs=="Dead" or cs=="Staggered" or cs=="GuardBroken" or cs=="Clashing"
       or cs=="Downed" or cs=="BeingCarried" or cs=="BeingExecuted" or cs=="Executing" then
        return true
    end
    if tick() < s.hitstunUntil then return true end
    -- PlayerState=="Dead" is intentionally NOT blocked here anymore -- permanently-dead
    -- (PDE) and mod-killed players now get a real, controllable body in the void
    -- (workspace.'void place', see LoreManager's death-hole respawn redirect) and need
    -- dash/slide/crouch/sprint to work for the floatable parkour there. combatState=="Dead"
    -- (a couple lines up) is a separate, unrelated flag -- only set by the execution-kill
    -- mechanic in processExecute -- and is still blocked as before.
    if not ignoreExhaustion then
        local sm = _G.StaminaManager
        if sm and sm.isExhausted(player) then return true end -- exhaustion: walk-only, no attacks
    end
    if not ignoreLandingRecovery and tick() < s.landingRecoveryUntil then return true end -- landing recovery: walk-only, no attacks/dash (slide is exempt, see above)
    return false
end

local function checkRateLimit(player, action)
    local s = getPS(player); if not s then return false end
    local last = s.cooldowns[action] or 0
    if tick()-last < CD[action] then return false end
    s.cooldowns[action] = tick(); return true
end

local function applyCombatTag(victim, sourceTag)
    if sourceTag~="Player" and sourceTag~="Mob" then return end
    local sm = _G.StaminaManager
    if sm and sm.tagCombat then sm.tagCombat(victim) end
end

local function checkHitbox(attackerChar, boxKey)
    local hrp = attackerChar:FindFirstChild("HumanoidRootPart"); if not hrp then return {} end
    local h = HITBOX[boxKey]
    local boxCF = hrp.CFrame * CFrame.new(h.offset)
    if _G.DEBUG_HITBOXES then _G.DEBUG_HITBOXES(boxCF, h.size, boxKey) end
    local params = OverlapParams.new()
    params.FilterDescendantsInstances = {attackerChar}
    params.FilterType = Enum.RaycastFilterType.Exclude
    return workspace:GetPartBoundsInBox(boxCF, h.size, params)
end

-- DownSlam's hitbox is anchored to the ground beneath the attacker (via a downward raycast)
-- instead of the attacker's own HRP offset like every other attack in HITBOX -- the attacker
-- may still be mid-air (falling naturally under gravity) when this resolves, and forcing
-- their real body down to meet a fixed HRP-relative hitbox (previously a hard -120 stud/s
-- BodyVelocity, see processM1's aerial branch) made them visibly clip/glitch into the
-- ground on impact instead of the hit just landing cleanly where the ground actually is.
local function checkHitboxDownSlam(attackerChar)
    local hrp = attackerChar:FindFirstChild("HumanoidRootPart"); if not hrp then return {} end
    local rayParams = RaycastParams.new()
    rayParams.FilterDescendantsInstances = {attackerChar}
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    local rayResult = workspace:Raycast(hrp.Position, Vector3.new(0, -100, 0), rayParams)
    local groundY = rayResult and rayResult.Position.Y or (hrp.Position.Y - 100)
    -- Spans from the attacker down to the ground (+3 stud pad so it still catches a target
    -- standing right at ground level), floored to a sane minimum height.
    local height = math.max(6, (hrp.Position.Y - groundY) + 3)
    local boxCF = CFrame.new(hrp.Position.X, groundY + height/2, hrp.Position.Z)
    local size = Vector3.new(7, height, 7)
    if _G.DEBUG_HITBOXES then _G.DEBUG_HITBOXES(boxCF, size, "DownSlam") end
    local params = OverlapParams.new()
    params.FilterDescendantsInstances = {attackerChar}
    params.FilterType = Enum.RaycastFilterType.Exclude
    return workspace:GetPartBoundsInBox(boxCF, size, params)
end

-- lateralDir/lateralForce are optional and default to nil, so every existing 3-argument
-- caller behaves exactly as before. They add a sideways shove along a supplied axis, for
-- sweeping attacks (the Shroom's swings) where a purely backward push reads as a poke.
local function applyKnockback(attackerChar, victimChar, force, lateralDir, lateralForce)
    local aHRP = attackerChar:FindFirstChild("HumanoidRootPart")
    local vHRP = victimChar:FindFirstChild("HumanoidRootPart")
    if not aHRP or not vHRP then return end
    local victimPlayer = Players:GetPlayerFromCharacter(victimChar)
    local resist = 0
    if victimPlayer then
        local rm = _G.RageManager
        if rm and rm.isKnockbackImmune(victimPlayer) then return end
    else
        -- Non-player victim = a mob. Mobs are bigger/stronger than humans and shouldn't be
        -- launched by a person's swing; they take a slight step back instead. Per-model
        -- "KnockbackResist" attribute wins over the global default when present.
        local attr = victimChar:GetAttribute("KnockbackResist")
        resist = tonumber(attr) or combatCfg.MobKnockbackResist or 0
        resist = math.clamp(resist, 0, 1)
        if resist >= 1 then return end -- fully immovable
    end
    local dir = vHRP.Position - aHRP.Position
    local flatDir = Vector3.new(dir.X, 0, dir.Z)
    if flatDir.Magnitude < 0.01 then
        local lv = aHRP.CFrame.LookVector
        flatDir = Vector3.new(lv.X, 0, lv.Z)
    end
    local hDir = flatDir.Unit
    local f = (force or combatCfg.KnockbackForce) * (1 - resist)
    local vx, vz = hDir.X * f, hDir.Z * f
    if lateralDir and lateralForce and lateralForce ~= 0 then
        local lat = Vector3.new(lateralDir.X, 0, lateralDir.Z)
        if lat.Magnitude > 0.01 then
            lat = lat.Unit
            local lf = lateralForce * (1 - resist) -- resistance applies to the sideways shove too
            vx += lat.X * lf
            vz += lat.Z * lf
        end
    end
    vHRP.AssemblyLinearVelocity = Vector3.new(vx, vHRP.AssemblyLinearVelocity.Y, vz)
end

-- Combat polish 4B: CombatStance flips true for 10s after this player is INVOLVED in a
-- landed hit (attacker or victim), then reverts to the neutral idle automatically. Token-
-- based (same pattern as RageManager's sleepingSince) so a fresh hit within the window
-- just extends it instead of stacking multiple pending reverts.
local function setCombatStance(player)
    local s = getPS(player); if not s then return end
    local token = tick()
    s.combatStanceToken = token
    local char = player.Character
    if char then char:SetAttribute("CombatStance", true) end
    task.delay(10, function()
        local cur = getPS(player)
        if cur and cur.combatStanceToken == token then
            local c2 = player.Character
            if c2 then c2:SetAttribute("CombatStance", false) end
        end
    end)
end

local function applyStagger(player, duration)
    local rm = _G.RageManager
    if rm and rm.isStaggerImmune(player) then return end
    local s = getPS(player); if not s then return end
    s.combatState = "Staggered"; setSpeed(player, combatCfg.SpeedStagger)
    RE_OnStagger:FireClient(player, {duration=duration})
    task.delay(duration, function()
        local cur = getPS(player)
        if cur and cur.combatState=="Staggered" then cur.combatState="Idle"; restoreSpeed(player) end
    end)
end

-- Refreshed on every hit landed OR received (see onHitLanded) so a fight can't be escaped
-- by just holding Sprint through an exchange -- cuts an already-active sprint immediately
-- and blocks starting a new one until the window lapses (checked in MovementManager.startSprint).
local function applySprintLock(player, duration)
    local s = getPS(player); if not s then return end
    s.sprintLockUntil = tick() + (duration or combatCfg.SprintLockDuration or 1.5)
    local mm = _G.MovementManager; if mm and mm.stopSprint then mm.stopSprint(player) end
end

local function applyHitstun(player, duration)
    local s = getPS(player); if not s then return end
    s.hitstunUntil = tick() + (duration or combatCfg.HitstunDuration)
    -- Taking a hit interrupts and resets the M1 chain — no resuming where you left off
    s.chainCount = 0; s.chainWindowUntil = 0
    -- Cancel any in-progress attack of THIS player's own (M1/M2/DownSlam/Sweep) -- bumping
    -- swingToken invalidates whatever pending windup coroutine below checks it before
    -- dealing damage, so getting hit mid-windup stops your own attack from still landing a
    -- moment later instead of resolving on schedule regardless.
    s.swingToken = (s.swingToken or 0) + 1
    s.isDownSlamming = false
    if s.isExecuting and s.executionTarget then
        local targetId = s.executionTarget
        s.isExecuting=false; s.executionTarget=nil; s.combatLocked=false; s.combatState="Idle"
        local tp = Players:GetPlayerByUserId(targetId)
        if tp then
            local ts = getPS(tp)
            if ts and ts.combatState=="BeingExecuted" then
                ts.combatState="Downed"
                local tc = tp.Character
                if tc then
                    local th=tc:FindFirstChildOfClass("Humanoid"); if th then th.Health=1 end
                    local rm=_G.RagdollManager; if rm then rm.ragdoll(tc,nil) end
                end
                RE_OnDowned:FireClient(tp,{survived=true})
                print("[CombatManager] Execution interrupted — "..tp.Name.." survives at 1 HP")
            end
        end
    end
    if s.airCritWindup then
        s.airCritWindup=false; s.combatLocked=false; s.combatState="Idle"
        removeWindupHighlight(player)
        applyStagger(player,1.0)
        print("[CombatManager] Air critical cancelled by hit — "..player.Name.." staggered")
    end
    if s.isCritting or s.isSweeping then
        s.isCritting=false; s.isSweeping=false; s.combatLocked=false; s.combatState="Idle"
    end
    removeWindupHighlight(player)
end

-- ── Blood Pool: grows under a downed player over ~60s, cleared on carry/execute/revive ──
local BLOOD_POOL_GROW_DURATION = 60
local BLOOD_POOL_START_RADIUS  = 0.6
local BLOOD_POOL_MAX_RADIUS    = 4

local function removeBloodPool(player)
    local s = getPS(player); if not s then return end
    if s.bloodPoolConn then s.bloodPoolConn:Disconnect(); s.bloodPoolConn=nil end
    if s.bloodPool then s.bloodPool:Destroy(); s.bloodPool=nil end
end

local function spawnBloodPool(player)
    local s = getPS(player); if not s then return end
    removeBloodPool(player)
    local char = player.Character; if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
    local rayParams = RaycastParams.new()
    rayParams.FilterDescendantsInstances = {char}
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    local result = workspace:Raycast(hrp.Position, Vector3.new(0,-12,0), rayParams)
    local groundPos = result and result.Position or (hrp.Position - Vector3.new(0,3,0))

    local pool = Instance.new("Part")
    pool.Name = "BloodPool"
    pool.Shape = Enum.PartType.Cylinder
    pool.Material = Enum.Material.SmoothPlastic
    pool.Color = Color3.fromRGB(90,8,8)
    pool.Anchored = true; pool.CanCollide = false; pool.CanQuery = false
    pool.Transparency = 0.35
    pool.Size = Vector3.new(0.05, BLOOD_POOL_START_RADIUS*2, BLOOD_POOL_START_RADIUS*2)
    pool.CFrame = CFrame.new(groundPos + Vector3.new(0,0.03,0)) * CFrame.Angles(0,0,math.rad(90))
    pool.Parent = workspace
    s.bloodPool = pool

    local startTick = tick()
    s.bloodPoolConn = RunService.Heartbeat:Connect(function()
        if not pool or not pool.Parent then return end
        local t = math.min(1, (tick()-startTick)/BLOOD_POOL_GROW_DURATION)
        local radius = BLOOD_POOL_START_RADIUS + (BLOOD_POOL_MAX_RADIUS-BLOOD_POOL_START_RADIUS)*t
        pool.Size = Vector3.new(0.05, radius*2, radius*2)
    end)
end

local function applyDownedState(player)
    local s = getPS(player); if not s then return end
    s.combatState="Downed"; s.chainCount=0; s.chainWindowUntil=0; s.endLagUntil=0
    local char=player.Character; if not char then return end
    local hum=char:FindFirstChildOfClass("Humanoid"); if not hum then return end
    hum.WalkSpeed=0; hum.JumpPower=0
    local rm=_G.RagdollManager; if rm then rm.ragdoll(char,Vector3.new(0,-10,0)) end
    RE_OnDowned:FireClient(player,{survived=false})
    task.delay(0.3, function() spawnBloodPool(player) end) -- let the ragdoll settle before placing the pool
    -- No automatic death: player stays Downed indefinitely until executed (B), revived by lore
    -- team, or self-recovers once StaminaManager's regen heals them past DOWNED_RECOVER_PCT
    -- (see recoverFromDowned below).
end

-- Natural get-up: called by StaminaManager once a Downed player's HP regen (which keeps
-- ticking while Downed, unlike Dead/BeingCarried/BeingExecuted) crosses the recovery
-- threshold. Restores movement/collision but leaves Health wherever it regenerated to --
-- this is a partial self-recovery, not a full lore-team revive.
local function recoverFromDowned(player)
    local s = getPS(player); if not s or s.combatState ~= "Downed" then return end
    s.combatState = "Idle"
    setSpeed(player, 1)
    removeBloodPool(player)
    local char = player.Character
    if char then
        local hum = char:FindFirstChildOfClass("Humanoid")
        if hum then hum.JumpPower = 50 end
        local rm = _G.RagdollManager; if rm then rm.unragdoll(char) end
    end
    RE_OnDowned:FireClient(player, {survived=true, selfRecovered=true})
    print(string.format("[CombatManager] %s recovered from Downed (self-healed)", player.Name))
end

-- ── Hit feedback: impact flash, blood burst ─────────────────────────
-- Hitstop was removed entirely per owner request (2026-07-18, combat polish 4A) -- hits are
-- now continuous with no freeze-frame. RE_Hitstop/Config.Hitstop are intentionally gone too,
-- see RemoteEvents/Config for the matching cleanup.
local Debris = game:GetService("Debris")
local HEAVY_TYPES = { M2=true, CritNormal=true, CritAir=true, Sweep=true, DownSlam=true }
local BLOOD_TIER  = { M1=0.8, M1Running=0.8, M1Aerial=0.8, M1Ender=1.1, DownSlam=1.4,
    M2=1.3, CritNormal=1.6, CritAir=1.6, Sweep=1.6 }

local function spawnBloodBurst(position, sizeMult)
    sizeMult = sizeMult or 1
    local anchor = Instance.new("Part")
    anchor.Name="BloodBurstFX"; anchor.Anchored=true; anchor.CanCollide=false; anchor.CanQuery=false
    anchor.Transparency=1; anchor.Size=Vector3.new(0.2,0.2,0.2)
    anchor.CFrame=CFrame.new(position); anchor.Parent=workspace
    local e = Instance.new("ParticleEmitter")
    e.Color = ColorSequence.new(Color3.fromRGB(120,10,10)) -- dark arterial red, not bright red
    e.Size = NumberSequence.new(0.35*sizeMult)
    e.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,0.1),NumberSequenceKeypoint.new(1,1)})
    e.Speed = NumberRange.new(4*sizeMult, 9*sizeMult)
    e.Lifetime = NumberRange.new(0.2, 0.4)
    e.SpreadAngle = Vector2.new(180,180)
    e.Rate = 0
    e.Parent = anchor
    e:Emit(math.max(4, math.floor(9*sizeMult)))
    Debris:AddItem(anchor, 0.6)
end

local function spawnImpactFlash(char)
    if not char then return end
    local hl = Instance.new("Highlight")
    hl.FillColor = Color3.new(1,1,1)
    hl.FillTransparency = 0.6
    hl.OutlineTransparency = 1
    hl.Parent = char
    Debris:AddItem(hl, 0.05) -- ~1 frame flash
end

-- Real authored VFX for parry/block, from workspace.VFX.combat -- built by hand per each
-- asset's own README (Parry: Shine emitters Emit(1), Shockwave Emit(5), Lines/BigLines
-- Emit(25); Block: everything Emit(50)). Falls back to nothing if the folder's missing
-- rather than erroring, same defensive style as everything else that reads _G managers.
local vfxCombatFolder = workspace:FindFirstChild("VFX") and workspace.VFX:FindFirstChild("combat")
local parryVFXSource = vfxCombatFolder and vfxCombatFolder:FindFirstChild("Parry")
local blockVFXSource = vfxCombatFolder and vfxCombatFolder:FindFirstChild("Block")
local hitVFXSource   = vfxCombatFolder and vfxCombatFolder:FindFirstChild("Hit")

-- These VFX packs follow a real per-emitter Attribute convention (matching the game's own
-- working "FirstAura" pattern): EmitDelay (stagger before firing), EmitCount (burst size),
-- EmitDuration (how long to ALSO run continuously via Enabled=true after the burst, letting
-- the emitter's own Rate keep replenishing short-lived particles so the effect reads for a
-- full window instead of vanishing with the first burst's ~0.03-0.34s Lifetime). Not every
-- emitter in every pack has all three Attributes (Block's plain "Lines" emitters have none;
-- Hit's have Delay/Count but no Duration) so each falls back safely when absent.
local function cloneAndEmitVFX(sourcePart, position, emitCounts, defaultCount, defaultDuration)
    if not sourcePart or not position then return end
    local sourceAttachment = sourcePart:FindFirstChildOfClass("Attachment")
    if not sourceAttachment then return end
    local anchor = Instance.new("Part")
    anchor.Name = sourcePart.Name .. "FX"; anchor.Anchored = true; anchor.CanCollide = false; anchor.CanQuery = false
    anchor.Transparency = 1; anchor.Size = Vector3.new(0.2, 0.2, 0.2)
    anchor.CFrame = CFrame.new(position); anchor.Parent = workspace
    local attachment = Instance.new("Attachment")
    attachment.Parent = anchor
    local maxCleanup = 0.5
    -- GetDescendants, not GetChildren: some VFX packs (e.g. the current Parry asset) nest
    -- their real emitters several Attachments deep (Attachment/Attachment1/Reverse) for
    -- organization -- a shallow scan silently skips all of those.
    for _, child in ipairs(sourceAttachment:GetDescendants()) do
        if child:IsA("ParticleEmitter") then
            local clone = child:Clone()
            clone.Enabled = false
            clone.Parent = attachment
            local delay = child:GetAttribute("EmitDelay") or 0
            -- Prefer the emitter's own authored EmitCount attribute over our guessed default --
            -- it's the actual designed burst size for that specific particle.
            local count = child:GetAttribute("EmitCount") or emitCounts[child.Name] or defaultCount
            local duration = child:GetAttribute("EmitDuration")
            if duration == nil then duration = defaultDuration end
            task.delay(delay, function()
                if not clone.Parent then return end
                clone:Emit(count)
                clone.Enabled = true
                task.delay(duration, function()
                    if clone then clone.Enabled = false end
                end)
            end)
            maxCleanup = math.max(maxCleanup, delay + duration + child.Lifetime.Max + 0.5)
        end
    end
    Debris:AddItem(anchor, maxCleanup)
end

-- Parry's live asset (many varied emitters nested a few Attachments deep) has no per-name
-- authored guidance like Block's README, so it just gets one modest uniform default --
-- with ~20+ distinct emitters a high per-emitter count would read as visual noise.
local function spawnParryVFX(position)
    cloneAndEmitVFX(parryVFXSource, position, {}, 8, 0.3)
end

local function spawnBlockVFX(position)
    cloneAndEmitVFX(blockVFXSource, position, {}, 50, 0.4)
end

-- Hit: flat set of ~12 impact emitters, no authored README -- uniform default same as the
-- other landed-hit feedback (blood burst/impact flash) it fires alongside in onHitLanded.
local function spawnHitVFX(position)
    cloneAndEmitVFX(hitVFXSource, position, {}, 12, 0.3)
end

-- Weapon clash sparks: parry success, block contact, clash trigger. No weapon geometry
-- exists in this codebase (hand/limb-based, matching MovementManager's particle convention).
local function spawnClashSpark(position)
    if not position then return end
    local anchor = Instance.new("Part")
    anchor.Name="ClashSparkFX"; anchor.Anchored=true; anchor.CanCollide=false; anchor.CanQuery=false
    anchor.Transparency=1; anchor.Size=Vector3.new(0.2,0.2,0.2)
    anchor.CFrame=CFrame.new(position); anchor.Parent=workspace

    local light = Instance.new("PointLight")
    light.Color = Color3.fromRGB(255,170,60)
    light.Brightness = 6
    light.Range = 10
    light.Parent = anchor

    local e = Instance.new("ParticleEmitter")
    e.Color = ColorSequence.new(Color3.fromRGB(255,190,80))
    e.Size = NumberSequence.new(0.25)
    e.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,0.05),NumberSequenceKeypoint.new(1,1)})
    e.Speed = NumberRange.new(8,16)
    e.Lifetime = NumberRange.new(0.1,0.25)
    e.SpreadAngle = Vector2.new(180,180)
    e.Rate = 0
    e.Parent = anchor
    e:Emit(14)

    Debris:AddItem(anchor, 0.2)
end

-- Layered hit sounds (Part Five): swing whoosh at swing start, impact + grunt on landed
-- hits, metal clang on blocked hits. Real 3D sounds parented to characters (not personal
-- 2D sounds) so nearby players hear combat too. Pitch randomized 0.92-1.08 per spec.
local function playSound3D(parent, volume, name)
    if not parent then return end
    local id = soundId(name)
    if not id then return end
    local snd = Instance.new("Sound")
    snd.SoundId = id
    snd.Volume = volume or 0.35
    snd.PlaybackSpeed = 0.92 + math.random()*0.16
    snd.Parent = parent
    snd:Play()
    -- Destroy once actually finished, not on a fixed timer -- a fixed Debris delay can
    -- destroy the instance before a slower-to-stream asset ever finishes (or even starts)
    -- playing, which is what read as combat sounds "sometimes not playing." The task.delay
    -- is only a safety net for sounds that never fire Ended (e.g. a failed/unauthorized load).
    local cleaned = false
    local function cleanup() if not cleaned then cleaned = true; if snd.Parent then snd:Destroy() end end end
    snd.Ended:Once(cleanup)
    task.delay(8, cleanup)
    return snd
end

-- Returns the Sound instance so callers can cut it short once the hit actually lands
-- (see onHitLanded) instead of letting the whoosh ring out over the impact sound.
local function playSwingWhoosh(attackerChar, name)
    local hrp = attackerChar and attackerChar:FindFirstChild("HumanoidRootPart")
    return playSound3D(hrp, 0.15, name)
end

-- Weapon Trails (Part Ten): no weapon geometry exists in this codebase (confirmed by
-- research), so the trail rides the Right Arm limb, matching MovementManager's existing
-- hand/limb-based particle convention. M1 thin/short/gray-white, M2 thicker/longer/red-
-- tinted, Crit red and most visible.
local TRAIL_CFG = {
    M1   = { color=Color3.fromRGB(220,220,220), width=0.25, lifetime=0.15, startTrans=0.35 },
    M2   = { color=Color3.fromRGB(200,60,40),   width=0.55, lifetime=0.35, startTrans=0.1 },
    Crit = { color=Color3.fromRGB(255,20,20),   width=0.8,  lifetime=0.45, startTrans=0 },
}

local function ensureWeaponTrail(char)
    local rArm = char and char:FindFirstChild("Right Arm"); if not rArm then return nil end
    local a0 = rArm:FindFirstChild("TrailA0")
    if not a0 then a0 = Instance.new("Attachment"); a0.Name="TrailA0"; a0.Position=Vector3.new(0,0.9,0); a0.Parent=rArm end
    local a1 = rArm:FindFirstChild("TrailA1")
    if not a1 then a1 = Instance.new("Attachment"); a1.Name="TrailA1"; a1.Position=Vector3.new(0,-0.9,0); a1.Parent=rArm end
    local trail = rArm:FindFirstChild("WeaponTrail")
    if not trail then
        trail = Instance.new("Trail")
        trail.Name="WeaponTrail"; trail.Attachment0=a0; trail.Attachment1=a1; trail.Enabled=false
        trail.Parent = rArm
    end
    return trail
end

local function flashWeaponTrail(char, kind, duration)
    local trail = ensureWeaponTrail(char); if not trail then return end
    local cfg = TRAIL_CFG[kind] or TRAIL_CFG.M1
    trail.Color = ColorSequence.new(cfg.color)
    trail.WidthScale = NumberSequence.new(cfg.width)
    trail.Lifetime = cfg.lifetime
    trail.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,cfg.startTrans),NumberSequenceKeypoint.new(1,1)})
    trail.Enabled = true
    task.delay(duration, function() if trail and trail.Parent then trail.Enabled=false end end)
end

local function playImpactAndGrunt(vc, name)
    local vHRP = vc and vc:FindFirstChild("HumanoidRootPart")
    if not vHRP then return end
    playSound3D(vHRP, 0.45, name)
end

-- Wall/Ground Impact (Part Eleven): dust burst + thud at a sharp knockback-velocity-drop
-- collision. Detection itself lives in StaminaManager's existing per-frame player loop
-- (avoids adding a second Heartbeat connection); this just spawns the effect.
local function spawnWallImpact(position)
    if not position then return end
    local anchor = Instance.new("Part")
    anchor.Name="WallImpactFX"; anchor.Anchored=true; anchor.CanCollide=false; anchor.CanQuery=false
    anchor.Transparency=1; anchor.Size=Vector3.new(0.2,0.2,0.2)
    anchor.CFrame=CFrame.new(position); anchor.Parent=workspace

    local e = Instance.new("ParticleEmitter")
    e.Color = ColorSequence.new(Color3.fromRGB(150,140,120)) -- dust
    e.Size = NumberSequence.new(0.6)
    e.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0,0.2),NumberSequenceKeypoint.new(1,1)})
    e.Speed = NumberRange.new(3,7)
    e.Lifetime = NumberRange.new(0.3,0.6)
    e.SpreadAngle = Vector2.new(180,180)
    e.Rate = 0
    e.Parent = anchor
    e:Emit(12)

    playSound3D(anchor, 0.6, "Wall_Thud")
    Debris:AddItem(anchor, 0.8)
end

-- Which Sounds/Combat entry to play on a landed hit, by attack type. M1/M1Running use
-- the chain-hit-number suffix (hitNum, 1-5) since the folder has one clip per combo hit.
local HIT_SOUND_BASE = {
    M1Ender   = "M1_Hit5",
    M2        = "M2_Hit",
    DownSlam  = "ground slam",
    CritNormal = "Critical_Impact",
    CritAir    = "Critical_Impact",
    Sweep      = "Critical_Impact",
}

local function hitSoundName(attackType, hitNum)
    if attackType == "M1" or attackType == "M1Running" then
        return "M1_Hit" .. math.clamp(hitNum or 1, 1, 5)
    end
    return HIT_SOUND_BASE[attackType]
end

-- Called right after applyDamage for every landed hit: spawns blood + flash + hitstop.
-- Returns (hitPosition, isHeavyHit) so callers can thread them into the OnHit payload.
local function onHitLanded(attacker, vp, vc, part, attackType, hitNum)
    -- Combat-tag the attacker too, not just the victim (applyDamage below already tags the
    -- victim via applyCombatTag) -- landing a hit should put YOU in combat as well, not just
    -- the person you hit. onHitLanded fires for every landed-hit type (M1/M2/crits/sweep/
    -- downslam), so this one call site covers all of them. Re-tagging on every hit naturally
    -- resets the 60s window each time, same as it already does for the victim.
    applyCombatTag(attacker, "Player")
    applySprintLock(attacker)
    setCombatStance(attacker)
    if vp then applySprintLock(vp); setCombatStance(vp) end
    -- Cut the attacker's still-ringing swing whoosh short the instant a hit actually lands,
    -- instead of letting it play out over the impact/grunt sound.
    local aS = getPS(attacker)
    if aS and aS.activeSwingSound then
        if aS.activeSwingSound.Parent then aS.activeSwingSound:Destroy() end
        aS.activeSwingSound = nil
    end
    local pos = (part and part.Position) or (vc:FindFirstChild("HumanoidRootPart") and vc.HumanoidRootPart.Position)
    if pos then spawnBloodBurst(pos, BLOOD_TIER[attackType] or 1) end
    if pos then spawnHitVFX(pos) end
    spawnImpactFlash(vc)
    playImpactAndGrunt(vc, hitSoundName(attackType, hitNum))
    -- Bleed system (Part Twelve): dagger/spear fighting styles apply a stacking bleed on
    -- landed hits; crits apply the heaviest tier regardless of weapon.
    if vp then
        local dm = _G.DataManager
        local bm = _G.BleedManager
        local style = dm and dm.getValue(attacker, "FightingStyle")
        if bm and style then
            local isCrit = attackType=="CritNormal" or attackType=="CritAir" or attackType=="Sweep"
            if isCrit and (style=="Dagger" or style=="Spear") then
                bm.applyBleed(vp, "Heavy")
            elseif style == "Dagger" then
                bm.applyBleed(vp, "Light")
            elseif style == "Spear" then
                bm.applyBleed(vp, "Medium")
            end
        end
    end
    return pos, HEAVY_TYPES[attackType] == true
end

local function applyDamage(humanoid, damage, victimPlayer, sourceTag)
    if victimPlayer then
        -- Godmode is real server-side immunity here, not just the mod menu's client-side
        -- HP-snap-back (which only ever fixed the LOCAL display -- the server's authoritative
        -- Health kept dropping from real combat hits and could still down/kill the player).
        local mm=_G.ModManager
        if mm and mm.isInvincible(victimPlayer) then return humanoid.Health end
        -- Deep-stage meditation: invulnerable, heavy-sleep-style (spec: "Player takes damage
        -- but does not die -- treated as heavy sleep"). Same early-return pattern as godmode.
        local medM=_G.MeditationManager
        if medM and medM.isDeepMeditating(victimPlayer) then return humanoid.Health end
        local s=getPS(victimPlayer)
        if s then
            local cs=s.combatState
            if cs=="Downed" or cs=="Dead" or cs=="BeingCarried" or cs=="BeingExecuted" then
                -- HP locked while downed/handled: absorb the hit entirely, never fall through to TakeDamage
                return humanoid.Health
            end
            if humanoid.Health-damage<=0 then
                humanoid.Health=1; applyDownedState(victimPlayer); applyCombatTag(victimPlayer,sourceTag); return 1
            end
        end
    end
    humanoid:TakeDamage(damage)
    if victimPlayer then applyCombatTag(victimPlayer,sourceTag) end
    return humanoid.Health
end

-- Routes a landed hit to whichever victim type actually owns it. applyDamage above only
-- ever understood Players (victimPlayer nil = bare TakeDamage, no downed-state/grip parity
-- at all) -- NPCManager owns that same parity for NPC Models, since NPCs aren't Players
-- and can't be keyed into applyDamage's player-only state lookups.
local function resolveVictimDamage(humanoid, damage, victimPlayer, victimChar, attacker, sourceTag)
    local rm = _G.RageManager
    if rm and attacker then damage = damage * rm.getDamageMult(attacker) end
    -- Talent compendium's generic AllDamageDealt/AllDamageTaken (GodsMistake, CursedMarkMinor,
    -- PacifistBlood, IronCovenant, ...) -- same one-more-multiplicative-factor pattern as
    -- RageManager just above. Per-attack-type talent modifiers (M1ChainEnderDamageMult,
    -- AerialM1DamageMult, etc.) are deliberately NOT wired here -- see TalentEffects' own
    -- comments; only the two universal keys are safe to fold into this single shared choke
    -- point without touching each of the ~6 separate M1/M2/aerial/sweep damage-calc call sites.
    local tm = _G.TalentManager
    if tm and attacker then damage = damage * tm.getDamageMultiplier(attacker) end
    if tm and victimPlayer then damage = damage * tm.getDamageTakenMultiplier(victimPlayer) end
    if victimPlayer then return applyDamage(humanoid, damage, victimPlayer, sourceTag) end
    local npcM = _G.NPCManager
    local npc = npcM and victimChar and npcM.getNPC(victimChar)
    if npc then return npcM.applyDamageToNPC(victimChar, damage, attacker, sourceTag) end
    return applyDamage(humanoid, damage, nil, sourceTag)
end

local function endChain(player)
    local s=getPS(player); if not s then return end
    s.chainCount=0; s.chainWindowUntil=0
    s.endLagUntil=tick()+combatCfg.M1EndLagDuration
    s.combatState="Idle"; restoreSpeed(player)
end

local function findDownedTarget(attacker, range)
    local char=attacker.Character; if not char then return nil end
    local hrp=char:FindFirstChild("HumanoidRootPart"); if not hrp then return nil end
    local best,bestDist=nil,range
    for _,p in ipairs(Players:GetPlayers()) do
        if p==attacker then continue end
        local ps=getPS(p); if not ps then continue end; local cs=ps.combatState; if cs~="Downed" and cs~="BeingCarried" then continue end
        local pc=p.Character; if not pc then continue end
        local ph=pc:FindFirstChild("HumanoidRootPart"); if not ph then continue end
        local dist=(ph.Position-hrp.Position).Magnitude
        if dist<bestDist then best=p; bestDist=dist end
    end
    return best
end

-- DownSlam impact FX: erupt a ring of rocks out of the ground around a point. Cosmetic,
-- unanchored so they scatter and settle, and Debris-cleaned so they never accumulate.
local function spawnSlamRocks(position)
    local Debris = game:GetService("Debris")
    local count = math.random(7, 10)
    for i = 1, count do
        local ang = (i / count) * math.pi * 2 + (math.random() - 0.5) * 0.5
        local dist = 1.8 + math.random() * 2.8 -- 1.8..4.6 studs from the victim
        local w = 0.7 + math.random() * 1.3
        local rock = Instance.new("Part")
        rock.Name = "SlamRock"
        rock.Size = Vector3.new(w, w * (0.9 + math.random() * 0.8), w)
        rock.CFrame = CFrame.new(position + Vector3.new(math.cos(ang) * dist, -0.4, math.sin(ang) * dist))
            * CFrame.Angles(math.rad(math.random(-40, 40)), math.rad(math.random(0, 360)), math.rad(math.random(-40, 40)))
        rock.Color = Color3.fromRGB(78 + math.random(0, 22), 72 + math.random(0, 18), 66 + math.random(0, 16))
        rock.Material = Enum.Material.Slate
        rock.Anchored = false
        rock.CanCollide = true
        rock.Parent = workspace
        rock.AssemblyLinearVelocity = Vector3.new(math.cos(ang) * math.random(4, 11), math.random(10, 20), math.sin(ang) * math.random(4, 11))
        Debris:AddItem(rock, 4)
    end
end

local function processM1(attacker)
    local s=getPS(attacker); if not s then return false end
    local _dm=_G.DataManager
    local _wpn=_dm and _dm.getValue(attacker,"EquippedWeapon")
    if not _wpn and not s.fistsEquipped then return false end
    local _bm=_G.BlockManager; if _bm and _bm.isBlocking(attacker) then return false end -- can't attack while blocking
    -- Fist M1s cost no stamina (see below), so they stay usable through exhaustion --
    -- only a weapon M1 should actually be gated by running out of stamina.
    if isActionBlocked(attacker, not _wpn) then return false end
    if s.isM2Swinging then return false end  -- M1 locked during active M2 swing
    if tick()<s.endLagUntil then return false end
    if tick()<(s.dashFeintRecoveryUntil or 0) then return false end -- brief no-attack window right after a dash feint
    -- Fist punches (no weapon equipped) cost no stamina; only weapon M1s drain it.
    if _wpn then
        local sm=_G.StaminaManager
        if not sm or not sm.drain(attacker,sm.Costs.CostM1,true) then return false end
    end
    local attackerChar=attacker.Character; if not attackerChar then return false end
    if isAirborne(attacker) then
        if not checkRateLimit(attacker,"AerialSlam") then return false end
        -- No forced downward velocity here anymore -- gravity alone carries the attacker
        -- down naturally during the windup (they're already airborne to trigger this), and
        -- checkHitboxDownSlam below finds the real ground via raycast regardless of exactly
        -- where the attacker's body has gotten to by the time the windup finishes. The old
        -- hard -120 stud/s BodyVelocity slam used to ram the character partway into terrain.
        s.combatState="Attacking"
        s.isDownSlamming=true
        local DOWNSLAM_WINDUP = 0.55 -- was 0.45: bumped for a more readable windup, matching M1/M2
        s.turnCapUntil=tick()+DOWNSLAM_WINDUP+0.15
        playSwingWhoosh(attackerChar)
        flashWeaponTrail(attackerChar,"Crit",DOWNSLAM_WINDUP)
        applyWindupHighlight(attacker) -- same red-outline windup tell M2 already uses -- DownSlam had no visual cue at all before this
        RE_PlayCombatAnim:FireClient(attacker,"DownSlam",1) -- overrides the client's default ground M1Attack guess (InputHandler predicts M1Attack on every M1 click, airborne or not)
        task.delay(DOWNSLAM_WINDUP,function()
            if not attacker.Character then removeWindupHighlight(attacker); return end
            local cur=getPS(attacker)
            if not cur or not cur.isDownSlamming then removeWindupHighlight(attacker); return end -- cancelled (e.g. hit) during the windup
            cur.isDownSlamming=false; cur.combatState="Idle"
            removeWindupHighlight(attacker)
            local dm=_G.DataManager
            local damage=getScaledValue(combatCfg.M1Damage,getStat(attacker,"Strength"),scalingCfg.StrengthPerPoint)*injuryDamageMult(attacker)*dnaDamageMult(attacker,"M1Damage")
            if dm and dm.getValue(attacker,"EquippedWeapon")==nil then damage=damage*combatCfg.FistDamageMultiplier end
            damage=damage*1.5  -- slam bonus
            local parts=checkHitboxDownSlam(attackerChar); local seen={}
            for _,part in ipairs(parts) do
                local vc=part:FindFirstAncestorOfClass("Model")
                if not vc or vc==attackerChar or seen[vc] then continue end; seen[vc]=true
                local hum=vc:FindFirstChildOfClass("Humanoid"); if not hum or hum.Health<=0 then continue end
                local vp=Players:GetPlayerFromCharacter(vc)
                if vp and dm and dm.getValue(vp,"PlayerState")=="Dead" then continue end
                if vp and hasIframes(vp) then continue end -- dashed/dash-feinted through the slam (airborne M1 variant)
                if vp then local parryM=_G.ParryManager; if parryM and parryM.checkHit(vp,attacker,"M1") then continue end
                else local npcM=_G.NPCManager; local npc=npcM and npcM.getNPC(vc); if npc and npcM.checkParry(npc,attacker,"M1") then continue end end
                -- Block does not protect vs downslam — goes straight to guard break
                local hpB=hum.Health
                local causedDowned = vp and damage >= hpB
                if vp and damage >= hpB then damage=math.max(0,hpB-1); task.spawn(applyDownedState,vp) end
                local hpA=resolveVictimDamage(hum,damage,vp,vc,attacker,"Player")
                local hitPos,isHeavy=onHitLanded(attacker,vp,vc,part,"DownSlam")
                local vHRP=vc:FindFirstChild("HumanoidRootPart")
                if vHRP and not vp then
                    -- non-player victim keeps the old upward pop
                    local sbv=Instance.new("BodyVelocity")
                    sbv.Name="SlamLaunch"; sbv.Velocity=Vector3.new(0,35,0)
                    sbv.MaxForce=Vector3.new(0,1e5,0); sbv.P=1e4; sbv.Parent=vHRP
                    game:GetService("Debris"):AddItem(sbv,0.2)
                end
                if vp then
                    -- Slammed into the dirt: ragdoll the victim IN PLACE and erupt a ring of rocks
                    -- around them (owner request). They pop back up when the ragdoll lapses, unless
                    -- the slam downed/killed them -- in which case the Downed/Dead state owns the
                    -- ragdoll and recovery instead, so we don't schedule an unragdoll over it.
                    spawnSlamRocks((vHRP and (vHRP.Position - Vector3.new(0, 2.5, 0))) or hitPos)
                    local rm=_G.RagdollManager
                    if rm and not causedDowned then
                        rm.ragdoll(vc, Vector3.new(0, -14, 0))
                        task.delay(1.7, function()
                            local cur=getPS(vp)
                            if cur and cur.combatState~="Downed" and cur.combatState~="BeingCarried" and cur.combatState~="Dead" then
                                rm.unragdoll(vc)
                            end
                        end)
                    end
                    applyHitstun(vp,1.2)
                    local postureM=_G.PostureManager; if postureM then postureM.triggerGuardBreak(vp) end
                    RE_PlayCombatAnim:FireClient(vp,"DownSlamGotHit",1)
                    RE_OnHit:FireClient(vp,{attackerName=attacker.Name,damage=damage,attackType="DownSlam",newHealth=hpA,hitPosition=hitPos,heavy=isHeavy,downed=causedDowned})
                end
                RE_OnHit:FireClient(attacker,{victimName=vc.Name,damage=damage,attackType="DownSlam",newHealth=hpA,hitPosition=hitPos,heavy=isHeavy,downed=causedDowned})
                print(string.format("[CombatManager] %s->%s DownSlam dmg=%.0f HP %.0f->%.0f",attacker.Name,vc.Name,damage,hpB,hpA))
            end
        end)
        return true
    end
    -- M1 fire rate is locked to CD.M1 (the swing rhythm), not to click speed — gating/buffering
    -- happens in the requestM1() wrapper below, not here.
    local boxKey,knockForce,variant
    local now=tick()
    if s.isSprinting then
        variant="M1Running"; boxKey="M1Running"; knockForce=combatCfg.KnockbackRunningM1
        s.combatState="Attacking"
        s.activeSwingSound = playSwingWhoosh(attackerChar, "M1_Swing_1")
        flashWeaponTrail(attackerChar,"M1",0.3)
        s.lastSwingTick=now
        local hrp=attackerChar:FindFirstChild("HumanoidRootPart")
        if hrp then
            local lv=hrp.CFrame.LookVector
            local hDir=Vector3.new(lv.X,0,lv.Z).Unit
            hrp.AssemblyLinearVelocity=Vector3.new(hDir.X*20,0,hDir.Z*20)
        end
        local _mm2=_G.MovementManager; if _mm2 then _mm2.stopSprint(attacker) end
    else
        variant="M1"; boxKey="M1"; knockForce=combatCfg.KnockbackForce
        -- Chain resets to hit 1 after ChainResetTime(2s) of no M1, or when hit (see applyHitstun)
        s.chainCount=(now<=s.chainWindowUntil) and math.min(s.chainCount+1,combatCfg.M1ChainMax) or 1
        s.chainWindowUntil=now+combatCfg.ChainResetTime
        setSpeed(attacker,combatCfg.SpeedM1Chain); s.combatState="Attacking"
        s.activeSwingSound = playSwingWhoosh(attackerChar, "M1_Swing_" .. math.random(1, 3))
        flashWeaponTrail(attackerChar,"M1",0.3)
        s.lastSwingTick=now; local ct=now
        task.delay(CD.M1-0.05,function() local cur=getPS(attacker); if cur and cur.lastSwingTick==ct then restoreSpeed(attacker) end end)
    end
    -- combatState otherwise only ever reverts to "Idle" via a full 5-hit chain
    -- (endChain) or an interrupt (getting hit, etc.) -- if a player throws one M1
    -- and simply stops, it was staying stuck on "Attacking" forever. That silently
    -- broke anything driven off the Idle<->Attacking transition (e.g. the client's
    -- attack-facing turn cap only re-engages on a fresh transition into Attacking,
    -- so once stuck it would never fire again for the rest of the session). Revert
    -- to Idle once the chain window lapses with no newer swing.
    do
        local thisSwingTick = now
        task.delay(combatCfg.ChainResetTime, function()
            local cur = getPS(attacker)
            if cur and cur.lastSwingTick == thisSwingTick and cur.combatState == "Attacking" then
                cur.chainCount = 0; cur.chainWindowUntil = 0
                cur.combatState = "Idle"
                restoreSpeed(attacker)
            end
        end)
    end
    local dm=_G.DataManager
    local damage=getScaledValue(combatCfg.M1Damage,getStat(attacker,"Strength"),scalingCfg.StrengthPerPoint)*injuryDamageMult(attacker)*dnaDamageMult(attacker,"M1Damage")
    if dm and dm.getValue(attacker,"EquippedWeapon")==nil then damage=damage*combatCfg.FistDamageMultiplier end
    local isEnder = variant=="M1" and s.chainCount==combatCfg.M1ChainMax
    if isEnder then damage=damage*combatCfg.M1EnderDamageMultiplier end
    -- Hitbox becomes active once the punch actually reaches forward, not at swing start, and
    -- stays live for a short window instead of one frozen instant. A single-frame check either
    -- whiffs or lands based on exactly where attacker/target happened to be that one tick --
    -- that's what read as "the hitbox is behind me" when either side keeps walking mid-swing.
    local startupDelay = (s.chainCount<=1) and (combatCfg.M1Startup/60) or 0.34 -- bumped from 0.28: chain hits' hitbox was activating too quickly
    local HITBOX_WINDOW = 0.12
    -- Turn-cap only lasts through this swing's own active window (startup + hitbox + a
    -- brief recovery), not the full combatState=="Attacking" duration -- that stays
    -- "Attacking" until the entire chain times out (up to ChainResetTime, 2s), which used
    -- to keep turning capped for up to 2s after a single swing with no follow-up ("you
    -- don't turn after you hit someone"). Re-clicking to continue a combo keeps pushing
    -- this forward each swing, so a real combo still stays capped throughout.
    s.turnCapUntil = now + startupDelay + HITBOX_WINDOW + 0.15
    -- Feint window: M2 pressed before the hitbox actually activates cancels this swing
    -- (see processFeint/processM2 below) -- only good for this one swing, invalidated by
    -- swingToken if a newer swing starts or this one gets feinted first.
    s.swingToken = (s.swingToken or 0) + 1
    local mySwingToken = s.swingToken
    s.m1FeintWindowUntil = now + startupDelay
    task.spawn(function()
        task.wait(startupDelay)
        if not attacker.Character then return end
        if s.swingToken ~= mySwingToken then return end -- feinted before the hitbox ever activated
        local seen={}
        local windowStart = tick()
        while attacker.Character and tick()-windowStart < HITBOX_WINDOW do
        local parts=checkHitbox(attackerChar,boxKey)
        for _,part in ipairs(parts) do
            local vc=part:FindFirstAncestorOfClass("Model")
            if not vc or vc==attackerChar or seen[vc] then continue end
            seen[vc]=true
            local hum=vc:FindFirstChildOfClass("Humanoid")
            if not hum or hum.Health<=0 then continue end
            local vp=Players:GetPlayerFromCharacter(vc)
            if vp and dm and dm.getValue(vp,"PlayerState")=="Dead" then continue end
            if vp and hasIframes(vp) then continue end -- dashed/dash-feinted through the swing
            -- Parry interception
            if vp then
                local parryM=_G.ParryManager
                if parryM and parryM.checkHit(vp,attacker,"M1") then
                    RE_PlayCombatAnim:FireClient(attacker,"M1Parried",s.chainCount)
                    if vp then RE_PlayCombatAnim:FireClient(vp,"M1Parry",s.chainCount) end
                    continue
                end
            elseif vc then
                local npcM=_G.NPCManager; local npc=npcM and npcM.getNPC(vc)
                if npc and npcM.checkParry(npc,attacker,"M1") then
                    RE_PlayCombatAnim:FireClient(attacker,"M1Parried",s.chainCount)
                    continue
                end
            end
            -- Block absorption (M1 only; M2 bypasses; shaky block leaks 40%)
            if vp then
                local blockM=_G.BlockManager
                local bResult = blockM and blockM.checkHit(vp,attacker,"M1")
                if bResult == true then continue end
                if type(bResult)=="number" then damage=damage*bResult end
            elseif vc then
                local npcM2=_G.NPCManager; local npc2=npcM2 and npcM2.getNPC(vc)
                if npc2 and npcM2.checkBlock(npc2,attacker,"M1") then continue end
            end
            local hpB=hum.Health
            -- M1 cannot kill — downed state instead
            local causedDowned = vp and damage >= hpB
            if vp and damage >= hpB then damage=math.max(0,hpB-1); task.spawn(applyDownedState,vp) end
            local hpA=resolveVictimDamage(hum,damage,vp,vc,attacker,"Player")
            local aType = isEnder and "M1Ender" or variant
            local hitPos,isHeavy=onHitLanded(attacker,vp,vc,part,aType,s.chainCount)
            if isEnder then
                local vHRP = vc:FindFirstChild("HumanoidRootPart")
                local aHRP = attackerChar:FindFirstChild("HumanoidRootPart")
                if vHRP and aHRP then
                    local flat = Vector3.new(vHRP.Position.X-aHRP.Position.X, 0, vHRP.Position.Z-aHRP.Position.Z)
                    if flat.Magnitude < 0.01 then flat = aHRP.CFrame.LookVector end
                    local hDir = flat.Unit
                    local bv = Instance.new("BodyVelocity")
                    bv.Name = "EnderKnockback"
                    bv.Velocity = Vector3.new(hDir.X*80, 28, hDir.Z*80)
                    bv.MaxForce = Vector3.new(1e5, 1e5, 1e5)
                    bv.P = 1e4
                    bv.Parent = vHRP
                    game:GetService("Debris"):AddItem(bv, 0.2)
                end
            else
                applyKnockback(attackerChar, vc, knockForce)
            end
            if vp then
                applyHitstun(vp)
                if vp then RE_PlayCombatAnim:FireClient(vp,"M1GotHit",s.chainCount) end
                RE_OnHit:FireClient(vp,{attackerName=attacker.Name,damage=damage,attackType=aType,newHealth=hpA,hitPosition=hitPos,heavy=isHeavy,downed=causedDowned})
            elseif vc then
                -- NPC victim has no client to play its own GotHit reaction, so the server
                -- drives its Animator directly here -- mirrors the vp branch above exactly.
                local npcM3=_G.NPCManager; local npc3=npcM3 and npcM3.getNPC(vc)
                if npc3 then npcM3.playAnim(vc,"M1GotHit",s.chainCount) end
            end
            RE_OnHit:FireClient(attacker,{victimName=vc.Name,damage=damage,attackType=aType,newHealth=hpA,hitPosition=hitPos,heavy=isHeavy,downed=causedDowned})
            print(string.format("[CombatManager] %s->%s %s dmg=%.0f HP %.0f->%.0f",attacker.Name,vc.Name,aType,damage,hpB,hpA))
        end
        task.wait()
        end
        if variant=="M1" and s.chainCount>=combatCfg.M1ChainMax then
            task.delay(0.15,function() endChain(attacker) end)
        end
    end)
    return true
end

-- Feint: M2 pressed during the just-thrown M1's pre-hitbox startup window cancels that
-- swing instead of firing an M2 of its own. Invalidates the in-flight hitbox coroutine via
-- swingToken (same invalidate-by-token pattern as MovementController's landingToken/
-- jumpToken), rolls back the chain-count increment that swing made (it never actually
-- landed/committed), and restores full movement speed immediately instead of waiting out
-- the swing's own slowdown.
local function processFeint(attacker, s)
    if not checkRateLimit(attacker, "Feint") then return end
    local sm = _G.StaminaManager
    if not sm or not sm.drain(attacker, combatCfg.CostFeint or 4, true) then return end
    s.swingToken = (s.swingToken or 0) + 1
    s.m1FeintWindowUntil = 0
    s.chainCount = math.max(0, s.chainCount - 1)
    s.combatState = "Idle"
    restoreSpeed(attacker)
    local attackerChar = attacker.Character
    if attackerChar then playSwingWhoosh(attackerChar, "Feint") end
    RE_PlayCombatAnim:FireClient(attacker, "Feint", s.chainCount)
    print(string.format("[CombatManager] %s feinted M1 (chain now %d)", attacker.Name, s.chainCount))
end

local function processM2(attacker)
    local s=getPS(attacker); if not s then return end
    if isActionBlocked(attacker) then return end
    local mm=_G.MovementManager
    if mm and mm.isSliding and mm.isSliding(attacker) then return end -- M2 is not usable while sliding (mirrors M1's rule)
    -- Only works in that first sliver of time before the hitbox activates -- once the
    -- window passes, M2 just follows the normal "blocked while an M1 chain is active" rule
    -- below like always.
    if tick() < (s.m1FeintWindowUntil or 0) then
        processFeint(attacker, s)
        return
    end
    if s.chainCount>0 and tick()<s.chainWindowUntil then return end  -- ignore M2 while M1 chain is active
    if tick()<(s.dashFeintRecoveryUntil or 0) then return end -- brief no-attack window right after a dash feint
    if not checkRateLimit(attacker,"M2") then return end
    local sm=_G.StaminaManager; if not sm then return end
    if not sm.drain(attacker,sm.Costs.CostM2,true) then return end
    local attackerChar=attacker.Character; if not attackerChar then return end
    s.combatState="Attacking"; s.isM2Swinging=true; s.turnCapUntil=tick()+combatCfg.M2SwingDuration; setSpeed(attacker,combatCfg.SpeedM2Swing)
    -- Invalidated by applyHitstun if the attacker takes damage before the hitbox resolves --
    -- getting hit mid-windup should cancel the swing, not let it still land on schedule.
    s.swingToken = (s.swingToken or 0) + 1
    local myM2Token = s.swingToken
    if mm and mm.stopSprint then mm.stopSprint(attacker) end
    applyWindupHighlight(attacker)
    playSwingWhoosh(attackerChar, "M2_Swing")
    flashWeaponTrail(attackerChar,"M2",combatCfg.M2SwingDuration)
    if _G.ClashManager then _G.ClashManager.registerM2Swing(attacker) end
    task.delay(combatCfg.M2SwingDuration,function()
        local cur=getPS(attacker)
        if cur then
            if cur.combatState=="Attacking" then cur.combatState="Idle"; restoreSpeed(attacker) end
            cur.isM2Swinging=false  -- always clear regardless of how swing ended
        end
        removeWindupHighlight(attacker)
    end)
    local dm=_G.DataManager
    local damage=getScaledValue(combatCfg.M2Damage,getStat(attacker,"Strength"),scalingCfg.StrengthPerPoint)*injuryDamageMult(attacker)*dnaDamageMult(attacker,"M2Damage")
    if dm and dm.getValue(attacker,"EquippedWeapon")==nil then damage=damage*combatCfg.FistDamageMultiplier end
    -- Hitbox activates after a real windup instead of on the same frame as the input --
    -- previously M2 had NO startup delay at all (hit landed the instant it was thrown),
    -- making it effectively impossible to react to or parry. Mirrors M1's windowed-check
    -- pattern below (position checked once the swing actually arrives, held open briefly,
    -- rather than a single frozen instant that whiffs/lands based on one exact tick).
    local startupDelay = combatCfg.M2Startup/60
    local HITBOX_WINDOW = 0.12
    task.spawn(function()
        task.wait(startupDelay)
        if not attacker.Character then return end
        if s.swingToken ~= myM2Token then return end -- cancelled (e.g. hit) during the windup
        local seen={}
        local windowStart = tick()
        while attacker.Character and tick()-windowStart < HITBOX_WINDOW do
        local parts=checkHitbox(attackerChar,"M2")
        for _,part in ipairs(parts) do
            local vc=part:FindFirstAncestorOfClass("Model")
            if not vc or vc==attackerChar or seen[vc] then continue end
            seen[vc]=true
            local hum=vc:FindFirstChildOfClass("Humanoid")
            if not hum or hum.Health<=0 then continue end
            local vp=Players:GetPlayerFromCharacter(vc)
            if vp and dm and dm.getValue(vp,"PlayerState")=="Dead" then continue end
            if vp and hasIframes(vp) then continue end -- dashed/dash-feinted through the swing
            -- Clash: simultaneous M2
            if vp then
                local clashM=_G.ClashManager
                if clashM and clashM.checkClash(attacker,vp) then continue end
            end

            -- Parry Break: let ParryManager handle M2 into active parry
            if vp then
                local parryM=_G.ParryManager
                if parryM and parryM.checkHit(vp,attacker,"M2") then continue end
            elseif vc then
                local npcM=_G.NPCManager; local npc=npcM and npcM.getNPC(vc)
                if npc and npcM.checkParry(npc,attacker,"M2") then continue end
            end
            local hpB=hum.Health
            local causedDowned = vp and (hpB-damage)<=0
            local hpA=resolveVictimDamage(hum,damage,vp,vc,attacker,"Player")
            local hitPos,isHeavy=onHitLanded(attacker,vp,vc,part,"M2")
            applyKnockback(attackerChar,vc,combatCfg.KnockbackForce)
            if vp then
                applyHitstun(vp)
                -- M2 actually breaks an active block now instead of silently bypassing it --
                -- previously triggerGuardBreak fired unconditionally on every M2 hit, even
                -- against players who weren't blocking at all, so it never read as a real
                -- consequence of blocking. Now it's gated on the victim actually blocking.
                local blockM=_G.BlockManager
                if blockM and blockM.isBlocking(vp) then
                    if blockM.endBlock then blockM.endBlock(vp) end
                    local _pm=_G.PostureManager; if _pm then _pm.triggerGuardBreak(vp) end
                end
                RE_OnHit:FireClient(vp,{attackerName=attacker.Name,damage=damage,attackType="M2",newHealth=hpA,hitPosition=hitPos,heavy=isHeavy,downed=causedDowned})
            end
            RE_OnHit:FireClient(attacker,{victimName=vc.Name,damage=damage,attackType="M2",newHealth=hpA,hitPosition=hitPos,heavy=isHeavy,downed=causedDowned})
            print(string.format("[CombatManager] %s->%s M2 dmg=%.0f HP %.0f->%.0f",attacker.Name,vc.Name,damage,hpB,hpA))
        end
        task.wait()
        end
    end)
end

local function processExecute(attacker)
    local s=getPS(attacker); if not s then return end
    if isActionBlocked(attacker) then return end
    local target=findDownedTarget(attacker,combatCfg.ExecuteRange); if not target then return end
    local ts=getPS(target); if not ts then return end
    s.isExecuting=true; s.executionTarget=target.UserId; s.combatLocked=true; s.combatState="Executing"
    ts.combatState="BeingExecuted"
    local aC=attacker.Character; local tC=target.Character
    if aC and tC then
        local rm=_G.RagdollManager; if rm then rm.unragdoll(tC) end
        local th2=tC:FindFirstChildOfClass("Humanoid"); if th2 then th2.PlatformStand=true end
        local aHRP=aC:FindFirstChild("HumanoidRootPart"); local tHRP=tC:FindFirstChild("HumanoidRootPart")
        if aHRP and tHRP then tHRP.CFrame=aHRP.CFrame*CFrame.new(0,0,-2); tHRP.AssemblyLinearVelocity=Vector3.zero end
    end
    -- PLACEHOLDER_ANIMATION: execution — replace with actual AnimationId
    print("[CombatManager] "..attacker.Name.." executing "..target.Name)
    task.delay(EXECUTE_ANIM_TIME,function()
        local cur=getPS(attacker)
        if not cur or not cur.isExecuting then return end
        cur.isExecuting=false; cur.executionTarget=nil; cur.combatLocked=false; cur.combatState="Idle"
        local tcc=getPS(target); if tcc then tcc.combatState="Dead" end
        local deathPos = target.Character and target.Character:FindFirstChild("HumanoidRootPart") and target.Character.HumanoidRootPart.Position
        removeBloodPool(target)
        local tc=target.Character
        if tc then
            local tHRP=tc:FindFirstChild("HumanoidRootPart")
            if tHRP then playSound3D(tHRP, 0.7, "Execute") end
            local ac=attacker.Character
            local impulse=ac and ac:FindFirstChild("HumanoidRootPart")
                and (ac.HumanoidRootPart.CFrame.LookVector*15+Vector3.new(0,8,0)) or nil
            local rm=_G.RagdollManager; if rm then rm.applyDeathRagdoll(tc,impulse) end
        end
        -- Sanity/Ally/Feelings fallout (design doc PARTS ONE/FOUR/FIVE) -- a grip execution
        -- is this game's real "kill" mechanic, so this is the one true hook for it.
        if deathPos then
            local sanM=_G.SanityManager
            if sanM then sanM.notifyWitnessDeath(deathPos, true, {[attacker]=true,[target]=true}) end
        end
        local allyM=_G.AllyManager
        if allyM then allyM.onPlayerKilled(attacker, target) end
        print("[CombatManager] "..attacker.Name.." execution complete -> "..target.Name.." killed")
    end)
end

local function dropCarried(carrier)
    local s=getPS(carrier); if not s or not s.carryingPlayer then return end
    local cid=s.carryingPlayer; s.carryingPlayer=nil; s.combatLocked=false; restoreSpeed(carrier)
    if carrier.Character then carrier.Character:SetAttribute("IsCarrying", false) end
    local carried=Players:GetPlayerByUserId(cid)
    if carried then
        local cs=getPS(carried)
        if cs then cs.beingCarriedBy=nil; cs.combatState="Downed" end
        local tc=carried.Character
        if tc then
            local thrp=tc:FindFirstChild("HumanoidRootPart")
            if thrp then local w=thrp:FindFirstChild("CarryWeld"); if w then w:Destroy() end end
            local rm=_G.RagdollManager; if rm then rm.ragdoll(tc,nil) end
        end
        task.delay(0.3, function() spawnBloodPool(carried) end) -- resumes bleeding out where dropped
    end
    print("[CombatManager] "..carrier.Name.." dropped carried player")
end

local function processCarry(attacker)
    local s=getPS(attacker); if not s then return end
    if s.carryingPlayer then dropCarried(attacker); return end
    if isActionBlocked(attacker) then return end
    local target=findDownedTarget(attacker,combatCfg.CarryRange); if not target then return end
    local ts=getPS(target); if not ts then return end
    s.carryingPlayer=target.UserId; s.combatLocked=true; setSpeed(attacker,combatCfg.SpeedCarrying)
    ts.beingCarriedBy=attacker.UserId; ts.combatState="BeingCarried"
    -- Mirrors CombatState/CrouchActive's replication pattern -- the carrier's own combatState
    -- stays "Idle" (only combatLocked flips), so client scripts that need to know "is this
    -- player currently carrying someone" (e.g. EmoteWheelClient's wheel-open gate) need a
    -- dedicated signal instead of reading CombatState.
    if attacker.Character then attacker.Character:SetAttribute("IsCarrying", true) end
    removeBloodPool(target) -- paused while slung over a carrier's shoulder
    local aC=attacker.Character; local tC=target.Character
    if aC and tC then
        local aH=aC:FindFirstChild("HumanoidRootPart"); local tH=tC:FindFirstChild("HumanoidRootPart")
        if aH and tH then
            local rm=_G.RagdollManager; if rm then rm.unragdoll(tC) end
            local th=tC:FindFirstChildOfClass("Humanoid"); if th then th.PlatformStand=true end
            -- PLACEHOLDER_ANIMATION: carried_limp — replace with actual AnimationId
            local w=Instance.new("Weld"); w.Name="CarryWeld"; w.Part0=aH; w.Part1=tH
            w.C0=CFrame.new(1.5,0,0); w.C1=CFrame.new(); w.Parent=tH
        end
    end
    print("[CombatManager] "..attacker.Name.." picked up "..target.Name)
end

local function processNormalCritical(attacker)
    local s=getPS(attacker); if not s then return end
    if isActionBlocked(attacker) then return end
    if not checkRateLimit(attacker,"Critical") then return end
    local attackerChar=attacker.Character; if not attackerChar then return end
    local aHRP=attackerChar:FindFirstChild("HumanoidRootPart"); if not aHRP then return end
    local CRIT_RANGE=6; local bestTarget,bestDist=nil,CRIT_RANGE
    for _,p in ipairs(Players:GetPlayers()) do
        if p==attacker then continue end
        local ps=getPS(p); if not ps then continue end; local cs=ps.combatState
        if cs~="GuardBroken" and cs~="Staggered" and cs~="Downed" then continue end
        local pc=p.Character; if not pc then continue end
        local ph=pc:FindFirstChild("HumanoidRootPart"); if not ph then continue end
        local dist=(ph.Position-aHRP.Position).Magnitude
        if dist<bestDist then bestTarget=p; bestDist=dist end
    end
    if not bestTarget then return end
    s.isCritting=true; s.combatLocked=true; s.combatState="Attacking"; s.turnCapUntil=tick()+1.0+0.1
    applyWindupHighlight(attacker)
    flashWeaponTrail(attackerChar,"Crit",1.0)
    -- PLACEHOLDER_ANIMATION: critical_normal -- replace with actual AnimationId
    -- Hitbox fires on animation Hit marker (fallback 1.0s)
    local animObj = ANIMS and ANIMS.Combat:FindFirstChild("Critical_Normal")
    playAndWaitForHit(attackerChar, animObj, 1.0, function()
        local cur=getPS(attacker); if not cur or not cur.isCritting then return end
        cur.isCritting=false; cur.combatLocked=false; cur.combatState="Idle"
        removeWindupHighlight(attacker)
        local tC=bestTarget.Character; if not tC then return end
        local tH=tC:FindFirstChildOfClass("Humanoid"); if not tH or tH.Health<=0 then return end
        if hasIframes(bestTarget) then return end -- dashed away during the windup
        local tS=getPS(bestTarget); local tm=_G.TraitManager
        local isRiposte=tm and tm.hasTrait and tm.hasTrait(attacker,"Riposte") and (tS and tS.combatState=="GuardBroken")
        local scaledM1=getScaledValue(combatCfg.M1Damage,getStat(attacker,"Strength"),scalingCfg.StrengthPerPoint)*injuryDamageMult(attacker)*dnaDamageMult(attacker,"M1Damage")
        local damage=isRiposte and (scaledM1*4) or (scaledM1*3)
        local dm=_G.DataManager
        if dm and dm.getValue(attacker,"EquippedWeapon")==nil then damage=damage*combatCfg.FistDamageMultiplier end
        local hpB=tH.Health
        local causedDowned = (hpB-damage)<=0
        local hpA=applyDamage(tH,damage,bestTarget,"Player")
        local hitPos,isHeavy=onHitLanded(attacker,bestTarget,tC,nil,"CritNormal")
        applyKnockback(attackerChar,tC,combatCfg.KnockbackForce); applyHitstun(bestTarget)
        RE_OnHit:FireClient(bestTarget,{attackerName=attacker.Name,damage=damage,attackType="CritNormal",newHealth=hpA,hitPosition=hitPos,heavy=isHeavy,downed=causedDowned})
        RE_OnHit:FireClient(attacker,  {victimName=bestTarget.Name, damage=damage,attackType="CritNormal",newHealth=hpA,hitPosition=hitPos,heavy=isHeavy,downed=causedDowned})
        print(string.format("[CombatManager] %s NORMAL CRIT(marker)->%s dmg=%.0f HP %.0f->%.0f%s",
            attacker.Name,bestTarget.Name,damage,hpB,hpA,isRiposte and " [RIPOSTE]" or ""))
    end)
end

local function processAirCritical(attacker)
    local s=getPS(attacker); if not s then return end
    if isActionBlocked(attacker) then return end
    if not checkRateLimit(attacker,"Critical") then return end
    local attackerChar=attacker.Character; if not attackerChar then return end
    s.airCritWindup=true; s.combatLocked=true; s.combatState="Attacking"; s.turnCapUntil=tick()+0.55+0.1
    applyWindupHighlight(attacker)
    flashWeaponTrail(attackerChar,"Crit",0.55)
    -- PLACEHOLDER_ANIMATION: critical_air -- replace with actual AnimationId
    -- Hitbox fires on Hit marker (fallback 0.55s); lunge applied at that same moment
    local animObj = ANIMS and ANIMS.Combat:FindFirstChild("Critical_Air")
    playAndWaitForHit(attackerChar, animObj, 0.55, function()
        local cur=getPS(attacker); if not cur or not cur.airCritWindup then return end
        cur.airCritWindup=false; cur.combatLocked=false; cur.combatState="Idle"
        removeWindupHighlight(attacker)
        local hrp=attackerChar:FindFirstChild("HumanoidRootPart")
        if hrp then
            local flat=Vector3.new(hrp.CFrame.LookVector.X,0,hrp.CFrame.LookVector.Z)
            if flat.Magnitude>0.01 then
                local bv=Instance.new("BodyVelocity")
                bv.Name="AerialLungeVelocity"
                bv.Velocity=flat.Unit*34
                bv.MaxForce=Vector3.new(65000,0,65000)
                bv.P=45000
                bv.Parent=hrp
                task.delay(0.2,function() if bv and bv.Parent then bv:Destroy() end end)
            end
        end
        local dm=_G.DataManager; local damage=getScaledValue(combatCfg.M1Damage,getStat(attacker,"Strength"),scalingCfg.StrengthPerPoint)*2*injuryDamageMult(attacker)*dnaDamageMult(attacker,"M1Damage")
        if dm and dm.getValue(attacker,"EquippedWeapon")==nil then damage=damage*combatCfg.FistDamageMultiplier end
        local parts=checkHitbox(attackerChar,"M1Aerial"); local seen={}
        for _,part in ipairs(parts) do
            local vc=part:FindFirstAncestorOfClass("Model")
            if not vc or vc==attackerChar or seen[vc] then continue end; seen[vc]=true
            local hum=vc:FindFirstChildOfClass("Humanoid"); if not hum or hum.Health<=0 then continue end
            local vp=Players:GetPlayerFromCharacter(vc)
            if vp and dm and dm.getValue(vp,"PlayerState")=="Dead" then continue end
            local hpB=hum.Health
            local causedDowned = vp and (hpB-damage)<=0
            local hpA=resolveVictimDamage(hum,damage,vp,vc,attacker,"Player")
            local hitPos,isHeavy=onHitLanded(attacker,vp,vc,part,"CritAir")
            applyKnockback(attackerChar,vc,combatCfg.KnockbackForce)
            if vp then
                applyHitstun(vp)
                RE_OnHit:FireClient(vp,{attackerName=attacker.Name,damage=damage,attackType="CritAir",newHealth=hpA,hitPosition=hitPos,heavy=isHeavy,downed=causedDowned})
            end
            RE_OnHit:FireClient(attacker,{victimName=vc.Name,damage=damage,attackType="CritAir",newHealth=hpA,hitPosition=hitPos,heavy=isHeavy,downed=causedDowned})
            print(string.format("[CombatManager] %s AIR CRIT(marker)->%s dmg=%.0f HP %.0f->%.0f",attacker.Name,vc.Name,damage,hpB,hpA))
        end
    end)
end

-- NOTE: Ctrl is a placeholder binding -- reassign when crouch/slide claims Ctrl
local function processSweepCritical(attacker)
    local s=getPS(attacker); if not s then return end
    -- Same rule processM2 already follows: refuse while an M1 chain/swing is still active.
    -- This was missing here, which let Sweep be thrown mid-M1-swing (regular M1 never sets
    -- combatLocked, only combatState="Attacking", and isActionBlocked doesn't treat
    -- "Attacking" as blocking) -- its own hitbox/turn-cap/combatLocked would then stack on
    -- top of the still-resolving M1 swing instead of waiting for it to finish.
    if s.chainCount>0 and tick()<s.chainWindowUntil then return end
    if isActionBlocked(attacker) then return end
    if not checkRateLimit(attacker,"M1") then return end
    local sm=_G.StaminaManager
    if not sm or not sm.drain(attacker,sm.Costs.CostM1,true) then return end
    local attackerChar=attacker.Character; if not attackerChar then return end
    s.isSweeping=true; s.combatLocked=true; s.combatState="Attacking"; s.turnCapUntil=tick()+0.5+0.1
    applyWindupHighlight(attacker)
    flashWeaponTrail(attackerChar,"Crit",0.5)
    -- PLACEHOLDER_ANIMATION: critical_sweep -- replace with actual AnimationId
    -- PLACEHOLDER: counter by airborne opponent hitting attacker during sweep anim
    -- Hitbox fires on animation Hit marker (fallback 0.5s)
    local animObj = ANIMS and ANIMS.Combat:FindFirstChild("Critical_Sweep")
    playAndWaitForHit(attackerChar, animObj, 0.5, function()
        local cur=getPS(attacker)
        if not cur or not cur.isSweeping then return end -- cancelled (e.g. hit) during the windup
        cur.isSweeping=false; cur.combatLocked=false; cur.combatState="Idle"; removeWindupHighlight(attacker)
        local dm=_G.DataManager; local damage=getScaledValue(combatCfg.M1Damage,getStat(attacker,"Strength"),scalingCfg.StrengthPerPoint)*0.9*injuryDamageMult(attacker)*dnaDamageMult(attacker,"M1Damage")
        if dm and dm.getValue(attacker,"EquippedWeapon")==nil then damage=damage*combatCfg.FistDamageMultiplier end
        local parts=checkHitbox(attackerChar,"Sweep"); local seen={}
        for _,part in ipairs(parts) do
            local vc=part:FindFirstAncestorOfClass("Model")
            if not vc or vc==attackerChar or seen[vc] then continue end; seen[vc]=true
            local hum=vc:FindFirstChildOfClass("Humanoid"); if not hum or hum.Health<=0 then continue end
            local vp=Players:GetPlayerFromCharacter(vc)
            if vp and dm and dm.getValue(vp,"PlayerState")=="Dead" then continue end
            local hpB=hum.Health
            local causedDowned = vp and (hpB-damage)<=0
            local hpA=resolveVictimDamage(hum,damage,vp,vc,attacker,"Player")
            local hitPos,isHeavy=onHitLanded(attacker,vp,vc,part,"Sweep")
            applyKnockback(attackerChar,vc,combatCfg.KnockbackForce*0.7)
            if vp then
                applyHitstun(vp)
                RE_OnHit:FireClient(vp,{attackerName=attacker.Name,damage=damage,attackType="Sweep",newHealth=hpA,hitPosition=hitPos,heavy=isHeavy,downed=causedDowned})
            end
            RE_OnHit:FireClient(attacker,{victimName=vc.Name,damage=damage,attackType="Sweep",newHealth=hpA,hitPosition=hitPos,heavy=isHeavy,downed=causedDowned})
            print(string.format("[CombatManager] %s SWEEP CRIT(marker)->%s dmg=%.0f HP %.0f->%.0f",attacker.Name,vc.Name,damage,hpB,hpA))
        end
    end)
end

local function processCritical(attacker)
    if isAirborne(attacker) then processAirCritical(attacker) else processNormalCritical(attacker) end
end

-- M1 fire rate is locked to CD.M1 (the swing rhythm), never to click speed. Clicking
-- faster than the rhythm buffers the LAST input (one slot, no stacking) and it auto-fires
-- the instant the previous swing's window opens — never speeds the rhythm up.
local function requestM1(attacker)
    local s = getPS(attacker); if not s then return end
    local mm = _G.MovementManager
    if mm and mm.isSliding and mm.isSliding(attacker) then RE_M1Denied:FireClient(attacker); return end -- M1 is not usable while sliding
    local now = tick()
    local nextAllowed = s.lastSwingTick + CD.M1
    if now >= nextAllowed then
        s.m1Buffered = false
        if processM1(attacker) == false then RE_M1Denied:FireClient(attacker) end
    elseif not s.m1Buffered then
        s.m1Buffered = true
        task.delay(nextAllowed - now, function()
            local cur = getPS(attacker)
            if cur and cur.m1Buffered then
                cur.m1Buffered = false
                if mm and mm.isSliding and mm.isSliding(attacker) then RE_M1Denied:FireClient(attacker); return end
                if processM1(attacker) == false then RE_M1Denied:FireClient(attacker) end
            end
        end)
    end
end

getOrCreate("RequestM1").OnServerEvent:Connect(function(p) requestM1(p) end)
getOrCreate("RequestM2").OnServerEvent:Connect(function(p) processM2(p) end)
getOrCreate("RequestExecute").OnServerEvent:Connect(function(p) processExecute(p) end)
getOrCreate("RequestCarry").OnServerEvent:Connect(function(p) processCarry(p) end)
getOrCreate("RequestCritical").OnServerEvent:Connect(function(p)      processCritical(p)      end)
getOrCreate("RequestSweepCritical").OnServerEvent:Connect(function(p) processSweepCritical(p) end)

Players.PlayerAdded:Connect(function(player)
    initState(player.UserId)
    player.CharacterAdded:Connect(function(char)
        local s=getPS(player); if s then char:SetAttribute("FistsEquipped", s.fistsEquipped) end
        -- Combat polish 4B: spawn in a neutral idle, not the fists-up combat stance --
        -- CombatStance is a separate flag from FistsEquipped (which just means "capable of
        -- throwing an unarmed M1" and must stay true by default, see initState, or unarmed
        -- combat breaks for anyone who hasn't pressed V yet). CombatStance only gates the
        -- MovementController fist_idle POSE, set true by setCombatStance below.
        char:SetAttribute("CombatStance", false)
        local hum = char:WaitForChild("Humanoid", 5)
        if hum then
            hum.StateChanged:Connect(function(_, new)
                -- Freefall (past the peak of a jump's arc) is when the fall actually begins --
                -- track the HRP height right then so Landed can measure real fall distance.
                if new == Enum.HumanoidStateType.Freefall then
                    local cur = getPS(player); if not cur then return end
                    local hrp = char:FindFirstChild("HumanoidRootPart")
                    cur.fallStartY = hrp and hrp.Position.Y
                    return
                end
                if new ~= Enum.HumanoidStateType.Landed then return end
                local cur = getPS(player); if not cur then return end
                local mm = _G.MovementManager
                local wasSlideJump = mm and mm.consumeSlideJump(player)
                if not wasSlideJump then
                    -- Only a real fall triggers landing recovery -- a small hop/step down
                    -- (user: "a 5 stud fall") shouldn't lock out dash/M1/M2/slide at all.
                    local hrp = char:FindFirstChild("HumanoidRootPart")
                    local fallDist = (cur.fallStartY and hrp) and (cur.fallStartY - hrp.Position.Y) or 0
                    if fallDist >= LANDING_RECOVERY_MIN_FALL then
                        cur.landingRecoveryUntil = tick() + combatCfg.LandingRecovery
                    end
                end
                cur.fallStartY = nil
            end)
            -- WalkSpeed otherwise only changes at explicit state transitions (attack
            -- start/end, sprint tick, etc.), so a slow HP change while just standing/
            -- walking (bleed, regen, healing) wouldn't otherwise ever re-apply the
            -- low-health speed penalty until some unrelated action happened to call
            -- setSpeed again. Re-derive WalkSpeed from the last commanded mult every time.
            hum.HealthChanged:Connect(function()
                local cur = getPS(player); if not cur then return end
                setSpeed(player, cur.speedMult or 1)
            end)
        end
    end)
    player.CharacterRemoving:Connect(function()
        local s=getPS(player); if s and s.carryingPlayer then dropCarried(player) end
        removeWindupHighlight(player)
        removeBloodPool(player)
        task.wait(); initState(player.UserId)
    end)
end)
Players.PlayerRemoving:Connect(function(player)
    local s=getPS(player); if s and s.carryingPlayer then dropCarried(player) end
    removeBloodPool(player)
    pState[player.UserId]=nil
end)
for _,p in ipairs(Players:GetPlayers()) do initState(p.UserId) end

local CombatManager = {}
function CombatManager.getCombatState(player) local s=getPS(player); return s and s.combatState or "Idle" end
function CombatManager.setCombatState(player,state) local s=getPS(player); if s then if state=="Idle" and s.combatState=="Attacking" then print("[DIAGSCS] Attacking->Idle via public API, trace:"..debug.traceback()) end; s.combatState=state end end
function CombatManager.isInHitstun(player) local s=getPS(player); return s~=nil and tick()<s.hitstunUntil end
function CombatManager.applyHitstun(player,duration) applyHitstun(player,duration) end
function CombatManager.clearHitstun(player) local s=getPS(player); if s then s.hitstunUntil=0 end end
function CombatManager.isFistsEquipped(player) local s=getPS(player); return s~=nil and s.fistsEquipped==true end
function CombatManager.applyStagger(player,duration) applyStagger(player,duration) end
-- Exposed so mob AI (ShroomManager) shoves players with the SAME logic players use -- including
-- the RageManager knockback-immunity check, which a reimplementation would have missed.
function CombatManager.applyKnockback(attackerChar,victimChar,force,lateralDir,lateralForce)
	applyKnockback(attackerChar,victimChar,force,lateralDir,lateralForce)
end
function CombatManager.applyDownedState(player) applyDownedState(player) end
function CombatManager.recoverFromDowned(player) recoverFromDowned(player) end
function CombatManager.isActionBlocked(player, ignoreExhaustion, ignoreLandingRecovery) return isActionBlocked(player, ignoreExhaustion, ignoreLandingRecovery) end
function CombatManager.isSprintLocked(player) local s=getPS(player); return s ~= nil and tick() < (s.sprintLockUntil or 0) end
function CombatManager.setSprinting(player,bool) local s=getPS(player); if s then s.isSprinting=bool end end
function CombatManager.setSpeed(player,mult) setSpeed(player,mult) end
-- Re-applies whatever speed multiplier is already active (combat swing-slow, stagger, etc)
-- against the CURRENT injury/health multipliers -- setSpeed only recalculates WalkSpeed when
-- actually called, so an injury applied outside of combat would otherwise sit unnoticed on
-- WalkSpeed until the next unrelated setSpeed call (next swing, sprint toggle, etc).
function CombatManager.refreshSpeed(player) local s=getPS(player); setSpeed(player, s and s.speedMult or 1) end
function CombatManager.applyDamage(hum,dmg,vp,src) return applyDamage(hum,dmg,vp,src) end
function CombatManager.dropCarried(player) dropCarried(player) end
function CombatManager.removeBloodPool(player) removeBloodPool(player) end
function CombatManager.spawnClashSpark(pos) spawnClashSpark(pos) end
function CombatManager.spawnParryVFX(pos) spawnParryVFX(pos) end
function CombatManager.spawnBlockVFX(pos) spawnBlockVFX(pos) end
function CombatManager.spawnHitVFX(pos) spawnHitVFX(pos) end
function CombatManager.spawnWallImpact(pos) spawnWallImpact(pos) end
function CombatManager.spawnBloodBurst(pos,sizeMult) spawnBloodBurst(pos,sizeMult) end
function CombatManager.isLandingRecovery(player) local s=getPS(player); return s~=nil and tick()<s.landingRecoveryUntil end
function CombatManager.grantIframes(player,duration) local s=getPS(player); if s then s.iframesUntil=tick()+duration end end
-- Additive version for dash feint: stacks on top of any iframe time still remaining
-- (rather than overwriting), matching "ADDITIONAL iframes on top of remaining" from spec.
function CombatManager.grantBonusIframes(player,duration) local s=getPS(player); if s then s.iframesUntil=math.max(s.iframesUntil or 0, tick())+duration end end
function CombatManager.hasIframes(player) return hasIframes(player) end
-- Dash feint recovery: brief no-attack window (processM1/processM2 check this directly) --
-- deliberately NOT routed through isActionBlocked, since that also gates movement
-- (sprint/crouch/slide) and a feint should only lock out attacks, not repositioning.
function CombatManager.applyDashFeintRecovery(player,duration) local s=getPS(player); if s then s.dashFeintRecoveryUntil=math.max(s.dashFeintRecoveryUntil or 0, tick()+duration) end end
function CombatManager.isTurnCapped(player) return isTurnCapped(player) end
_G.CombatManager = CombatManager

print(string.format(
    "[CombatManager v3] Init — M1=%.0f M2=%.0f Fist*%.1f Chain=%d EndLag=%.1fs Bleedout=%.0fs",
    combatCfg.M1Damage, combatCfg.M2Damage, combatCfg.FistDamageMultiplier,
    combatCfg.M1ChainMax, combatCfg.M1EndLagDuration, combatCfg.BleedoutDuration
))


RE_EquipFists.OnServerEvent:Connect(function(player, equipped)
    local s=getPS(player); if not s then return end
    s.fistsEquipped = equipped == true
    local char = player.Character
    if char then char:SetAttribute("FistsEquipped", s.fistsEquipped) end -- lets client scripts (dodge anim) read it
    if not equipped then
        local bm=_G.BlockManager; if bm then bm.endBlock(player) end
        local prm=_G.ParryManager; if prm and prm.cancelParry then prm.cancelParry(player) end
    end
end)