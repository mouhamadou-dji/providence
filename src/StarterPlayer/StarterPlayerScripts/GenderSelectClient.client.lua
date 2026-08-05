-- GenderSelectClient
-- One-time fullscreen gender prompt. Cannot be dismissed without choosing.

local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")

local Remotes = require(RepStorage:WaitForChild("Shared",10):WaitForChild("RemoteEvents",10))
local player  = Players.LocalPlayer
local pgui    = player.PlayerGui

local BG      = Color3.fromRGB(6, 4, 2)
local PARCHM  = Color3.fromRGB(208, 194, 165)
local GOLD    = Color3.fromRGB(201, 168, 76)
local BORDER  = Color3.fromRGB(78, 60, 30)

local screen = nil

local function buildScreen()
	local sg = Instance.new("ScreenGui")
	sg.Name = "AbyssGenderSelect"; sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true; sg.DisplayOrder = 2000
	sg.Parent = pgui

	local overlay = Instance.new("Frame")
	overlay.Size = UDim2.new(1,0,1,0)
	overlay.BackgroundColor3 = BG; overlay.BackgroundTransparency = 0
	overlay.BorderSizePixel = 0; overlay.Active = true
	overlay.Parent = sg

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(0, 500, 0, 40)
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.Position = UDim2.new(0.5, 0, 0.4, 0)
	title.BackgroundTransparency = 1
	title.Text = "Choose your form"
	title.Font = Enum.Font.Garamond; title.TextSize = 32
	title.TextColor3 = PARCHM
	title.Parent = overlay

	local row = Instance.new("Frame")
	row.Size = UDim2.new(0, 340, 0, 60)
	row.AnchorPoint = Vector2.new(0.5, 0.5)
	row.Position = UDim2.new(0.5, 0, 0.52, 0)
	row.BackgroundTransparency = 1
	row.Parent = overlay

	local function makeButton(label, xPos)
		local btn = Instance.new("TextButton")
		btn.Size = UDim2.new(0, 160, 0, 56)
		btn.Position = UDim2.new(0, xPos, 0, 0)
		btn.BackgroundColor3 = Color3.fromRGB(20,15,8)
		btn.BackgroundTransparency = 0.1
		btn.BorderSizePixel = 0
		btn.Text = label
		btn.TextColor3 = GOLD
		btn.Font = Enum.Font.GothamMedium; btn.TextSize = 18
		btn.AutoButtonColor = false
		btn.Parent = row
		local corner = Instance.new("UICorner", btn); corner.CornerRadius = UDim.new(0,4)
		local stroke = Instance.new("UIStroke", btn); stroke.Thickness = 1; stroke.Color = BORDER
		return btn
	end

	local maleBtn   = makeButton("MALE", 0)
	local femaleBtn = makeButton("FEMALE", 180)

	local function submit(gender)
		Remotes.SubmitGenderSelect:FireServer(gender)
		sg:Destroy()
		screen = nil
	end

	maleBtn.MouseButton1Click:Connect(function() submit("Male") end)
	femaleBtn.MouseButton1Click:Connect(function() submit("Female") end)

	screen = sg
end

Remotes.ShowGenderSelect.OnClientEvent:Connect(function()
	if screen then return end
	buildScreen()
end)

print("[GenderSelectClient] ready")
