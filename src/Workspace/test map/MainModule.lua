-- Saved by UniversalSynSaveInstance (Join to Copy Games) https://discord.gg/wx4ThpAsmw

-- https://lua.expert/
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedEvents = ReplicatedStorage:WaitForChild("ReplicatedEvents")
local TweenService = game:GetService("TweenService")
local ProjectileStart = ReplicatedEvents.ProjectileStart
local ProjectileHit = ReplicatedEvents.ProjectileHit
local ReplicateAim = ReplicatedEvents.ReplicateAim
local DoBlood = ReplicatedEvents.DoBlood
local DoSpark = ReplicatedEvents.DoSpark
local ArtilleryReplicated = ReplicatedStorage:WaitForChild("ArtilleryReplicated")
local ArtilleryEvents = ArtilleryReplicated.ArtilleryEvents
local MoveArcade = ArtilleryEvents.MoveArcade
local MoveRealistic = ArtilleryEvents.MoveRealistic
local ElevateArcade = ArtilleryEvents.ElevateArcade
local ElevateRealistic = ArtilleryEvents.ElevateRealistic
local ChangeRPM = ArtilleryEvents.ChangeRPM
local Debris = game:GetService("Debris")

ReplicatedStorage:WaitForChild("FirearmsReplicated").MusketFire:GetChildren()
ArtilleryReplicated.CannonFire:GetChildren()

local t = {}
local t2 = {}

local function getLeaderstats(p1) --[[ getLeaderstats | Line: 34 ]]
    if p1 and p1:IsA("Player") then
        return p1:FindFirstChild("leaderstats")
    end

    return nil
end

local function getOrCreateDamageStat(p1) --[[ getOrCreateDamageStat | Line: 41 ]]
    local v1 = if p1 and p1:IsA("Player") then p1:FindFirstChild("leaderstats") else nil

    if not v1 then
        return nil
    end

    local v2 = v1:FindFirstChild("DamageDealt") or v1:FindFirstChild("Damage")

    if not v2 then
        local DamageDealt = Instance.new("IntValue")

        DamageDealt.Name = "DamageDealt"
        DamageDealt.Value = 0
        DamageDealt.Parent = v1
        v2 = DamageDealt
    end

    return v2
end

local function addDamage(p1, p2) --[[ addDamage | Line: 60 | Upvalues: t2 (copy), getOrCreateDamageStat (copy) ]]
    if not (p1 and p1:IsA("Player")) then
        return
    end

    if type(p2) ~= "number" then
        return
    end

    local v1 = math.floor(p2)

    if v1 <= 0 then
        return
    end

    local v2 = (t2[p1] or 0) + v1

    t2[p1] = v2

    local v3 = getOrCreateDamageStat(p1)

    if not v3 then
        return
    end

    v3.Value = v2
end

function t.GetPlayerDamage(p1) --[[ GetPlayerDamage | Line: 84 | Upvalues: t2 (copy) ]]
    return t2[p1] or 0
end
function t.ResetPlayerDamage(p1) --[[ ResetPlayerDamage | Line: 88 | Upvalues: t2 (copy), getOrCreateDamageStat (copy) ]]
    if not (p1 and p1:IsA("Player")) then
        return
    end

    t2[p1] = 0

    local v1 = getOrCreateDamageStat(p1)

    if not v1 then
        return
    end

    v1.Value = 0
end
function t.AddDamage(p1, p2) --[[ AddDamage | Line: 100 | Upvalues: t2 (copy), getOrCreateDamageStat (copy) ]]
    if not p1 then
        return
    end

    if not p1:IsA("Player") then
        return
    end

    if type(p2) ~= "number" then
        return
    end

    local v1 = math.floor(p2)

    if v1 <= 0 then
        return
    end

    local v2 = (t2[p1] or 0) + v1

    t2[p1] = v2

    local v3 = getOrCreateDamageStat(p1)

    if not v3 then
        return
    end

    v3.Value = v2
end
Players.PlayerAdded:Connect(function(p1) --[[ Line: 104 | Upvalues: t2 (copy), getOrCreateDamageStat (copy) ]]
    t2[p1] = t2[p1] or 0

    if p1:FindFirstChild("leaderstats") then
        local v1 = getOrCreateDamageStat(p1)

        if v1 then
            v1.Value = t2[p1]
        end
    end

    p1.ChildAdded:Connect(function(p12) --[[ Line: 117 | Upvalues: getOrCreateDamageStat (ref), p1 (copy), t2 (ref) ]]
        if p12.Name ~= "leaderstats" then
            return
        end

        local v1 = getOrCreateDamageStat(p1)

        if not v1 then
            return
        end

        v1.Value = t2[p1] or 0
    end)
end)
Players.PlayerRemoving:Connect(function(p1) --[[ Line: 127 | Upvalues: t2 (copy) ]]
    t2[p1] = nil
end)

local function SeatLeave(p1, p2) --[[ SeatLeave | Line: 135 ]]
    local Occupant = p2.Values.Occupant

    p2.Values.Occupant.Value = nil

    local Occupied = p1.Character.Humanoid:FindFirstChild("Occupied")

    if Occupied then
        Occupied:Destroy()
    end

    local SitPartClone = p2.Chassis:FindFirstChild("SitPartClone")

    if not SitPartClone then
        return true
    end

    SitPartClone:Destroy()

    return true
end

local function CannonCheck(p1, p2) --[[ CannonCheck | Line: 150 | Upvalues: SeatLeave (copy) ]]
    local Character = p1.Character
    local Occupant = p2.Values.Occupant
    local Roped = p2.Values:FindFirstChild("Roped")
    local SitPartClone = p2.Chassis:FindFirstChild("SitPartClone", true)

    if SitPartClone and Occupant.Value then
        local Character2 = Occupant.Value.Character

        if not Character2 then
            SeatLeave(p1, p2)

            return false
        end

        local Occupied = Character2:FindFirstChild("Humanoid"):FindFirstChild("Occupied")
        local Weld = SitPartClone:FindFirstChild("Weld")

        if not Occupied or (not Weld or Occupied.Value ~= Weld) then
            SeatLeave(p1, p2)
        end

        return false
    end

    if SitPartClone then
        SeatLeave(p1, p2)

        return false
    end

    local function ResetRope() --[[ ResetRope | Line: 176 | Upvalues: p2 (copy), Roped (copy), Occupant (copy) ]]
        local Rope = p2.Chassis.RopePart:FindFirstChild("Rope")

        if Rope then
            Rope:Destroy()
        end

        Roped.Value = false
        Occupant.Value = nil
        p2.Chassis.RopePart.Transparency = 1

        local v1 = p2:GetDescendants()

        for i = 1, #v1 do
            if v1[i]:IsA("BasePart") then
                v1[i].Anchored = true

                continue
            end

            if v1[i]:IsA("Weld") then
                v1[i]:Destroy()
            end
        end

        return false
    end

    if Roped and (Roped.Value and Occupant.Value) then
        local Character2 = Occupant.Value.Character

        if Character2 then
            local Occupied = Character2:FindFirstChild("Humanoid"):FindFirstChild("Occupied")
            local Rope = p2.Chassis.RopePart:FindFirstChild("Rope")

            if Occupied and (Rope and Occupied.Value == Rope) then
                return false
            end
        end
    elseif not (Roped and Roped.Value) then
        return true
    end

    ResetRope()

    return true
end

local function SeatOccupy(p1, p2) --[[ SeatOccupy | Line: 214 | Upvalues: CannonCheck (copy) ]]
    local Character = p1.Character
    local Occupant = p2.Values.Occupant

    if not p1.Character or (Character.Humanoid.Health == 0 or (not p1:FindFirstChild("Swab", true) or Character.Humanoid:FindFirstChild("Occupied"))) then
        return false
    end

    if not p2.Values.MoveEnabled.Value then
        return false
    end

    if CannonCheck(p1, p2) then
        Occupant.Value = p1

        local v1 = p2:WaitForChild("ArtilleryLocal"):Clone()

        v1:WaitForChild("ParentedCannon").Value = p2
        v1.Parent = p1:WaitForChild("PlayerGui")
        v1.Disabled = false

        local SitPartClone = p2.Chassis.SitPart:Clone()

        SitPartClone.Parent = p2.Chassis
        SitPartClone.Name = "SitPartClone"

        local Weld = Instance.new("Weld", SitPartClone)

        Weld.Part0 = SitPartClone
        Weld.Part1 = Character.HumanoidRootPart

        local Occupied = Instance.new("ObjectValue")

        Occupied.Name = "Occupied"
        Occupied.Value = Weld
        Occupied.Parent = Character.Humanoid

        return true
    end

    return false
end

local function MakeRope(p1, p2) --[[ MakeRope | Line: 243 | Upvalues: CannonCheck (copy), t (copy) ]]
    local Character = p1.Character
    local Roped = p2.Values.Roped

    if not p1.Character or (Character.Humanoid.Health == 0 or (not p1:FindFirstChild("Swab", true) or Character.Humanoid:FindFirstChild("Occupied"))) then
        return false
    end

    if not p2.Values.MoveEnabled.Value then
        return false
    end

    if not CannonCheck(p1, p2) then
        return false
    end

    local RopePart = p2.Chassis.RopePart
    local CannonRoot = p2.Chassis.CannonRoot

    p2.Values.Roped.Value = true

    local TorsoRopeAttachment = Instance.new("Attachment")

    TorsoRopeAttachment.Name = "TorsoRopeAttachment"
    TorsoRopeAttachment.Parent = Character.Torso

    local Rope = Instance.new("RopeConstraint")

    Rope.Name = "Rope"
    Rope.Attachment0 = RopePart.RopeAttachment
    Rope.Attachment1 = TorsoRopeAttachment
    Rope.Length = 6
    Rope.Visible = true
    Rope.Parent = RopePart
    RopePart.Transparency = 0

    local Occupied = Instance.new("ObjectValue")

    Occupied.Name = "Occupied"
    Occupied.Value = Rope
    Occupied.Parent = Character.Humanoid
    p2.Values.Occupant.Value = p1

    local v1 = p2:GetDescendants()

    for i = 1, #v1 do
        if v1[i]:IsA("BasePart") and (v1[i].Parent ~= p2.LeftWheel and v1[i].Parent ~= p2.RightWheel) then
            t.MakeWeld(v1[i], CannonRoot, "Weld")
            v1[i].Anchored = false
        end
    end

    local LWheelRoot = p2.LeftWheel.LWheelRoot
    local v2 = p2.LeftWheel:GetChildren()

    for j = 1, #v2 do
        t.MakeWeld(v2[j], LWheelRoot, "Weld")
        v2[j].Anchored = false
    end

    local RWheelRoot = p2.RightWheel.RWheelRoot
    local v3 = p2.RightWheel:GetChildren()

    for k = 1, #v3 do
        t.MakeWeld(v3[k], RWheelRoot, "Weld")
        v3[k].Anchored = false
    end

    RopePart:SetNetworkOwner(p1)

    return true
end

local function v1(p1) --[[ HandleIntegrityRecursive | Line: 301 | Upvalues: v1 (copy) ]]
    local CollisionWhenDestroyed = p1:FindFirstChild("CollisionWhenDestroyed")
    local TransparencyWhenDestroyed = p1:FindFirstChild("TransparencyWhenDestroyed")

    for k, v in pairs(p1:GetChildren()) do
        if v:IsA("Model") then
            v1(v)

            continue
        end

        if v:IsA("BasePart") or (v:IsA("MeshPart") or v:IsA("UnionOperation")) then
            if CollisionWhenDestroyed then
                v.CanCollide = CollisionWhenDestroyed.Value
            else
                v.CanCollide = false
            end

            if TransparencyWhenDestroyed then
                v.Transparency = TransparencyWhenDestroyed.Value
            else
                v.Transparency = 1
            end

            for k2, v2 in pairs(v:GetChildren()) do
                if v2:IsA("ParticleEmitter") then
                    task.spawn(function() --[[ Line: 321 | Upvalues: v2 (copy) ]]
                        v2:Emit(v2.Rate * 0.2)
                    end)

                    continue
                end

                if v2:IsA("Sound") then
                    v2:Play()
                end
            end
        end
    end
end

local function DestroyRope(p1, p2) --[[ DestroyRope | Line: 332 ]]
    local Character = p1.Character
    local RopePart = p2.Chassis.RopePart
    local Rope = RopePart:FindFirstChild("Rope")
    local TorsoRopeAttachment = Character.Torso:FindFirstChild("TorsoRopeAttachment")

    if not TorsoRopeAttachment then
        return false
    end

    if not Rope then
        return false
    end

    if Rope.Attachment0 ~= p2.Chassis.RopePart.RopeAttachment then
        return false
    end

    if Rope.Attachment1 ~= TorsoRopeAttachment then
        return false
    end

    Rope:Destroy()
    TorsoRopeAttachment:Destroy()
    RopePart.Transparency = 1
    p2.Values.Roped.Value = false
    p2.Values.Occupant.Value = nil

    local v1 = p2:GetDescendants()

    for i = 1, #v1 do
        if v1[i]:IsA("BasePart") then
            v1[i].Anchored = true

            continue
        end

        if v1[i]:IsA("Weld") then
            v1[i]:Destroy()
        end
    end

    local Occupied = Character.Humanoid:FindFirstChild("Occupied")

    if not Occupied then
        return true
    end

    Occupied:Destroy()

    return true
end

local function RunWhitelistCheck() --[[ RunWhitelistCheck | Line: 365 ]]
    local t = {}

    for k, v in pairs(workspace:GetChildren()) do
        if v:FindFirstChild("Humanoid") and v:FindFirstChild("Torso") then
            table.insert(t, v.Torso)
        end
    end

    return t
end

local function v2(p1, p2) --[[ CheckForHumanoid | Line: 376 | Upvalues: v2 (copy) ]]
    if p2 then
        if p2 >= 6 then
            print("tried too many times")

            return false
        end
    else
        p2 = 0
    end

    if not p1 then
        return false
    end

    local v1 = p1.Parent

    if not v1 or v1 == workspace then
        return false
    end

    local v22 = v1:FindFirstChildWhichIsA("Humanoid")

    if v22 then
        return v22
    end

    return v2(v1, p2 + 1)
end

local function DetermineTeams(p1, p2, p3) --[[ DetermineTeams | Line: 401 | Upvalues: v2 (copy), Players (copy) ]]
    local v1 = v2(p1)

    if not v1 then
        return false
    end

    local v22 = Players:GetPlayerFromCharacter(v1.Parent)

    if (not v22 or (not p3 or v22.Team == p3.Team)) and ((not v22 or (v22.Team ~= p3.Team or not p2)) and v22) then
        return false
    end

    return v1
end

local function CreateCreator(p1, p2, p3) --[[ CreateCreator | Line: 414 | Upvalues: t2 (copy), getOrCreateDamageStat (copy) ]]
    if p1.Health - p3 <= 0 then
        local creator = Instance.new("ObjectValue")

        creator.Name = "creator"
        creator.Value = p2
        creator.Parent = p1
    end

    p1:TakeDamage(p3)

    if not (p2 and p2) then
        return
    end

    if not p2:IsA("Player") then
        return
    end

    if type(p3) ~= "number" then
        return
    end

    local v1 = math.floor(p3)

    if v1 <= 0 then
        return
    end

    local v2 = (t2[p2] or 0) + v1

    t2[p2] = v2

    local v3 = getOrCreateDamageStat(p2)

    if not v3 then
        return
    end

    v3.Value = v2
end

local function checkPosition(p1, p2, p3) --[[ checkPosition | Line: 429 | Upvalues: Players (copy) ]]
    if Players:FindFirstChild(p2) then
        local Character = Players[p2].Character

        return Character and (Character.PrimaryPart and (Character.PrimaryPart.Position - p1).Magnitude <= p3) and true or false
    end

    return false
end

function t.PlayAnimation(p1, p2, p3, p4) --[[ PlayAnimation | Line: 443 ]]
    if p2 or p3 then
        if p2 == "Wait" then
            p1:Play(0, 1, 1)
            p1.Stopped:Wait()

            return
        end

        if p2 == "Reverse" then
            if p1.IsPlaying then
                p1:AdjustSpeed(-1)
            else
                p1:Play(0, 1, -1)
                p1.TimePosition = p1.Length
            end

            return
        end

        if p2 == "Morph" then
            p1:Play(p3, 1, 1)
            task.spawn(function() --[[ Line: 462 | Upvalues: p4 (copy), p3 (copy) ]]
                if not p4 then
                    return
                end

                p4:AdjustWeight(0, p3)
                task.wait(p3)
                p4:Stop()
            end)

            return
        end

        if p2 ~= "ReverseMorph" then
            return
        end

        p1:Play(p3, 1, -1)
        p1.TimePosition = p1.Length
        task.spawn(function() --[[ Line: 472 | Upvalues: p4 (copy), p3 (copy) ]]
            if not p4 then
                return
            end

            p4:AdjustWeight(0, p3)
            task.wait(p3)
            p4:Stop()
        end)
    else
        if p1.IsPlaying and p1.Speed == 0 then
            p1:AdjustSpeed(1)

            return
        end

        if not p1.IsPlaying then
            p1:Play()
        end
    end
end
function t.MoveHumanoid(p1, p2) --[[ MoveHumanoid | Line: 482 | Upvalues: TweenService (copy) ]]
    local HumanoidRootPart = p1.Parent.HumanoidRootPart
    local v2 = TweenService:Create(HumanoidRootPart, TweenInfo.new(0.25 + (HumanoidRootPart.Position - p2.Position).Magnitude / 8), {
        CFrame = p2
    })

    v2:Play()
    v2.Completed:Wait()
end
function t.PlayServerSound(p1, p2) --[[ PlayServerSound | Line: 492 ]]
    p1.Events.PlaySound:FireServer(p2)
end
function t.SetPart(p1) --[[ SetPart | Line: 496 ]]
    local Part = Instance.new("Part")

    Part.Size = Vector3.new(1, 1, 1)
    Part.Anchored = true
    Part.CanCollide = false
    Part.CanQuery = false
    Part.CanTouch = false
    Part.Position = p1
    Part.Parent = workspace
    game.Debris:AddItem(Part, 0.25)
end
function t.CreateConnection(p1, p2, p3, p4) --[[ CreateConnection | Line: 508 ]]
    table.insert(p3, (p1:GetMarkerReachedSignal(p2):Connect(p4)))
end
function t.CreateEnding(p1, p2, p3) --[[ CreateEnding | Line: 513 ]]
    table.insert(p2, (p1.Stopped:Connect(p3)))
end
function t.RemoveAnimations(p1, p2) --[[ RemoveAnimations | Line: 518 ]]
    for k, v in pairs(p2:GetPlayingAnimationTracks()) do
        if v.Name ~= "WalkAnim" and v.Name ~= "JumpAnim" then
            v:Stop()
        end
    end
end
function t.RemoveConnections(p1) --[[ RemoveConnections | Line: 526 ]]
    for k, v in pairs(p1) do
        v:Disconnect()
        p1[v] = nil
    end
end
function t.MakeWeld(p1, p2, p3, p4) --[[ MakeWeld | Line: 533 ]]
    local Weld = Instance.new("Weld")

    if p3 then
        Weld.Name = p3
    else
        Weld.Name = p2.Name .. "Weld"
    end

    Weld.Part0 = p1
    Weld.Part1 = p2
    Weld.C0 = p1.CFrame:ToObjectSpace(p2.CFrame)
    Weld.C1 = CFrame.new()

    if p4 then
        Weld.Parent = p4
    else
        Weld.Parent = p1
    end

    return Weld
end
function t.createConstructable(p1, p2, p3) --[[ createConstructable | Line: 552 | Upvalues: ReplicatedStorage (copy) ]]
    local v1 = ReplicatedStorage.Constructables:FindFirstChild(p3)
    local Model = Instance.new("Model")

    Model.Name = p3
    v1.BuildIncrement:Clone().Parent = Model
    v1.BuildType:Clone().Parent = Model
    v1.Integrity:Clone().Parent = Model
    v1.MaxIntegrity:Clone().Parent = Model

    local v2 = v1.ConstructableScript:Clone()

    v2.Parent = Model
    v2.Enabled = true

    local v3 = v1[p3 .. "BP"]:Clone()

    v3.PrimaryPart = v3:WaitForChild("RootPart")
    v3:SetPrimaryPartCFrame(p2)
    v3.Parent = Model
    Model.Parent = workspace
end
function t.HandleIntegrity(p1, p2) --[[ HandleIntegrity | Line: 573 | Upvalues: v1 (copy) ]]
    if not p1:IsA("Model") then
        print("Somehow, part passed was not a model.")

        return
    end

    local Integrity = p1:FindFirstChild("Integrity")

    if not (Integrity and Integrity:IsA("NumberValue")) then
        return
    end

    Integrity.Value = p2

    if not (p2 <= 0) then
        return
    end

    v1(p1)
end
function t.ProjectileStartFired(p1, p2, p3, p4, p5) --[[ ProjectileStartFired | Line: 584 | Upvalues: ProjectileStart (copy) ]]
    local Character = p1.Character

    if not Character then
        return
    end

    if not (Character.Humanoid.Health <= 0) then
        ProjectileStart:FireAllClients(p1, p2, p3, p4, p5)
    end
end
function t.ProjectileHitFired(p1, p2, p3, p4, p5, p6, p7) --[[ ProjectileHitFired | Line: 591 | Upvalues: RunWhitelistCheck (copy), ProjectileHit (copy), v2 (copy), Players (copy), t2 (copy), getOrCreateDamageStat (copy), Debris (copy) ]]
    local v1, v22, v3 = string.unpack(p2, p3)
    local v4 = Vector3.new(v1, v22, v3)
    local v5 = RunWhitelistCheck()

    ProjectileHit:FireAllClients(p2, p3, p4, p6, p7)

    if p4 == 1 or p4 == 1.5 then
        local EnableTK = p5.Settings.Features.EnableTK.Value
        local v7 = (p5.Settings:FindFirstChild("RoundshotImpactRadius", true) or p5.Settings:FindFirstChild("ShellImpactRadius", true)).Value
        local v8 = OverlapParams.new()

        v8.FilterDescendantsInstances = v5
        v8.FilterType = Enum.RaycastFilterType.Include
        v8.MaxParts = 700

        for k, v in pairs((workspace:GetPartBoundsInBox(CFrame.new(v4), Vector3.new(v7, v7, v7) * 2, v8))) do
            local v10
            local v11 = v2(v)

            if v11 then
                local v12 = Players:GetPlayerFromCharacter(v11.Parent)

                v10 = if v12 and (p1 and v12.Team ~= p1.Team) or v12 and (v12.Team == p1.Team and EnableTK) then v11 elseif v12 then false else v11
            else
                v10 = false
            end

            if v10 then
                if v10.Health - 100 <= 0 then
                    local creator = Instance.new("ObjectValue")

                    creator.Name = "creator"
                    creator.Value = p1
                    creator.Parent = v10
                end

                v10:TakeDamage(100)

                if p1 then
                    local v13 = 100

                    if p1 and (p1:IsA("Player") and type(v13) == "number") then
                        local v14 = math.floor(v13)

                        if not (v14 <= 0) then
                            local v15 = (t2[p1] or 0) + v14

                            t2[p1] = v15

                            local v16 = getOrCreateDamageStat(p1)

                            if v16 then
                                v16.Value = v15
                            end
                        end
                    end
                end
            end
        end

        local ArtilleryNegatePart = game.ServerStorage.Artillery.ArtilleryNegatePart
        local v17 = ArtilleryNegatePart.Size.Y / 1.5
        local v18 = OverlapParams.new()

        v18.FilterDescendantsInstances = v5
        v18.FilterType = Enum.RaycastFilterType.Exclude
        v18.MaxParts = 700

        for k, v in pairs((workspace:GetPartBoundsInBox(CFrame.new(v4), Vector3.new(v17, v17, v17) * 2, v18))) do
            if v:IsA("Part") or v:IsA("UnionOperation") then
                local v20 = ArtilleryNegatePart:Clone()

                v20.Position = v4

                local v21 = v:SubtractAsync({ v20 }, Enum.CollisionFidelity.PreciseConvexDecomposition)

                if v21 then
                    v21.Parent = workspace
                    Debris:AddItem(v, 0)
                    table.insert(v5, v21)
                end

                table.insert(v5, v)
            end
        end
    else
        if p4 ~= 3 then
            return
        end

        local EnableTK = p5.Settings.Features.EnableTK.Value
        local _, _2, _3, v222 = string.unpack(p2, p3)
        local v23 = OverlapParams.new()

        v23.FilterDescendantsInstances = v5
        v23.FilterType = Enum.RaycastFilterType.Include
        v23.MaxParts = 700

        for k, v in pairs((workspace:GetPartBoundsInBox(CFrame.new(v4), Vector3.new(v222, v222, v222) * 2, v23))) do
            local v25
            local v26 = v2(v)

            if v26 then
                local v27 = Players:GetPlayerFromCharacter(v26.Parent)

                v25 = if v27 and (p1 and v27.Team ~= p1.Team) or v27 and (v27.Team == p1.Team and EnableTK) then v26 elseif v27 then false else v26
            else
                v25 = false
            end

            if v25 then
                if v25.Health - 100 <= 0 then
                    local creator = Instance.new("ObjectValue")

                    creator.Name = "creator"
                    creator.Value = p1
                    creator.Parent = v25
                end

                v25:TakeDamage(100)

                if p1 then
                    local v28 = 100

                    if p1 and (p1:IsA("Player") and type(v28) == "number") then
                        local v29 = math.floor(v28)

                        if not (v29 <= 0) then
                            local v30 = (t2[p1] or 0) + v29

                            t2[p1] = v30

                            local v31 = getOrCreateDamageStat(p1)

                            if v31 then
                                v31.Value = v30
                            end
                        end
                    end
                end
            end
        end
    end
end
function t.HumanoidManipulation(p1, p2, p3) --[[ HumanoidManipulation | Line: 654 | Upvalues: Players (copy), v2 (copy), t2 (copy), getOrCreateDamageStat (copy), Debris (copy), ServerStorage (copy) ]]
    local v1, v22, v3, v4, v5 = string.unpack("fffff", p3)
    local v6 = Vector3.new(v3, v4, v5)
    local Humanoid = p2:FindFirstChild("Humanoid")

    Players:GetPlayerFromCharacter(p2)

    if not Humanoid then
        return
    end

    local v7 = v2(Humanoid)
    local v8

    if v7 then
        local v9 = Players:GetPlayerFromCharacter(v7.Parent)

        if v9 and (p1 and v9.Team ~= p1.Team) then
            v8 = v7
        else
            if v9 then
                local isTeam = v9.Team == p1.Team
            end

            v8 = if v9 then false else v7
        end
    else
        v8 = false
    end

    if not v8 then
        return
    end

    if v22 == 1 or v22 == 1.5 then
        if Humanoid.Health - 100 <= 0 then
            local creator = Instance.new("ObjectValue")

            creator.Name = "creator"
            creator.Value = p1
            creator.Parent = Humanoid
        end

        Humanoid:TakeDamage(100)

        if p1 then
            local v10 = 100

            if p1 and (p1:IsA("Player") and type(v10) == "number") then
                local v11 = math.floor(v10)

                if not (v11 <= 0) then
                    local v12 = (t2[p1] or 0) + v11

                    t2[p1] = v12

                    local v13 = getOrCreateDamageStat(p1)

                    if v13 then
                        v13.Value = v12
                    end
                end
            end
        end

        local Attachment = Instance.new("Attachment", p2.HumanoidRootPart)
        local LinearVelocity = Instance.new("LinearVelocity")

        LinearVelocity.Attachment0 = Attachment
        LinearVelocity.MaxForce = (1 / 0)
        LinearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
        LinearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World

        if v22 == 1.5 then
            LinearVelocity.VectorVelocity = v6.Unit * 50
        else
            LinearVelocity.VectorVelocity = v6.Unit * 100
        end

        LinearVelocity.Parent = p2.HumanoidRootPart

        local AngularVelocity = Instance.new("AngularVelocity")

        AngularVelocity.Attachment0 = Attachment
        AngularVelocity.MaxTorque = (1 / 0)
        AngularVelocity.RelativeTo = Enum.ActuatorRelativeTo.World

        local v14 = math.random(-50, 50)
        local v15 = math.random(-50, 50)

        AngularVelocity.AngularVelocity = Vector3.new(v14, v15, math.random(-50, 50))
        AngularVelocity.Parent = p2.HumanoidRootPart
        Debris:AddItem(LinearVelocity, 0.2)
        Debris:AddItem(AngularVelocity, 0.2)

        local v16 = ServerStorage.Vocalizations.Blunts:GetChildren()[math.random(1, #ServerStorage.Vocalizations.Blunts:GetChildren())]:Clone()

        v16.Parent = p2.HumanoidRootPart
        v16.PlaybackSpeed = 0.6
        v16.Volume = 4
        v16:Play()
        Debris:AddItem(v16)

        local v17 = v16:Clone()

        v17.SoundId = "rbxassetid://1237557124"
        v17.PlaybackSpeed = math.random(80, 120) / 100
        v17.Parent = p2.HumanoidRootPart
        v17.Volume = 6
        v17:Play()
        Debris:AddItem(v17)
    elseif v22 == 2 then
        if Humanoid.Health - v1 <= 0 then
            local creator = Instance.new("ObjectValue")

            creator.Name = "creator"
            creator.Value = p1
            creator.Parent = Humanoid
        end

        Humanoid:TakeDamage(v1)

        if p1 and (p1 and (p1:IsA("Player") and type(v1) == "number")) then
            local v18 = math.floor(v1)

            if not (v18 <= 0) then
                local v19 = (t2[p1] or 0) + v18

                t2[p1] = v19

                local v20 = getOrCreateDamageStat(p1)

                if v20 then
                    v20.Value = v19
                end
            end
        end

        local Attachment = Instance.new("Attachment", p2.HumanoidRootPart)
        local LinearVelocity = Instance.new("LinearVelocity")

        LinearVelocity.Attachment0 = Attachment
        LinearVelocity.MaxForce = (1 / 0)
        LinearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
        LinearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
        LinearVelocity.VectorVelocity = v6.Unit * 20
        LinearVelocity.Parent = p2.HumanoidRootPart

        local AngularVelocity = Instance.new("AngularVelocity")

        AngularVelocity.Attachment0 = Attachment
        AngularVelocity.MaxTorque = (1 / 0)
        AngularVelocity.RelativeTo = Enum.ActuatorRelativeTo.World

        local v21 = math.random(-50, 50)
        local v222 = math.random(-50, 50)

        AngularVelocity.AngularVelocity = Vector3.new(v21, v222, math.random(-50, 50))
        AngularVelocity.Parent = p2.HumanoidRootPart
        Debris:AddItem(LinearVelocity, 0.2)
        Debris:AddItem(AngularVelocity, 0.2)

        local v23 = ServerStorage.Vocalizations.Blunts:GetChildren()[math.random(1, #ServerStorage.Vocalizations.Blunts:GetChildren())]:Clone()

        v23.Parent = p2.HumanoidRootPart
        v23.PlaybackSpeed = 0.6
        v23.Volume = 4
        v23:Play()
        Debris:AddItem(v23)

        if Humanoid.Health <= 0 then
            local v24 = v23:Clone()

            v24.SoundId = "rbxassetid://1237557124"
            v24.PlaybackSpeed = math.random(80, 120) / 100
            v24.Parent = p2.HumanoidRootPart
            v24.Volume = 6
            v24:Play()
            Debris:AddItem(v24)
        end
    else
        if v22 ~= 3 then
            return
        end

        Humanoid.Sit = true

        local Attachment = Instance.new("Attachment", p2.HumanoidRootPart)
        local LinearVelocity = Instance.new("LinearVelocity")

        LinearVelocity.Attachment0 = Attachment
        LinearVelocity.MaxForce = (1 / 0)
        LinearVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
        LinearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
        LinearVelocity.VectorVelocity = v6.Unit * 50
        LinearVelocity.Parent = p2.HumanoidRootPart

        local AngularVelocity = Instance.new("AngularVelocity")

        AngularVelocity.Attachment0 = Attachment
        AngularVelocity.MaxTorque = (1 / 0)
        AngularVelocity.RelativeTo = Enum.ActuatorRelativeTo.World

        local v25 = math.random(-50, 50)
        local v26 = math.random(-50, 50)

        AngularVelocity.AngularVelocity = Vector3.new(v25, v26, math.random(-50, 50))
        AngularVelocity.Parent = p2.HumanoidRootPart
        Debris:AddItem(LinearVelocity, 0.2)
        Debris:AddItem(AngularVelocity, 0.2)
    end
end
function t.ProjectileDamageFired(p1, p2, p3, p4, p5) --[[ ProjectileDamageFired | Line: 762 | Upvalues: DoBlood (copy), v2 (copy), Players (copy), t2 (copy), getOrCreateDamageStat (copy) ]]
    if p5 == 0 then
        if p2 ~= "fffffffff" then
            return
        end

        local v1, v22, v3, v4, v5, v6, v7, _, v8 = string.unpack(p2, p3)

        Vector3.new(v1, v22, v3)
        Vector3.new(v4, v5, v6)

        if v8 == 1 then
            DoBlood:FireAllClients("fffffff", (string.pack("fffffff", v1, v22, v3, v4, v5, v6, v7)))
        end

        local v9

        if p4:IsA("Humanoid") then
            v9 = p4
        else
            local v10 = v2(p4)

            if v10 then
                local v11 = Players:GetPlayerFromCharacter(v10.Parent)

                if v11 and (p1 and v11.Team ~= p1.Team) then
                    v9 = v10
                else
                    if v11 then
                        local isTeam = v11.Team == p1.Team
                    end

                    v9 = if v11 then false else v10
                end
            else
                v9 = false
            end
        end

        if not v9 then
            print("Humanoid not found in " .. p4.Name)

            return
        end

        if v9.Health - v7 <= 0 then
            local creator = Instance.new("ObjectValue")

            creator.Name = "creator"
            creator.Value = p1
            creator.Parent = v9
        end

        v9:TakeDamage(v7)

        if not (p1 and p1) then
            return
        end

        if not p1:IsA("Player") then
            return
        end

        if type(v7) ~= "number" then
            return
        end

        local v13 = math.floor(v7)

        if v13 <= 0 then
            return
        end

        local v14 = (t2[p1] or 0) + v13

        t2[p1] = v14

        local v15 = getOrCreateDamageStat(p1)

        if v15 then
            v15.Value = v14
        end
    else
        if p5 ~= 1 then
            return
        end

        local v16, v17, v18, v19, v20, v21, v22, _, v23 = string.unpack(p2, p3)

        Vector3.new(v16, v17, v18)
        Vector3.new(v19, v20, v21)

        local v24 = v2(p4)
        local v25

        if v24 then
            local v26 = Players:GetPlayerFromCharacter(v24.Parent)

            if v26 and (p1 and v26.Team ~= p1.Team) then
                v25 = v24
            else
                if v26 then
                    local isTeam = v26.Team == p1.Team
                end

                v25 = if v26 then false else v24
            end
        else
            v25 = false
        end

        if not (v25 and v25.Health > 0) then
            return
        end

        if v23 == 1 then
            DoBlood:FireAllClients("fffffff", (string.pack("fffffff", v16, v17, v18, v19, v20, v21, v22)))
        end

        if v25.Health - v22 <= 0 then
            local creator = Instance.new("ObjectValue")

            creator.Name = "creator"
            creator.Value = p1
            creator.Parent = v25
        end

        v25:TakeDamage(v22)

        if not (p1 and p1) then
            return
        end

        if not p1:IsA("Player") then
            return
        end

        if type(v22) ~= "number" then
            return
        end

        local v27 = math.floor(v22)

        if v27 <= 0 then
            return
        end

        local v28 = (t2[p1] or 0) + v27

        t2[p1] = v28

        local v29 = getOrCreateDamageStat(p1)

        if not v29 then
            return
        end

        v29.Value = v28
    end
end
function t.FireMoveArcade(p1, p2, p3) --[[ FireMoveArcade | Line: 795 | Upvalues: MoveArcade (copy) ]]
    if p2 == "Finish" then
        p1:SetPrimaryPartCFrame(p3)
    else
        MoveArcade:FireAllClients(p1, p2, p3)
    end
end
function t.FireCannonRealistic(p1, p2) --[[ FireCannonRealistic | Line: 803 | Upvalues: ReplicatedEvents (copy) ]]
    local v1 = string.gsub(p2.Values.LoadedStatus.Value, " Ready", "")
    local v2 = os.clock()

    for k, v in pairs(p2.InteractionParts:GetDescendants()) do
        if v:IsA("ProximityPrompt") then
            v.Enabled = false
        end
    end

    ReplicatedEvents.FireCannon:FireAllClients(p1, p2, v1, v2)
    p2.Values.LoadedStatus.Value = "Fired"

    if not p2.Settings.Features.EnableRecoil.Value then
        return
    end

    p2.Chassis.CannonRoot.Anchored = false
    p2.LeftWheel.LWheelRoot.Anchored = false
    p2.RightWheel.RWheelRoot.Anchored = false
    p2.Chassis.CannonRoot:SetNetworkOwner(p1)
end
function t.CannonFiredReturnRealistic(p1, p2) --[[ CannonFiredReturnRealistic | Line: 823 ]]
    if p2.Settings.Features.EnableRecoil.Value then
        p2.Chassis.CannonRoot:SetNetworkOwnershipAuto()
        p2.Chassis.CannonRoot.Anchored = true
        p2.LeftWheel.LWheelRoot.Anchored = true
        p2.RightWheel.RWheelRoot.Anchored = true
    end

    for k, v in pairs(p2.InteractionParts:GetDescendants()) do
        if v:IsA("ProximityPrompt") and not v:FindFirstChild("StartDisabled") then
            v.Enabled = true
        end
    end
end
function t.FireMoveRealistic(p1, p2, p3, p4) --[[ FireMoveRealistic | Line: 838 | Upvalues: Players (copy), MoveRealistic (copy) ]]
    if p3 == "Forward" or (p3 == "Reverse" or p3 == "MoveNone") then
        if p3 == "MoveNone" then
            p2.Values.MovingStatus.Value = "None"
        else
            p2.Values.MovingStatus.Value = p3
        end
    elseif p3 == "Right" or (p3 == "Left" or p3 == "TurnNone") then
        if p3 == "TurnNone" then
            p2.Values.TurningStatus.Value = "None"
        else
            p2.Values.TurningStatus.Value = p3
        end
    elseif p3 == "None" then
        p2.Values.TurningStatus.Value = "TurningNone"
        p2.Values.MovingStatus.Value = "MovingNone"
    end

    for k, v in pairs(Players:GetPlayers()) do
        local v1
        local Position = p2.Chassis.CannonRoot.Position
        local v2 = v.Name

        if Players:FindFirstChild(v2) then
            local Character = Players[v2].Character

            v1 = Character and (Character.PrimaryPart and (Character.PrimaryPart.Position - Position).Magnitude <= 100) and true or false
        else
            v1 = false
        end

        if v1 then
            MoveRealistic:FireClient(v, p1, p2, p3, p4)
        end
    end
end
function t.FireElevatingArcade(p1, p2, p3) --[[ FireElevatingArcade | Line: 862 | Upvalues: ElevateArcade (copy) ]]
    if p2 == "Finish" then
        p1.ElevatedParts:SetPrimaryPartCFrame(p1.Chassis.ChassisRotation.CFrame * CFrame.Angles(-math.rad(p3), 0, 0))
        p1.Values.Pitch.Value = p3

        local ChassisBipodRotation = p1:FindFirstChild("ChassisBipodRotation", true)

        if ChassisBipodRotation then
            p1.ElevatedParts.Bipod:SetPrimaryPartCFrame(ChassisBipodRotation.CFrame * CFrame.Angles(-math.rad(p1.Values.Pitch.Value - 45) * 2, 0, 0))
        end
    else
        ElevateArcade:FireAllClients(p1, p2, p3)
    end
end
function t.FireElevatingRealistic(p1, p2, p3, p4) --[[ FireElevatingRealistic | Line: 875 | Upvalues: Players (copy), ElevateRealistic (copy) ]]
    if p3 == "Set" then
        p2.ElevatedParts.Rotation.RotationWeld.C0 = CFrame.new() * CFrame.Angles(math.rad(p4), 0, 0)

        if p2.Settings.Configurations.MaxPitch.Value <= p4 then
            p4 = p2.Settings.Configurations.MaxPitch.Value
        elseif p4 <= p2.Settings.Configurations.MinPitch.Value then
            p4 = p2.Settings.Configurations.MinPitch.Value
        end

        p2.Values.Pitch.Value = p4
    end

    for k, v in pairs(Players:GetPlayers()) do
        local v1
        local Position = p2.Chassis.CannonRoot.Position
        local v2 = v.Name

        if Players:FindFirstChild(v2) then
            local Character = Players[v2].Character

            v1 = Character and (Character.PrimaryPart and (Character.PrimaryPart.Position - Position).Magnitude <= 100) and true or false
        else
            v1 = false
        end

        if v1 and p1.Name ~= v.Name then
            ElevateRealistic:FireClient(v, p2, p3, p4)
        end
    end
end
function t.SendRPM(p1, p2) --[[ SendRPM | Line: 893 | Upvalues: RunService (copy) ]]
    local RPMStatus = p1.Values.RPMStatus
    local RPM = p1.Values.RPM

    if RPMStatus.Value ~= p2 then
        RPMStatus.Value = p2
        task.spawn(function() --[[ Line: 898 | Upvalues: RPMStatus (copy), RunService (ref), RPM (copy), p1 (copy) ]]
            while RPMStatus.Value == "Increase" do
                local v1 = RunService.Heartbeat:Wait() / 0.016666

                if RPM.Value >= p1.Settings.Configurations.MaxRPM.Value then
                    RPM.Value = p1.Settings.Configurations.MaxRPM.Value

                    return
                end

                RPM.Value = RPM.Value + v1
            end
        end)
        task.spawn(function() --[[ Line: 909 | Upvalues: RPMStatus (copy), RunService (ref), RPM (copy), p1 (copy) ]]
            while RPMStatus.Value == "Decrease" do
                local v1 = RunService.Heartbeat:Wait() / 0.016666

                if RPM.Value <= p1.Settings.Configurations.MinRPM.Value then
                    RPM.Value = p1.Settings.Configurations.MinRPM.Value

                    return
                end

                RPM.Value = RPM.Value - v1
            end
        end)

        return
    end

    if not (tonumber(p2) and (tonumber(p2) <= p1.Settings.Configurations.MaxRPM.Value and tonumber(p2) >= p1.Settings.Configurations.MinRPM.Value)) then
        return
    end

    RPMStatus.Value = "Stop"
    RPM.Value = p2
end
function t.HandleBlood(p1, p2) --[[ HandleBlood | Line: 926 | Upvalues: DoBlood (copy) ]]
    DoBlood:FireAllClients(p1, p2)
end
function t.HandleSpark(p1, p2) --[[ HandleSpark | Line: 930 | Upvalues: DoSpark (copy) ]]
    DoSpark:FireAllClients(p1, p2)
end
function t.StatusChange(p1, p2, p3, p4) --[[ StatusChange | Line: 934 | Upvalues: MakeRope (copy), DestroyRope (copy), SeatOccupy (copy), SeatLeave (copy), ArtilleryReplicated (copy), Debris (copy) ]]
    local LoadedStatus = p2.Values:FindFirstChild("LoadedStatus")

    if p4 == "Realistic" then
        local Values = p2.Values

        if Values.LoadedStatus.Value == "Cleaned" then
            if not string.find(p3, "Load ") then
                return
            end

            local v1 = string.gsub(p3, "Load ", "")

            if not (v1 and (p2.Settings:FindFirstChild(v1) and p2.ElevatedParts:FindFirstChild(v1))) then
                return
            end

            Values.LoadedStatus.Value = v1 .. " Loaded"

            for k, v in pairs(p2.ElevatedParts[v1]:GetChildren()) do
                if v:IsA("Part") or (v:IsA("UnionOperation") or v:IsA("MeshPart")) then
                    v.Transparency = 0
                end
            end

            return
        end

        if p3 == "Ram" and string.find(Values.LoadedStatus.Value, " Loaded") then
            local v2 = string.gsub(Values.LoadedStatus.Value, " Loaded", "")

            Values.LoadedStatus.Value = v2 .. " Ready"

            for k, v in pairs(p2.ElevatedParts[v2]:GetChildren()) do
                if v:IsA("Part") or (v:IsA("UnionOperation") or v:IsA("MeshPart")) then
                    v.Transparency = 1
                end
            end

            return
        end

        if Values.LoadedStatus.Value == "Fired" and p3 == "Worm" then
            Values.LoadedStatus.Value = "Wormed"

            return
        end

        if Values.LoadedStatus.Value == "Wormed" and p3 == "Clean" then
            Values.LoadedStatus.Value = "Cleaned"
        end
    else
        local v3 = 0

        if p2.Name == "5 in. Howitzer" then
            v3 = 1
        elseif p2.Name == "8 in. Mortar" then
            v3 = 2
        elseif p2.Name == "18 lb. Rockets" then
            v3 = 3
        elseif p2.Name == "Gatling Gun" then
            v3 = 4
        end

        if p3 == 1 and (LoadedStatus.Value == "Cleaned" and (v3 == 0 or v3 == 1)) and p2.Values.MoveEnabled.Value then
            LoadedStatus.Value = "Canister Loaded"
            p2.ElevatedParts.Canister.Transparency = 0

            return
        end

        local v4, v5, v6, v7, v8, v9

        if p3 == 0 then
            if (v3 == 0 or v3 == 1) and LoadedStatus.Value == "Cleaned" then
                if p2.Values.MoveEnabled.Value then
                    if v3 == 2 then
                        LoadedStatus.Value = "Roundshot Ready"

                        return
                    end

                    if v3 == 0 or v3 == 1 then
                        LoadedStatus.Value = "Roundshot Loaded"
                        p2.ElevatedParts.Roundshot.Transparency = 0

                        return
                    end
                else
                    if p3 == 2 and p2.Values.MoveEnabled.Value then
                        if v3 ~= 1 or LoadedStatus.Value ~= "Cleaned" then
                            local _ = v3 ~= 2 or LoadedStatus.Value ~= "Powder Loaded"
                        end

                        if v3 == 2 then
                            LoadedStatus.Value = "Shell Ready"
                        elseif v3 == 0 or v3 == 1 then
                            LoadedStatus.Value = "Shell Loaded"
                            p2.ElevatedParts.Shell.Transparency = 0
                        end

                        p2.Values.Timer.Value = p4

                        return
                    end

                    if p3 == 3 and (LoadedStatus.Value == "Cleaned" and (p2.Values.MoveEnabled.Value and (v3 == 0 or (v3 == 1 or v3 == 2)))) then
                        LoadedStatus.Value = "Blank Loaded"
                        p2.ElevatedParts.Blank.Transparency = 0

                        return
                    end

                    if p3 == 4 then
                        if LoadedStatus.Value == "Canister Loaded" and (v3 == 0 or v3 == 1) and p2.Values.MoveEnabled.Value then
                            p2.ElevatedParts.Canister.Transparency = 1
                            LoadedStatus.Value = "Canister Ready"

                            return
                        end

                        if LoadedStatus.Value == "Roundshot Loaded" and (v3 == 0 or v3 == 1) and p2.Values.MoveEnabled.Value then
                            p2.ElevatedParts.Roundshot.Transparency = 1
                            LoadedStatus.Value = "Roundshot Ready"

                            return
                        end

                        if LoadedStatus.Value == "Shell Loaded" and (v3 == 1 and p2.Values.MoveEnabled.Value) then
                            p2.ElevatedParts.Shell.Transparency = 1
                            LoadedStatus.Value = "Shell Ready"

                            return
                        end

                        if LoadedStatus.Value == "Blank Loaded" and (v3 == 0 or (v3 == 1 or v3 == 2)) and p2.Values.MoveEnabled.Value then
                            p2.ElevatedParts.Blank.Transparency = 1
                            LoadedStatus.Value = "Blank Ready"

                            return
                        end

                        if LoadedStatus.Value == "Wormed" and p2.Values.MoveEnabled.Value then
                            LoadedStatus.Value = "Cleaned"

                            return
                        end

                        if LoadedStatus.Value == "Fired" and (v3 == 1 or v3 == 2) and p2.Values.MoveEnabled.Value then
                            LoadedStatus.Value = "Wormed"

                            return
                        end

                        if LoadedStatus.Value == "Fired" and (v3 == 0 and p2.Values.MoveEnabled.Value) then
                            LoadedStatus.Value = "Cleaned"

                            return
                        end
                    else
                        if p3 == 5 and (v3 == 0 or (v3 == 1 or (v3 == 2 or v3 == 4))) then
                            return MakeRope(p1, p2)
                        end

                        if p3 == 6 and (v3 == 0 or (v3 == 1 or (v3 == 2 or v3 == 4))) then
                            return DestroyRope(p1, p2)
                        end

                        if p3 == 7 then
                            return SeatOccupy(p1, p2)
                        end

                        if p3 == 8 then
                            return SeatLeave(p1, p2)
                        end

                        if p3 == 9 then
                            if LoadedStatus and (LoadedStatus.Value == "Magazine Ready" or LoadedStatus.Value == "Magazine Empty") and (v3 == 4 and p2.Values.MoveEnabled.Value) then
                                if p4 > 0 then
                                    v4 = game.ServerStorage.Artillery:FindFirstChild("Magazine")

                                    if v4 then
                                        v5 = v4:Clone()
                                        v5:WaitForChild("AmmunitionLeft").Value = p4
                                        v5.Parent = p1.Backpack
                                    end
                                else
                                    v6 = ArtilleryReplicated.Projectiles.GatlingMagazine:Clone()
                                    v7 = p2.ElevatedParts.Magazine.CFrame
                                    v8 = math.random(-5, 5) / 10
                                    v9 = math.random(-5, 5) / 10
                                    v6.CFrame = v7 + Vector3.new(v8, 0, v9)
                                    v6.Parent = workspace
                                    Debris:AddItem(v6, 5)
                                end

                                LoadedStatus.Value = "No Magazine"
                                p2.Values.AmmunitionLeft.Value = 0
                                p2.ElevatedParts.Magazine.Transparency = 1

                                return
                            end

                            if LoadedStatus and (LoadedStatus.Value == "No Magazine" and (v3 == 4 and p2.Values.MoveEnabled.Value)) then
                                LoadedStatus.Value = "Magazine Ready"
                                p2.Values.AmmunitionLeft.Value = p4
                                p2.ElevatedParts.Magazine.Transparency = 0

                                return
                            end
                        elseif p3 == 10 then
                            if LoadedStatus.Value == "Magazine Ready" and (v3 == 4 and p2.Values.MoveEnabled.Value) then
                                LoadedStatus.Value = "Magazine Empty"
                                p2.Values.AmmunitionLeft.Value = 0

                                return
                            end
                        else
                            if p3 == 11 then
                                p2.Values:FindFirstChild("LeftStatus").Value = "Explosive Ready"

                                for k2, v in pairs(p2.ElevatedParts.LeftExplosive:GetChildren()) do
                                    v.Transparency = 0
                                end

                                return
                            end

                            if p3 == 11.25 then
                                p2.Values:FindFirstChild("LeftStatus").Value = "Shell Ready"
                                p2.Values:FindFirstChild("LeftFuse").Value = p4

                                for k2, v in pairs(p2.ElevatedParts.LeftShell:GetChildren()) do
                                    v.Transparency = 0
                                end

                                return
                            end

                            if p3 == 11.5 then
                                p2.Values:FindFirstChild("RightStatus").Value = "Explosive Ready"

                                for k2, v in pairs(p2.ElevatedParts.RightExplosive:GetChildren()) do
                                    v.Transparency = 0
                                end

                                return
                            end

                            if p3 == 11.75 then
                                p2.Values:FindFirstChild("RightStatus").Value = "Shell Ready"
                                p2.Values:FindFirstChild("RightFuse").Value = p4

                                for k2, v in pairs(p2.ElevatedParts.RightShell:GetChildren()) do
                                    v.Transparency = 0
                                end

                                return
                            end

                            if p3 ~= 12 then
                                return
                            end

                            p2.Values:FindFirstChild("PowderAmount").Value = p4
                            LoadedStatus.Value = "Powder Loaded"
                        end
                    end
                end

                return
            end

            if v3 == 2 and LoadedStatus.Value == "Powder Loaded" and p2.Values.MoveEnabled.Value then
                if v3 == 2 then
                    LoadedStatus.Value = "Roundshot Ready"

                    return
                end

                if v3 == 0 or v3 == 1 then
                    LoadedStatus.Value = "Roundshot Loaded"
                    p2.ElevatedParts.Roundshot.Transparency = 0
                end

                return
            end
        end

        if p3 == 2 and p2.Values.MoveEnabled.Value then
            if v3 ~= 1 or LoadedStatus.Value ~= "Cleaned" then
                local _ = v3 ~= 2 or LoadedStatus.Value ~= "Powder Loaded"
            end

            if v3 == 2 then
                LoadedStatus.Value = "Shell Ready"
            elseif v3 == 0 or v3 == 1 then
                LoadedStatus.Value = "Shell Loaded"
                p2.ElevatedParts.Shell.Transparency = 0
            end

            p2.Values.Timer.Value = p4

            return
        end

        if p3 == 3 and (LoadedStatus.Value == "Cleaned" and (p2.Values.MoveEnabled.Value and (v3 == 0 or (v3 == 1 or v3 == 2)))) then
            LoadedStatus.Value = "Blank Loaded"
            p2.ElevatedParts.Blank.Transparency = 0

            return
        end

        if p3 == 4 then
            if LoadedStatus.Value == "Canister Loaded" and (v3 == 0 or v3 == 1) and p2.Values.MoveEnabled.Value then
                p2.ElevatedParts.Canister.Transparency = 1
                LoadedStatus.Value = "Canister Ready"

                return
            end

            if LoadedStatus.Value == "Roundshot Loaded" and (v3 == 0 or v3 == 1) and p2.Values.MoveEnabled.Value then
                p2.ElevatedParts.Roundshot.Transparency = 1
                LoadedStatus.Value = "Roundshot Ready"

                return
            end

            if LoadedStatus.Value == "Shell Loaded" and (v3 == 1 and p2.Values.MoveEnabled.Value) then
                p2.ElevatedParts.Shell.Transparency = 1
                LoadedStatus.Value = "Shell Ready"

                return
            end

            if LoadedStatus.Value == "Blank Loaded" and (v3 == 0 or (v3 == 1 or v3 == 2)) and p2.Values.MoveEnabled.Value then
                p2.ElevatedParts.Blank.Transparency = 1
                LoadedStatus.Value = "Blank Ready"

                return
            end

            if LoadedStatus.Value == "Wormed" and p2.Values.MoveEnabled.Value then
                LoadedStatus.Value = "Cleaned"

                return
            end

            if LoadedStatus.Value == "Fired" and (v3 == 1 or v3 == 2) and p2.Values.MoveEnabled.Value then
                LoadedStatus.Value = "Wormed"

                return
            end

            if LoadedStatus.Value == "Fired" and (v3 == 0 and p2.Values.MoveEnabled.Value) then
                LoadedStatus.Value = "Cleaned"
            end
        else
            if p3 == 5 and (v3 == 0 or (v3 == 1 or (v3 == 2 or v3 == 4))) then
                return MakeRope(p1, p2)
            end

            if p3 == 6 and (v3 == 0 or (v3 == 1 or (v3 == 2 or v3 == 4))) then
                return DestroyRope(p1, p2)
            end

            if p3 == 7 then
                return SeatOccupy(p1, p2)
            end

            if p3 == 8 then
                return SeatLeave(p1, p2)
            end

            if p3 == 9 then
                if LoadedStatus and (LoadedStatus.Value == "Magazine Ready" or LoadedStatus.Value == "Magazine Empty") and (v3 == 4 and p2.Values.MoveEnabled.Value) then
                    if p4 > 0 then
                        v4 = game.ServerStorage.Artillery:FindFirstChild("Magazine")

                        if v4 then
                            v5 = v4:Clone()
                            v5:WaitForChild("AmmunitionLeft").Value = p4
                            v5.Parent = p1.Backpack
                        end
                    else
                        v6 = ArtilleryReplicated.Projectiles.GatlingMagazine:Clone()
                        v7 = p2.ElevatedParts.Magazine.CFrame
                        v8 = math.random(-5, 5) / 10
                        v9 = math.random(-5, 5) / 10
                        v6.CFrame = v7 + Vector3.new(v8, 0, v9)
                        v6.Parent = workspace
                        Debris:AddItem(v6, 5)
                    end

                    LoadedStatus.Value = "No Magazine"
                    p2.Values.AmmunitionLeft.Value = 0
                    p2.ElevatedParts.Magazine.Transparency = 1

                    return
                end

                if LoadedStatus and (LoadedStatus.Value == "No Magazine" and (v3 == 4 and p2.Values.MoveEnabled.Value)) then
                    LoadedStatus.Value = "Magazine Ready"
                    p2.Values.AmmunitionLeft.Value = p4
                    p2.ElevatedParts.Magazine.Transparency = 0
                end
            elseif p3 == 10 then
                if LoadedStatus.Value == "Magazine Ready" and (v3 == 4 and p2.Values.MoveEnabled.Value) then
                    LoadedStatus.Value = "Magazine Empty"
                    p2.Values.AmmunitionLeft.Value = 0
                end
            else
                if p3 == 11 then
                    p2.Values:FindFirstChild("LeftStatus").Value = "Explosive Ready"

                    for k2, v in pairs(p2.ElevatedParts.LeftExplosive:GetChildren()) do
                        v.Transparency = 0
                    end

                    return
                end

                if p3 == 11.25 then
                    p2.Values:FindFirstChild("LeftStatus").Value = "Shell Ready"
                    p2.Values:FindFirstChild("LeftFuse").Value = p4

                    for k2, v in pairs(p2.ElevatedParts.LeftShell:GetChildren()) do
                        v.Transparency = 0
                    end

                    return
                end

                if p3 == 11.5 then
                    p2.Values:FindFirstChild("RightStatus").Value = "Explosive Ready"

                    for k2, v in pairs(p2.ElevatedParts.RightExplosive:GetChildren()) do
                        v.Transparency = 0
                    end

                    return
                end

                if p3 == 11.75 then
                    p2.Values:FindFirstChild("RightStatus").Value = "Shell Ready"
                    p2.Values:FindFirstChild("RightFuse").Value = p4

                    for k2, v in pairs(p2.ElevatedParts.RightShell:GetChildren()) do
                        v.Transparency = 0
                    end

                    return
                end

                if p3 ~= 12 then
                    return
                end

                p2.Values:FindFirstChild("PowderAmount").Value = p4
                LoadedStatus.Value = "Powder Loaded"
            end
        end
    end
end
function t.ReplicateAim(p1, p2, p3) --[[ ReplicateAim | Line: 1087 | Upvalues: ReplicateAim (copy) ]]
    ReplicateAim:FireAllClients(p1, p2, p3)
end

return t