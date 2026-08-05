-- Custom "E - Interact" HUD prompt, replacing Roblox's default floating 3D ProximityPrompt
-- UI for every interactable this feature set created (Chest/Journal/Ritual/Custom via
-- InteractableManager, plus Mining/Smelting/Tailoring/Smithing/Farming). Those managers set
-- prompt.Style = Enum.ProximityPromptStyle.Custom specifically so Roblox renders nothing for
-- them and this script has full control; SpiritManager/BToolsManager prompts are untouched
-- (still Default style) and keep their normal floating UI.
local ProximityPromptService = game:GetService("ProximityPromptService")

local gui = Instance.new("ScreenGui")
gui.Name = "InteractPromptGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 50
gui.Parent = game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")

local label = Instance.new("TextLabel")
label.Name = "Prompt"
label.AnchorPoint = Vector2.new(0.5, 1)
-- Matches the ABYSSHud health-bar Frame's own anchor/position (0.4866, 0.7415) so this sits
-- directly above it regardless of screen resolution -- a fixed offset, not a live reference
-- to the Frame instance, so it survives ABYSSHud re-cloning on respawn with zero reconnect logic.
label.Position = UDim2.new(0.4866, 0, 0.7415, -10)
label.Size = UDim2.new(0, 220, 0, 34)
label.BackgroundColor3 = Color3.fromRGB(15, 12, 10)
label.BackgroundTransparency = 0.35
label.BorderSizePixel = 0
label.Font = Enum.Font.GothamBold
label.TextSize = 20
label.TextColor3 = Color3.fromRGB(235, 220, 190)
label.Text = "E - Interact"
label.Visible = false
label.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 6)
corner.Parent = label

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(120, 95, 60)
stroke.Thickness = 1.5
stroke.Transparency = 0.3
stroke.Parent = label

local shown = {} -- [prompt] = true, supports overlapping prompts without flicker

local function refreshVisibility()
	label.Visible = next(shown) ~= nil
end

ProximityPromptService.PromptShown:Connect(function(prompt)
	if prompt.Style ~= Enum.ProximityPromptStyle.Custom then return end
	shown[prompt] = true
	label.Text = (prompt.ActionText ~= "" and prompt.ActionText or "Interact")
	label.Text = "E - " .. label.Text
	refreshVisibility()
end)

ProximityPromptService.PromptHidden:Connect(function(prompt)
	shown[prompt] = nil
	refreshVisibility()
end)

print("[InteractPromptClient] Loaded")
