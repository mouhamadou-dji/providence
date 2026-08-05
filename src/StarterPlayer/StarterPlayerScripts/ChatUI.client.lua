-- ChatUI — Input bar + overhead bubble display
-- Disables Roblox default chat. / or Enter to type. Messages appear overhead only.

local Players      = game:GetService("Players")
local StarterGui   = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UIS          = game:GetService("UserInputService")
local RepStorage   = game:GetService("ReplicatedStorage")
local TextService  = game:GetService("TextService")

task.defer(function()
	pcall(function() StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Chat, false) end)
end)

local Remotes = require(RepStorage:WaitForChild("Shared",10):WaitForChild("RemoteEvents",10))
local player  = Players.LocalPlayer
local pgui    = player.PlayerGui

local INPUT_BG  = Color3.fromRGB(8,   5,   2)
local BORDER    = Color3.fromRGB(58,  44,  22)
local PARCHM    = Color3.fromRGB(200, 185, 155)
local HINT_C    = Color3.fromRGB(72,  58,  36)
local GOLD      = Color3.fromRGB(201, 168, 76)
local BUBBLE_BG     = Color3.fromRGB(246, 246, 244) -- actual white
local BUBBLE_BORDER = Color3.fromRGB(165, 160, 150) -- soft neutral edge
local CHAT_C    = Color3.fromRGB(200, 185, 155)
local ACTION_C  = Color3.fromRGB(201, 168, 76)
local WHISP_C   = Color3.fromRGB(118, 118, 112)
local THOUGHT_C = Color3.fromRGB(155,  89, 182)
local SHOUT_C   = Color3.fromRGB(163,  21,  21)
local SYSTEM_C  = Color3.fromRGB(170,  55,  55)

-- ── Input bar GUI ──────────────────────────────────────────────────────────────────────────
local sg = Instance.new("ScreenGui")
sg.Name="AbyssChatGui"; sg.ResetOnSpawn=false
sg.IgnoreGuiInset=false; sg.Parent=pgui

local hintLbl = Instance.new("TextLabel")
hintLbl.Size=UDim2.new(0,390,0,13); hintLbl.Position=UDim2.new(0,6,1,-68)
hintLbl.BackgroundTransparency=1; hintLbl.TextColor3=HINT_C
hintLbl.Font=Enum.Font.Code; hintLbl.TextSize=9
hintLbl.TextXAlignment=Enum.TextXAlignment.Left
hintLbl.Text=""; hintLbl.Visible=false; hintLbl.Parent=sg

local inputRow = Instance.new("Frame")
inputRow.Name="InputRow"; inputRow.Size=UDim2.new(0,390,0,28)
inputRow.Position=UDim2.new(0,6,1,-54)
inputRow.BackgroundColor3=INPUT_BG; inputRow.BackgroundTransparency=0.15
inputRow.BorderSizePixel=0; inputRow.Visible=false; inputRow.Parent=sg
Instance.new("UICorner",inputRow).CornerRadius=UDim.new(0,4)
local ist=Instance.new("UIStroke",inputRow); ist.Thickness=1; ist.Color=BORDER

local inputBox = Instance.new("TextBox")
inputBox.Size=UDim2.new(1,-54,1,-4); inputBox.Position=UDim2.new(0,6,0,2)
inputBox.BackgroundTransparency=1; inputBox.BorderSizePixel=0
inputBox.Text=""; inputBox.PlaceholderText="speak..."
inputBox.PlaceholderColor3=HINT_C; inputBox.TextColor3=PARCHM
inputBox.Font=Enum.Font.Code; inputBox.TextSize=13
inputBox.TextXAlignment=Enum.TextXAlignment.Left
inputBox.ClearTextOnFocus=false; inputBox.MultiLine=false; inputBox.Parent=inputRow

local sendBtn = Instance.new("TextButton")
sendBtn.Size=UDim2.new(0,44,1,-6); sendBtn.Position=UDim2.new(1,-47,0,3)
sendBtn.BackgroundColor3=Color3.fromRGB(22,15,7); sendBtn.BackgroundTransparency=0.2
sendBtn.BorderSizePixel=0; sendBtn.Text="say"; sendBtn.TextColor3=GOLD
sendBtn.Font=Enum.Font.GothamMedium; sendBtn.TextSize=11
sendBtn.AutoButtonColor=false; sendBtn.Parent=inputRow
Instance.new("UICorner",sendBtn).CornerRadius=UDim.new(0,2)

-- ── Hints ────────────────────────────────────────────────────────────────────────────────
local HINTS = {
	["/a"] = "  /a text  —  action (gold, server-wide)",
	["/t"] = "  /t text  —  thought (purple, self only + mods notified)",
	["/w"] = "  /w text  —  whisper (muted, 20 stud range)",
	["/s"] = "  /s text  —  shout (red, 60 stud range + overlay)",
}

inputBox:GetPropertyChangedSignal("Text"):Connect(function()
	local t = inputBox.Text; local p2 = t:sub(1,2)
	if HINTS[p2] and (#t==2 or t:sub(3,3)==" ") then hintLbl.Text=HINTS[p2]
	elseif t:sub(1,1)=="/" and #t<3 then hintLbl.Text="  /a action   /t thought   /w whisper   /s shout"
	else hintLbl.Text="" end
end)

-- ── Open / close ──────────────────────────────────────────────────────────────────────────
local isFocused = false

local function openInput(prefill)
	if isFocused then return end
	isFocused = true; inputRow.Visible=true; hintLbl.Visible=true
	task.defer(function()
		if prefill and #prefill>0 then inputBox.Text=prefill; inputBox.CursorPosition=#prefill+1 end
		inputBox:CaptureFocus()
	end)
end

local function closeInput()
	if not isFocused then return end
	isFocused=false; inputRow.Visible=false; hintLbl.Visible=false; hintLbl.Text=""
	inputBox:ReleaseFocus()
end

local function doSend()
	local raw = inputBox.Text:match("^%s*(.-)%s*$") or ""
	inputBox.Text=""; hintLbl.Text=""; closeInput()
	if #raw==0 then return end
	Remotes.SendChatMessage:FireServer(raw)
end

sendBtn.MouseButton1Click:Connect(doSend)
inputBox.FocusLost:Connect(function(byEnter)
	if byEnter then doSend()
	else task.delay(0.05,function() if not inputBox:IsFocused() then closeInput() end end) end
end)

UIS.InputBegan:Connect(function(input, gpe)
	if gpe then return end
	if input.KeyCode==Enum.KeyCode.Slash then openInput("/")
	elseif input.KeyCode==Enum.KeyCode.Return then if not isFocused then openInput(nil) end
	elseif input.KeyCode==Enum.KeyCode.Escape then if isFocused then closeInput() end
	end
end)

-- ── Overhead bubbles ────────────────────────────────────────────────────────────────────────
local bubbleStacks = {}

local BUBBLE_MAX_WIDTH = 220 -- cap: past this, long messages wrap and grow in height instead of width
local BUBBLE_MIN_WIDTH = 40  -- floor: keeps a one-character message from collapsing to nothing
local BUBBLE_PAD_H  = 6
local BUBBLE_PAD_V  = 3
local BUBBLE_MIN_H  = 24
local BUBBLE_TEXT_SIZE = 16

-- A TextLabel's AutomaticSize/TextBounds does NOT correctly recompute for wrapped
-- multi-line text once it's parented under a BillboardGui -- confirmed live: it stayed
-- pinned to a single line's height (~32px) no matter how much longer the message got.
-- That's why bubbles past ~2 lines got clipped by the billboard's declared bounds
-- (previous fix attempt tried tracking AutomaticSize and never actually saw it grow).
-- Measuring the real text bounds with TextService up front and sizing everything
-- explicitly sidesteps the broken auto-layout entirely -- both width AND height are picked
-- to fit the actual message instead of every bubble always using one fixed width.
local function measureBubble(text, font)
	local innerMax = BUBBLE_MAX_WIDTH - BUBBLE_PAD_H*2
	local innerMin = BUBBLE_MIN_WIDTH - BUBBLE_PAD_H*2

	-- Measure unwrapped first (huge width) to get the message's natural single-line width.
	local unwrapped = Instance.new("GetTextBoundsParams")
	unwrapped.Text = text; unwrapped.Font = Font.fromEnum(font)
	unwrapped.Size = BUBBLE_TEXT_SIZE; unwrapped.Width = 10000
	local ok1, natural = pcall(function() return TextService:GetTextBoundsAsync(unwrapped) end)
	local naturalWidth  = (ok1 and natural and natural.X) or innerMax
	local naturalHeight = (ok1 and natural and natural.Y) or BUBBLE_TEXT_SIZE

	if naturalWidth <= innerMax then
		-- Short enough to fit on one line -- size the bubble tightly around it instead of
		-- always using the max width, so short messages don't get an oversized bubble.
		local innerWidth = math.clamp(naturalWidth, innerMin, innerMax)
		return innerWidth + BUBBLE_PAD_H*2, math.max(BUBBLE_MIN_H, naturalHeight + BUBBLE_PAD_V*2)
	end

	-- Too long for one line at the max width -- wrap at max width, grow height instead.
	local wrapped = Instance.new("GetTextBoundsParams")
	wrapped.Text = text; wrapped.Font = Font.fromEnum(font)
	wrapped.Size = BUBBLE_TEXT_SIZE; wrapped.Width = innerMax
	local ok2, bounds = pcall(function() return TextService:GetTextBoundsAsync(wrapped) end)
	local textHeight = (ok2 and bounds and bounds.Y) or naturalHeight
	return BUBBLE_MAX_WIDTH, math.max(BUBBLE_MIN_H, textHeight + BUBBLE_PAD_V*2)
end

local function spawnBubble(speakerName, text, color, duration, italic)
	local spk = Players:FindFirstChild(speakerName)
	if not spk then return end
	local char = spk.Character
	if not char then return end
	local head = char:FindFirstChild("Head")
	if not head then return end

	local stack = (bubbleStacks[speakerName] or 0) + 1
	bubbleStacks[speakerName] = stack

	local font = italic and Enum.Font.SourceSansItalic or Enum.Font.SourceSansBold

	local bubbleWidth, bubbleHeight = measureBubble(text, font)

	local bb = Instance.new("BillboardGui")
	bb.Name="AbyssBubble"; bb.AlwaysOnTop=false
	bb.MaxDistance=74; bb.Size=UDim2.new(0, bubbleWidth, 0, bubbleHeight)
	bb.StudsOffset=Vector3.new(0, 2.2+(stack-1)*1.6, 0)
	bb.LightInfluence=0.3; bb.Parent=head

	local bg=Instance.new("Frame")
	bg.Size=UDim2.new(1,0,1,0)
	bg.BackgroundColor3=BUBBLE_BG; bg.BackgroundTransparency=0
	bg.BorderSizePixel=0; bg.Parent=bb
	Instance.new("UICorner",bg).CornerRadius=UDim.new(0,3)
	local bgStroke=Instance.new("UIStroke",bg)
	bgStroke.Thickness=1; bgStroke.Color=BUBBLE_BORDER; bgStroke.Transparency=0.25
	local pad=Instance.new("UIPadding",bg)
	pad.PaddingLeft=UDim.new(0,BUBBLE_PAD_H); pad.PaddingRight=UDim.new(0,BUBBLE_PAD_H)
	pad.PaddingTop=UDim.new(0,BUBBLE_PAD_V); pad.PaddingBottom=UDim.new(0,BUBBLE_PAD_V)

	local lbl=Instance.new("TextLabel")
	lbl.Size=UDim2.new(1,0,1,0)
	lbl.BackgroundTransparency=1; lbl.TextColor3=color or CHAT_C
	lbl.Font=font; lbl.TextSize=BUBBLE_TEXT_SIZE
	lbl.TextWrapped=true; lbl.TextXAlignment=Enum.TextXAlignment.Center
	lbl.Text=text; lbl.Parent=bg

	task.delay(duration or 5, function()
		if not bb.Parent then return end
		bubbleStacks[speakerName] = math.max(0,(bubbleStacks[speakerName] or 1)-1)
		TweenService:Create(bg,  TweenInfo.new(0.4),{BackgroundTransparency=1}):Play()
		TweenService:Create(lbl, TweenInfo.new(0.4),{TextTransparency=1}):Play()
		TweenService:Create(bgStroke,  TweenInfo.new(0.4),{Transparency=1}):Play()
		task.delay(0.45, function() if bb.Parent then bb:Destroy() end end)
	end)
end

Remotes.ChatBubble.OnClientEvent:Connect(function(speakerName, text, color, dur, italic)
	spawnBubble(speakerName, text, color, dur, italic)
end)

-- ── Thought / system screen notifications ────────────────────────────────────────
Remotes.ChatEvent.OnClientEvent:Connect(function(msgType, charName, zone, text, color)
	if msgType ~= "SYSTEM" then return end
	local c = color or SYSTEM_C
	local notif = Instance.new("TextLabel")
	notif.Size=UDim2.new(0,390,0,16); notif.Position=UDim2.new(0,6,1,-90)
	notif.BackgroundTransparency=1; notif.TextColor3=c
	notif.Font=Enum.Font.Code; notif.TextSize=12
	notif.TextXAlignment=Enum.TextXAlignment.Left
	notif.Text=text; notif.Parent=sg
	task.delay(5, function()
		TweenService:Create(notif,TweenInfo.new(0.5),{TextTransparency=1}):Play()
		task.delay(0.55, function() if notif.Parent then notif:Destroy() end end)
	end)
end)

print("[ChatUI] Overhead bubble chat live")