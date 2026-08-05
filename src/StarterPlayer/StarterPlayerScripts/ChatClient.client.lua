-- ChatClient
-- Receives formatted chat events from ChatManager and displays them.
-- Handles: chat display, shout overlay, thought panels (mods), [LORE TEAM] broadcast.

local Players      = game:GetService("Players")
local StarterGui   = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local RepStorage   = game:GetService("ReplicatedStorage")

local Remotes = require(RepStorage.Shared.RemoteEvents)
local player  = Players.LocalPlayer
local pgui    = player.PlayerGui

-- ChatEvent display handled by StarterPlayerScripts.ChatUI (custom chat window)
-- ChatClient only manages overlays: shout, thought panels, [LORE TEAM] broadcast

-- ── 2. Shout broadcast — bare red text that fades in/out, no box (matches the
-- lore-team Broadcast style further down: just a stroked TextLabel, no Frame at all).
-- PLACEHOLDER_SOUND: shout_alert — replace rbxassetid://0 with actual sound

local shoutLabel  = nil
local shoutStroke = nil
local shoutSound  = nil
local shoutTween  = nil
local SHOUT_COLOR = Color3.fromRGB(200, 40, 40)

local function buildShoutGui()
	if pgui:FindFirstChild("AbyssShoutGui") then
		local sg = pgui.AbyssShoutGui
		shoutLabel = sg:FindFirstChild("ShoutText")
		shoutStroke = shoutLabel and shoutLabel:FindFirstChildOfClass("UIStroke")
		shoutSound = sg:FindFirstChild("ShoutSound")
		return
	end
	local sg = Instance.new("ScreenGui")
	sg.Name="AbyssShoutGui"; sg.ResetOnSpawn=false
	sg.IgnoreGuiInset=true; sg.Parent=pgui

	local lbl=Instance.new("TextLabel")
	lbl.Name="ShoutText"
	lbl.AnchorPoint=Vector2.new(0.5,0); lbl.Size=UDim2.new(0,600,0,40)
	lbl.Position=UDim2.new(0.5,0,0,64)
	lbl.BackgroundTransparency=1
	lbl.TextColor3=SHOUT_COLOR
	lbl.Font=Enum.Font.GothamBold; lbl.TextSize=22
	lbl.TextXAlignment=Enum.TextXAlignment.Center; lbl.TextWrapped=true
	lbl.Visible=false; lbl.Text=""; lbl.Parent=sg

	local stroke=Instance.new("UIStroke",lbl)
	stroke.Thickness=1.5; stroke.Color=Color3.fromRGB(0,0,0); stroke.Transparency=0

	local shoutSoundInst = RepStorage:WaitForChild("_Sounds", 5):WaitForChild("UI", 5):FindFirstChild("Shout_Alert")
	local snd=Instance.new("Sound")
	snd.Name="ShoutSound"; snd.SoundId=(shoutSoundInst and shoutSoundInst.SoundId) or ""
	snd.Volume=0.6; snd.RollOffMaxDistance=0; snd.Parent=sg

	shoutLabel=lbl; shoutStroke=stroke; shoutSound=snd
end

task.spawn(buildShoutGui)

local shoutToken = 0
Remotes.ShoutBroadcast.OnClientEvent:Connect(function(message)
	if not shoutLabel then buildShoutGui() end
	if not shoutLabel then return end
	shoutLabel.Text = message
	shoutLabel.TextTransparency = 0
	if shoutStroke then shoutStroke.Transparency = 0 end
	shoutLabel.Visible = true
	if shoutSound and shoutSound.SoundId~="" and shoutSound.SoundId~="rbxassetid://0" then shoutSound:Play() end
	if shoutTween then shoutTween:Cancel() end
	-- Token guards against overlapping shouts the same way Broadcast does below.
	shoutToken += 1
	local myToken = shoutToken
	task.delay(4, function()
		if myToken ~= shoutToken then return end
		if not shoutLabel or not shoutLabel.Visible then return end
		shoutTween=TweenService:Create(shoutLabel,TweenInfo.new(0.5),{TextTransparency=1})
		if shoutStroke then TweenService:Create(shoutStroke,TweenInfo.new(0.5),{Transparency=1}):Play() end
		shoutTween:Play()
		shoutTween.Completed:Once(function()
			shoutLabel.Visible=false; shoutLabel.TextTransparency=0
			if shoutStroke then shoutStroke.Transparency=0 end
		end)
	end)
end)

-- ── 3. Thought notification — persistent dismissable panels (mods only) ────────
-- PLACEHOLDER_GUI: ThoughtNotification — restyle cards below in Studio

local thoughtStack = nil
local thoughtCount = 0

local THOUGHT_BORDER = Color3.fromRGB(106, 13,173)
local THOUGHT_BG     = Color3.fromRGB( 12,  6, 20)
local THOUGHT_TEXT   = Color3.fromRGB(155, 89,182)
local PARCHM         = Color3.fromRGB(200,184,154)

local function getThoughtStack()
	if thoughtStack and thoughtStack.Parent then return thoughtStack end
	local existing = pgui:FindFirstChild("AbyssThoughtGui")
	if existing then
		thoughtStack = existing:FindFirstChild("Stack")
		return thoughtStack
	end
	local sg = Instance.new("ScreenGui")
	sg.Name="AbyssThoughtGui"; sg.ResetOnSpawn=false
	sg.IgnoreGuiInset=true; sg.ZIndexBehavior=Enum.ZIndexBehavior.Sibling; sg.Parent=pgui

	local stack=Instance.new("Frame")
	stack.Name="Stack"; stack.AnchorPoint=Vector2.new(1,1)
	stack.Size=UDim2.new(0,296,1,-120); stack.Position=UDim2.new(1,-8,1,-80)
	stack.BackgroundTransparency=1; stack.BorderSizePixel=0; stack.Parent=sg

	local layout=Instance.new("UIListLayout")
	layout.SortOrder=Enum.SortOrder.LayoutOrder
	layout.VerticalAlignment=Enum.VerticalAlignment.Bottom
	layout.Padding=UDim.new(0,4); layout.Parent=stack

	thoughtStack=stack; return stack
end

-- kind: nil/"THOUGHT" (default) or "ACTION" -- actions raise the same persistent panel
-- (user request: "actions still don't do notifications like thoughts"), styled gold.
local ACTION_BORDER = Color3.fromRGB(201,168, 76)
local ACTION_BG     = Color3.fromRGB( 20, 16,  6)
local ACTION_TEXT   = Color3.fromRGB(201,168, 76)
Remotes.ThoughtNotif.OnClientEvent:Connect(function(charName, zone, text, playerName, kind)
	local stack = getThoughtStack()
	if not stack then return end
	thoughtCount += 1
	local order = thoughtCount
	local isAction = kind == "ACTION"

	local card=Instance.new("Frame")
	card.Name=(isAction and "Action_" or "Thought_")..order; card.Size=UDim2.new(1,0,0,110)
	card.BackgroundColor3=isAction and ACTION_BG or THOUGHT_BG; card.BackgroundTransparency=0.08
	card.BorderSizePixel=0; card.LayoutOrder=order; card.ClipsDescendants=true

	local border=Instance.new("Frame")
	border.Size=UDim2.new(0,3,1,0); border.BackgroundColor3=isAction and ACTION_BORDER or THOUGHT_BORDER
	border.BorderSizePixel=0; border.ZIndex=2; border.Parent=card

	local function mkLabel(name, yPos, h, text, color, size)
		local l=Instance.new("TextLabel"); l.Name=name
		l.Size=UDim2.new(1,-56,0,h); l.Position=UDim2.new(0,10,0,yPos)
		l.BackgroundTransparency=1; l.TextColor3=color; l.Font=Enum.Font.Code
		l.TextSize=size; l.TextXAlignment=Enum.TextXAlignment.Left
		l.TextWrapped=true; l.Text=text; l.ZIndex=3; l.Parent=card
	end
	mkLabel("Title", 6,  16, (isAction and "[ACTION] " or "[THOUGHT] ")..charName, isAction and ACTION_TEXT or THOUGHT_TEXT, 10)
	mkLabel("Zone",  22, 14, "Zone: "..zone,                 Color3.fromRGB(90,70,110), 9)
	mkLabel("Msg",   38, 36, (isAction and "* "..text.." *" or '"'..text..'"'), PARCHM, 11)

	local btn=Instance.new("TextButton")
	btn.Name="DismissBtn"; btn.AnchorPoint=Vector2.new(1,0)
	btn.Size=UDim2.new(0,60,0,18); btn.Position=UDim2.new(1,-4,0,4)
	btn.BackgroundTransparency=1; btn.BorderSizePixel=0
	btn.Text="[Dismiss]"; btn.TextColor3=Color3.fromRGB(80,50,100)
	btn.Font=Enum.Font.Code; btn.TextSize=9; btn.AutoButtonColor=false
	btn.ZIndex=4; btn.Parent=card

	btn.MouseButton1Click:Connect(function()
		TweenService:Create(card,TweenInfo.new(0.18),{BackgroundTransparency=1}):Play()
		task.delay(0.2, function() if card.Parent then card:Destroy() end end)
	end)

	local replyBox=Instance.new("TextBox")
	replyBox.Size=UDim2.new(1,-66,0,18); replyBox.Position=UDim2.new(0,10,0,84)
	replyBox.BackgroundColor3=Color3.fromRGB(15,10,22); replyBox.BackgroundTransparency=0.25
	replyBox.BorderSizePixel=0; replyBox.PlaceholderText="broadcast answer..."
	replyBox.Text=""
	replyBox.PlaceholderColor3=Color3.fromRGB(80,60,100); replyBox.TextColor3=PARCHM
	replyBox.Font=Enum.Font.Code; replyBox.TextSize=10; replyBox.ClearTextOnFocus=true
	replyBox.ZIndex=4; replyBox.Parent=card

	local answerBtn=Instance.new("TextButton")
	answerBtn.Size=UDim2.new(0,50,0,18); answerBtn.Position=UDim2.new(1,-56,0,84)
	answerBtn.BackgroundColor3=Color3.fromRGB(45,25,70); answerBtn.BackgroundTransparency=0.25
	answerBtn.BorderSizePixel=0; answerBtn.Text="answer"
	answerBtn.TextColor3=Color3.fromRGB(155,89,182); answerBtn.Font=Enum.Font.Code
	answerBtn.TextSize=10; answerBtn.AutoButtonColor=false; answerBtn.ZIndex=4; answerBtn.Parent=card

	answerBtn.MouseButton1Click:Connect(function()
		local msg=replyBox.Text:match("^%s*(.-)%s*$") or ""
		if #msg>0 and playerName then Remotes.ModBroadcast:FireServer(playerName,msg); replyBox.Text="" end
	end)

	card.Position=UDim2.new(0,40,0,0); card.Parent=stack
	TweenService:Create(card,TweenInfo.new(0.22),{Position=UDim2.new(0,0,0,0)}):Play()
end)

-- ── 4. Broadcast message — lore team announcement, no box, no label ────────────

local broadLabel  = nil
local broadStroke = nil
local broadTween  = nil

local function buildBroadcastGui()
	if pgui:FindFirstChild("AbyssBroadcastGui") then
		local sg=pgui.AbyssBroadcastGui
		broadLabel=sg:FindFirstChild("BroadcastText")
		broadStroke=broadLabel and broadLabel:FindFirstChildOfClass("UIStroke")
		return
	end
	local sg=Instance.new("ScreenGui")
	sg.Name="AbyssBroadcastGui"; sg.ResetOnSpawn=false
	sg.IgnoreGuiInset=true; sg.Parent=pgui

	local lbl=Instance.new("TextLabel"); lbl.Name="BroadcastText"
	-- Sits just above the HP/stamina bar frame (anchored at (0.5,0), Y=0.740406334 scale).
	lbl.AnchorPoint=Vector2.new(0.5,1); lbl.Size=UDim2.new(0,760,0,70)
	lbl.Position=UDim2.new(0.5,0,0.740406334,-15)
	lbl.BackgroundTransparency=1; lbl.TextColor3=Color3.fromRGB(255,255,255)
	lbl.Font=Enum.Font.GrenzeGotisch; lbl.TextSize=28
	lbl.TextXAlignment=Enum.TextXAlignment.Center; lbl.TextYAlignment=Enum.TextYAlignment.Bottom
	lbl.TextWrapped=true; lbl.Visible=false; lbl.Text=""; lbl.Parent=sg

	local stroke=Instance.new("UIStroke",lbl)
	stroke.Thickness=2; stroke.Color=Color3.fromRGB(0,0,0); stroke.Transparency=0

	broadLabel=lbl; broadStroke=stroke
end

task.spawn(buildBroadcastGui)

local broadcastToken = 0
Remotes.BroadcastMsg.OnClientEvent:Connect(function(message)
	if not broadLabel then buildBroadcastGui() end
	if not broadLabel then return end
	broadLabel.Text=tostring(message)
	broadLabel.TextTransparency=0; broadStroke.Transparency=0
	broadLabel.Visible=true
	if broadTween then broadTween:Cancel() end
	-- Token guards against overlapping broadcasts: without it, an earlier message's
	-- 8s fade-out timer could fire after a newer message replaced its text, prematurely
	-- hiding something that should still have several seconds left on screen.
	broadcastToken += 1
	local myToken = broadcastToken
	task.delay(8, function()
		if myToken ~= broadcastToken then return end
		if not broadLabel or not broadLabel.Visible then return end
		broadTween=TweenService:Create(broadLabel,TweenInfo.new(0.5),{TextTransparency=1})
		TweenService:Create(broadStroke,TweenInfo.new(0.5),{Transparency=1}):Play()
		broadTween:Play()
		broadTween.Completed:Once(function()
			broadLabel.Visible=false; broadLabel.TextTransparency=0; broadStroke.Transparency=0
		end)
	end)
end)

print("[ChatClient] ready — chat/shout/thought/broadcast handlers live")