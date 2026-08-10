-- IdentityManager
-- Character creation & identity: gender select, random name/skin/face/hair/clothing,
-- name-visibility (/introduce) support data, /outfit slot application, PDE wipe reset.

local Players        = game:GetService("Players")
local RepStorage     = game:GetService("ReplicatedStorage")
local InsertService  = game:GetService("InsertService")

local Remotes = require(RepStorage.Shared.RemoteEvents)

local IdentityManager = {}

-- ── Pools ──────────────────────────────────────────────────────────────────
local MaleNames = {
	"Vercingetorix","Ambiorix","Brennus","Caratacus","Dumnorix",
	"Eporedorix","Liscus","Cingetorix","Orgetorix","Viridomarus",
	"Camulogenus","Sedullos","Cavarinus","Tasgetius","Bellovesus",
}
local FemaleNames = {
	"Boudicca","Cartimandua","Veleda","Onomaris","Ethlinn",
	"Adsagsona","Rigantona","Andraste","Nemetona","Litavis",
}
local FamilyNames = {
	"Dumnacus","Viridomarus","Litaviccus","Cotus","Camulogenus",
	"Sedullos","Guturvatus","Cavarinus","Tasgetius","Acco",
	"Massus","Bellovesus","Segovax","Molacos","Biturix",
}
local SkinTones = {
	Color3.fromRGB(255,220,185), -- fair Celtic
	Color3.fromRGB(240,200,160), -- light olive
	Color3.fromRGB(210,170,130), -- medium olive Mediterranean
	Color3.fromRGB(185,145,105), -- tan Gaulish
	Color3.fromRGB(160,120,80),  -- darker Mediterranean
	Color3.fromRGB(140,100,65),  -- North African/Persian influenced
}
local FacePool = {
	"rbxasset://textures/face.png", -- PLACEHOLDER_ASSET: Face_1
	"rbxasset://textures/face.png", -- PLACEHOLDER_ASSET: Face_2
	"rbxasset://textures/face.png", -- PLACEHOLDER_ASSET: Face_3
	"rbxasset://textures/face.png", -- PLACEHOLDER_ASSET: Face_4
	"rbxasset://textures/face.png", -- PLACEHOLDER_ASSET: Face_5
}
local MaleClothingPool = {
	{ shirt = "rbxassetid://0", pants = "rbxassetid://0" }, -- PLACEHOLDER_ASSET: MaleShirt_1 / MalePants_1
	{ shirt = "rbxassetid://0", pants = "rbxassetid://0" }, -- PLACEHOLDER_ASSET: MaleShirt_2 / MalePants_2
	{ shirt = "rbxassetid://0", pants = "rbxassetid://0" }, -- PLACEHOLDER_ASSET: MaleShirt_3 / MalePants_3
}
local FemaleClothingPool = {
	{ shirt = "rbxassetid://0", pants = "rbxassetid://0" }, -- PLACEHOLDER_ASSET: FemaleShirt_1 / FemalePants_1
	{ shirt = "rbxassetid://0", pants = "rbxassetid://0" }, -- PLACEHOLDER_ASSET: FemaleShirt_2 / FemalePants_2
	{ shirt = "rbxassetid://0", pants = "rbxassetid://0" }, -- PLACEHOLDER_ASSET: FemaleShirt_3 / FemalePants_3
}

IdentityManager.SkinTones = SkinTones
IdentityManager.FacePool = FacePool

local function pick(pool) return pool[math.random(1, #pool)] end

local function waitForData(player)
	local dm = _G.DataManager
	local tries = 0
	while dm and not dm.isLoaded(player) and tries < 50 do
		task.wait(0.1); tries += 1
	end
	return dm
end

-- ── Appearance application ───────────────────────────────────────
local function applySkinTone(char, colorIndex)
	local color = SkinTones[colorIndex] or SkinTones[1]
	local bc = char:FindFirstChildOfClass("BodyColors")
	if not bc then
		bc = Instance.new("BodyColors")
		bc.Parent = char
	end
	bc.HeadColor3 = color; bc.TorsoColor3 = color
	bc.LeftArmColor3 = color; bc.RightArmColor3 = color
	bc.LeftLegColor3 = color; bc.RightLegColor3 = color
end

local function applyFace(char, faceIndex)
	local head = char:FindFirstChild("Head")
	if not head then return end
	local decal = head:FindFirstChild("face")
	if not decal then
		decal = Instance.new("Decal")
		decal.Name = "face"
		decal.Parent = head
	end
	decal.Texture = FacePool[faceIndex] or FacePool[1]
end

-- Classic Shirt/Pants catalog items have a product/catalog ID (what a mod would
-- paste from the marketplace URL) that is a DIFFERENT number from the actual
-- ShirtTemplate/PantsTemplate asset ID baked into that item. Resolve the real
-- template by loading the item and reading its template property directly,
-- rather than assuming the pasted ID is itself usable as "rbxassetid://<id>".
local function resolveClothingTemplate(id, className)
	local ok, model = pcall(function() return InsertService:LoadAsset(id) end)
	if not ok or not model then return nil end
	local item = model:FindFirstChildOfClass(className)
	local template = item and (className == "Shirt" and item.ShirtTemplate or item.PantsTemplate)
	model:Destroy()
	if template and template ~= "" then return template end
	return nil
end

function IdentityManager.resolveShirtId(id) return resolveClothingTemplate(id, "Shirt") end
function IdentityManager.resolvePantsId(id) return resolveClothingTemplate(id, "Pants") end

local function applyClothing(char, outfit)
	if not outfit then return end
	local shirt = char:FindFirstChildOfClass("Shirt")
	if not shirt then shirt = Instance.new("Shirt"); shirt.Parent = char end
	shirt.ShirtTemplate = outfit.shirt or "rbxassetid://0"

	local pants = char:FindFirstChildOfClass("Pants")
	if not pants then pants = Instance.new("Pants"); pants.Parent = char end
	pants.PantsTemplate = outfit.pants or "rbxassetid://0"
end

local hairStash = {} -- [userId] = {Accessory clones captured before an override was applied}

local function stashOriginalHair(userId, char)
	if hairStash[userId] then return end -- already stashed from a previous override
	local list = {}
	for _, acc in ipairs(char:GetChildren()) do
		if acc:IsA("Accessory") then table.insert(list, acc:Clone()) end
	end
	hairStash[userId] = list
end

local function applyHairOverride(char, overrideId, userId)
	if not overrideId or overrideId == 0 then return end
	if userId then stashOriginalHair(userId, char) end
	for _, acc in ipairs(char:GetChildren()) do
		if acc:IsA("Accessory") then acc:Destroy() end
	end
	local ok, model = pcall(function() return InsertService:LoadAsset(overrideId) end)
	if not ok or not model then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	for _, acc in ipairs(model:GetChildren()) do
		if acc:IsA("Accessory") then
			if hum then hum:AddAccessory(acc) else acc.Parent = char end
		end
	end
	model:Destroy()
end

function IdentityManager.restoreNaturalHair(player, char)
	for _, acc in ipairs(char:GetChildren()) do
		if acc:IsA("Accessory") then acc:Destroy() end
	end
	local stash = hairStash[player.UserId]
	if not stash then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	for _, acc in ipairs(stash) do
		local clone = acc:Clone()
		if hum then hum:AddAccessory(clone) else clone.Parent = char end
	end
	hairStash[player.UserId] = nil
end

-- Strips whatever the player's real Roblox avatar brought in (gear/hats/other
-- accessories, custom body-part meshes from UGC/bundles, etc.) so every character
-- looks like a plain, consistent R6 rig before our own skin/face/clothing/hair gets
-- layered on top. Hair is the one accessory type worth keeping as-is -- it's a natural
-- part of someone's look, not armor/gear -- so it's captured before the strip and
-- re-added after (ApplyDescription with a blank HumanoidDescription wipes every
-- accessory indiscriminately, hair included).
local function stripToDefaultR6(char)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then return end
	local hairClones = {}
	for _, acc in ipairs(char:GetChildren()) do
		if acc:IsA("Accessory") and acc.AccessoryType == Enum.AccessoryType.Hair then
			table.insert(hairClones, acc:Clone())
		end
	end
	local ok = pcall(function()
		hum:ApplyDescription(Instance.new("HumanoidDescription"))
	end)
	if not ok then
		-- Fallback if ApplyDescription isn't available for some reason: at least strip
		-- non-hair accessories directly so a custom avatar's hats/gear don't linger.
		for _, acc in ipairs(char:GetChildren()) do
			if acc:IsA("Accessory") and acc.AccessoryType ~= Enum.AccessoryType.Hair then acc:Destroy() end
		end
		return
	end
	for _, clone in ipairs(hairClones) do
		pcall(function() hum:AddAccessory(clone) end)
	end
end

function IdentityManager.applyAppearance(player, char)
	char = char or player.Character
	if not char then return end
	local dm = _G.DataManager; if not dm then return end
	char:WaitForChild("HumanoidRootPart", 5)

	stripToDefaultR6(char)
	applySkinTone(char, dm.getValue(player, "SkinToneIndex"))
	applyFace(char, dm.getValue(player, "FaceIndex"))

	local slot = dm.getValue(player, "ActiveOutfitSlot") or 1
	local outfit = dm.getValue(player, slot == 2 and "OutfitSlot2" or "OutfitSlot1")
	if outfit then applyClothing(char, outfit) end

	local hairOverride = dm.getValue(player, "HairOverrideId")
	if hairOverride and hairOverride ~= 0 then applyHairOverride(char, hairOverride, player.UserId) end

	local fn = dm.getValue(player, "FirstName") or ""
	local ln = dm.getValue(player, "FamilyName") or ""
	char:SetAttribute("DisplayFirstName", fn)
	char:SetAttribute("DisplayFamilyName", ln)
	char:SetAttribute("ConcealmentActive", dm.getValue(player, "ConcealmentActive") or false)
end

-- ── Hair capture (record-keeping only — natural Roblox avatar accessories
-- already persist across respawns without any code) ────────────────────────
local function captureHair(player, char)
	local dm = _G.DataManager; if not dm then return end
	local ids = {}
	for _, acc in ipairs(char:GetChildren()) do
		if acc:IsA("Accessory") then
			table.insert(ids, acc.Name)
		end
	end
	dm.setValue(player, "HairAccessories", ids)
end

-- ── First-time identity roll (gender select or PDE wipe) ────────────────
function IdentityManager.rollIdentity(player, gender)
	local dm = _G.DataManager; if not dm then return end
	if (dm.getValue(player, "FirstName") or "") == "" then
		local namePool = (gender == "Female") and FemaleNames or MaleNames
		dm.setValue(player, "FirstName", pick(namePool))
		dm.setValue(player, "FamilyName", pick(FamilyNames))
	end
	dm.setValue(player, "SkinToneIndex", math.random(1, #SkinTones))
	dm.setValue(player, "FaceIndex", math.random(1, #FacePool))
	local clothingPool = (gender == "Female") and FemaleClothingPool or MaleClothingPool
	dm.setValue(player, "OutfitSlot1", pick(clothingPool))
	dm.setValue(player, "OutfitSlot2", nil)
	dm.setValue(player, "ActiveOutfitSlot", 1)
	dm.setValue(player, "IdentitySetupDone", true)
	local char = player.Character
	if char then captureHair(player, char) end
end

-- ── Gender-select gate ─────────────────────────────────────────────
-- IMPORTANT: never touch CanCollide here. Disabling collision without anchoring
-- lets gravity pull the character through the floor during the (arbitrarily long)
-- gender-select pause. Only hide visually and zero movement input.
-- WalkSpeed must go through CombatManager.setSpeed() -- see MovementManager.lua's
-- "ONE RULE: all WalkSpeed changes go through setMovementState()" -- setting it
-- directly here desyncs MovementManager's internal state machine from the real
-- Humanoid value, which is what was causing movement to break for new characters.
local function freeze(player, char)
	-- ABSOLUTE, and at the top weight: a frozen player must not be movable by any buff,
	-- passive or scalar, so this setter opts out of the modifier and multiplier layers
	-- entirely. Jump goes through the same key -- the raw JumpPower write that used to live
	-- here was silently dead anyway, because nothing set UseJumpPower until MovementFlow did.
	local mf = _G.MovementFlow
	if mf then
		local W = require(game:GetService("ReplicatedStorage").Shared.Config).Movement.FlowWeights
		mf.set(player, "Freeze", W.Freeze, 0, 0, { absolute = true })
	end
	for _, part in ipairs(char:GetDescendants()) do
		if part:IsA("BasePart") then part.Transparency = 1 end
		if part:IsA("Decal") then part.Transparency = 1 end
	end
end

local function unfreeze(player, char)
	-- Release the key rather than asserting "speed 1, jump 50". Restoring constants is what
	-- made this erase a live injury or rage slow; clearing lets whatever is actually true
	-- resolve on its own.
	local mf = _G.MovementFlow
	if mf then mf.clear(player, "Freeze") end
	for _, part in ipairs(char:GetDescendants()) do
		if part:IsA("BasePart") then part.Transparency = 0 end
		if part:IsA("Decal") then part.Transparency = 0 end
	end
end

local awaitingGender = {} -- [userId] = true while frozen pending choice

local function handleCharacter(player, char)
	local dm = waitForData(player)
	if not dm then return end
	char:WaitForChild("HumanoidRootPart", 5)

	local gender = dm.getValue(player, "Gender") or ""
	if gender == "" then
		awaitingGender[player.UserId] = true
		freeze(player, char)
		Remotes.ShowGenderSelect:FireClient(player)
		return
	end

	if not dm.getValue(player, "IdentitySetupDone") then
		IdentityManager.rollIdentity(player, gender)
	end
	IdentityManager.applyAppearance(player, char)
end

Remotes.SubmitGenderSelect.OnServerEvent:Connect(function(player, gender)
	if gender ~= "Male" and gender ~= "Female" then return end
	local dm = _G.DataManager; if not dm then return end
	if (dm.getValue(player, "Gender") or "") ~= "" then return end -- already chosen
	dm.setValue(player, "Gender", gender)
	IdentityManager.rollIdentity(player, gender)
	dm.save(player, true)
	awaitingGender[player.UserId] = nil
	local char = player.Character
	if char then
		unfreeze(player, char)
		IdentityManager.applyAppearance(player, char)
	end
end)

-- Roblox loads a character's real avatar accessories/clothing asynchronously, and they
-- can finish attaching AFTER CharacterAdded already fired -- which is when our strip in
-- handleCharacter runs. That let hats/gear/faces from the player's real Roblox avatar
-- sneak in moments after every reset/respawn/first-join, since the strip had already run
-- and nothing re-checked afterward. Player.CharacterAppearanceLoaded (note: a per-Player
-- event, not a Players-service one) is guaranteed to fire only once the character's full
-- appearance has actually finished loading, so re-running the strip there catches
-- anything that arrived late.
local function hookAppearanceLoaded(player)
	player.CharacterAppearanceLoaded:Connect(function(char)
		if awaitingGender[player.UserId] then return end -- still frozen pending gender choice
		local dm = _G.DataManager
		if not dm or not dm.isLoaded(player) then return end
		if (dm.getValue(player, "Gender") or "") == "" then return end
		IdentityManager.applyAppearance(player, char)
	end)
end

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(char) handleCharacter(player, char) end)
	hookAppearanceLoaded(player)
	if player.Character then handleCharacter(player, player.Character) end
end)
for _, p in ipairs(Players:GetPlayers()) do
	p.CharacterAdded:Connect(function(char) handleCharacter(p, char) end)
	hookAppearanceLoaded(p)
	if p.Character then handleCharacter(p, p.Character) end
end

-- ── KnownNames / introduce support (used by ChatManager) ──────────────────
function IdentityManager.refreshKnownObservers(target)
	local dm = _G.DataManager; if not dm then return end
	for _, observer in ipairs(Players:GetPlayers()) do
		local known = dm.getValue(observer, "KnownNames")
		local key = tostring(target.UserId)
		local entry = known and known[key]
		if entry then
			entry.first = dm.getValue(target, "FirstName") or target.Name
			if entry.family then entry.family = dm.getValue(target, "FamilyName") end
			known[key] = entry
			dm.setValue(observer, "KnownNames", known)
			Remotes.NameLearned:FireClient(observer, target.UserId, entry.first, entry.family)
		end
	end
end

function IdentityManager.learnName(observer, target, includeFamily)
	local dm = _G.DataManager; if not dm then return end
	local known = dm.getValue(observer, "KnownNames") or {}
	local key = tostring(target.UserId)
	local entry = known[key] or {}
	entry.first = dm.getValue(target, "FirstName") or target.Name
	if includeFamily then
		entry.family = dm.getValue(target, "FamilyName")
	end
	known[key] = entry
	dm.setValue(observer, "KnownNames", known)
	Remotes.NameLearned:FireClient(observer, target.UserId, entry.first, entry.family)
end

Remotes.GetKnownNames.OnServerInvoke = function(player)
	local dm = _G.DataManager; if not dm then return {} end
	return dm.getValue(player, "KnownNames") or {}
end

-- ── PDE wipe reset (called by LoreManager) ───────────────────────────
function IdentityManager.resetForWipe(player)
	local dm = _G.DataManager; if not dm then return end
	dm.setValue(player, "FirstName", "")
	dm.setValue(player, "FamilyName", "")
	dm.setValue(player, "OutfitSlot1", nil)
	dm.setValue(player, "OutfitSlot2", nil)
	dm.setValue(player, "ActiveOutfitSlot", 1)
	dm.setValue(player, "KnownNames", {})
	dm.setValue(player, "IdentitySetupDone", false)
	-- Injuries reset on PDE wipe (new character, clean body) -- DNA is deliberately NOT
	-- touched here, it's bloodline lineage that persists across characters (see DNAManager).
	dm.setValue(player, "Injuries", {})
	local im2 = _G.InjuryManager
	if im2 and player.Character then im2.applyVisuals(player, player.Character) end
	-- Gender is intentionally preserved across PDE wipe
	local gender = dm.getValue(player, "Gender")
	if gender and gender ~= "" then
		IdentityManager.rollIdentity(player, gender)
	end
end

Players.PlayerRemoving:Connect(function(p) hairStash[p.UserId] = nil end)

_G.IdentityManager = IdentityManager
print("[IdentityManager] Init — gender select + name/skin/face/outfit generation live")
