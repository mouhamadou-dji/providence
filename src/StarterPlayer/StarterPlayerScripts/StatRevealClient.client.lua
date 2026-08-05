-- StatRevealClient -- PLACEHOLDER_GUI: StatRevealPanel
-- The styled panel a Revealer NPC's answer arrives in. Only ever fires for the one player who
-- asked (RevealManager uses FireClient, never FireAllClients) -- another player standing next
-- to the oracle hears the NPC's spoken line via the normal speech bubble, but never sees the
-- numbers.

local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Remotes = require(RepStorage:WaitForChild("Shared"):WaitForChild("RemoteEvents"))
local player  = Players.LocalPlayer

local GOLD   = Color3.fromRGB(198, 166, 100)
local PANEL  = Color3.fromRGB(14, 11, 8)
local BORDER = Color3.fromRGB(92, 74, 44)
local TEXT   = Color3.fromRGB(232, 220, 196)

local gui = Instance.new("ScreenGui")
gui.Name = "StatRevealGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 60
gui.Enabled = false
gui.Parent = player:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.Name = "RevealPanel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.new(0.5, 0, 0.42, 0)
panel.Size = UDim2.new(0, 460, 0, 200)
panel.BackgroundColor3 = PANEL
panel.BackgroundTransparency = 0.06
panel.BorderSizePixel = 0
panel.Parent = gui

local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 4); corner.Parent = panel
local stroke = Instance.new("UIStroke"); stroke.Color = BORDER; stroke.Thickness = 1.5; stroke.Parent = panel

local speakerLbl = Instance.new("TextLabel")
speakerLbl.BackgroundTransparency = 1
speakerLbl.Size = UDim2.new(1, -32, 0, 24)
speakerLbl.Position = UDim2.new(0, 16, 0, 14)
speakerLbl.Font = Enum.Font.GothamBold
speakerLbl.TextSize = 15
speakerLbl.TextColor3 = GOLD
speakerLbl.TextXAlignment = Enum.TextXAlignment.Left
speakerLbl.Text = ""
speakerLbl.Parent = panel

local divider = Instance.new("Frame")
divider.Size = UDim2.new(1, -32, 0, 1)
divider.Position = UDim2.new(0, 16, 0, 40)
divider.BackgroundColor3 = BORDER
divider.BorderSizePixel = 0
divider.Parent = panel

local bodyLbl = Instance.new("TextLabel")
bodyLbl.BackgroundTransparency = 1
bodyLbl.Size = UDim2.new(1, -32, 1, -84)
bodyLbl.Position = UDim2.new(0, 16, 0, 52)
bodyLbl.Font = Enum.Font.Gotham
bodyLbl.TextSize = 15
bodyLbl.TextColor3 = TEXT
bodyLbl.TextWrapped = true
bodyLbl.TextXAlignment = Enum.TextXAlignment.Left
bodyLbl.TextYAlignment = Enum.TextYAlignment.Top
bodyLbl.RichText = true
bodyLbl.Text = ""
bodyLbl.Parent = panel

local hintLbl = Instance.new("TextLabel")
hintLbl.BackgroundTransparency = 1
hintLbl.Size = UDim2.new(1, -32, 0, 18)
hintLbl.Position = UDim2.new(0, 16, 1, -26)
hintLbl.Font = Enum.Font.Gotham
hintLbl.TextSize = 11
hintLbl.TextColor3 = Color3.fromRGB(130, 116, 92)
hintLbl.TextXAlignment = Enum.TextXAlignment.Right
hintLbl.Text = "click anywhere to dismiss"
hintLbl.Parent = panel

local dismissBtn = Instance.new("TextButton")
dismissBtn.BackgroundTransparency = 1
dismissBtn.Size = UDim2.new(1, 0, 1, 0)
dismissBtn.Text = ""
dismissBtn.ZIndex = 0
dismissBtn.Parent = gui

local hideAt = 0

local function hide()
	gui.Enabled = false
	hideAt = 0
end

dismissBtn.MouseButton1Click:Connect(hide)

Remotes.ShowStatReveal.OnClientEvent:Connect(function(data)
	if type(data) ~= "table" then return end
	speakerLbl.Text = string.upper(tostring(data.speaker or "???"))

	local lines = data.lines or {}
	bodyLbl.Text = '<i>"' .. table.concat(lines, '"</i>\n\n<i>"') .. '"</i>'

	-- Grow the panel to fit multi-line reveals (Everything returns three separate lines).
	panel.Size = UDim2.new(0, 460, 0, math.clamp(120 + (#lines * 46), 160, 400))

	if data.cost and data.cost > 0 then
		hintLbl.Text = "-" .. data.cost .. " Obol  |  click anywhere to dismiss"
	else
		hintLbl.Text = "click anywhere to dismiss"
	end

	-- PLACEHOLDER_SOUND: reveal_chime
	if data.sound and data.sound ~= "" and data.sound ~= "rbxassetid://0" then
		local snd = Instance.new("Sound")
		snd.SoundId = data.sound
		snd.Volume = 0.6
		snd.Parent = gui
		snd:Play()
		snd.Ended:Connect(function() snd:Destroy() end)
	end

	gui.Enabled = true
	panel.BackgroundTransparency = 1
	stroke.Transparency = 1
	TweenService:Create(panel, TweenInfo.new(0.35), { BackgroundTransparency = 0.06 }):Play()
	TweenService:Create(stroke, TweenInfo.new(0.35), { Transparency = 0 }):Play()

	-- Auto-dismiss as a safety net so a missed click can't leave the panel stuck over the HUD.
	hideAt = tick() + 14
	task.delay(14, function()
		if hideAt ~= 0 and tick() >= hideAt then hide() end
	end)
end)

print("[StatRevealClient] Loaded")
