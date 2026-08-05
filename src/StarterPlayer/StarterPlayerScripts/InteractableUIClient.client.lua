-- InteractableUIClient.client.lua -- renders the Chest loot popup and World Journal popup
-- (design doc PART ONE). PLACEHOLDER_GUI: ChestInventoryFrame / WorldJournalFrame.
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))

local playerGui = localPlayer:WaitForChild("PlayerGui")
local gui = Instance.new("ScreenGui")
gui.Name = "InteractableUIGui"; gui.ResetOnSpawn = false; gui.Enabled = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local GOLD = Color3.fromRGB(198,156,55)
local PARCHM = Color3.fromRGB(220,215,200)
local PANEL = Color3.fromRGB(18,14,10)

local frame = Instance.new("Frame")
frame.AnchorPoint = Vector2.new(0.5,0.5); frame.Position = UDim2.new(0.5,0,0.45,0)
frame.Size = UDim2.new(0,360,0,280); frame.BackgroundColor3 = PANEL; frame.BorderSizePixel = 0
frame.Parent = gui
do local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,8); c.Parent=frame end
do local s=Instance.new("UIStroke"); s.Color=GOLD; s.Thickness=1; s.Parent=frame end

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1,-40,0,30); titleLbl.Position = UDim2.new(0,10,0,8)
titleLbl.BackgroundTransparency = 1; titleLbl.Font = Enum.Font.Antique; titleLbl.TextSize = 18
titleLbl.TextColor3 = GOLD; titleLbl.TextXAlignment = Enum.TextXAlignment.Left; titleLbl.Parent = frame

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0,26,0,26); closeBtn.Position = UDim2.new(1,-32,0,6)
closeBtn.BackgroundColor3 = Color3.fromRGB(40,20,20); closeBtn.Text = "x"; closeBtn.TextColor3 = PARCHM
closeBtn.Font = Enum.Font.GothamBold; closeBtn.TextSize = 14; closeBtn.AutoButtonColor = false
closeBtn.Parent = frame
do local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,4); c.Parent=closeBtn end

local bodyFrame = Instance.new("Frame")
bodyFrame.Size = UDim2.new(1,-20,1,-50); bodyFrame.Position = UDim2.new(0,10,0,42)
bodyFrame.BackgroundTransparency = 1; bodyFrame.Parent = frame

local function close()
	gui.Enabled = false
	bodyFrame:ClearAllChildren()
end
closeBtn.MouseButton1Click:Connect(close)

-- ── Chest ─────────────────────────────────────────────────────────────────────
local currentChestPart = nil
local function renderChest(data)
	currentChestPart = data.chestPart
	titleLbl.Text = data.chestName or "Chest"
	bodyFrame:ClearAllChildren()
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.new(0,105,0,60); layout.CellPadding = UDim2.new(0,6,0,6)
	layout.Parent = bodyFrame
	for i, slot in ipairs(data.slots or {}) do
		local btn = Instance.new("TextButton")
		btn.BackgroundColor3 = Color3.fromRGB(28,22,14); btn.AutoButtonColor = false
		btn.Font = Enum.Font.Gotham; btn.TextSize = 12; btn.TextColor3 = PARCHM
		btn.TextWrapped = true
		btn.Text = slot and (slot.itemName .. "\nx" .. tostring(slot.count)) or "(empty)"
		btn.LayoutOrder = i
		btn.Parent = bodyFrame
		do local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,4); c.Parent=btn end
		if slot then
			btn.MouseButton1Click:Connect(function()
				Remotes.RequestTakeChestItem:FireServer(currentChestPart, i)
			end)
		end
	end
	gui.Enabled = true
end

Remotes.ShowChestUI.OnClientEvent:Connect(function(data)
	if not data then return end
	renderChest(data)
end)

-- ── World Journal ─────────────────────────────────────────────────────────────
Remotes.ShowWorldJournal.OnClientEvent:Connect(function(data)
	if not data then return end
	titleLbl.Text = data.title or "Journal"
	bodyFrame:ClearAllChildren()
	local txt = Instance.new("TextLabel")
	txt.Size = UDim2.new(1,0,1,0); txt.BackgroundTransparency = 1
	txt.Font = Enum.Font.Garamond; txt.TextSize = 18; txt.TextColor3 = PARCHM
	txt.TextWrapped = true; txt.TextXAlignment = Enum.TextXAlignment.Left; txt.TextYAlignment = Enum.TextYAlignment.Top
	txt.Text = data.text or ""
	txt.Parent = bodyFrame
	gui.Enabled = true
end)

-- ── Custom (no server-side handler registered yet -- lore team hasn't wired this name) ──
Remotes.CustomInteractTriggered.OnClientEvent:Connect(function(data)
	if not data then return end
	titleLbl.Text = data.name or "???"
	bodyFrame:ClearAllChildren()
	local txt = Instance.new("TextLabel")
	txt.Size = UDim2.new(1,0,1,0); txt.BackgroundTransparency = 1
	txt.Font = Enum.Font.Garamond; txt.TextSize = 16; txt.TextColor3 = PARCHM
	txt.TextWrapped = true; txt.Text = "Nothing happens... yet."
	txt.Parent = bodyFrame
	gui.Enabled = true
	task.delay(2, function() if gui.Enabled and titleLbl.Text == (data.name or "???") then close() end end)
end)

print("[InteractableUIClient] Loaded")
