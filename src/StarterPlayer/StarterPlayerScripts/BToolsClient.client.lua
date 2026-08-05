-- BToolsClient.client.lua
-- PLACEHOLDER_GUI: BToolsPanel -- functional-over-beautiful per project convention.
-- Mod-only floating panel (N key) for placing/selecting/moving/deleting session BTool
-- objects (NPC Spawner / Interactable QTE Point / Light Source / Ritual Circle Marker).
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local UIS        = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")

local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))
local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- ── Mod gate ──────────────────────────────────────────────────────────
-- Reuses the existing mod-only ModMenuData RemoteFunction (returns nil for non-mods)
-- rather than adding a new remote just to answer "am I a mod" -- ModMenuClient already
-- established this exact pattern.
local isModCache = nil
task.spawn(function()
    local ok, data = pcall(function() return Remotes.ModMenuData:InvokeServer() end)
    isModCache = ok and data ~= nil
end)

-- ── GUI shell ─────────────────────────────────────────────────────────────────
local gui = Instance.new("ScreenGui")
gui.Name = "BToolsGui"; gui.ResetOnSpawn = false; gui.Enabled = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local PANEL = Color3.fromRGB(13, 10, 7)
local BORDER = Color3.fromRGB(78, 60, 30)
local PARCHM = Color3.fromRGB(208, 194, 165)
local GOLD = Color3.fromRGB(198, 156, 55)
local BTN_BASE = Color3.fromRGB(22, 17, 11)

local frame = Instance.new("Frame")
frame.AnchorPoint = Vector2.new(1, 0.5)
frame.Position = UDim2.new(1, -20, 0.5, 0)
-- Wider and taller than the original 220x340: the transform rows carry their keybind in the
-- label, and the status block below now reports selection + gizmo + snap + live size rather
-- than two lines.
frame.Size = UDim2.new(0, 268, 0, 420)
frame.BackgroundColor3 = PANEL
frame.BorderSizePixel = 0
frame.Parent = gui
local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 4); corner.Parent = frame
local stroke = Instance.new("UIStroke"); stroke.Color = BORDER; stroke.Thickness = 1; stroke.Parent = frame

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -16, 0, 24)
title.Position = UDim2.new(0, 8, 0, 6)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold; title.TextSize = 14
title.TextColor3 = GOLD; title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "MOD BTOOLS"
title.Parent = frame

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 4)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
-- Scrolls: 16 buttons at 26+4px is ~480px of content in a ~270px body. As a plain Frame
-- this overflowed and drew straight through the panel border. ClipsDescendants contains it,
-- AutomaticCanvasSize grows the canvas to fit however many buttons exist so adding a new
-- mkButton below never needs a matching canvas-height edit.
local body = Instance.new("ScrollingFrame")
body.Size = UDim2.new(1, -16, 1, -124)
body.Position = UDim2.new(0, 8, 0, 34)
body.BackgroundTransparency = 1
body.BorderSizePixel = 0
body.ClipsDescendants = true
body.CanvasSize = UDim2.new(0, 0, 0, 0)
body.AutomaticCanvasSize = Enum.AutomaticSize.Y
body.ScrollBarThickness = 6
body.ScrollBarImageColor3 = GOLD
body.ScrollBarImageTransparency = 0.35
body.ScrollingDirection = Enum.ScrollingDirection.Y
body.ElasticBehavior = Enum.ElasticBehavior.Never
body.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
body.Parent = frame
listLayout.Parent = body

local statusLbl = Instance.new("TextLabel")
statusLbl.Size = UDim2.new(1, -16, 0, 86)
statusLbl.Position = UDim2.new(0, 8, 1, -90)
statusLbl.TextYAlignment = Enum.TextYAlignment.Top
statusLbl.BackgroundTransparency = 1
statusLbl.Font = Enum.Font.Gotham; statusLbl.TextSize = 11
statusLbl.TextColor3 = PARCHM; statusLbl.TextXAlignment = Enum.TextXAlignment.Left
statusLbl.TextWrapped = true
statusLbl.Text = "Selected: None\nPlacements: 0"
statusLbl.Parent = frame

local function mkButton(text, layoutOrder)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(1, -2, 0, 26) -- -2 keeps the button off the scrollbar gutter
    b.BackgroundColor3 = BTN_BASE
    b.BorderSizePixel = 0
    b.Font = Enum.Font.GothamMedium; b.TextSize = 12
    b.TextColor3 = PARCHM
    b.AutoButtonColor = false
    b.Text = text
    b.LayoutOrder = layoutOrder
    b.Parent = body
    local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, 3); c.Parent = b
    local s = Instance.new("UIStroke"); s.Color = BORDER; s.Thickness = 1; s.Parent = b
    return b
end

-- Forward declarations. Several button handlers below are wired up BEFORE the state block
-- that owns these names, and Lua binds a name to a local only if that local is already in
-- scope -- so without this, those handlers were reading and writing globals instead, and
-- calling a nil `setStatus`. Clicking Place Ship / Place Spirit / Place Ore Node threw
-- "attempt to call a nil value" and did nothing at all.
local panelOpen, placingMode, movingMode, selected, selectionBox
local setStatus, refreshGizmos, clearSelection, selectInstance, cancelModes, updateNudgeBinding

local btnNPCSpawner   = mkButton("Place NPC Spawner", 1)
local btnInteractable = mkButton("Place Interactable QTE Point", 2)

local lightTypeIdx = 1
local LIGHT_TYPES = { "Torch", "Campfire", "Lantern", "Brazier" }
local btnLight = mkButton("Place Light Source: " .. LIGHT_TYPES[lightTypeIdx], 3)
btnLight.MouseButton1Click:Connect(function()
    -- Shift+click cycles the type instead of placing, so a stray click doesn't place early
    if UIS:IsKeyDown(Enum.KeyCode.LeftShift) or UIS:IsKeyDown(Enum.KeyCode.RightShift) then
        lightTypeIdx = (lightTypeIdx % #LIGHT_TYPES) + 1
        btnLight.Text = "Place Light Source: " .. LIGHT_TYPES[lightTypeIdx]
    end
end)

local btnRitual = mkButton("Place Ritual Circle Marker", 4)

-- Crafting/gathering stations (design doc: Interactables/Mining/Smelting/Tailoring/
-- Smithing/Farming, PART SEVEN)
local btnChest    = mkButton("Place Chest", 8)
local btnOreNode  = mkButton("Place Ore Node: Iron", 9)
local btnShip     = mkButton("Place Ship", 10)
-- LayoutOrder below continues 11..16; Ship/Spirit/Smelter previously all shared order 10,
-- which left their relative order down to sibling enumeration rather than intent.
btnShip.MouseButton1Click:Connect(function()
    placingMode = "Ship"; movingMode = false; setStatus()
end)

local spiritFactionIdx = 1
local SPIRIT_FACTIONS = { "Flame", "Wind", "Water", "Earth", "Shadow", "Blood" }
local btnSpirit = mkButton("Place Spirit Spawner: " .. SPIRIT_FACTIONS[spiritFactionIdx], 11)
btnSpirit.MouseButton1Click:Connect(function()
    -- Same shift-click-cycles convention as the Light Source button above.
    if UIS:IsKeyDown(Enum.KeyCode.LeftShift) or UIS:IsKeyDown(Enum.KeyCode.RightShift) then
        spiritFactionIdx = (spiritFactionIdx % #SPIRIT_FACTIONS) + 1
        btnSpirit.Text = "Place Spirit Spawner: " .. SPIRIT_FACTIONS[spiritFactionIdx]
    else
        placingMode = "Spirit"; movingMode = false; setStatus()
    end
end)

local btnSmelter  = mkButton("Place Smelter", 12)
local btnTailor   = mkButton("Place Tailoring Station", 13)
local btnForge    = mkButton("Place Forge", 14)
local btnFarmPlot = mkButton("Place Farming Plot", 15)
local btnCustom   = mkButton("Place Custom Interactable", 16)

-- Mob spawner (owner request): Shift+click cycles the mob, a plain click spawns it ON you.
-- Same shift-cycle convention as the Light Source / Spirit buttons. Mob list comes from
-- Config.Mobs (the same curated registry the mod panel's Spawn Mob dropdown uses).
local _btConfig = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("Config"))
local MOB_LIST = {}
for _, e in ipairs(_btConfig.Mobs or {}) do MOB_LIST[#MOB_LIST + 1] = { name = e.name, template = e.template } end
if #MOB_LIST == 0 then MOB_LIST[1] = { name = "Lesser Wolf", template = "LesserWolf" } end
local mobIdx = 1
local btnMobSpawn = mkButton("Spawn Mob on Me: " .. MOB_LIST[mobIdx].name .. "   [Shift=cycle]", 21)
btnMobSpawn.MouseButton1Click:Connect(function()
    if UIS:IsKeyDown(Enum.KeyCode.LeftShift) or UIS:IsKeyDown(Enum.KeyCode.RightShift) then
        mobIdx = (mobIdx % #MOB_LIST) + 1
        btnMobSpawn.Text = "Spawn Mob on Me: " .. MOB_LIST[mobIdx].name .. "   [Shift=cycle]"
    else
        Remotes.RequestBToolAction:FireServer("spawnMob", MOB_LIST[mobIdx].template)
    end
end)

-- Transform controls. Keyboard shortcuts are the fast path; the buttons exist so the
-- bindings are discoverable rather than something you have to already know.
local btnGizmo    = mkButton("Gizmo: Move            [X]", 17)
local btnSnap     = mkButton("Snap: 0.5              [C]", 18)
local btnRotSnap  = mkButton("Rot Snap: 15 deg [Shift+C]", 19)
local btnResetRot = mkButton("Reset Rotation", 20)

local oreTypeIdx = 1
local ORE_TYPES = { "Iron", "Copper", "Silver", "Gold", "Rare_Bloodstone" }
btnOreNode.MouseButton1Click:Connect(function()
	if UIS:IsKeyDown(Enum.KeyCode.LeftShift) or UIS:IsKeyDown(Enum.KeyCode.RightShift) then
		oreTypeIdx = (oreTypeIdx % #ORE_TYPES) + 1
		btnOreNode.Text = "Place Ore Node: " .. ORE_TYPES[oreTypeIdx]
		return
	end
	placingMode = "OreNode"; movingMode = false; setStatus()
end)

local btnDelete = mkButton("Delete Selected", 5)
local btnMove   = mkButton("Grab Selected (follows cursor)", 6)
local btnClearAll = mkButton("Clear All Session Placements", 7)

-- ── State ───────────────────────────────────────────────────────────────────
panelOpen = false
placingMode = nil -- "NPCSpawner" | "Interactable" | "LightSource" | "RitualMarker" | nil
movingMode = false
selected = nil -- Instance
selectionBox = nil

-- ================================================================================
-- TRANSFORM GIZMOS
--
-- Before this, the only way to position anything was "Move Selected" -> click a point ->
-- the object teleported there, flat on the ground, at whatever rotation and size it was
-- born with. That is not enough to actually build a scene with, which is what these tools
-- are for.
--
-- Now: real drag handles (Roblox's own Handles/ArcHandles adornments, the same primitives
-- Studio's move/scale/rotate tools are built on), free-dragging the object along surfaces,
-- and keyboard nudging. The client drives the visuals locally for zero-latency feel and
-- streams the transform to the server, which is authoritative -- see
-- BToolsManager.transformPlacement.
-- ================================================================================

local GIZMO_MODES = { "Move", "Rotate", "Scale" }
local gizmoModeIdx = 1

-- Snap increments. 0 = free/continuous. Studio defaults to 1 stud; 0.5 is a better default
-- here because most placements are small props being nestled against existing geometry.
local SNAP_STEPS = { 0, 0.5, 1, 4 }
local snapIdx = 2
local ROT_SNAPS = { 0, 5, 15, 45 }
local rotSnapIdx = 3

local function snapLinear(v)
    local s = SNAP_STEPS[snapIdx]
    if s == 0 then return v end
    return math.round(v / s) * s
end
local function snapAngleRad(a)
    local s = ROT_SNAPS[rotSnapIdx]
    if s == 0 then return a end
    return math.rad(math.round(math.deg(a) / s) * s)
end

local function absV3(v) return Vector3.new(math.abs(v.X), math.abs(v.Y), math.abs(v.Z)) end

-- Selection can be a BasePart (most placements) or a Model (ships). Models have no Size and
-- no CFrame, so every read/write goes through these rather than being branched at each site.
local function isPart(i) return i ~= nil and i:IsA("BasePart") end
local function isModel(i) return i ~= nil and i:IsA("Model") end
local function getCF(i)
    if isPart(i) then return i.CFrame elseif isModel(i) then return i:GetPivot() end
    return nil
end
local function setCFLocal(i, cf)
    if isPart(i) then i.CFrame = cf elseif isModel(i) then i:PivotTo(cf) end
end
local function getSize(i)
    if isPart(i) then return i.Size elseif isModel(i) then return i:GetExtentsSize() end
    return Vector3.new(1, 1, 1)
end

-- Adornments live under PlayerGui: they're client-only decoration, and parenting them to the
-- adornee itself would replicate nothing but would tie their lifetime to a part the server
-- may delete mid-drag.
local moveHandles = Instance.new("Handles")
moveHandles.Name = "BToolMoveHandles"
moveHandles.Style = Enum.HandlesStyle.Movement
moveHandles.Color3 = GOLD
moveHandles.Transparency = 0.1
moveHandles.Adornee = nil
moveHandles.Parent = playerGui

local scaleHandles = Instance.new("Handles")
scaleHandles.Name = "BToolScaleHandles"
scaleHandles.Style = Enum.HandlesStyle.Resize
scaleHandles.Color3 = Color3.fromRGB(90, 175, 245)
scaleHandles.Transparency = 0.1
scaleHandles.Adornee = nil
scaleHandles.Parent = playerGui

local rotHandles = Instance.new("ArcHandles")
rotHandles.Name = "BToolRotateHandles"
rotHandles.Color3 = Color3.fromRGB(110, 220, 120)
rotHandles.Transparency = 0.1
rotHandles.Adornee = nil
rotHandles.Parent = playerGui

-- Drag bookkeeping. `origCF`/`origSize` are captured once on mouse-down so every MouseDrag
-- is computed from the drag's start rather than accumulating float error frame over frame
-- (Handles reports total distance from the grab point, not a per-frame delta).
local handleDragging = false
local origCF, origSize, origScale = nil, nil, nil
local lastSendAt = 0
local SEND_HZ = 30
local lastFeedback = ""
local placementCount = 0

local function sendLive(cf, size)
    local now = os.clock()
    if now - lastSendAt < (1 / SEND_HZ) then return end
    lastSendAt = now
    Remotes.RequestBToolAction:FireServer("transform", selected, cf, size)
end

-- Applied locally first so the drag feels instant, then streamed. The server is still the
-- authority and its replication will correct anything it rejects.
local function applyLive(cf, size)
    if not selected or not selected.Parent then return end
    if size and isPart(selected) then selected.Size = size end
    setCFLocal(selected, cf)
    sendLive(cf, size)
end

local function commit(verb, cf, size)
    if not selected or not selected.Parent then return end
    Remotes.RequestBToolAction:FireServer("transformCommit", selected, cf or getCF(selected), size, verb)
end

local function beginDrag()
    if not selected then return end
    origCF = getCF(selected)
    origSize = getSize(selected)
    origScale = isModel(selected) and selected:GetScale() or 1
end

function refreshGizmos()
    local mode = GIZMO_MODES[gizmoModeIdx]
    local target = (selected and selected.Parent and isPart(selected)) and selected or nil
    -- ArcHandles/Handles can only adorn a BasePart. For a Model, adorn its PrimaryPart if it
    -- has one -- otherwise the mode still works via keyboard nudging, just without handles.
    if not target and isModel(selected) then target = selected.PrimaryPart end
    moveHandles.Adornee  = (target and mode == "Move") and target or nil
    scaleHandles.Adornee = (target and mode == "Scale") and target or nil
    rotHandles.Adornee   = (target and mode == "Rotate") and target or nil
end

function clearSelection()
    if selectionBox then selectionBox:Destroy(); selectionBox = nil end
    selected = nil
    handleDragging = false
    refreshGizmos()
    if setStatus then setStatus() end
end

function selectInstance(inst)
    clearSelection()
    if not inst then return end
    selected = inst
    if inst:IsA("BasePart") or inst:IsA("Model") then
        selectionBox = Instance.new("SelectionBox")
        selectionBox.Adornee = inst
        selectionBox.Color3 = Color3.fromRGB(220, 60, 60)
        selectionBox.LineThickness = 0.03
        selectionBox.Transparency = 0.3
        selectionBox.Parent = playerGui
    end
    refreshGizmos()
    setStatus()
end

function cancelModes()
    placingMode = nil
    movingMode = false
    setStatus()
end

function setStatus()
    local mode = GIZMO_MODES[gizmoModeIdx]
    local snap = SNAP_STEPS[snapIdx]
    local rsnap = ROT_SNAPS[rotSnapIdx]
    local sizeTxt = ""
    if selected and selected.Parent then
        local s = getSize(selected)
        sizeTxt = string.format("\nSize: %.1f x %.1f x %.1f", s.X, s.Y, s.Z)
    end
    statusLbl.Text = string.format("Selected: %s   (%d placed)\nPlacing: %s   Gizmo: %s\nSnap: %s / %s deg%s%s",
        selected and selected.Name or "None",
        placementCount,
        placingMode or (movingMode and "GRABBED - click to drop, Esc to cancel" or "None"),
        mode,
        snap == 0 and "free" or tostring(snap),
        rsnap == 0 and "free" or tostring(rsnap),
        sizeTxt,
        lastFeedback ~= "" and ("\n" .. lastFeedback) or "")
    btnGizmo.Text   = "Gizmo: " .. mode .. "            [X]"
    btnSnap.Text    = "Snap: " .. (snap == 0 and "free" or tostring(snap)) .. "              [C]"
    btnRotSnap.Text = "Rot Snap: " .. (rsnap == 0 and "free" or (rsnap .. " deg")) .. " [Shift+C]"
    if updateNudgeBinding then updateNudgeBinding() end
end

-- ── Handle wiring ────────────────────────────────────────────────────────────
moveHandles.MouseButton1Down:Connect(function() handleDragging = true; beginDrag() end)
moveHandles.MouseButton1Up:Connect(function()
    handleDragging = false
    commit("moved"); setStatus()
end)
moveHandles.MouseDrag:Connect(function(face, distance)
    if not selected or not origCF then return end
    applyLive(origCF * CFrame.new(Vector3.FromNormalId(face) * snapLinear(distance)), nil)
end)

rotHandles.MouseButton1Down:Connect(function() handleDragging = true; beginDrag() end)
rotHandles.MouseButton1Up:Connect(function()
    handleDragging = false
    commit("rotated"); setStatus()
end)
rotHandles.MouseDrag:Connect(function(axis, relativeAngle)
    if not selected or not origCF then return end
    local a = snapAngleRad(relativeAngle)
    local rot
    if axis == Enum.Axis.X then rot = CFrame.Angles(a, 0, 0)
    elseif axis == Enum.Axis.Y then rot = CFrame.Angles(0, a, 0)
    else rot = CFrame.Angles(0, 0, a) end
    applyLive(origCF * rot, nil)
end)

scaleHandles.MouseButton1Down:Connect(function() handleDragging = true; beginDrag() end)
scaleHandles.MouseButton1Up:Connect(function()
    handleDragging = false
    commit("resized", getCF(selected), isPart(selected) and getSize(selected) or Vector3.new(origScale or 1, 0, 0))
    setStatus()
end)
-- Grows along the dragged face only, then shifts the part by half the growth so the OPPOSITE
-- face stays put -- otherwise the part appears to slide while you stretch it.
scaleHandles.MouseDrag:Connect(function(face, distance)
    if not selected or not origCF or not origSize then return end
    local n = Vector3.FromNormalId(face)
    local d = snapLinear(distance)

    if isModel(selected) then
        -- Models scale uniformly (no per-axis stretch is defined for one). Distance is
        -- normalised against the model's own extents so a big ship isn't hypersensitive.
        local ref = math.max(origSize.X, origSize.Y, origSize.Z, 1)
        local scale = math.clamp((origScale or 1) * (1 + d / ref), 0.1, 20)
        pcall(function() selected:ScaleTo(scale) end)
        sendLive(getCF(selected), Vector3.new(scale, 0, 0))
        return
    end

    local axisMask = absV3(n)
    local newSize = origSize + axisMask * d
    newSize = Vector3.new(math.max(0.2, newSize.X), math.max(0.2, newSize.Y), math.max(0.2, newSize.Z))
    local grown = newSize - origSize
    local along = grown.X * axisMask.X + grown.Y * axisMask.Y + grown.Z * axisMask.Z
    applyLive(origCF * CFrame.new(n * (along / 2)), newSize)
end)

-- ── Raycast helper ───────────────────────────────────────────────────────────
-- UIS:GetMouseLocation() INCLUDES the topbar inset; Camera:ViewportPointToRay() expects
-- viewport coordinates that EXCLUDE it. Feeding one straight into the other (as this did)
-- aims the ray ~58px below the cursor -- every placement landed low and selection clicks
-- missed whatever was actually under the pointer. Subtracting the inset reconciles them.
local function mouseViewportPoint()
    local m = UIS:GetMouseLocation()
    local inset = GuiService:GetGuiInset()
    return m.X - inset.X, m.Y - inset.Y
end

local function getMouseWorldHit()
    local camera = workspace.CurrentCamera
    local mx, my = mouseViewportPoint()
    local ray = camera:ViewportPointToRay(mx, my)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { localPlayer.Character }
    local result = workspace:Raycast(ray.Origin, ray.Direction * 500, params)
    if result then return result.Position, result.Instance end
    return ray.Origin + ray.Direction * 50, nil
end

-- ── Button wiring ───────────────────────────────────────────────────────────
btnNPCSpawner.MouseButton1Click:Connect(function()
    placingMode = "NPCSpawner"; movingMode = false; setStatus()
end)
btnInteractable.MouseButton1Click:Connect(function()
    placingMode = "Interactable"; movingMode = false; setStatus()
end)
btnRitual.MouseButton1Click:Connect(function()
    placingMode = "RitualMarker"; movingMode = false; setStatus()
end)
btnChest.MouseButton1Click:Connect(function()
    placingMode = "Chest"; movingMode = false; setStatus()
end)
btnSmelter.MouseButton1Click:Connect(function()
    placingMode = "Smelter"; movingMode = false; setStatus()
end)
btnTailor.MouseButton1Click:Connect(function()
    placingMode = "TailoringStation"; movingMode = false; setStatus()
end)
btnForge.MouseButton1Click:Connect(function()
    placingMode = "Forge"; movingMode = false; setStatus()
end)
btnFarmPlot.MouseButton1Click:Connect(function()
    placingMode = "FarmingPlot"; movingMode = false; setStatus()
end)
btnCustom.MouseButton1Click:Connect(function()
    placingMode = "CustomInteractable"; movingMode = false; setStatus()
end)
btnDelete.MouseButton1Click:Connect(function()
    if not selected then return end
    Remotes.RequestBToolAction:FireServer("delete", selected)
    clearSelection()
end)
-- "Grab": the object sticks to the cursor and follows it live until you click to drop it.
-- This replaces the old behaviour (click the button, then click a destination, and the object
-- teleported there) -- you can now see exactly where it's going to land while you aim, and
-- it beds itself against whatever surface you're pointing at on the way.
--
-- Kept alongside press-and-hold dragging rather than replacing it, because a sticky grab is
-- far easier to control when the destination is a long way from the object.
btnMove.MouseButton1Click:Connect(function()
    if not selected then return end
    placingMode = nil
    movingMode = true
    beginDrag()
    setStatus()
end)
btnClearAll.MouseButton1Click:Connect(function()
    Remotes.RequestBToolAction:FireServer("clearAll")
    clearSelection()
end)

-- ── World click handling ─────────────────────────────────────────────────────
-- Free drag: grab the object itself and slide it along whatever surface you point at.
-- This is the "just pick it up and move it" path, separate from the axis handles. The object
-- is placed flush against the surface under the cursor using its own half-extent along that
-- surface's normal, so it sits ON floors and flush AGAINST walls rather than clipping in.
local bodyDragging = false

local function surfaceRest(hitPos, normal, size)
    local halfAlong = math.abs(normal.X) * size.X / 2
                    + math.abs(normal.Y) * size.Y / 2
                    + math.abs(normal.Z) * size.Z / 2
    return hitPos + normal * halfAlong
end

local function dragRaycast()
    local camera = workspace.CurrentCamera
    local mx, my = mouseViewportPoint() -- inset-corrected, see the note on getMouseWorldHit
    local ray = camera:ViewportPointToRay(mx, my)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    -- The dragged object must not block its own placement raycast, or it sticks to the cursor
    -- at the distance it was grabbed and never lands on anything.
    params.FilterDescendantsInstances = { localPlayer.Character, selected }
    return workspace:Raycast(ray.Origin, ray.Direction * 1000, params)
end

RunService.RenderStepped:Connect(function()
    -- The server can delete a placement out from under the selection (another mod, Clear All).
    -- Drop the gizmos rather than leaving handles adorned to a destroyed part.
    if selected and not selected.Parent then clearSelection(); return end
    -- Two ways in: holding the mouse on the object (bodyDragging), or the sticky "grab" mode
    -- from the Move button (movingMode). Both funnel through the same follow-the-cursor code.
    if not (bodyDragging or movingMode) or not selected then return end
    local hit = dragRaycast()
    if not hit then return end
    local pos = surfaceRest(hit.Position, hit.Normal, getSize(selected))
    if SNAP_STEPS[snapIdx] > 0 then
        pos = Vector3.new(snapLinear(pos.X), snapLinear(pos.Y), snapLinear(pos.Z))
    end
    -- Keep the object's existing rotation; a free drag repositions, it doesn't reorient.
    local cf = getCF(selected)
    applyLive(CFrame.new(pos) * (cf - cf.Position), nil)
end)

UIS.InputEnded:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    if bodyDragging then
        bodyDragging = false
        commit("moved")
        setStatus()
    end
    -- Handles only fire their own MouseButton1Up when the cursor is still over the handle on
    -- release. Letting go anywhere else left handleDragging stuck true, which silently
    -- disabled free-dragging for the rest of the session. The real mouse button going up is
    -- the authoritative end of ANY drag, so clear it here too.
    handleDragging = false
end)

UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if not panelOpen then return end
    if input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end

    if placingMode then
        local pos = getMouseWorldHit()
        if placingMode == "NPCSpawner" then
            Remotes.RequestBToolAction:FireServer("placeNPCSpawner", pos, "", false, 60)
        elseif placingMode == "Interactable" then
            Remotes.RequestBToolAction:FireServer("placeInteractable", pos, "Tier2", "Search", "None", "", 60)
        elseif placingMode == "LightSource" then
            Remotes.RequestBToolAction:FireServer("placeLightSource", pos, LIGHT_TYPES[lightTypeIdx])
        elseif placingMode == "RitualMarker" then
            Remotes.RequestBToolAction:FireServer("placeRitualMarker", pos, "Unnamed Ritual")
        elseif placingMode == "Chest" then
            Remotes.RequestBToolAction:FireServer("placeChest", pos, "common_forest", 3600)
        elseif placingMode == "OreNode" then
            Remotes.RequestBToolAction:FireServer("placeOreNode", pos, ORE_TYPES[oreTypeIdx], "")
        elseif placingMode == "Smelter" then
            Remotes.RequestBToolAction:FireServer("placeSmelter", pos, "Basic")
        elseif placingMode == "TailoringStation" then
            Remotes.RequestBToolAction:FireServer("placeTailoringStation", pos, "Basic")
        elseif placingMode == "Forge" then
            Remotes.RequestBToolAction:FireServer("placeForge", pos)
        elseif placingMode == "FarmingPlot" then
            Remotes.RequestBToolAction:FireServer("placeFarmingPlot", pos)
        elseif placingMode == "CustomInteractable" then
            Remotes.RequestBToolAction:FireServer("placeCustomInteractable", pos, "")
        elseif placingMode == "Ship" then
            Remotes.RequestBToolAction:FireServer("placeShip", pos + Vector3.new(0, 5, 0), "")
        elseif placingMode == "Spirit" then
            Remotes.RequestBToolAction:FireServer("placeSpirit", pos + Vector3.new(0, 3, 0), SPIRIT_FACTIONS[spiritFactionIdx])
        end
        cancelModes()
        return
    end

    -- A click while grabbing drops the object where it currently sits.
    if movingMode then
        movingMode = false
        commit("moved")
        setStatus()
        return
    end

    -- Plain click with no active mode: select a session placement, or -- if the click landed
    -- on the ALREADY-selected object -- begin a free drag.
    local _, hitInst = getMouseWorldHit()
    local folder = workspace:FindFirstChild("SessionPlacements")
    if not (hitInst and folder and hitInst:IsDescendantOf(folder)) then return end

    local root = hitInst
    local asModel = hitInst:FindFirstAncestorOfClass("Model")
    if asModel and asModel:IsDescendantOf(folder) then root = asModel end

    if selected == root then
        -- Deferred so the Handles' own MouseButton1Down (which fires during this same input
        -- pass) has already set handleDragging -- otherwise grabbing an axis arrow that
        -- overlaps the part would start a body drag at the same time and the two would fight.
        task.defer(function()
            if not handleDragging and selected == root then
                bodyDragging = true
                beginDrag()
            end
        end)
    else
        selectInstance(root)
    end
end)

UIS.InputBegan:Connect(function(input, gpe)
    if input.KeyCode ~= Enum.KeyCode.Escape or not panelOpen then return end
    -- Escape during a grab puts the object back where it was picked up, rather than dropping
    -- it wherever the cursor happens to be -- that's what "cancel" should mean.
    if movingMode and selected and origCF then
        applyLive(origCF, nil)
        commit("moved")
    end
    if placingMode or movingMode then cancelModes() end
end)

-- Light Source needs its own placing-mode entry separate from the type-cycle click above
-- (Shift+click cycles type, plain click enters placing mode).
btnLight.MouseButton1Click:Connect(function()
    if UIS:IsKeyDown(Enum.KeyCode.LeftShift) or UIS:IsKeyDown(Enum.KeyCode.RightShift) then return end
    placingMode = "LightSource"; movingMode = false; setStatus()
end)

-- Keyboard nudging.
--
-- Bound through ContextActionService and ONLY while the panel is open with something
-- selected, because the arrow keys belong to the camera the rest of the time -- a permanent
-- binding would break looking around for every mod in the server.
local NUDGE_ACTION = "ABYSS_BToolsNudge"
local nudgeBound = false

local function shiftHeld()
    return UIS:IsKeyDown(Enum.KeyCode.LeftShift) or UIS:IsKeyDown(Enum.KeyCode.RightShift)
end

-- Shift = fine adjustment. Falls back to 1 stud / 15 deg when snapping is set to free, since
-- "nudge by nothing" isn't a useful key press.
local function nudgeStep()
    local s = SNAP_STEPS[snapIdx]
    if s == 0 then s = 1 end
    return shiftHeld() and (s / 4) or s
end
local function rotStepDeg()
    local s = ROT_SNAPS[rotSnapIdx]
    if s == 0 then s = 15 end
    return shiftHeld() and (s / 3) or s
end

local function scaleBy(f)
    local cf = getCF(selected)
    if isPart(selected) then
        local ns = selected.Size * f
        ns = Vector3.new(math.clamp(ns.X, 0.2, 2048), math.clamp(ns.Y, 0.2, 2048), math.clamp(ns.Z, 0.2, 2048))
        applyLive(cf, ns)
        commit("resized", cf, ns)
    elseif isModel(selected) then
        local sc = math.clamp(selected:GetScale() * f, 0.1, 20)
        pcall(function() selected:ScaleTo(sc) end)
        commit("resized", getCF(selected), Vector3.new(sc, 0, 0))
    end
end

local function handleNudge(_actionName, state, obj)
    if state ~= Enum.UserInputState.Begin then return Enum.ContextActionResult.Pass end
    if not (panelOpen and selected and selected.Parent) then return Enum.ContextActionResult.Pass end
    local kc = obj.KeyCode
    local cf = getCF(selected)

    if kc == Enum.KeyCode.Up then
        applyLive(cf + Vector3.new(0, nudgeStep(), 0), nil); commit("moved")
    elseif kc == Enum.KeyCode.Down then
        applyLive(cf - Vector3.new(0, nudgeStep(), 0), nil); commit("moved")
    elseif kc == Enum.KeyCode.Left or kc == Enum.KeyCode.Right then
        local dir = (kc == Enum.KeyCode.Right) and -1 or 1
        applyLive(cf * CFrame.Angles(0, math.rad(rotStepDeg() * dir), 0), nil); commit("rotated")
    elseif kc == Enum.KeyCode.Equals then
        scaleBy(1.1)
    elseif kc == Enum.KeyCode.Minus then
        scaleBy(1 / 1.1)
    elseif kc == Enum.KeyCode.X then
        gizmoModeIdx = (gizmoModeIdx % #GIZMO_MODES) + 1
        refreshGizmos()
    elseif kc == Enum.KeyCode.C then
        if shiftHeld() then rotSnapIdx = (rotSnapIdx % #ROT_SNAPS) + 1
        else snapIdx = (snapIdx % #SNAP_STEPS) + 1 end
    else
        return Enum.ContextActionResult.Pass
    end
    setStatus()
    return Enum.ContextActionResult.Sink
end

function updateNudgeBinding()
    local want = panelOpen and selected ~= nil and selected.Parent ~= nil
    if want and not nudgeBound then
        ContextActionService:BindActionAtPriority(NUDGE_ACTION, handleNudge, false, 3100,
            Enum.KeyCode.Up, Enum.KeyCode.Down, Enum.KeyCode.Left, Enum.KeyCode.Right,
            Enum.KeyCode.Equals, Enum.KeyCode.Minus, Enum.KeyCode.X, Enum.KeyCode.C)
        nudgeBound = true
    elseif not want and nudgeBound then
        ContextActionService:UnbindAction(NUDGE_ACTION)
        nudgeBound = false
    end
end

btnGizmo.MouseButton1Click:Connect(function()
    gizmoModeIdx = (gizmoModeIdx % #GIZMO_MODES) + 1
    refreshGizmos(); setStatus()
end)
btnSnap.MouseButton1Click:Connect(function()
    snapIdx = (snapIdx % #SNAP_STEPS) + 1; setStatus()
end)
btnRotSnap.MouseButton1Click:Connect(function()
    rotSnapIdx = (rotSnapIdx % #ROT_SNAPS) + 1; setStatus()
end)
btnResetRot.MouseButton1Click:Connect(function()
    if not (selected and selected.Parent) then return end
    local cf = CFrame.new(getCF(selected).Position)
    applyLive(cf, nil); commit("rotated"); setStatus()
end)

-- Server feedback feeds INTO setStatus rather than overwriting the label with its own
-- shorter format -- the old version wiped the gizmo/snap/size readout every time a
-- placement or transform came back, which is exactly when you most want to see it.
Remotes.BToolFeedback.OnClientEvent:Connect(function(data)
    lastFeedback = tostring(data.message or "")
    placementCount = data.count or placementCount
    setStatus()
end)

-- ── Panel toggle (N key, mods only) ────────────────────────────────────────────────────
local function togglePanel()
    if isModCache == nil then return end -- still resolving mod status
    if not isModCache then return end -- non-mods: N does nothing, panel never appears
    panelOpen = not panelOpen
    gui.Enabled = panelOpen
    if not panelOpen then cancelModes(); clearSelection() end
end

local function handleBToolsKey(_actionName, inputState, _inputObj)
    if inputState == Enum.UserInputState.Begin then
        togglePanel()
        return Enum.ContextActionResult.Sink
    end
    return Enum.ContextActionResult.Pass
end
ContextActionService:BindActionAtPriority("ABYSS_BTools", handleBToolsKey, false, 3000, Enum.KeyCode.N)

print("[BToolsClient] Loaded -- N to open (mods only)")
