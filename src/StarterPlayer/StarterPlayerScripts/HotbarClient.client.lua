local Players           = game:GetService("Players")
local RepStorage        = game:GetService("ReplicatedStorage")
local UserInputService  = game:GetService("UserInputService")
local StarterGui        = game:GetService("StarterGui")

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))

-- The default CoreGui Backpack reserves keys 1-9/0 to equip Tools from Player.Backpack;
-- left enabled it can consume those same keypresses before our own hotbar sees them.
pcall(function() StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false) end)

local NUM_SLOTS = 10
-- Number row 1-9 map to slots 1-9; 0 maps to slot 10 (matches a real keyboard's layout).
local KEY_TO_SLOT = {
	[Enum.KeyCode.One]=1, [Enum.KeyCode.Two]=2, [Enum.KeyCode.Three]=3, [Enum.KeyCode.Four]=4,
	[Enum.KeyCode.Five]=5, [Enum.KeyCode.Six]=6, [Enum.KeyCode.Seven]=7, [Enum.KeyCode.Eight]=8,
	[Enum.KeyCode.Nine]=9, [Enum.KeyCode.Zero]=10,
}

local hotbar, slots
local currentInventory = {}
local equippedSlot = nil

local function setSlotSelected(slot, selected)
	local flash = slot:FindFirstChild("Flash")
	if flash then flash.ImageTransparency = selected and 0.9 or 1 end
end

local function render()
	if not hotbar or not slots then return end
	hotbar.Visible = #currentInventory > 0
	for i = 1, NUM_SLOTS do
		local slot = slots[i]
		local item = currentInventory[i]
		slot.Visible = item ~= nil
		if item then
			local desc = slot:FindFirstChild("Description")
			if desc then desc.Text = item.itemName end
		end
		setSlotSelected(slot, i == equippedSlot)
	end
end

local function selectSlot(i)
	if not currentInventory[i] then return end
	-- Clicking/pressing the already-equipped slot again unequips it (matches the server's
	-- InventoryManager toggle). Optimistic local highlight; the server's UpdateInventory
	-- reply (below) corrects this if the request is ever rejected.
	equippedSlot = (equippedSlot == i) and nil or i
	render()
	Remotes.RequestEquipSlot:FireServer(i)
end


local function buildSlots()
	local template = hotbar:FindFirstChild("HotbarTool")
	if not template then warn("[HotbarClient] HotbarTool template not found"); return end
	for _, child in ipairs(hotbar:GetChildren()) do
		if child ~= template and child.Name:match("^HotbarTool%d+$") then child:Destroy() end
	end
	slots = { template }
	template.LayoutOrder = 1
	for i = 2, NUM_SLOTS do
		local clone = template:Clone()
		clone.Name = "HotbarTool" .. i
		clone.LayoutOrder = i
		clone.Parent = hotbar
		slots[i] = clone
	end
	for i, slot in ipairs(slots) do
		local keybind = slot:FindFirstChild("Keybind")
		if keybind then keybind.Text = (i == NUM_SLOTS) and "0" or tostring(i) end
		slot.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				selectSlot(i)
			end
		end)
	end
end


local function acquireHotbar()
	local abyssHud = playerGui
		:WaitForChild("_GUIs", 10)
		:WaitForChild("HUD", 10)
		:WaitForChild("ABYSSHud", 10)
	hotbar = abyssHud and abyssHud:FindFirstChild("Hotbar")
	if not hotbar then warn("[HotbarClient] Hotbar frame not found"); return end
	buildSlots()
	render()
end

Remotes.UpdateInventory.OnClientEvent:Connect(function(inventory, equipped)
	currentInventory = inventory or {}
	equippedSlot = equipped
	render()
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.UserInputType ~= Enum.UserInputType.Keyboard then return end
	local slotIndex = KEY_TO_SLOT[input.KeyCode]
	if slotIndex then
		selectSlot(slotIndex)
		return
	end
	if input.KeyCode == Enum.KeyCode.Backquote then
		-- TODO: toggle the Inventory frame once it's built.
	end
end)

player.CharacterAdded:Connect(acquireHotbar)
acquireHotbar()

print("[HotbarClient] Init")
