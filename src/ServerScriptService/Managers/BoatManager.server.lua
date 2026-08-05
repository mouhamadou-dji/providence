-- BoatManager -- design doc PART TWO. Ships move via anchored-Part CFrame updates every
-- Heartbeat, exactly the technique FloatablesManager already proved reliable in this codebase
-- for carrying standing players (see its header comment: "Roblox already carries a standing
-- character along with a smoothly-moving anchored part's contact velocity, the standard
-- moving-platform pattern") -- no BodyMovers/physics simulation, no client-side compensation
-- script layered on top (that would double-count the carry the engine already does for free
-- off replicated anchored-part CFrame changes, and risks drifting players away over time).
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))
local boatCfg = Config.Boat

local function getOrCreate(name, isFunc)
	local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
		local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
	end)()
	local r=folder:FindFirstChild(name); if r then return r end
	r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local RE_ShipWheel     = getOrCreate("RequestShipWheel")     -- client -> server: hull, wantTake(bool)
local RE_ShipInput     = getOrCreate("RequestShipInput")     -- client -> server: hull, throttle(-1/0/1), turn(-1/0/1)
local RE_ShipAnchor    = getOrCreate("RequestShipAnchor")    -- client -> server: hull
local RE_ManCannon     = getOrCreate("RequestManCannon")     -- client -> server: cannonPart, wantTake(bool)
local RE_FireCannon    = getOrCreate("RequestFireCannon")    -- client -> server: cannonPart, aimDirection(Vector3)
local RE_BoatFeedback  = getOrCreate("BoatFeedback")         -- server -> requesting player: {ok, message}
local RE_ShipCFrame    = getOrCreate("ShipCFrameUpdate")     -- server -> all clients: hull, CFrame (deck-follow compensation, see BoatDeckClient)
local RE_LiveFeedUpdate = getOrCreate("LiveFeedUpdate")

local PROXIMITY_RANGE = 12

local ships = {}       -- [hullPart] = shipState
local cannonballs = {} -- array of {part, velocity, spawnTick, firedBy, hull}

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
			RE_LiveFeedUpdate:FireClient(p, { type = "BOAT", h = now.hour, m = now.min, zone = "?", charName = charName, message = message })
		end
	end
end

local function feedback(player, ok, message, extra)
	local payload = { ok = ok, message = message }
	if extra then for k, v in pairs(extra) do payload[k] = v end end
	RE_BoatFeedback:FireClient(player, payload)
end

local function playerNear(player, part, range)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or not part then return false end
	return (hrp.Position - part.Position).Magnitude <= (range or PROXIMITY_RANGE)
end

local BoatManager = {}

-- ================================================================================
-- SHIP CREATION -- placeholder art (blocky wood-colored Parts) per user request:
-- "leave placeholders... you'll be making her make placeholders" -- real hull/deck meshes
-- come later, this just needs to be a fully functional, testable ship right now.
-- ================================================================================

local function makePart(name, size, cframe, color, material, parent)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = true
	p.Parent = parent
	return p
end

function BoatManager.createShip(position, shipName)
	local model = Instance.new("Model")
	model.Name = shipName and (shipName ~= "" and shipName) or "Ship"

	local basePos = position + Vector3.new(0, -1, 0)
	-- PLACEHOLDER_ASSET: ShipHull / ShipDeck / ShipRigging -- blocky wood-tone placeholder
	-- geometry standing in for real ship meshes.
	local hull = makePart("Hull", Vector3.new(16, 6, 34), CFrame.new(basePos), Color3.fromRGB(92, 61, 33), Enum.Material.Wood, model)
	local deck = makePart("Deck", Vector3.new(15, 1, 33), CFrame.new(basePos + Vector3.new(0, 3.5, 0)), Color3.fromRGB(120, 85, 50), Enum.Material.WoodPlanks, model)
	local cabin = makePart("Cabin", Vector3.new(8, 5, 8), CFrame.new(basePos + Vector3.new(0, 6.5, -10)), Color3.fromRGB(100, 68, 38), Enum.Material.Wood, model)
	local mast = makePart("Mast", Vector3.new(1.2, 26, 1.2), CFrame.new(basePos + Vector3.new(0, 17, 4)), Color3.fromRGB(70, 48, 28), Enum.Material.Wood, model)
	local wheel = makePart("Wheel", Vector3.new(3, 3, 0.6), CFrame.new(basePos + Vector3.new(0, 6.5, -14)), Color3.fromRGB(60, 40, 22), Enum.Material.Wood, model)
	local anchorPart = makePart("Anchor", Vector3.new(2, 3, 1.5), CFrame.new(basePos + Vector3.new(6.5, 4, 15)), Color3.fromRGB(50, 50, 55), Enum.Material.Metal, model)
	local cannon1 = makePart("Cannon1", Vector3.new(2, 2, 6), CFrame.new(basePos + Vector3.new(-7, 4.5, 0)), Color3.fromRGB(35, 35, 38), Enum.Material.Metal, model)
	local cannon2 = makePart("Cannon2", Vector3.new(2, 2, 6), CFrame.new(basePos + Vector3.new(7, 4.5, 0)), Color3.fromRGB(35, 35, 38), Enum.Material.Metal, model)

	deck.CanCollide = true
	cabin.CanCollide = true
	mast.CanCollide = false
	wheel.CanCollide = false
	cannon1.CanCollide = true
	cannon2.CanCollide = true

	model.PrimaryPart = hull
	hull:SetAttribute("HullHP", boatCfg.DefaultHullHP)
	hull:SetAttribute("HullMaxHP", boatCfg.DefaultHullHP)
	hull:SetAttribute("ShipName", model.Name)
	hull:SetAttribute("OwnerUserId", 0)
	hull:SetAttribute("AnchorState", "Anchored")
	hull:SetAttribute("Ammo", boatCfg.DefaultAmmo)

	-- PLACEHOLDER_GUI: ShipHealthBar -- a plain always-on BillboardGui, no remote needed since
	-- it just reads the Hull's own replicated HullHP/HullMaxHP Attributes directly per-client.
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "ShipHealthBar"
	billboard.Size = UDim2.new(0, 160, 0, 24)
	billboard.StudsOffset = Vector3.new(0, 6, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 250
	billboard.Parent = hull
	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 0.4
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.TextColor3 = Color3.fromRGB(220, 60, 60)
	label.Font = Enum.Font.SourceSansBold
	label.TextScaled = true
	label.Name = "HPLabel"
	label.Text = model.Name .. " | HP " .. boatCfg.DefaultHullHP .. "/" .. boatCfg.DefaultHullHP
	label.Parent = billboard

	model.Parent = workspace
	BoatManager.registerShip(model)
	return model
end

-- Wires prompts + captures the rigid-body part offsets + adds the ship to the live runtime
-- registry. Used both right after createShip builds a brand new ship, AND at server start to
-- "adopt" any ship model already sitting in the place file (hand-placed, or left over from a
-- previous session) -- ProximityPrompt.Triggered connections and the `ships` table entry are
-- pure runtime state that never survives a server restart, so this must re-run every time
-- regardless of whether the Parts themselves are freshly built or were already saved.
function BoatManager.registerShip(model)
	local hull = model:FindFirstChild("Hull")
	if not hull or ships[hull] then return end
	if hull:GetAttribute("HullHP") == nil then return end

	-- HP label is a plain server-written TextLabel (LocalScripts can't have their .Source set
	-- at runtime by a live Script -- only Studio's own plugin/edit context can do that, a real
	-- capability restriction hit live) -- so the server just writes label.Text directly on
	-- damage, which replicates to every client the same as any other property change.
	local label = hull:FindFirstChild("ShipHealthBar") and hull.ShipHealthBar:FindFirstChild("HPLabel")
	if label then
		hull:GetAttributeChangedSignal("HullHP"):Connect(function()
			local hp = hull:GetAttribute("HullHP") or 0
			local maxHp = hull:GetAttribute("HullMaxHP") or 1
			label.Text = hull:GetAttribute("ShipName") .. " | HP " .. math.floor(hp) .. "/" .. math.floor(maxHp)
			label.TextColor3 = (hp / maxHp) > 0.4 and Color3.fromRGB(220,220,220) or Color3.fromRGB(220,60,60)
		end)
	end

	local wheel = model:FindFirstChild("Wheel")
	local anchorPart = model:FindFirstChild("Anchor")
	local cannon1 = model:FindFirstChild("Cannon1")
	local cannon2 = model:FindFirstChild("Cannon2")

	for _, entry in ipairs({
		{ part = wheel, text = "Take the Wheel", kind = "wheel" },
		{ part = anchorPart, text = "Toggle Anchor", kind = "anchor" },
		{ part = cannon1, text = "Man Cannon", kind = "cannon" },
		{ part = cannon2, text = "Man Cannon", kind = "cannon" },
	}) do
		local part = entry.part
		if part then
			for _, old in ipairs(part:GetChildren()) do
				if old:IsA("ProximityPrompt") then old:Destroy() end
			end
			local prompt = Instance.new("ProximityPrompt")
			prompt.HoldDuration = 0
			prompt.RequiresLineOfSight = false
			prompt.MaxActivationDistance = PROXIMITY_RANGE
			prompt.KeyboardKeyCode = Enum.KeyCode.E
			prompt.Style = Enum.ProximityPromptStyle.Custom
			prompt.ActionText = entry.text
			prompt.Parent = part
			prompt.Triggered:Connect(function(player)
				if entry.kind == "wheel" then BoatManager.requestWheel(player, hull, true)
				elseif entry.kind == "anchor" then BoatManager.requestAnchor(player, hull)
				else BoatManager.requestManCannon(player, part, true) end
			end)
		end
	end

	-- Capture every part's rigid offset from the hull ONCE -- moved every Heartbeat as
	-- hull.CFrame * localOffset, exactly FloatablesManager's proven anchored-rig technique.
	local rigidParts = {}
	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") and part ~= hull then
			table.insert(rigidParts, { part = part, offset = hull.CFrame:ToObjectSpace(part.CFrame) })
		end
	end

	-- Derive heading from the hull's own current Y rotation so an adopted, already-rotated
	-- ship (or one created facing a specific direction) starts facing the right way.
	local _, headingRad, _ = hull.CFrame:ToOrientation()

	ships[hull] = {
		model = model, hull = hull, rigidParts = rigidParts,
		pos = hull.Position, headingRad = headingRad, speed = 0,
		helmsman = nil, throttle = 0, turn = 0, lastInputAt = 0,
		cannonSeats = {}, cannonCooldowns = {},
		sinking = false, sinkStartTick = nil, sinkRoll = 0,
	}
end

-- Adopt any ship model already sitting in the place file at server start (see registerShip's
-- comment) -- scans direct children of workspace only (ships are always top-level models).
for _, inst in ipairs(workspace:GetChildren()) do
	if inst:IsA("Model") then
		local hull = inst:FindFirstChild("Hull")
		if hull and hull:GetAttribute("HullHP") ~= nil then
			BoatManager.registerShip(inst)
		end
	end
end

-- ================================================================================
-- WHEEL / ANCHOR / CANNON REQUESTS
-- ================================================================================

function BoatManager.requestWheel(player, hull, wantTake)
	local ship = ships[hull]; if not ship then return end
	local wheel = ship.model:FindFirstChild("Wheel")
	if not playerNear(player, wheel) then feedback(player, false, "Too far from the wheel."); return end
	if not wantTake or ship.helmsman == player then
		if ship.helmsman == player then
			ship.helmsman = nil; ship.throttle = 0; ship.turn = 0
			feedback(player, true, "Released the wheel.", { controlling = "none" })
		end
		return
	end
	if hull:GetAttribute("AnchorState") ~= "Sailing" then
		feedback(player, false, "Raise the anchor first."); return
	end
	if ship.helmsman then feedback(player, false, "Someone else is already steering."); return end
	ship.helmsman = player
	ship.lastInputAt = tick()
	feedback(player, true, "You take the wheel.", { controlling = "wheel", hull = hull })
	fireLiveFeed(getCharName(player), "took the wheel of " .. hull:GetAttribute("ShipName"))
end

function BoatManager.requestAnchor(player, hull)
	local ship = ships[hull]; if not ship then return end
	if ship.sinking then return end
	local anchorPart = ship.model:FindFirstChild("Anchor")
	if not playerNear(player, anchorPart) then feedback(player, false, "Too far from the anchor."); return end
	local newState = (hull:GetAttribute("AnchorState") == "Sailing") and "Anchored" or "Sailing"
	hull:SetAttribute("AnchorState", newState)
	if newState == "Anchored" then
		if ship.helmsman then feedback(ship.helmsman, true, "The anchor drops -- the wheel goes slack.") end
		ship.helmsman = nil; ship.throttle = 0; ship.turn = 0; ship.speed = 0
	end
	feedback(player, true, newState == "Sailing" and "Anchor raised." or "Anchor dropped.")
	fireLiveFeed(getCharName(player), (newState == "Sailing" and "raised" or "dropped") .. " anchor on " .. hull:GetAttribute("ShipName"))
end

function BoatManager.requestManCannon(player, cannonPart, wantTake)
	local model = cannonPart and cannonPart.Parent
	local hull = model and model:FindFirstChild("Hull")
	local ship = hull and ships[hull]; if not ship then return end
	if not playerNear(player, cannonPart) then feedback(player, false, "Too far from the cannon."); return end
	if not wantTake or ship.cannonSeats[cannonPart] == player then
		if ship.cannonSeats[cannonPart] == player then
			ship.cannonSeats[cannonPart] = nil
			feedback(player, true, "You step away from the cannon.", { controlling = "none" })
		end
		return
	end
	if ship.cannonSeats[cannonPart] then feedback(player, false, "Someone else is manning that cannon."); return end
	ship.cannonSeats[cannonPart] = player
	feedback(player, true, "You man the cannon.", { controlling = "cannon", cannonPart = cannonPart })
end

RE_ShipWheel.OnServerEvent:Connect(function(player, hull, wantTake) BoatManager.requestWheel(player, hull, wantTake) end)
RE_ShipAnchor.OnServerEvent:Connect(function(player, hull) BoatManager.requestAnchor(player, hull) end)
RE_ManCannon.OnServerEvent:Connect(function(player, cannonPart, wantTake) BoatManager.requestManCannon(player, cannonPart, wantTake) end)

RE_ShipInput.OnServerEvent:Connect(function(player, hull, throttle, turn)
	local ship = ships[hull]; if not ship or ship.helmsman ~= player then return end
	ship.throttle = math.clamp(tonumber(throttle) or 0, -1, 1)
	ship.turn = math.clamp(tonumber(turn) or 0, -1, 1)
	ship.lastInputAt = tick()
end)

RE_FireCannon.OnServerEvent:Connect(function(player, cannonPart, aimDir)
	local model = cannonPart and cannonPart.Parent
	local hull = model and model:FindFirstChild("Hull")
	local ship = hull and ships[hull]; if not ship or ship.sinking then return end
	if ship.cannonSeats[cannonPart] ~= player then return end
	if typeof(aimDir) ~= "Vector3" or aimDir.Magnitude < 0.01 then return end
	local now = tick()
	if (ship.cannonCooldowns[cannonPart] or 0) > now then return end
	local ammo = hull:GetAttribute("Ammo") or 0
	if ammo <= 0 then feedback(player, false, "Out of cannonballs."); return end
	ship.cannonCooldowns[cannonPart] = now + boatCfg.CannonCooldown
	hull:SetAttribute("Ammo", ammo - 1)

	-- PLACEHOLDER_ASSET: Cannonball -- driven by our own per-frame position update (see the
	-- cannonball loop below) rather than real Roblox physics, matching the rest of this
	-- codebase's server-authoritative anchored/kinematic movement convention.
	local ball = Instance.new("Part")
	ball.Name = "Cannonball"
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(1.4, 1.4, 1.4)
	ball.Color = Color3.fromRGB(20, 20, 20)
	ball.Material = Enum.Material.Metal
	ball.Anchored = true
	ball.CanCollide = false
	ball.CFrame = CFrame.new(cannonPart.Position + aimDir.Unit * 4)
	ball.Parent = workspace
	table.insert(cannonballs, {
		part = ball, velocity = aimDir.Unit * boatCfg.CannonballSpeed,
		spawnTick = now, firedBy = player, sourceHull = hull,
	})
end)

-- ================================================================================
-- DAMAGE / SINKING
-- ================================================================================

function BoatManager.damageShip(hull, amount, source)
	local ship = ships[hull]; if not ship or ship.sinking then return end
	local hp = math.max(0, (hull:GetAttribute("HullHP") or 0) - amount)
	hull:SetAttribute("HullHP", hp)
	if hp <= 0 then BoatManager.sinkShip(hull) end
end

function BoatManager.sinkShip(hull)
	local ship = ships[hull]; if not ship or ship.sinking then return end
	ship.sinking = true
	ship.sinkStartTick = tick()
	hull:SetAttribute("AnchorState", "Sinking")
	if ship.helmsman then feedback(ship.helmsman, true, hull:GetAttribute("ShipName") .. " is sinking!", { controlling = "none" }) end
	ship.helmsman = nil; ship.throttle = 0; ship.turn = 0
	for cannonPart, p in pairs(ship.cannonSeats) do
		if p then feedback(p, true, hull:GetAttribute("ShipName") .. " is sinking!", { controlling = "none" }) end
	end
	ship.cannonSeats = {}
	fireLiveFeed(hull:GetAttribute("ShipName"), "is sinking")
	task.delay(boatCfg.SinkDuration, function()
		if ship.model and ship.model.Parent then ship.model:Destroy() end
		ships[hull] = nil
	end)
end

-- ================================================================================
-- MAIN HEARTBEAT -- ship movement + cannonball flight, all kinematic (no BodyMovers).
-- ================================================================================

-- Deck-follow compensation (design doc's "Approach B") -- confirmed live that anchored-Part
-- CFrame movement alone does NOT carry a standing character horizontally in this engine
-- version (only FloatablesManager's slow vertical bob happens to work via gravity re-settling
-- the character each frame; a 15+ stud/sec horizontal slide left the player standing still
-- while the hull sailed out from under them). So every DeckFollowUpdateRate seconds, broadcast
-- the hull's new CFrame and let each client apply the delta directly to any character standing
-- on that ship's deck (see BoatDeckClient) -- this is the ACTUAL mechanism that keeps players
-- aboard, not a supplementary nicety.
local function maybeBroadcast(hull, ship)
	local now = tick()
	if now - (ship.lastBroadcast or 0) >= boatCfg.DeckFollowUpdateRate then
		ship.lastBroadcast = now
		RE_ShipCFrame:FireAllClients(hull, hull.CFrame)
	end
end

RunService.Heartbeat:Connect(function(dt)
	for hull, ship in pairs(ships) do
		if not hull.Parent then
			ships[hull] = nil
		elseif ship.sinking then
			local elapsed = tick() - ship.sinkStartTick
			local t = math.clamp(elapsed / boatCfg.SinkDuration, 0, 1)
			local sinkY = ship.pos.Y - t * 14
			ship.sinkRoll = t * 35 -- degrees, tips over as it goes under
			local newCFrame = CFrame.new(ship.pos.X, sinkY, ship.pos.Z)
				* CFrame.Angles(0, ship.headingRad, 0) * CFrame.Angles(math.rad(ship.sinkRoll), 0, math.rad(ship.sinkRoll * 0.5))
			hull.CFrame = newCFrame
			for _, rp in ipairs(ship.rigidParts) do
				if rp.part.Parent then rp.part.CFrame = newCFrame * rp.offset end
			end
			maybeBroadcast(hull, ship)
		else
			local anchorState = hull:GetAttribute("AnchorState")
			if anchorState == "Sailing" then
				if ship.helmsman then
					-- Helmsman disconnected/character removed without releasing the wheel cleanly.
					if not ship.helmsman.Parent or (tick() - ship.lastInputAt) > 5 then
						ship.helmsman = nil; ship.throttle = 0; ship.turn = 0
					end
				end
				if ship.helmsman then
					ship.speed = math.clamp(ship.speed + ship.throttle * boatCfg.Acceleration * dt, 0, boatCfg.SpeedCap)
					ship.headingRad = ship.headingRad + math.rad(ship.turn * boatCfg.TurnRate) * dt
					local forward = Vector3.new(math.sin(ship.headingRad), 0, math.cos(ship.headingRad))
					local om = _G.OceanManager
					local windDir = om and om.getWindDirection() or Vector3.new(1,0,0)
					local alignment = forward:Dot(windDir)
					local effSpeed = ship.speed * (1 + alignment * boatCfg.WindAlignBonus)
					ship.pos = ship.pos + forward * effSpeed * dt
				else
					ship.speed = math.max(0, ship.speed - boatCfg.Acceleration * dt)
					-- Unmanned but sailing: drift with the wind (design doc PART TWO).
					local om = _G.OceanManager
					if om then
						local windDir = om.getWindDirection()
						local windStrength = om.getWindStrength()
						ship.pos = ship.pos + windDir * windStrength * 0.5 * dt
					end
				end
				local newCFrame = CFrame.new(ship.pos) * CFrame.Angles(0, ship.headingRad, 0)
				hull.CFrame = newCFrame
				for _, rp in ipairs(ship.rigidParts) do
					if rp.part.Parent then rp.part.CFrame = newCFrame * rp.offset end
				end
				maybeBroadcast(hull, ship)
			end
		end
	end

	-- Cannonballs: simple kinematic flight + raycast-per-step hit detection (see header --
	-- deliberately not real Touched-event physics, matching the rest of this file).
	for i = #cannonballs, 1, -1 do
		local cb = cannonballs[i]
		if not cb.part.Parent then
			table.remove(cannonballs, i)
		else
			local oldPos = cb.part.Position
			local newPos = oldPos + cb.velocity * dt
			local rp = RaycastParams.new()
			rp.FilterType = Enum.RaycastFilterType.Exclude
			-- Must exclude the firing ship's own model too, not just the ball -- spawning 4 studs
			-- in front of the cannon still put the ball inside/grazing the ship's own hitbox, so
			-- the very first frame's raycast immediately "hit" a non-Hull part of the SAME ship
			-- (Cannon/Deck/Mast) and self-splashed before ever traveling anywhere (confirmed live:
			-- target ship took zero damage after a fire that reported success).
			rp.FilterDescendantsInstances = { cb.part, cb.sourceHull.Parent }
			local result = workspace:Raycast(oldPos, newPos - oldPos, rp)
			local hitHull = nil
			if result then
				local anc = result.Instance
				while anc and not hitHull do
					if anc:IsA("BasePart") and anc.Name == "Hull" and anc:GetAttribute("HullHP") ~= nil then hitHull = anc end
					anc = anc.Parent
				end
			end
			if hitHull and hitHull ~= cb.sourceHull then
				BoatManager.damageShip(hitHull, boatCfg.CannonDamage, cb.firedBy)
				fireLiveFeed(getCharName(cb.firedBy), "landed a cannon hit on " .. hitHull:GetAttribute("ShipName"))
				cb.part:Destroy(); table.remove(cannonballs, i)
			elseif result then
				-- PLACEHOLDER_ASSET: CannonballSplash -- hit terrain/water/anything else, just stop here.
				cb.part:Destroy(); table.remove(cannonballs, i)
			elseif tick() - cb.spawnTick > boatCfg.CannonballLifetime then
				cb.part:Destroy(); table.remove(cannonballs, i)
			else
				cb.part.CFrame = CFrame.new(newPos)
			end
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	for hull, ship in pairs(ships) do
		if ship.helmsman == player then ship.helmsman = nil; ship.throttle = 0; ship.turn = 0 end
		for cannonPart, p in pairs(ship.cannonSeats) do
			if p == player then ship.cannonSeats[cannonPart] = nil end
		end
	end
end)

_G.BoatManager = BoatManager
print("[BoatManager] Init")
