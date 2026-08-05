-- FarmingClient.client.lua -- design doc PART SIX: seed selection popup only, the rest of
-- the flow (growth/harvest) is server-driven notifications (ShowNotification).
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")

local localPlayer = Players.LocalPlayer
local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))
local playerGui = localPlayer:WaitForChild("PlayerGui")

local GOLD = Color3.fromRGB(198,156,55)
local PARCHM = Color3.fromRGB(220,215,200)

local selectGui = Instance.new("ScreenGui")
selectGui.Name = "FarmingSelectGui"; selectGui.ResetOnSpawn = false; selectGui.Enabled = false
selectGui.Parent = playerGui
local selectFrame = Instance.new("Frame")
selectFrame.AnchorPoint = Vector2.new(0.5,0.5); selectFrame.Position = UDim2.new(0.5,0,0.4,0)
selectFrame.Size = UDim2.new(0,220,0,180); selectFrame.BackgroundColor3 = Color3.fromRGB(18,14,10)
selectFrame.Parent = selectGui
do local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,8); c.Parent=selectFrame end
do local s=Instance.new("UIStroke"); s.Color=GOLD; s.Thickness=1; s.Parent=selectFrame end
local selectTitle = Instance.new("TextLabel")
selectTitle.Size = UDim2.new(1,-20,0,26); selectTitle.Position=UDim2.new(0,10,0,8)
selectTitle.BackgroundTransparency=1; selectTitle.Font=Enum.Font.Antique; selectTitle.TextSize=16
selectTitle.TextColor3=GOLD; selectTitle.Text="PLANT SEED"; selectTitle.TextXAlignment=Enum.TextXAlignment.Left
selectTitle.Parent = selectFrame
local selectList = Instance.new("ScrollingFrame")
selectList.Size = UDim2.new(1,-16,1,-42); selectList.Position=UDim2.new(0,8,0,38)
selectList.BackgroundTransparency=1; selectList.BorderSizePixel=0; selectList.ScrollBarThickness=3
selectList.CanvasSize=UDim2.new(0,0,0,0); selectList.AutomaticCanvasSize=Enum.AutomaticSize.Y
selectList.Parent = selectFrame
do local l=Instance.new("UIListLayout"); l.Padding=UDim.new(0,4); l.Parent=selectList end

local currentPlotPart = nil
Remotes.FarmingOpenSeedSelect.OnClientEvent:Connect(function(data)
	if not data then return end
	currentPlotPart = data.plotPart
	selectList:ClearAllChildren()
	for _, seedName in ipairs(data.seeds or {}) do
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(1,0,0,30); btn.BackgroundColor3 = Color3.fromRGB(28,22,14)
		btn.Font = Enum.Font.Gotham; btn.TextSize = 14; btn.TextColor3 = PARCHM; btn.AutoButtonColor=false
		btn.Text = seedName
		btn.Parent = selectList
		do local c=Instance.new("UICorner"); c.CornerRadius=UDim.new(0,4); c.Parent=btn end
		btn.MouseButton1Click:Connect(function()
			selectGui.Enabled = false
			Remotes.RequestPlantSeed:FireServer(currentPlotPart, seedName)
		end)
	end
	selectGui.Enabled = true
end)

print("[FarmingClient] Loaded")
