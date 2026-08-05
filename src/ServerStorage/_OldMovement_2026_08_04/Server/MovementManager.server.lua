-- MovementManager.server.lua
-- Full movement system: base walk, sprint, momentum, A/D tilt (client),
-- shiftlock (client), crouch, slide, jump boost, idle/fidget (client), footsteps (client)
-- ONE RULE: all WalkSpeed changes go through setMovementState() — never set directly elsewhere
--
-- CTRL KEY NOTE:
--   Ctrl alone (no M1 active) = crouch or slide (this script)
--   Ctrl + M1 simultaneously  = Sweep Critical (fist combat, handled in CombatManager)
--   These don't conflict: InputHandler checks Ctrl+M1 first and fires RequestSweepCritical;
--   if only Ctrl is pressed it fires RequestCrouch or RequestSlide.

local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local staminaCfg, combatDashIframeSec, dashFeintBonusIframeSec, dashFeintRecoverySec, movementCfg
do
    local ok, cfg = pcall(function()
        local shared = RepStorage:WaitForChild("Shared", 5)
        return require(shared:WaitForChild("Config", 3))
    end)
    if ok and cfg then
        staminaCfg = cfg.Stamina
        combatDashIframeSec = cfg.Combat and cfg.Combat.DashIFrames and (cfg.Combat.DashIFrames/60)
        dashFeintBonusIframeSec = cfg.Combat and cfg.Combat.DashFeintBonusIFrames and (cfg.Combat.DashFeintBonusIFrames/60)
        dashFeintRecoverySec = cfg.Combat and cfg.Combat.DashFeintRecovery
        movementCfg = cfg.Movement
    end
end
staminaCfg = staminaCfg or { CostDash = 10, CostSprint = 3, CostDodgeFist = 8 }
combatDashIframeSec = combatDashIframeSec or 0.1
dashFeintBonusIframeSec = dashFeintBonusIframeSec or (4/60)
dashFeintRecoverySec = dashFeintRecoverySec or 0.15
movementCfg = movementCfg or {
    SprintSpeed = 25, SprintMaxSpeed = 35, JumpBase = 50, JumpMax = 65,
    DashForce = 54, DashCooldown = 0.6, DashTravelDuration = 0.22,
    SlideCooldown = 4, SlideJumpBoostSpeed = 48, SlideJumpBoostDuration = 0.55,
    SpeedMult = { Normal=1.0, Crouch=0.5, Stagger=0.3, GuardBreak=0, ParryWindow=0.75, Blocking=0.4, EndLag=1.0, Carrying=0.5, Feint=1.0 },
    Momentum = { BuildFlat=2, BuildDownhill=5, DrainIdle=10, DrainUphill=5, DrainSlide=15, DrainSlideUp=25, BuildSlideDown=12, SlideTurnSpeed=200, SpeedBonus=0.1, ParticleThresh=30, SlideMinMom=20, JumpThreshold=50, JumpBoostMult=0.15, SlopeAngle=15, SlopeAngleMax=60 },
}

-- Speed constants (spec-exact values)
local BASE_WALK_SPEED  = 16
local SPRINT_SPEED     = movementCfg.SprintSpeed     -- W x2 base sprint
local SPRINT_MAX_SPEED = movementCfg.SprintMaxSpeed  -- cap with full momentum
local JUMP_BASE        = movementCfg.JumpBase
local JUMP_MAX         = movementCfg.JumpMax
local DASH_FORCE       = movementCfg.DashForce -- buffed from 46 per user request (dash should go slightly further)
local DASH_COOLDOWN    = movementCfg.DashCooldown
local DASH_TRAVEL_DURATION = movementCfg.DashTravelDuration -- must match the DashVelocity BodyVelocity's own Debris/task.delay lifetime below
local SLIDE_COOLDOWN   = movementCfg.SlideCooldown -- can't slide again for 4s after getting up from a slide
local SLIDE_JUMP_BOOST_SPEED    = movementCfg.SlideJumpBoostSpeed
local SLIDE_JUMP_BOOST_DURATION = movementCfg.SlideJumpBoostDuration

-- Speed multipliers used by setMovementState() -> cm.setSpeed(player, mult)
local SPEED_MULT = {
    Normal      = movementCfg.SpeedMult.Normal,
    Sprint      = SPRINT_SPEED / BASE_WALK_SPEED,   -- 1.5625
    Crouch      = movementCfg.SpeedMult.Crouch,    -- 8
    Stagger     = movementCfg.SpeedMult.Stagger,    -- 4.8
    GuardBreak  = movementCfg.SpeedMult.GuardBreak,      -- 0
    M1Active    = 0.25,   -- 4 -- kept in sync with Config.Combat.SpeedM1Chain (unused here directly -- CombatManager sets M1/M2 speed itself -- but kept matching to avoid stale/misleading values)
    M2Swing     = 0.10,   -- 1.6 -- kept in sync with Config.Combat.SpeedM2Swing (see note above)
    ParryWindow = movementCfg.SpeedMult.ParryWindow,   -- 12
    Blocking    = movementCfg.SpeedMult.Blocking,    -- 6.4
    EndLag      = movementCfg.SpeedMult.EndLag,    -- 16
    Carrying    = movementCfg.SpeedMult.Carrying,    -- 8
    Feint       = movementCfg.SpeedMult.Feint,    -- 16
}

-- Momentum config
local MOM = {
    BuildFlat      = movementCfg.Momentum.BuildFlat,    -- /sec sprinting flat
    BuildDownhill  = movementCfg.Momentum.BuildDownhill,    -- /sec sprinting downhill
    DrainIdle      = movementCfg.Momentum.DrainIdle,   -- /sec not sprinting
    DrainUphill    = movementCfg.Momentum.DrainUphill,    -- /sec sprinting uphill
    DrainSlide     = movementCfg.Momentum.DrainSlide,   -- /sec sliding flat
    DrainSlideUp   = movementCfg.Momentum.DrainSlideUp,   -- /sec sliding uphill
    BuildSlideDown = movementCfg.Momentum.BuildSlideDown,   -- /sec sliding downhill (cliffs) -- builds momentum instead of draining it, per user request
    SlideTurnSpeed = movementCfg.Momentum.SlideTurnSpeed,  -- deg/sec the slide direction can carve toward current input
    SpeedBonus     = movementCfg.Momentum.SpeedBonus,  -- speed = SPRINT_SPEED + momentum * 0.1
    ParticleThresh = movementCfg.Momentum.ParticleThresh,   -- show particles above this
    SlideMinMom    = movementCfg.Momentum.SlideMinMom,   -- minimum to enter slide
    JumpThreshold  = movementCfg.Momentum.JumpThreshold,   -- minimum for jump boost
    JumpBoostMult  = movementCfg.Momentum.JumpBoostMult, -- JumpPower += momentum * 0.15
    SlopeAngle     = movementCfg.Momentum.SlopeAngle,   -- degrees to qualify as slope
    SlopeAngleMax  = movementCfg.Momentum.SlopeAngleMax,   -- degrees -- steeper than this is too steep to stand/slide on; character slips into a fall
}

-- R6 limb names for momentum particles
local PARTICLE_PARTS = {"Right Arm", "Left Arm", "Right Leg", "Left Leg"}  -- R6 part names have spaces
local UP = Vector3.new(0, 1, 0)

-- R6 has no separate foot parts, so "on the feet" means the leg parts themselves.
local SLIDE_SMOKE_PARTS = {"Right Leg", "Left Leg"}
-- Authored asset (Workspace."slide Smoke") -- clone its tuned ParticleEmitter rather than
-- reconstructing one from scratch, same convention as CombatManager's VFX cloning.
local SlideSmokeTemplate = workspace:FindFirstChild("slide Smoke")
local SlideSmokeSource = SlideSmokeTemplate and SlideSmokeTemplate:FindFirstChildOfClass("ParticleEmitter")

-- ─── Remote events ───────────────────────────────────────────────────────────
local function getOrCreateRE(name)
    local folder = RepStorage:FindFirstChild("RemoteEvents")
        or (function()
            local f = Instance.new("Folder")
            f.Name = "RemoteEvents"
            f.Parent = RepStorage
            return f
        end)()
    local r = folder:FindFirstChild(name)
    if r then return r end
    r = Instance.new("RemoteEvent")
    r.Name = name
    r.Parent = folder
    return r
end

local RE_Sprint    = getOrCreateRE("RequestSprint")
local RE_SprintEnd = getOrCreateRE("RequestSprintEnd")
local RE_Dash      = getOrCreateRE("RequestDash")
local RE_Slide     = getOrCreateRE("RequestSlide")
local RE_Crouch    = getOrCreateRE("RequestCrouch")
local RE_Jump      = getOrCreateRE("RequestJump")
local RE_MovState  = getOrCreateRE("UpdateMovementState") -- server → client
local RE_DashDenied = getOrCreateRE("OnDashDenied") -- server → client: cooldown/stamina silently blocked a dash
local RE_SlideDenied = getOrCreateRE("OnSlideDenied") -- server → client: still on the post-slide cooldown
-- RequestSweepCritical stub removed 2026-08-02 with the combat stack -- creating it here
-- would leave an orphan remote nothing fires or listens to.

-- ─── Per-player state ────────────────────────────────────────────────────────
local pState = {}

local function initState(uid)
    pState[uid] = {
        isSprinting       = false,
        isCrouching       = false,
        isSliding         = false,
        dashCooldownUntil = 0,
        slideCooldownUntil = 0,
        momentum          = 0,
        slideBV           = nil,   -- BodyVelocity active during slide
        particles         = {},    -- [partName] = ParticleEmitter
        slideSmoke        = {},    -- [partName] = ParticleEmitter (cloned from "slide Smoke", legs only)
        partThrottle      = 0,     -- seconds until next particle update
        wasSlideJump      = false, -- consumed by CombatManager on landing to skip landing recovery
        slideJumpBV       = nil,   -- BodyVelocity carrying a slide-jump's horizontal boost
        slideJumpBoostUntil = 0,
        isDashing         = false, -- true only during the dash's real travel window (DASH_TRAVEL_DURATION), not the full cooldown
        activeDashBV      = nil,   -- the current dash's BodyVelocity, so a feint can cancel it early
        dashToken         = 0,     -- invalidates a stale "end of dash" cleanup after a feint already handled it
    }
end

local function getPS(player) return pState[player.UserId] end

-- ─── CENTRAL SPEED SETTER — all WalkSpeed changes go here ────────────────────
local function setMovementState(player, stateName, customMult)
    local mult = customMult or SPEED_MULT[stateName] or 1.0
    local cm   = _G.CombatManager
    if cm then
        cm.setSpeed(player, mult)
    else
        local char = player.Character
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if hum then hum.WalkSpeed = BASE_WALK_SPEED * mult end
    end
end

local function applySprintSpeed(player, momentum)
    local speed = math.min(SPRINT_MAX_SPEED, SPRINT_SPEED + momentum * MOM.SpeedBonus)
    setMovementState(player, "Sprint", speed / BASE_WALK_SPEED)
end

local function updateJumpPower(player, momentum, isCrouching)
    local char = player.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    if isCrouching or momentum <= MOM.JumpThreshold then
        hum.JumpPower = JUMP_BASE
    else
        hum.JumpPower = math.min(JUMP_MAX, JUMP_BASE + momentum * MOM.JumpBoostMult)
    end
end

-- ─── SLOPE DETECTION ─────────────────────────────────────────────────────────
local function getSlopeType(character)
    local hrp = character:FindFirstChild("HumanoidRootPart")
    local hum = character:FindFirstChildOfClass("Humanoid")
    if not hrp or not hum then return "flat" end
    local params = RaycastParams.new()
    params.FilterDescendantsInstances = {character}
    params.FilterType = Enum.RaycastFilterType.Exclude
    local hit = workspace:Raycast(hrp.Position, Vector3.new(0, -4, 0), params)
    if not hit then return "flat" end
    local angle = math.deg(math.acos(math.clamp(hit.Normal:Dot(UP), -1, 1)))
    if angle < MOM.SlopeAngle then return "flat" end
    if angle > MOM.SlopeAngleMax then return "toosteep" end
    local moveDir = hum.MoveDirection
    if moveDir.Magnitude < 0.05 then return "flat" end
    local slopeH = Vector3.new(hit.Normal.X, 0, hit.Normal.Z)
    if slopeH.Magnitude < 0.01 then return "flat" end
    local dot = moveDir:Dot(slopeH.Unit)
    if dot > 0.1 then return "uphill"
    elseif dot < -0.1 then return "downhill"
    else return "flat" end
end

-- ─── MOMENTUM PARTICLES ──────────────────────────────────────────────────────
local function ensureParticles(character, s)
    for _, partName in ipairs(PARTICLE_PARTS) do
        local existing = s.particles[partName]
        if existing and existing.Parent then continue end  -- already valid
        local part = character:FindFirstChild(partName)
        if not part then continue end
        local e = Instance.new("ParticleEmitter")
        e.Name              = "MomentumParticle"
        -- PLACEHOLDER_ASSET: MomentumParticle — replace with final particle effect
        e.Color             = ColorSequence.new(Color3.fromRGB(190, 215, 255))
        e.LightEmission     = 0.2
        e.Size              = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.12), NumberSequenceKeypoint.new(1, 0)})
        e.Transparency      = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.75), NumberSequenceKeypoint.new(1, 1)})
        e.Speed             = NumberRange.new(0.5, 2)
        e.Lifetime          = NumberRange.new(0.15, 0.35)
        e.Rate              = 0
        e.VelocityInheritance = -0.5  -- trails behind movement direction
        e.Enabled           = false
        e.Parent            = part
        s.particles[partName] = e
    end
end

local function updateParticles(s, momentum)
    local visible = momentum > MOM.ParticleThresh
    local t = math.clamp((momentum - MOM.ParticleThresh) / (100 - MOM.ParticleThresh), 0, 1)
    local rate = math.floor(t * 20)
    local sz   = 0.08 + t * 0.22
    local tr0  = 0.9  - t * 0.45
    for _, e in pairs(s.particles) do
        if not e or not e.Parent then continue end
        e.Enabled = visible
        e.Rate    = visible and rate or 0
        if visible then
            e.Size         = NumberSequence.new({NumberSequenceKeypoint.new(0, sz), NumberSequenceKeypoint.new(1, 0)})
            e.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, tr0), NumberSequenceKeypoint.new(1, 1)})
        end
    end
end

local function destroyParticles(s)
    for k, e in pairs(s.particles) do
        if e and e.Parent then e:Destroy() end
        s.particles[k] = nil
    end
end

-- ─── SLIDE SMOKE ──────────────────────────────────────────────────────────────
-- Clones (not toggles Rate on) the authored template onto each leg once per spawn, then
-- just flips Enabled on/off with isSliding every frame -- the template's own Rate/Size/
-- Speed/Drag/VelocityInheritance tuning already gives the "kicks up and trails behind"
-- look on its own, so nothing here needs to fight or recompute those.
local SLIDE_SMOKE_RATE = 12 -- template's own authored Rate (39) was too heavy for two legs at once; toned down

local function ensureSlideSmoke(character, s)
    if not SlideSmokeSource then return end
    for _, partName in ipairs(SLIDE_SMOKE_PARTS) do
        local existing = s.slideSmoke[partName]
        if existing and existing.Parent then continue end
        local part = character:FindFirstChild(partName)
        if not part then continue end
        local e = SlideSmokeSource:Clone()
        e.Enabled = false
        e.Rate = SLIDE_SMOKE_RATE
        e.Parent = part
        s.slideSmoke[partName] = e
    end
end

local function destroySlideSmoke(s)
    for k, e in pairs(s.slideSmoke) do
        if e and e.Parent then e:Destroy() end
        s.slideSmoke[k] = nil
    end
end

-- ─── SLIDE END ───────────────────────────────────────────────────────────────
local function endSlide(player, s)
    if not s.isSliding then return end
    s.isSliding = false
    if s.slideBV and s.slideBV.Parent then s.slideBV:Destroy() end
    s.slideBV = nil
    -- BUG FIX: the post-slide cooldown was checked on entry (processSlide) but never
    -- actually ARMED anywhere -- SLIDE_COOLDOWN existed only as a comment and slides were
    -- freely spammable back-to-back. Armed here so every slide exit starts the clock.
    s.slideCooldownUntil = tick() + SLIDE_COOLDOWN
    setMovementState(player, "Normal")
    RE_MovState:FireClient(player, "SlideEnd")
end

-- ─── SPRINT ──────────────────────────────────────────────────────────────────
local function stopSprint(player, s)
    s = s or getPS(player)
    if not s or not s.isSprinting then return end
    s.isSprinting = false
    local cm = _G.CombatManager
    if cm and cm.setSprinting then cm.setSprinting(player, false) end
    if not s.isSliding then
        -- Combat polish 4C: momentum coast -- releasing sprint at real speed doesn't stop
        -- dead, the character keeps drifting forward briefly with decaying velocity (not a
        -- slide, just visible momentum). Only worth doing above the same momentum>50
        -- threshold this file already uses elsewhere for "real sprint speed" boosts.
        if s.momentum > 50 then
            local char = player.Character
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if hrp then
                local flatVel = Vector3.new(hrp.AssemblyLinearVelocity.X, 0, hrp.AssemblyLinearVelocity.Z)
                if flatVel.Magnitude > 1 then
                    local bv = Instance.new("BodyVelocity")
                    bv.Name = "MomentumCoast"
                    bv.MaxForce = Vector3.new(4000, 0, 4000)
                    bv.P = 1200
                    bv.Velocity = flatVel
                    bv.Parent = hrp
                    local COAST_DURATION = 0.3
                    local startTick = tick()
                    local conn
                    conn = RunService.Heartbeat:Connect(function()
                        local t = (tick() - startTick) / COAST_DURATION
                        if t >= 1 or not bv.Parent then
                            if conn then conn:Disconnect() end
                            if bv.Parent then bv:Destroy() end
                            return
                        end
                        bv.Velocity = flatVel * (1 - t)
                    end)
                end
            end
        end
        s.momentum = 0
        updateParticles(s, 0)
        setMovementState(player, "Normal")
        RE_MovState:FireClient(player, "SprintEnd")
    end
end

local function startSprint(player, s)
    s = s or getPS(player)
    if not s or s.isSprinting or s.isCrouching or s.isSliding then return end
    local cm = _G.CombatManager
    if cm and cm.isActionBlocked(player) then return end
    if cm and cm.isSprintLocked and cm.isSprintLocked(player) then return end -- refreshed on every hit landed/received -- see CombatManager.applySprintLock
    local _bm = _G.BlockManager; if _bm and _bm.isBlocking(player) then return end
    local sm = _G.StaminaManager
    if sm and sm.get(player) < 1 then return end
    s.isSprinting = true
    if cm and cm.setSprinting then cm.setSprinting(player, true) end
    applySprintSpeed(player, s.momentum)
end

-- ─── DASH FEINT ──────────────────────────────────────────────────────────────
-- Q pressed again while a dash is already active (s.isDashing) ends it early: trades the
-- rest of its travel distance for extra iframes -- a mix-up tool to bait a punish read for
-- the full dash. Called from processDash below once it detects a second Q mid-dash.
local function processDashFeint(player, s)
    if not s.isDashing then return end
    s.isDashing = false
    s.dashToken = (s.dashToken or 0) + 1 -- invalidates the still-pending "end of dash" cleanup below
    if s.activeDashBV and s.activeDashBV.Parent then s.activeDashBV:Destroy() end
    s.activeDashBV = nil
    local char = player.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if hrp then
        -- Cancel the movement (stop momentum) -- destroying the BodyVelocity alone leaves
        -- whatever velocity the physics solver already imparted this frame.
        local vel = hrp.AssemblyLinearVelocity
        hrp.AssemblyLinearVelocity = Vector3.new(0, vel.Y, 0)
    end
    local cm = _G.CombatManager
    if cm and cm.grantBonusIframes then cm.grantBonusIframes(player, dashFeintBonusIframeSec) end
    if cm and cm.applyDashFeintRecovery then cm.applyDashFeintRecovery(player, dashFeintRecoverySec) end
    RE_MovState:FireClient(player, "DashFeint")
    -- PLACEHOLDER_ANIMATION: dash_feint — replace with actual AnimationId (played client-side
    -- in MovementController off the "DashFeint" UpdateMovementState signal)
    print(string.format("[MovementManager] %s dash-feinted (bonus iframes=%.2fs, recovery=%.2fs)",
        player.Name, dashFeintBonusIframeSec, dashFeintRecoverySec))
end

-- ─── DASH ────────────────────────────────────────────────────────────────────
local function processDash(player, dir)
    local s = getPS(player)
    if not s then return end
    -- Combat polish 4E: Parry->Dash cancel -- clears a mid-whiff parry's active state
    -- cleanly if applicable (see ParryManager.tryCancelToDash's comment for why this
    -- matters even though "Parrying" combatState never blocked dash to begin with).
    local pm = _G.ParryManager
    if pm and pm.tryCancelToDash then pm.tryCancelToDash(player) end
    local cm = _G.CombatManager
    -- Landing recovery (Config.Combat.LandingRecovery, ~0.93s after touching down from a
    -- jump) silently blocks dash/M1/M2/parry with zero feedback -- that's exactly what read
    -- as "dash doesn't work when you jump": jump, land, try to dash immediately, nothing
    -- happens and no cue explains why. Give it the same denial cue as cooldown/stamina below.
    -- Checked before the general isActionBlocked so it gets its own distinct feedback --
    -- the other blocked states (staggered, downed, etc.) already have their own visual
    -- feedback elsewhere, so those stay silent here to avoid a redundant/confusing flash.
    if cm and cm.isLandingRecovery and cm.isLandingRecovery(player) then
        RE_DashDenied:FireClient(player)
        return
    end
    if cm and cm.isActionBlocked(player) then return end
    -- A second Q press while already mid-dash is a feint request, not a new dash attempt --
    -- must come before the cooldown check below, since dashCooldownUntil is already active
    -- for the whole dash and would otherwise just silently deny this as spam.
    if s.isDashing then processDashFeint(player, s); return end
    -- Dash was silently dropping these two cases with zero feedback -- at a press cadence
    -- faster than DASH_COOLDOWN (0.6s) it looked exactly like "works half the time."
    -- RE_DashDenied lets the client play a quick, unmistakable "nope" cue either way.
    if tick() < s.dashCooldownUntil then RE_DashDenied:FireClient(player); return end
    local sm   = _G.StaminaManager
    local isFists = cm and cm.isFistsEquipped(player)
    local cost = isFists and staminaCfg.CostDodgeFist or staminaCfg.CostDash
    local tm   = _G.TraitManager
    if tm and tm.getDashCostReduction then
        cost = math.max(0, cost - tm.getDashCostReduction(player))
    end
    local drainOk = sm and sm.drain(player, cost, true)
    if sm and not drainOk then RE_DashDenied:FireClient(player); return end
    s.dashCooldownUntil = tick() + DASH_COOLDOWN
    if cm and cm.grantIframes then cm.grantIframes(player, combatDashIframeSec) end
    local char = player.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if hrp then
        local cf = hrp.CFrame
        local dirVec
        if     dir == "back"  then dirVec = -cf.LookVector
        elseif dir == "left"  then dirVec = -cf.RightVector
        elseif dir == "right" then dirVec =  cf.RightVector
        else                       dirVec =  cf.LookVector end
        local flat = Vector3.new(dirVec.X, 0, dirVec.Z)
        if flat.Magnitude > 0.01 then
            local bv = Instance.new("BodyVelocity")
            bv.Name     = "DashVelocity"
            bv.Velocity  = flat.Unit * DASH_FORCE
            bv.MaxForce  = Vector3.new(65000, 0, 65000)
            bv.P         = 45000
            bv.Parent    = hrp
            s.isDashing    = true
            s.dashStartTime = tick()
            s.activeDashBV = bv
            s.dashToken    = (s.dashToken or 0) + 1
            local myDashToken = s.dashToken
            task.delay(DASH_TRAVEL_DURATION, function()
                if bv and bv.Parent then bv:Destroy() end
                -- Only clear if a feint hasn't already handled this (token still matches) --
                -- otherwise this stale cleanup could stomp a newer dash's isDashing/activeDashBV.
                if s.dashToken == myDashToken then
                    s.isDashing    = false
                    s.activeDashBV = nil
                end
            end)
        end
    end
    -- Fist dodge reuses the same dash motion/iframes with the existing Fist_Dodge clip
    -- and its own (cheaper) stamina cost; MovementController.lua resolves which anim to
    -- play client-side based on whether fists are currently equipped.
    -- PLACEHOLDER_ANIMATION: dash_forward — replace with actual AnimationId
    -- dash_whoosh sound is played client-side in MovementController.fireDash()
end

-- ─── CROUCH ──────────────────────────────────────────────────────────────────
local function processCrouch(player, s)
    s = s or getPS(player)
    if not s or s.isSliding then return end
    local cm = _G.CombatManager
    -- Block during GuardBreak, Stagger, Downed, etc.
    if cm and cm.isActionBlocked(player) then return end
    if s.isSprinting then stopSprint(player, s) end
    s.isCrouching = not s.isCrouching
    local char = player.Character
    if char then char:SetAttribute("CrouchActive", s.isCrouching) end
    if s.isCrouching then
        setMovementState(player, "Crouch")
        RE_MovState:FireClient(player, "Crouch")
        -- The "stuck after WalkSpeed change while idle" fix used to also live here, but the
        -- character's own client owns its physics/state authority (confirmed via
        -- HumanoidRootPart:GetNetworkOwner()), so this server-side ChangeState call was just a
        -- delayed, redundant echo of the client-side one in InputHandler -- arriving after real
        -- network latency (unlike near-zero-latency Studio Solo testing), it could land mid-
        -- movement and re-interrupt what the client had already correctly resumed. Removed;
        -- the client-side fix is authoritative on its own.
    else
        setMovementState(player, "Normal")
        RE_MovState:FireClient(player, "CrouchEnd")
        -- PLACEHOLDER_ANIMATION: crouch_to_stand — replace with actual AnimationId
    end
end

-- ─── SLIDE ───────────────────────────────────────────────────────────────────
-- sOrForce: state table (internal calls) OR boolean true (test harness force-start)
local function processSlide(player, sOrForce)
    local s, forceMode
    if type(sOrForce) == "boolean" then
        forceMode = sOrForce
        s = getPS(player)
    else
        s = sOrForce or getPS(player)
        forceMode = false
    end
    if not s or s.isCrouching then return end
    -- Ctrl again mid-slide cancels it early. Previously a slide was locked in until
    -- momentum fully drained (or a jump) -- committing to several seconds of travel with
    -- no way out. Cancelling keeps current velocity (BodyVelocity removal preserves it)
    -- and still arms the normal post-slide cooldown via endSlide.
    if s.isSliding then endSlide(player, s); return end
    if not forceMode then
        if tick() < s.slideCooldownUntil then RE_SlideDenied:FireClient(player); return end
        if not s.isSprinting then return end
        -- Uphill refusal now gets the same denial cue as cooldown/stamina -- it was a
        -- silent return, which read as "slide randomly doesn't work".
        if getSlopeType(player.Character or {}) == "uphill" then RE_SlideDenied:FireClient(player); return end
        local cm2 = _G.CombatManager
        -- Slide takes priority over landing recovery (ignoreLandingRecovery=true) -- sliding
        -- right as you touch down from a jump/fall was silently getting refused otherwise,
        -- since landing recovery normally locks out dash/M1/M2 too. Every other block
        -- (Staggered/GuardBroken/Downed/hitstun/exhaustion) still applies to slide as before.
        if cm2 and cm2.isActionBlocked(player, false, true) then return end
    end
    local char = player.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")
    if not hum or not hrp then return end
    -- Seed minimum momentum so sprint→slide always has real distance
    if s.momentum < 50 then s.momentum = 50 end
    -- Commit to slide: stop sprint first
    s.isSprinting = false
    local cm = _G.CombatManager
    if cm and cm.setSprinting then cm.setSprinting(player, false) end
    s.isSliding = true
    -- BodyVelocity carries the slide forward; Y MaxForce=0 preserves gravity
    local lv    = hrp.CFrame.LookVector
    local hDir  = Vector3.new(lv.X, 0, lv.Z)
    if hDir.Magnitude < 0.01 then hDir = hrp.CFrame.LookVector end
    hDir = hDir.Unit
    local initSpeed = math.min(SPRINT_MAX_SPEED, SPRINT_SPEED + s.momentum * MOM.SpeedBonus) * 1.3
    local bv = Instance.new("BodyVelocity")
    bv.Name     = "SlideVelocity"
    bv.Velocity  = hDir * initSpeed
    bv.MaxForce  = Vector3.new(65000, 0, 65000)
    bv.P         = 8000
    bv.Parent    = hrp
    s.slideBV    = bv
    -- Zero WalkSpeed so Roblox controller doesn't fight the BodyVelocity
	if hum then hum.WalkSpeed = 0 end
    RE_MovState:FireClient(player, "Slide")
    -- PLACEHOLDER_ANIMATION: slide — replace with actual AnimationId
    -- slide_sound (continuous, looped) is played client-side in MovementController
end

-- ─── JUMP (slide cancel + momentum boost) ────────────────────────────────────
local function processJump(player)
    local s = getPS(player)
    if not s then return end
    local cm = _G.CombatManager
    if cm and cm.isActionBlocked(player) then return end
    local char = player.Character
    local hum  = char and char:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    -- Exit crouch on jump; no boost (spec)
    if s.isCrouching then
        s.isCrouching = false
        setMovementState(player, "Normal")
        RE_MovState:FireClient(player, "CrouchEnd")
    end
    local wasSlideJumping = false
    local slideFwd = nil
    if s.isSliding then
        local hrp2 = char:FindFirstChild("HumanoidRootPart")
        endSlide(player, s)
        -- updateJumpPower() already keeps hum.JumpPower boosted off current momentum every
        -- Heartbeat tick, and momentum isn't touched by endSlide, so the upcoming
        -- hum.Jump=true already gets a taller jump for free -- no need to special-case
        -- JumpPower here too. On top of that, give a clear, deliberate shove up and
        -- forward out of the slide (not just a taller jump). Applied synchronously right
        -- after Jump=true below -- task.defer's timing relative to Jump's own internal
        -- impulse turned out to be unpredictable and the horizontal component never sti​ck.
        if hrp2 then
            local lv = hrp2.CFrame.LookVector
            local fwd = Vector3.new(lv.X, 0, lv.Z)
            slideFwd = (fwd.Magnitude > 0.01) and fwd.Unit or Vector3.new(0, 0, -1)
            wasSlideJumping = true
        end
        RE_MovState:FireClient(player, "SlideJump")
        s.wasSlideJump = true -- slide-jump landing preserves momentum and skips landing recovery
        -- PLACEHOLDER_ANIMATION: slide_jump — replace with actual AnimationId
    end
    -- Humanoid:ChangeState(Jumping) only *requests* a state -- it doesn't apply an actual
    -- upward impulse, so Roblox's own grounded-check immediately overrides it back to
    -- Running when no real velocity was imparted (this silently broke every slide-jump,
    -- since normal jumps only worked because Roblox's client-side controller
    -- independently sets Humanoid.Jump on spacebar -- a mechanism that isn't engaged
    -- during the custom WalkSpeed=0 slide state). Humanoid.Jump=true is the reliable,
    -- canonical way to trigger a real jump impulse from the server.
    --
    -- The actual root cause of the slide-jump "not pushing you up at all" turned out to be
    -- upstream of this function entirely: hum.UseJumpPower was never set to true anywhere
    -- (fixed in setupPlayer), so the Humanoid was computing its jump impulse from the fixed
    -- JumpHeight the whole time and silently ignoring JumpPower -- which is why no amount of
    -- post-hoc AssemblyLinearVelocity/BodyVelocity tampering on the Y axis ever stuck; the
    -- Humanoid's own state machine kept re-asserting its JumpHeight-derived velocity every
    -- frame. With UseJumpPower now actually honored, a real, deliberate slide-jump boost
    -- just means giving JumpPower a real bump before the jump fires.
    -- Buffed for a much more dramatic slide-jump (was +20/85 JumpPower, 30 studs/s for
    -- 0.4s horizontal) -- now noticeably higher and further.
    if wasSlideJumping then
        hum.JumpPower = math.max(hum.JumpPower, JUMP_MAX) + 35
    end
    hum.Jump = true
    if wasSlideJumping and slideFwd then
        local hrp3 = char:FindFirstChild("HumanoidRootPart")
        if hrp3 then
            -- Horizontal: a continuous BodyVelocity wins against Roblox's own
            -- WalkSpeed/MoveDirection-driven movement recompute every physics step.
            -- Stored on state (not just Debris-timed) so the Heartbeat loop below can
            -- steer it toward the player's held input every frame during the boost window,
            -- instead of leaving it locked to whichever way the character faced at takeoff.
            if s.slideJumpBV and s.slideJumpBV.Parent then s.slideJumpBV:Destroy() end
            local bv = Instance.new("BodyVelocity")
            bv.Name = "SlideJumpBoost"
            bv.Velocity = slideFwd * SLIDE_JUMP_BOOST_SPEED
            bv.MaxForce = Vector3.new(2e4, 0, 2e4)
            bv.P = 4000
            bv.Parent = hrp3
            s.slideJumpBV = bv
            s.slideJumpBoostUntil = tick() + SLIDE_JUMP_BOOST_DURATION
        end
    end
end

-- ─── REMOTE BINDINGS ─────────────────────────────────────────────────────────
RE_Sprint.OnServerEvent:Connect(function(p)    startSprint(p)   end)
RE_SprintEnd.OnServerEvent:Connect(function(p) stopSprint(p)    end)
RE_Dash.OnServerEvent:Connect(function(p, dir) processDash(p, dir) end)
RE_Slide.OnServerEvent:Connect(function(p)     processSlide(p)  end)
RE_Crouch.OnServerEvent:Connect(function(p)    processCrouch(p) end)
RE_Jump.OnServerEvent:Connect(function(p)      processJump(p)   end)

-- ─── PLAYER SETUP ────────────────────────────────────────────────────────────
-- Public API for other managers
_G.MovementManager = {
    stopSprint = function(p)
        local ps = getPS(p); if ps then stopSprint(p, ps) end
    end,
}

local function setupPlayer(player)
    initState(player.UserId)
    player.CharacterAdded:Connect(function(char)
        local s = getPS(player)
        if s then
            s.isSprinting = false; s.isCrouching = false; s.isSliding = false
            s.momentum = 0; s.slideBV = nil
            s.slideJumpBV = nil; s.slideJumpBoostUntil = 0
            -- Rate-limit cooldowns reset on respawn too -- dying mid-cooldown shouldn't leave
            -- the fresh character silently unable to dash/slide for a few more seconds.
            s.dashCooldownUntil = 0; s.slideCooldownUntil = 0
            destroyParticles(s)
            destroySlideSmoke(s)
        end
        local hrp = char:WaitForChild("HumanoidRootPart", 5)
        local hum = char:WaitForChild("Humanoid", 5)
        -- UseJumpPower defaults to false, which makes the Humanoid ignore JumpPower entirely
        -- and jump off the fixed JumpHeight instead -- silently breaking every bit of jump
        -- boosting in this file (momentum-scaled JumpPower below, the slide-jump shove) since
        -- none of it was ever actually being read.
        if hum then hum.UseJumpPower = true; hum.WalkSpeed = BASE_WALK_SPEED; hum.JumpPower = JUMP_BASE end
        task.delay(0.5, function()
            if char.Parent and s then ensureParticles(char, s) end
        end)
    end)
end

Players.PlayerAdded:Connect(setupPlayer)
for _, p in ipairs(Players:GetPlayers()) do setupPlayer(p) end
Players.PlayerRemoving:Connect(function(player)
    local s = getPS(player)
    if s then destroyParticles(s); destroySlideSmoke(s) end
    pState[player.UserId] = nil
end)

-- ─── HEARTBEAT: momentum, slide decay, jump power, particles ─────────────────
RunService.Heartbeat:Connect(function(dt)
    local sm = _G.StaminaManager
    for _, player in ipairs(Players:GetPlayers()) do
        local s = getPS(player)
        if not s then continue end
        local char = player.Character
        if not char then continue end
        local hum = char:FindFirstChildOfClass("Humanoid")
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if not hum or not hrp then continue end

		if s.isSliding then

            -- CLIFF FIX: the slide must only be active while grounded on a valid slope.
            -- Previously this loop only checked s.momentum <= 0 to end the slide, so walking
            -- off a cliff/edge mid-slide left the character in isSliding=true with a
            -- horizontal BodyVelocity still being re-applied every frame while they fell --
            -- the slide "kept going forever" instead of dropping into a normal fall. Now:
            -- the instant FloorMaterial goes to Air (left the ground) or the surface
            -- underfoot is too steep to stand on (>60°), the slide ends immediately and its
            -- current horizontal velocity is transferred onto the character as real
            -- AssemblyLinearVelocity so momentum carries into the fall/jump instead of being
            -- lost outright. s.momentum itself is untouched by endSlide, so a player who
            -- still holds sprint direction on landing picks sprinting back up with residual
            -- momentum, per spec.
            local grounded = hum.FloorMaterial ~= Enum.Material.Air
            local slope = grounded and getSlopeType(char) or "flat"
            if not grounded or slope == "toosteep" then
                local exitVel = (s.slideBV and s.slideBV.Parent) and s.slideBV.Velocity or Vector3.new(0, 0, 0)
                endSlide(player, s)
                hrp.AssemblyLinearVelocity = Vector3.new(exitVel.X, hrp.AssemblyLinearVelocity.Y, exitVel.Z)
                continue
            end

            -- Downhill (cliffs) builds momentum instead of draining it, same as sprinting
            -- downhill does -- previously slide ALWAYS drained momentum regardless of slope,
            -- so sliding down a cliff felt identical to sliding on flat ground.
            if slope == "downhill" then
                s.momentum = math.min(100, s.momentum + MOM.BuildSlideDown * dt)
            else
                local drain = slope == "uphill" and MOM.DrainSlideUp or MOM.DrainSlide
                s.momentum  = math.max(0, s.momentum - drain * dt)
            end
            ensureSlideSmoke(char, s) -- unthrottled: wants to exist the instant a slide starts, not up to 0.1s later
            -- Decay the BodyVelocity proportionally so the slide slows naturally, while
            -- letting the player carve: direction turns toward current WASD input
            -- (MoveDirection still updates with WalkSpeed=0 — it reflects input, not speed)
            -- at a capped rate, instead of staying locked to the direction it started in.
            if s.slideBV and s.slideBV.Parent then
                local vel = s.slideBV.Velocity
                local curDir = vel.Magnitude > 0.1 and Vector3.new(vel.X, 0, vel.Z).Unit
                             or Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z).Unit
                local moveDir = Vector3.new(hum.MoveDirection.X, 0, hum.MoveDirection.Z)
                local newDir = curDir
                if moveDir.Magnitude > 0.1 then
                    moveDir = moveDir.Unit
                    local curYaw = math.atan2(-curDir.X, -curDir.Z)
                    local desiredYaw = math.atan2(-moveDir.X, -moveDir.Z)
                    local maxStep = math.rad(MOM.SlideTurnSpeed) * dt
                    local diff = (desiredYaw - curYaw + math.pi) % (2 * math.pi) - math.pi
                    local step = math.clamp(diff, -maxStep, maxStep)
                    local newYaw = curYaw + step
                    newDir = Vector3.new(-math.sin(newYaw), 0, -math.cos(newYaw))
                end
                -- Speed directly tied to momentum so slide visibly decelerates
                local slideSpd = math.max(5, 8 + s.momentum * 0.6)
                s.slideBV.Velocity = newDir * slideSpd
            end
            -- End the slide once it has decayed to a crawl (momentum ~8 = ~13 studs/s)
            -- instead of riding it all the way to zero -- the last stretch was slower than
            -- walking and read as the slide "dying" rather than ending.
            if s.momentum <= 8 then endSlide(player, s) end

        elseif s.isSprinting then
            -- Stamina drain
            local cm = _G.CombatManager
            if cm and cm.isActionBlocked(player) then stopSprint(player, s); continue end
            -- M1/M2 stops sprint; other non-Idle states (parry, block) just pause the tick
            local _cs = cm and cm.getCombatState and cm.getCombatState(player) or "Idle"
            if _cs == "Attacking" then stopSprint(player, s); continue end
            if _cs ~= "Idle" then continue end
            if sm and not sm.drain(player, staminaCfg.CostSprint * dt, true) then
                stopSprint(player, s); continue
            end
            -- Momentum build/drain from slope
            local slope = getSlopeType(char)
            if slope == "downhill" then
                s.momentum = math.min(100, s.momentum + MOM.BuildDownhill * dt)
                applySprintSpeed(player, s.momentum)
            elseif slope == "uphill" then
                s.momentum = math.max(0, s.momentum - MOM.DrainUphill * dt)
                setMovementState(player, "Sprint")  -- no bonus uphill
            else
                s.momentum = math.min(100, s.momentum + MOM.BuildFlat * dt)
                applySprintSpeed(player, s.momentum)
            end
        else
            -- Idle drain
            if s.momentum > 0 then
                s.momentum = math.max(0, s.momentum - MOM.DrainIdle * dt)
            end
        end

        -- Slide-jump boost: steer the airborne launch velocity toward whatever direction
        -- the player is currently holding, instead of leaving it locked to the direction
        -- the character happened to be facing at the moment of takeoff.
        if s.slideJumpBV and s.slideJumpBV.Parent then
            if tick() < s.slideJumpBoostUntil then
                local moveDir = Vector3.new(hum.MoveDirection.X, 0, hum.MoveDirection.Z)
                if moveDir.Magnitude > 0.1 then
                    s.slideJumpBV.Velocity = moveDir.Unit * SLIDE_JUMP_BOOST_SPEED
                end
            else
                s.slideJumpBV:Destroy()
                s.slideJumpBV = nil
            end
        end

        -- Jump power: set proactively every frame (spec: boost at momentum > 50)
        updateJumpPower(player, s.momentum, s.isCrouching)

        -- Particle update throttled to ~10 Hz
        s.partThrottle = s.partThrottle + dt
        if s.partThrottle >= 0.1 then
            s.partThrottle = 0
            ensureParticles(char, s)
            updateParticles(s, s.momentum)
        end

        -- Slide smoke: unthrottled Enabled toggle so it starts/stops the instant isSliding
        -- flips (e.g. right when endSlide fires above in this same frame), not up to 0.1s late.
        for _, e in pairs(s.slideSmoke) do
            if e and e.Parent then e.Enabled = s.isSliding end
        end
    end
end)

-- ─── PUBLIC API ──────────────────────────────────────────────────────────────
local MovementManager = {}
MovementManager.setMovementState   = setMovementState
MovementManager.isSprinting        = function(p) local s=getPS(p); return s~=nil and s.isSprinting end
MovementManager.isSliding          = function(p) local s=getPS(p); return s~=nil and s.isSliding end
MovementManager.isCrouching        = function(p) local s=getPS(p); return s~=nil and s.isCrouching end
MovementManager.isDashOnCooldown   = function(p) local s=getPS(p); return s~=nil and tick()<s.dashCooldownUntil end
MovementManager.isDashing          = function(p) local s=getPS(p); return s~=nil and s.isDashing end
MovementManager.getMomentum        = function(p) local s=getPS(p); return s and s.momentum or 0 end
MovementManager.startSprint        = startSprint
MovementManager.stopSprint         = stopSprint
MovementManager.dash               = processDash
MovementManager.slide              = processSlide
MovementManager.crouch             = processCrouch
MovementManager.jump               = processJump
-- Combat polish 4E: Dash->Parry cancel. During the last CancelWindowFrames of a dash's
-- travel, pressing F cancels the dash immediately and lets ParryManager's normal
-- activateParry take over (own cooldown/stamina/equip checks still apply -- this only
-- cuts the dash short, it doesn't bypass parry's own rules). Called from ParryManager's
-- RequestParry handler before its usual checks.
local cancelCfg = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config")).Combat
function MovementManager.tryCancelDashToParry(player)
    if not cancelCfg.DashToParryCancel then return false end
    local s = getPS(player); if not s or not s.isDashing then return false end
    local windowSec = (cancelCfg.CancelWindowFrames or 4) / 60
    local elapsed = tick() - (s.dashStartTime or 0)
    if elapsed < DASH_TRAVEL_DURATION - windowSec then return false end
    s.isDashing = false
    s.dashToken = (s.dashToken or 0) + 1
    if s.activeDashBV and s.activeDashBV.Parent then s.activeDashBV:Destroy() end
    s.activeDashBV = nil
    local char = player.Character
    local hrp = char and char:FindFirstChild("HumanoidRootPart")
    if hrp then
        local vel = hrp.AssemblyLinearVelocity
        hrp.AssemblyLinearVelocity = Vector3.new(0, vel.Y, 0)
    end
    return true
end

MovementManager.consumeSlideJump   = function(p)
    local s=getPS(p); if not s or not s.wasSlideJump then return false end
    s.wasSlideJump = false; return true
end
_G.MovementManager = MovementManager

print(string.format(
    "[MovementManager] Init — Base=%d | Sprint=%d→%d | SlideMin=%.0f mom | JumpBoost@>%.0f mom",
    BASE_WALK_SPEED, SPRINT_SPEED, SPRINT_MAX_SPEED, MOM.SlideMinMom, MOM.JumpThreshold
))
