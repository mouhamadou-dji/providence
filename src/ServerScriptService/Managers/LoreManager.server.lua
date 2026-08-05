-- LoreManager — Module 10
local Players          = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RepStorage       = game:GetService("ReplicatedStorage")
local RunService       = game:GetService("RunService")

local LoreDataStore = DataStoreService:GetDataStore("AbyssLoreData_v1")
local Remotes       = require(RepStorage.Shared.RemoteEvents)

local PD_STAGES = {
	[0]="Inert",[1]="Awakened",[2]="Scarred",
	[3]="Burning",[4]="Condemned",[5]="TheAbyss",
}
local PDE_THRESHOLD = 3

-- Permanent Death is a single server-wide switch, not a per-player flag -- once a lore
-- team member throws it, EVERY player at Stage 3+ dies for good on their next death, not
-- just whichever player a mod had targeted. Persisted under a fixed key (not a per-user
-- one) so it survives server restarts.
local GLOBAL_PD_KEY = "GlobalPDState"
local globalPDActive = false
do
	local ok, data = pcall(function() return LoreDataStore:GetAsync(GLOBAL_PD_KEY) end)
	if ok and type(data) == "boolean" then globalPDActive = data end
end

local PD_ANNOUNCE_MESSAGE = "In this world, there is a time one is forever unable to retrieve."

-- Any player whose PlayerState is "Dead" (whichever manager set it -- PDE, or a mod's
-- killPlayer/setDead) respawns into the void instead of the normal spawn point. Found by
-- name/class rather than a hardcoded path since it just needs to exist somewhere under
-- workspace."void place".
local DEATH_HOLE_DROP_HEIGHT = 5 -- studs above the hole's center a respawning character is placed, so they drop onto it instead of clipping through

local function findDeathHole()
	local vp = workspace:FindFirstChild("void place")
	if not vp then return nil end
	for _, d in ipairs(vp:GetDescendants()) do
		if d:IsA("BasePart") and d.Name:lower() == "death hole" then return d end
	end
	return nil
end

local function teleportToDeathHole(char)
	local deathHole = findDeathHole()
	if not deathHole then warn("[LoreManager] 'death hole' part not found under workspace.'void place'"); return end
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	hrp.CFrame = CFrame.new(deathHole.Position + Vector3.new(0, DEATH_HOLE_DROP_HEIGHT, 0))
end

-- Void floor catch: anyone who falls off the floatables/parkour in workspace.'void place'
-- and drops down to "The void floor" (a big decorative safety-net plane far below --
-- CanCollide/CanTouch are both off on it, it was never meant to physically stop a fall)
-- gets teleported back to the death hole instead of falling forever. A Heartbeat position
-- check is used instead of .Touched: CanTouch is off, and even with it on, a fast fall can
-- tunnel through a thin part between physics steps and never fire Touched at all.
local function startVoidFloorCatch()
	local vp = workspace:FindFirstChild("void place")
	local floor = vp and vp:FindFirstChild("The void floor")
	if not floor then warn("[LoreManager] 'The void floor' part not found -- void fall-catch disabled"); return end

	-- Floor has no rotation (confirmed: CFrame.Rotation is identity), so a plain axis-aligned
	-- XZ bounding box off its own Position/Size is exact -- no need for full OBB math.
	local halfX, halfZ = floor.Size.X/2, floor.Size.Z/2
	local minX, maxX = floor.Position.X - halfX, floor.Position.X + halfX
	local minZ, maxZ = floor.Position.Z - halfZ, floor.Position.Z + halfZ
	local catchY = floor.Position.Y + floor.Size.Y/2 + 3 -- a few studs above the floor's own top surface

	RunService.Heartbeat:Connect(function()
		for _, plr in ipairs(Players:GetPlayers()) do
			local char = plr.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp then
				local pos = hrp.Position
				if pos.Y <= catchY and pos.X >= minX and pos.X <= maxX and pos.Z >= minZ and pos.Z <= maxZ then
					teleportToDeathHole(char)
				end
			end
		end
	end)
end

local function safeUpdate(key, fn)
	local attempts, success = 0, false
	repeat
		attempts += 1
		local ok, err = pcall(function() LoreDataStore:UpdateAsync(key, fn) end)
		if ok then success = true
		else
			warn("[LoreManager] DS write failed (" .. attempts .. "): " .. tostring(err))
			if attempts < 3 then task.wait(2) end
		end
	until success or attempts >= 3
	return success
end

local LoreManager = {}

function LoreManager.getStage(player)
	local dm = _G.DataManager
	return (dm and dm.getValue(player, "PDStage")) or 0
end

function LoreManager.setStage(player, stage)
	assert(
		type(stage) == "number" and stage >= 0 and stage <= 5
		and math.floor(stage) == stage,
		"PDStage must be integer 0-5, got: " .. tostring(stage)
	)
	local dm = _G.DataManager
	if dm then dm.setValue(player, "PDStage", stage) end
	Remotes.UpdateEclipseMoon:FireClient(player, stage)
	print(string.format("[LoreManager] %s PDStage -> %d (%s)",
		player.Name, stage, PD_STAGES[stage] or "?"))
end

function LoreManager.escalateStage(player)
	local current = LoreManager.getStage(player)
	if current >= 5 then
		print(string.format("[LoreManager] %s already at max stage", player.Name))
		return current
	end
	local next = current + 1
	LoreManager.setStage(player, next)
	return next
end

function LoreManager.isGlobalPDActive()
	return globalPDActive
end

function LoreManager.activatePDE()
	if globalPDActive then return end
	globalPDActive = true
	local ok, err = pcall(function() LoreDataStore:SetAsync(GLOBAL_PD_KEY, true) end)
	if not ok then warn("[LoreManager] Failed to persist global PD state: " .. tostring(err)) end
	print("[LoreManager] GLOBAL Permanent Death ACTIVATED -- every Stage " .. PDE_THRESHOLD .. "+ player's next death is now permanent")
	Remotes.PDGlobalAnnounce:FireAllClients(PD_ANNOUNCE_MESSAGE)
end

function LoreManager.deactivatePDE()
	if not globalPDActive then return end
	globalPDActive = false
	local ok, err = pcall(function() LoreDataStore:SetAsync(GLOBAL_PD_KEY, false) end)
	if not ok then warn("[LoreManager] Failed to persist global PD state: " .. tostring(err)) end
	print("[LoreManager] GLOBAL Permanent Death deactivated")
end

function LoreManager.isPDEEligible(player)
	return globalPDActive and LoreManager.getStage(player) >= PDE_THRESHOLD
end

function LoreManager.getLoreEchoes(player)
	local dm = _G.DataManager
	return (dm and dm.getValue(player, "LoreEchoes")) or {}
end

function LoreManager.addLoreEcho(player, echoText)
	assert(type(echoText) == "string" and #echoText > 0, "Echo must be a non-empty string")
	local dm = _G.DataManager
	if not dm then return end
	local echoes = dm.getValue(player, "LoreEchoes") or {}
	table.insert(echoes, {
		text      = echoText,
		timestamp = os.time(),
		stage     = LoreManager.getStage(player),
	})
	dm.setValue(player, "LoreEchoes", echoes)
	print(string.format("[LoreManager] %s echo added (total: %d)", player.Name, #echoes))
end

function LoreManager.writeLoreRecord(player, eventType, data)
	assert(type(eventType) == "string", "eventType must be a string")
	local dm     = _G.DataManager
	local charId = (dm and dm.getValue(player, "CharacterID")) or "unknown"
	local entry  = {
		type        = eventType,
		characterId = charId,
		timestamp   = os.time(),
		stage       = LoreManager.getStage(player),
		data        = data or {},
	}
	local key = "LoreRecord_" .. player.UserId
	safeUpdate(key, function(existing)
		local record = existing or {}
		table.insert(record, entry)
		return record
	end)
	print(string.format("[LoreManager] %s LoreRecord: %s", player.Name, eventType))
end

function LoreManager.applyLoreScar(player, zoneName)
	assert(type(zoneName) == "string" and #zoneName > 0, "zoneName must be a non-empty string")
	local dm     = _G.DataManager
	local charId = (dm and dm.getValue(player, "CharacterID")) or "unknown"
	local fn     = (dm and dm.getValue(player, "FirstName"))  or ""
	local ln     = (dm and dm.getValue(player, "FamilyName")) or ""
	local charName = (#fn > 0) and (fn .. " " .. ln) or player.Name
	local scar = {
		characterName = charName,
		characterId   = charId,
		stage         = LoreManager.getStage(player),
		timestamp     = os.time(),
	}
	local key = "ZoneScar_" .. zoneName
	safeUpdate(key, function(existing)
		local scars = existing or {}
		table.insert(scars, scar)
		return scars
	end)
	print(string.format("[LoreManager] Scar -> zone '%s' by %s (Stage %d)",
		zoneName, charName, scar.stage))
end

function LoreManager.triggerPDE(player, zoneName)
	assert(LoreManager.isPDEEligible(player), "triggerPDE: player is not PDE eligible")
	local dm   = _G.DataManager
	local fn   = (dm and dm.getValue(player, "FirstName"))  or ""
	local ln   = (dm and dm.getValue(player, "FamilyName")) or ""
	local charName = (#fn > 0) and (fn .. " " .. ln) or player.Name
	print(string.format("[LoreManager] PDE triggered — %s (Stage %d) zone='%s'",
		charName, LoreManager.getStage(player), zoneName or "unknown"))
	LoreManager.writeLoreRecord(player, "PDE_DEATH", {
		characterName = charName,
		zone = zoneName or "unknown",
	})
	if zoneName then LoreManager.applyLoreScar(player, zoneName) end
	if dm then
		dm.setValue(player, "PlayerState", "Dead")
	end
	local im = _G.IdentityManager
	if im then im.resetForWipe(player) end
	-- Give the player a fresh character rather than leaving them characterless forever --
	-- loadPlayer's CharacterAdded hook below redirects any "Dead"-state respawn straight to
	-- the void's death hole, so this doesn't put them back at a normal spawn point.
	task.delay(3, function()
		if player and player.Parent then player:LoadCharacter() end
	end)
	-- Fire moon update (keep stage visible in dead state)
	local stage = LoreManager.getStage(player)
	Remotes.UpdateEclipseMoon:FireClient(player, stage)
	-- PLACEHOLDER_DISCORD: PDE_DEATH
	-- PLACEHOLDER_ASSET: Valhalla statue spawn
	print(string.format("[LoreManager] %s entered Valhalla (stage %d)", charName, stage))
end

_G.LoreManager = LoreManager

local function hookDeath(p, char)
	local hum = char:WaitForChild("Humanoid")
	hum.Died:Connect(function()
		local hrp = char:FindFirstChild("HumanoidRootPart")
		local deathPos = hrp and hrp.Position
		if deathPos then
			local sanM = _G.SanityManager
			-- Grip/execution deaths already fire their own WitnessGripDeath from CombatManager's
			-- execution-completion callback; this generic hook covers every OTHER way a player's
			-- Humanoid can actually die (environmental, PDE, etc.), so it stays plain WitnessDeath.
			if sanM then sanM.notifyWitnessDeath(deathPos, false, {[p]=true}) end
		end
		task.spawn(function()
			if LoreManager.isPDEEligible(p) then
				LoreManager.triggerPDE(p, nil)
			else
				task.wait(3)
				if p and p.Parent then p:LoadCharacter() end
			end
		end)
	end)
end

local function loadPlayer(p)
	task.wait(1)
	local dm = _G.DataManager
	if not dm then return end
	if dm.getValue(p, "PDStage") == nil then dm.setValue(p, "PDStage", 0) end

	local stage = dm.getValue(p, "PDStage") or 0
	Remotes.UpdateEclipseMoon:FireClient(p, stage)

	print(string.format("[LoreManager] %s — Stage: %d (%s) | Global PDE: %s",
		p.Name,
		stage,
		PD_STAGES[stage] or "?",
		tostring(globalPDActive)))

	-- Hook current and future characters for death detection, and redirect any respawn
	-- that happens while PlayerState=="Dead" (PDE, or a mod's killPlayer/setDead) into the
	-- void instead of letting it land at the normal spawn point.
	local function onCharacterAdded(char)
		hookDeath(p, char)
		if dm.getValue(p, "PlayerState") == "Dead" then
			task.defer(function()
				task.wait(0.1) -- let the default spawn CFrame settle first so this teleport sticks
				if char and char.Parent then teleportToDeathHole(char) end
			end)
		end
	end
	p.CharacterAdded:Connect(onCharacterAdded)
	if p.Character then onCharacterAdded(p.Character) end
end

Players.PlayerAdded:Connect(loadPlayer)
for _, p in ipairs(Players:GetPlayers()) do task.spawn(function() loadPlayer(p) end) end
startVoidFloorCatch()

print("[LoreManager] Init — PDE threshold: Stage " .. PDE_THRESHOLD .. "+ (Burning) | Global PD active: " .. tostring(globalPDActive))
