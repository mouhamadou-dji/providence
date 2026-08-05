-- TradeClient -- design doc PART THREE. Backspace drops whichever hotbar slot is currently
-- equipped (EquippedSlot is this game's existing "selected item" concept -- HotbarClient
-- already highlights it, so no separate slot-selection UI is needed for this).
local Players          = game:GetService("Players")
local RepStorage       = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Remotes = RepStorage:WaitForChild("RemoteEvents")
local RE_RequestDrop = Remotes:WaitForChild("RequestDropItem")

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode ~= Enum.KeyCode.Backspace then return end
	RE_RequestDrop:FireServer()
end)

print("[TradeClient] Init -- Backspace drops the equipped hotbar item")
