-- NameBillboardClient
-- Renders a name above a character's head only if the local player has learned
-- it via /introduce. Hidden entirely if the target has ConcealmentActive set.

local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Remotes = require(RepStorage:WaitForChild("Shared",10):WaitForChild("RemoteEvents",10))
local player  = Players.LocalPlayer

-- Roblox's own default overhead name/health display isn't distance-gated the way our
-- lore-name tag is below (it also just shows the raw account name, which broke the
-- "unknown until introduced" mystery system), and the default PlayerList (Tab menu) leaks
-- everyone's real username anyway -- both replaced entirely by AbyssNameTag below.
pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
end)

local PARCHM    = Color3.fromRGB(208, 194, 165)
local USERNAME_C = Color3.fromRGB(140, 132, 118)

local knownNames = {} -- [userId] = {first=, family=}

-- Sanity Tier 2 (Face Scribbles, see SanityEffectsClient): while active, names disappear
-- entirely for the affected (local) player. refresh() polls every 1s per billboard already
-- (see below), so just gating on this flag there is race-safe in both directions -- no need
-- to touch bb.Enabled from outside this script.
local scribbleActive = false
task.spawn(function()
	local remotes = RepStorage:WaitForChild("RemoteEvents", 10)
	local re = remotes and remotes:WaitForChild("UpdateSanityEffects", 10)
	if not re then return end
	re.OnClientEvent:Connect(function(payload)
		if payload and payload.tiers then scribbleActive = payload.tiers.scribble == true end
	end)
end)

local function fetchKnownNames()
	local ok, result = pcall(function() return Remotes.GetKnownNames:InvokeServer() end)
	if ok and type(result) == "table" then
		for uidStr, entry in pairs(result) do
			knownNames[tonumber(uidStr)] = entry
		end
	end
end
fetchKnownNames()

Remotes.NameLearned.OnClientEvent:Connect(function(targetUserId, first, family)
	knownNames[targetUserId] = { first = first, family = family }
end)

local function buildLabel(head, targetUserId, robloxUsername)
	local bb = Instance.new("BillboardGui")
	bb.Name = "AbyssNameTag"
	bb.Size = UDim2.new(0, 160, 0, 36)
	bb.StudsOffset = Vector3.new(0, 3.2, 0)
	bb.MaxDistance = 80 -- hides past this range; only tag left once the default CoreGui one is off
	bb.AlwaysOnTop = false
	bb.Parent = head

	local lbl = Instance.new("TextLabel")
	lbl.Name = "LoreName"
	lbl.Size = UDim2.new(1,0,0,20)
	lbl.BackgroundTransparency = 1
	-- GothamBold reads far more cleanly at small billboard sizes than SourceSansBold, which
	-- gets mushy/hard to make out past a few dozen studs.
	lbl.Font = Enum.Font.GothamBold; lbl.TextSize = 15
	lbl.TextColor3 = PARCHM
	lbl.TextStrokeTransparency = 0.3
	lbl.Text = ""
	lbl.Parent = bb

	local userLbl = Instance.new("TextLabel")
	userLbl.Name = "Username"
	userLbl.Size = UDim2.new(1,0,0,14)
	userLbl.Position = UDim2.new(0,0,0,20)
	userLbl.BackgroundTransparency = 1
	userLbl.Font = Enum.Font.Gotham; userLbl.TextSize = 11
	userLbl.TextColor3 = USERNAME_C
	userLbl.TextStrokeTransparency = 0.5
	userLbl.Text = "@" .. robloxUsername
	userLbl.Parent = bb

	local char = head.Parent

	local function refresh()
		if not bb.Parent then return end
		local entry = knownNames[targetUserId]
		local concealed = char and char:GetAttribute("ConcealmentActive")
		if not entry or concealed or scribbleActive then
			bb.Enabled = false
			return
		end
		bb.Enabled = true
		lbl.Text = entry.family and (entry.first .. " " .. entry.family) or entry.first
	end

	refresh()

	if char then
		char:GetAttributeChangedSignal("ConcealmentActive"):Connect(refresh)
	end

	-- KnownNames can update via NameLearned (a mod rename, or a fresh /introduce)
	-- independent of any attribute change, so poll lightly while the tag exists.
	task.spawn(function()
		while bb.Parent do
			refresh()
			task.wait(1)
		end
	end)
end

local function onCharacterAdded(plr, char)
	if plr == player then return end -- don't show your own name above your own head
	local head = char:WaitForChild("Head", 5)
	if not head then return end
	buildLabel(head, plr.UserId, plr.Name)
end

for _, p in ipairs(Players:GetPlayers()) do
	if p.Character then onCharacterAdded(p, p.Character) end
	p.CharacterAdded:Connect(function(char) onCharacterAdded(p, char) end)
end
Players.PlayerAdded:Connect(function(p)
	p.CharacterAdded:Connect(function(char) onCharacterAdded(p, char) end)
end)

print("[NameBillboardClient] ready")
