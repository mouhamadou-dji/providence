-- RagdollManager.server.lua
-- Handles Motor6D ragdoll / unragdoll for Downed and Death states.
-- All state changes are server-authoritative; Motor6D.Enabled replicates to clients.

local PhysicsService = game:GetService("PhysicsService")
local Players        = game:GetService("Players")
local RunService     = game:GetService("RunService")

-- ── Collision groups ──────────────────────────────────────────────────────────
local GRP_RAGDOLL = "RagdolledPlayers"
local GRP_PLAYERS = "Players"

pcall(function() PhysicsService:RegisterCollisionGroup(GRP_RAGDOLL) end)
pcall(function() PhysicsService:RegisterCollisionGroup(GRP_PLAYERS) end)
pcall(function() PhysicsService:CollisionGroupSetCollidable(GRP_RAGDOLL, GRP_PLAYERS, false) end)

-- ── Helpers ───────────────────────────────────────────────────────────────────
local function getAllMotor6Ds(character)
    local motors = {}
    for _, d in ipairs(character:GetDescendants()) do
        if d:IsA("Motor6D") then motors[#motors + 1] = d end
    end
    return motors
end

-- Disabling a Motor6D alone does nothing to hold the two parts together -- Motor6Ds
-- are the ONLY thing connecting an R6 character's limbs, so disabling them lets
-- every limb become an independent rigid body (flies apart from residual velocity,
-- can clip through thin floors at high speed and fall out of the map). Fix: mirror
-- each Motor6D with a BallSocketConstraint at the same joint position, built once
-- and cached, enabled only while ragdolled -- joints rotate freely (limp) while
-- staying physically attached.
local function ensureRagdollConstraints(character)
    local rigFolder = character:FindFirstChild("RagdollConstraints")
    if rigFolder then return rigFolder end
    rigFolder = Instance.new("Folder")
    rigFolder.Name = "RagdollConstraints"
    rigFolder.Parent = character
    for _, motor in ipairs(getAllMotor6Ds(character)) do
        local part0, part1 = motor.Part0, motor.Part1
        if part0 and part1 then
            local a0 = Instance.new("Attachment")
            a0.Name = "RagdollA0_" .. motor.Name
            a0.CFrame = motor.C0
            a0.Parent = part0
            local a1 = Instance.new("Attachment")
            a1.Name = "RagdollA1_" .. motor.Name
            a1.CFrame = motor.C1
            a1.Parent = part1
            local socket = Instance.new("BallSocketConstraint")
            socket.Name = "RagdollSocket_" .. motor.Name
            socket.Attachment0 = a0
            socket.Attachment1 = a1
            socket.LimitsEnabled = true
            socket.TwistLimitsEnabled = true
            socket.UpperAngle = 60
            socket.TwistUpperAngle = 30
            socket.TwistLowerAngle = -30
            socket.Enabled = false
            socket.Parent = rigFolder
        end
    end
    return rigFolder
end

local function setRagdollConstraintsEnabled(character, enabled)
    local rigFolder = character:FindFirstChild("RagdollConstraints")
    if not rigFolder then return end
    for _, c in ipairs(rigFolder:GetChildren()) do
        if c:IsA("BallSocketConstraint") then c.Enabled = enabled end
    end
end

local function setCollisionGroup(character, group)
    for _, d in ipairs(character:GetDescendants()) do
        if d:IsA("BasePart") then d.CollisionGroup = group end
    end
end

-- R6's default rig only has Torso/Head with CanCollide=true -- Left/Right Arm/Leg are
-- CanCollide=false by default (so limbs don't snag on stairs/geometry during normal
-- walking). That's fine while a Motor6D holds them rigidly to the torso, but once
-- ragdolled the limbs swing loose under gravity and, since they don't collide with
-- anything, sink straight through the floor while only the torso/head stay on top.
-- Force every limb to collide while ragdolled so the whole body rests on the ground,
-- then restore each part's original value on unragdoll (walking with colliding limbs
-- would reintroduce the stair-snagging Roblox's default avoids).
local function setLimbsCollidable(character, collidable)
    for _, d in ipairs(character:GetDescendants()) do
        if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
            if collidable then
                if d:GetAttribute("RagdollOrigCanCollide") == nil then
                    d:SetAttribute("RagdollOrigCanCollide", d.CanCollide)
                end
                d.CanCollide = true
            else
                local orig = d:GetAttribute("RagdollOrigCanCollide")
                if orig ~= nil then d.CanCollide = orig end
            end
        end
    end
end

-- Roblox's own engine forces limb CanCollide back to false within the very next
-- physics step whenever PlatformStand=true is combined with disabled Motor6Ds (an
-- R6-specific internal behavior, confirmed by direct testing -- a one-time assignment
-- gets silently overwritten almost immediately). The only reliable way to win is to
-- keep re-asserting it every frame for as long as the character stays ragdolled.
local collisionEnforceConns = {} -- [character] = RBXScriptConnection

local function startCollisionEnforcement(character)
    if collisionEnforceConns[character] then return end
    collisionEnforceConns[character] = RunService.Heartbeat:Connect(function()
        if not character.Parent then
            collisionEnforceConns[character]:Disconnect()
            collisionEnforceConns[character] = nil
            return
        end
        for _, d in ipairs(character:GetDescendants()) do
            if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" and not d.CanCollide then
                d.CanCollide = true
            end
        end
    end)
end

local function stopCollisionEnforcement(character)
    local conn = collisionEnforceConns[character]
    if conn then conn:Disconnect(); collisionEnforceConns[character] = nil end
end

-- ── Assign "Players" group to each spawned character ─────────────────────────
local function setupCharCollision(character)
    character:WaitForChild("HumanoidRootPart", 5)
    setCollisionGroup(character, GRP_PLAYERS)
end

Players.PlayerAdded:Connect(function(player)
    player.CharacterAdded:Connect(function(character)
        setupCharCollision(character)
    end)
end)
for _, player in ipairs(Players:GetPlayers()) do
    if player.Character then setupCharCollision(player.Character) end
    player.CharacterAdded:Connect(function(character)
        setupCharCollision(character)
    end)
end

-- ── Public API ────────────────────────────────────────────────────────────────
local RagdollManager = {}

-- Disable all Motor6D joints → character collapses under physics.
-- impulse (Vector3, optional): additional velocity applied to HumanoidRootPart.
function RagdollManager.ragdoll(character, impulse)
    if not character or not character.Parent then return end
    local hum = character:FindFirstChildOfClass("Humanoid")
    if hum then hum.PlatformStand = true end
    ensureRagdollConstraints(character)
    for _, motor in ipairs(getAllMotor6Ds(character)) do
        motor.Enabled = false
    end
    setRagdollConstraintsEnabled(character, true)
    setLimbsCollidable(character, true)
    startCollisionEnforcement(character)
    setCollisionGroup(character, GRP_RAGDOLL)
    if impulse then
        local hrp = character:FindFirstChild("HumanoidRootPart")
        if hrp then
            hrp.AssemblyLinearVelocity = hrp.AssemblyLinearVelocity + impulse
        end
    end
end

-- Re-enable all Motor6D joints → character can be posed / animated again.
function RagdollManager.unragdoll(character)
    if not character or not character.Parent then return end
    local hum = character:FindFirstChildOfClass("Humanoid")
    if hum then hum.PlatformStand = false end
    setRagdollConstraintsEnabled(character, false)
    stopCollisionEnforcement(character)
    setLimbsCollidable(character, false)
    for _, motor in ipairs(getAllMotor6Ds(character)) do
        motor.Enabled = true
    end
    setCollisionGroup(character, GRP_PLAYERS)
end

-- Death ragdoll: ragdoll + optional impulse → fade 3 s → Health = 0.
function RagdollManager.applyDeathRagdoll(character, impulse)
    if not character or not character.Parent then return end
    RagdollManager.ragdoll(character, impulse)
    local hum = character:FindFirstChildOfClass("Humanoid")
    task.delay(3, function()
        if not character or not character.Parent then return end
        for i = 1, 20 do
            if not character.Parent then break end
            local alpha = i / 20
            for _, part in ipairs(character:GetDescendants()) do
                if part:IsA("BasePart") then part.Transparency = alpha end
            end
            task.wait(0.15)
        end
        if hum and hum.Parent then hum.Health = 0 end
    end)
end

_G.RagdollManager = RagdollManager

print(string.format("[RagdollManager] Init — groups: '%s' × '%s' = non-collidable",
    GRP_RAGDOLL, GRP_PLAYERS))