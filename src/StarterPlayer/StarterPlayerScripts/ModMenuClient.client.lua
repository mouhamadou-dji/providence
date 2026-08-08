-- ModMenuClient — full command suite with self-effects and view overlay
local Players          = game:GetService("Players")
local RepStorage       = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService     = game:GetService("TweenService")
local RunService       = game:GetService("RunService")

local Remotes = require(RepStorage.Shared.RemoteEvents)
local Config  = require(RepStorage.Shared.Config) -- Config.Mobs backs the Spawn Mob dropdown
local player  = Players.LocalPlayer
local pgui    = player.PlayerGui
local UIS     = UserInputService
local mouse   = player:GetMouse() 

local IMG_BG    = "rbxassetid://106844519299601"
local IMG_HDR   = "rbxassetid://94319779202764"
local IMG_LEFT  = "rbxassetid://137792783944875"
local IMG_RIGHT = "rbxassetid://135544317854707"

local BG       = Color3.fromRGB(8,   6,   4)
local PANEL    = Color3.fromRGB(13,  10,  7)
local HDR_BG   = Color3.fromRGB(17,  13,  8)
local BORDER   = Color3.fromRGB(78,  60,  30)
local PARCHM   = Color3.fromRGB(208, 194, 165)
local MUTED    = Color3.fromRGB(118, 102, 72)
local FAINT    = Color3.fromRGB(70,  58,  38)
local GOLD     = Color3.fromRGB(198, 156, 55)
local INPUT_BG = Color3.fromRGB(10,   8,   5)
local BTN_BASE = Color3.fromRGB(22,  17,  11)
local BTN_KILL = Color3.fromRGB(80,  20,  14)
local BTN_FLY  = Color3.fromRGB(14,  42,  70)
local BTN_ON   = Color3.fromRGB(14,  60,  30)

local menuOpen     = false
local selectedName = nil
local allSelected  = false
local playerBtns   = {}
local logEntries   = {}
local screenGui, mainFrame, rosterFrame, cmdFrame, logFrame, infoLbl

-- self-effect state
local flying       = false
local flyBody      = nil
local flyConn      = nil
local flyBtn       = nil
local noclipActive = false
local noclipConn   = nil
local godmodeActive= false
local godmodeConn  = nil
local espActive    = false
local espBillboards= {}
local spectating   = false
local viewOverlay, viewTitle, viewContent

local liveFeedOverlay, liveFeedContent
local liveFeedEntries = {}
local liveFeedOpen    = false
local feedBtn         = nil
local FEED_COLORS = {
	CHAT      = Color3.fromRGB(140,140,140),
	ACTION    = Color3.fromRGB(201,168, 76),
	WHISPER   = Color3.fromRGB(100,100, 95),
	THOUGHT   = Color3.fromRGB(155, 89,182),
	SHOUT     = Color3.fromRGB(163, 21, 21),
	BROADCAST = Color3.fromRGB(201,168, 76),
	INTRODUCE = Color3.fromRGB(200,184,154),
	SANITY    = Color3.fromRGB(150,150,150),
	RAGE      = Color3.fromRGB(200, 60, 60),
	ALLY      = Color3.fromRGB(230,220,190),
}
-- Real type= values a server manager can actually fire (verified against every
-- LiveFeedUpdate:FireClient call site, not assumed) -- Meditation/Pushups/Spirit/
-- Interactable/NPC/BTools/Injury/DNA/Potion all lump under the generic "ACTION" type,
-- they don't get their own filter category.
local FEED_FILTERS = {"All","CHAT","ACTION","WHISPER","THOUGHT","SHOUT","INTRODUCE","SANITY","RAGE","ALLY"}
local feedFilterIdx = 1
local feedScrolledToBottom = true
local function applyFeedFilter()
	local want = FEED_FILTERS[feedFilterIdx]
	for _, lbl in ipairs(liveFeedEntries) do
		if lbl.Parent then
			lbl.Visible = (want=="All") or (lbl:GetAttribute("FeedType")==want)
		end
	end
end

-- UI helpers
local function mk(class,props)
	local i=Instance.new(class); for k,v in pairs(props) do i[k]=v end; return i
end
local function addCorner(p,r) mk("UICorner",{CornerRadius=UDim.new(0,r or 2),Parent=p}) end
local function addStroke(p,t,c) mk("UIStroke",{Thickness=t or 1,Color=c or BORDER,Parent=p}) end
local function addPad(p,l,t,r,b) mk("UIPadding",{PaddingLeft=UDim.new(0,l or 0),PaddingTop=UDim.new(0,t or 0),PaddingRight=UDim.new(0,r or 0),PaddingBottom=UDim.new(0,b or 0),Parent=p}) end
local function txt(parent,props)
	local l=mk("TextLabel",{BackgroundTransparency=1,TextXAlignment=Enum.TextXAlignment.Left,Font=Enum.Font.Gotham,TextSize=12,TextColor3=PARCHM,TextTruncate=Enum.TextTruncate.AtEnd,ClipsDescendants=true,Parent=parent})
	for k,v in pairs(props) do l[k]=v end; return l
end
local function bgImg(parent,img)
	mk("ImageLabel",{Size=UDim2.new(1,0,1,0),BackgroundTransparency=1,Image=img,ScaleType=Enum.ScaleType.Stretch,Active=false,Selectable=false,BorderSizePixel=0,Parent=parent})
end
local function field(parent,placeholder,sz,pos)
	local b=mk("TextBox",{Size=sz,Position=pos,BackgroundColor3=INPUT_BG,BorderSizePixel=0,Text="",PlaceholderText=placeholder,PlaceholderColor3=FAINT,TextColor3=PARCHM,Font=Enum.Font.Gotham,TextSize=12,ClearTextOnFocus=false,TextXAlignment=Enum.TextXAlignment.Left,TextTruncate=Enum.TextTruncate.AtEnd,ClipsDescendants=true,Parent=parent})
	addCorner(b,2); addStroke(b,1,BORDER); addPad(b,5); return b
end
local function action(parent,label,sz,pos,danger)
	local bg=danger and BTN_KILL or BTN_BASE
	local b=mk("TextButton",{Size=sz,Position=pos,BackgroundColor3=bg,BorderSizePixel=0,Text=label,TextColor3=PARCHM,Font=Enum.Font.GothamMedium,TextSize=12,AutoButtonColor=false,Parent=parent})
	addCorner(b,2); addStroke(b,1,BORDER)
	b.MouseEnter:Connect(function() TweenService:Create(b,TweenInfo.new(0.08),{BackgroundColor3=bg:Lerp(Color3.new(1,1,1),0.1)}):Play() end)
	b.MouseLeave:Connect(function() TweenService:Create(b,TweenInfo.new(0.08),{BackgroundColor3=bg}):Play() end)
	return b
end
local function toggle(parent,label,sz,pos,onColor)
	local col=onColor or BTN_ON; local active=false
	local b=mk("TextButton",{Size=sz,Position=pos,BackgroundColor3=BTN_BASE,BorderSizePixel=0,Text=label,TextColor3=PARCHM,Font=Enum.Font.GothamMedium,TextSize=12,AutoButtonColor=false,Parent=parent})
	addCorner(b,2); addStroke(b,1,BORDER)
	local function refresh() b.BackgroundColor3=active and col or BTN_BASE; b.Text=active and (label.." ON") or label end
	return b, function(state) active=state; refresh() end
end
-- Sections collapse by hiding every sibling between this header and the next one in
-- cmdFrame's child order (matches the visual order UIListLayout already renders them in,
-- since none of the ~16 call sites set an explicit LayoutOrder) -- this lets every existing
-- sectionHdr(cmdFrame,...) call site gain collapse behavior for free, no other edits needed.
local SECTION_MARKER = "ModMenuSection"
local COLLAPSE_MARKER = "ModMenuCollapsed"
local SEARCHTEXT_MARKER = "ModMenuSearchText"
local function sectionHdr(parent,label)
	local f=mk("Frame",{Size=UDim2.new(1,0,0,22),BackgroundTransparency=1,Parent=parent})
	f:SetAttribute(SECTION_MARKER,true)
	mk("Frame",{Size=UDim2.new(1,-8,0,1),Position=UDim2.new(0,4,0.5,0),BackgroundColor3=BORDER,BorderSizePixel=0,Parent=f})
	local bg=mk("Frame",{Size=UDim2.new(0,0,0,18),Position=UDim2.new(0,10,0.5,-9),BackgroundColor3=PANEL,BorderSizePixel=0,AutomaticSize=Enum.AutomaticSize.X,Parent=f})
	addPad(bg,5,0,5)
	mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,VerticalAlignment=Enum.VerticalAlignment.Center,Padding=UDim.new(0,4),SortOrder=Enum.SortOrder.LayoutOrder,Parent=bg})
	local arrow=txt(bg,{Size=UDim2.new(0,10,1,0),Text="v",TextColor3=MUTED,Font=Enum.Font.GothamBold,TextSize=10,TextXAlignment=Enum.TextXAlignment.Center,LayoutOrder=1})
	txt(bg,{Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,Text=label,TextColor3=MUTED,Font=Enum.Font.GothamBold,TextSize=10,TextXAlignment=Enum.TextXAlignment.Center,LayoutOrder=2})
	local hitArea=mk("TextButton",{Size=UDim2.new(1,0,1,0),BackgroundTransparency=1,Text="",AutoButtonColor=false,Parent=f})
	local collapsed=false
	-- Mirrored onto an attribute so the command search below can restore each section to its
	-- real collapsed/expanded state when the query is cleared, instead of blanket-showing
	-- everything and leaving collapsed sections with a ">" arrow but visible rows.
	f:SetAttribute(COLLAPSE_MARKER,false)
	hitArea.MouseButton1Click:Connect(function()
		collapsed=not collapsed
		f:SetAttribute(COLLAPSE_MARKER,collapsed)
		arrow.Text=collapsed and ">" or "v"
		local siblings=parent:GetChildren()
		local idx=table.find(siblings,f)
		if not idx then return end
		for i=idx+1,#siblings do
			local child=siblings[i]
			if child:GetAttribute(SECTION_MARKER) then break end
			if child:IsA("GuiObject") then child.Visible=not collapsed end
		end
	end)
	return f
end
local function cmdRow(parent,labelTxt,h)
	local r=mk("Frame",{Size=UDim2.new(1,0,0,h or 26),BackgroundTransparency=1,ClipsDescendants=true,Parent=parent})
	txt(r,{Text=labelTxt,Size=UDim2.new(0,108,1,0),Position=UDim2.new(0,4,0,0),TextColor3=MUTED,TextSize=11})
	return r
end

-- ── Command search ───────────────────────────────────────────────────────────
-- ~130 rows across ~40 sections meant finding a command was pure scrolling. This filters
-- rows live against their own label plus every button caption inside them (so "spectate"
-- finds "Force Spectate", and "ban" finds the Ban/Unban rows), and hides any section header
-- left with nothing under it.
local searchQuery = ""

-- A row's searchable text never changes after build, so it's computed once and cached on the
-- row. Deliberately reads TextLabel/TextButton only -- TextBox contents are user-entered
-- values, not command names, and would make rows match on whatever was last typed into them.
local function rowSearchText(row)
	local cached = row:GetAttribute(SEARCHTEXT_MARKER)
	if cached then return cached end
	local parts = {}
	for _, d in ipairs(row:GetDescendants()) do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			if d.Text and d.Text ~= "" then parts[#parts+1] = d.Text end
		end
	end
	local s = string.lower(table.concat(parts, " "))
	row:SetAttribute(SEARCHTEXT_MARKER, s)
	return s
end

local function applyCmdFilter(q)
	if not cmdFrame then return end
	searchQuery = string.lower(tostring(q or "")):match("^%s*(.-)%s*$")
	-- GetChildren() order is the visual order here -- the same assumption the section-collapse
	-- handler above already relies on to walk rows following a header.
	local kids = cmdFrame:GetChildren()

	if searchQuery == "" then
		local collapsed = false
		for _, child in ipairs(kids) do
			if child:GetAttribute(SECTION_MARKER) then
				collapsed = child:GetAttribute(COLLAPSE_MARKER) == true
				if child:IsA("GuiObject") then child.Visible = true end
			elseif child:IsA("GuiObject") then
				child.Visible = not collapsed
			end
		end
		return
	end

	local header, headerHasMatch = nil, false
	for _, child in ipairs(kids) do
		if child:GetAttribute(SECTION_MARKER) then
			if header then header.Visible = headerHasMatch end
			header, headerHasMatch = child, false
			child.Visible = false
		elseif child:IsA("GuiObject") then
			-- Plain substring, not a Lua pattern: mods type things like "npc (" or "+/-" and
			-- pattern magic chars in a raw query would either error or silently mis-match.
			local hit = string.find(rowSearchText(child), searchQuery, 1, true) ~= nil
			child.Visible = hit
			if hit then headerHasMatch = true end
		end
	end
	if header then header.Visible = headerHasMatch end
end
local function log(text,col)
	if not logFrame then return end
	local e=mk("TextLabel",{Size=UDim2.new(1,-6,0,14),BackgroundTransparency=1,Text="  "..tostring(text),TextColor3=col or Color3.fromRGB(138,182,130),Font=Enum.Font.Code,TextSize=11,TextXAlignment=Enum.TextXAlignment.Left,TextTruncate=Enum.TextTruncate.AtEnd,ClipsDescendants=true,LayoutOrder=#logEntries+1,Parent=logFrame})
	table.insert(logEntries,e)
	if #logEntries>60 then logEntries[1]:Destroy(); table.remove(logEntries,1); for i,v in ipairs(logEntries) do v.LayoutOrder=i end end
	task.defer(function() logFrame.CanvasPosition=Vector2.new(0,math.huge) end)
end

local function getTarget() return allSelected and "ALL" or selectedName end
local function fire(cmd,target,...) Remotes.ModCommand:FireServer(cmd,target,...); local a={...}; log("> "..cmd.." "..(target or "=")..(#a>0 and "  "..table.concat(a," ") or ""),Color3.fromRGB(165,148,82)) end
local function need() if allSelected or selectedName then return true end; log("no player selected",Color3.fromRGB(195,72,62)); return false end

-- ── Mod Action Cards ─────────────────────────────────────────────────────────
-- Generic persistent mod-facing prompt (meditation/pushups milestones, spirit
-- interactions) with buttons that just call the existing fire()/ModCommand pipeline --
-- one shared system instead of three bespoke notification UIs for the same shape of thing.
-- Always-visible (own ScreenGui, independent of the collapsible menu's screenGui.Enabled),
-- same convention as the player-facing AbyssNotifications overlay built by buildNotifGui.
local modCardGui = Instance.new("ScreenGui")
modCardGui.Name = "AbyssModActionCards"; modCardGui.ResetOnSpawn = false
modCardGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
modCardGui.IgnoreGuiInset = true; modCardGui.DisplayOrder = 25
modCardGui.Parent = pgui

local modCardStack = mk("Frame", {
	AnchorPoint = Vector2.new(1,0), Position = UDim2.new(1,-12,0,60),
	Size = UDim2.new(0,300,1,-80), BackgroundTransparency = 1, Parent = modCardGui,
})
mk("UIListLayout", { HorizontalAlignment=Enum.HorizontalAlignment.Right, Padding=UDim.new(0,6), SortOrder=Enum.SortOrder.LayoutOrder, Parent = modCardStack })

local function buildModActionCard(data)
	local card = mk("Frame", {
		Size = UDim2.new(1,0,0,0), AutomaticSize=Enum.AutomaticSize.Y,
		BackgroundColor3 = PANEL, BorderSizePixel = 0, Parent = modCardStack,
	})
	addCorner(card,4); addStroke(card,1,BORDER); addPad(card,8,8,8,8)
	mk("UIListLayout",{Padding=UDim.new(0,4),SortOrder=Enum.SortOrder.LayoutOrder,Parent=card})
	txt(card,{Text=tostring(data.title or "MOD ACTION"),Size=UDim2.new(1,0,0,16),Font=Enum.Font.GothamBold,TextSize=12,TextColor3=GOLD,LayoutOrder=1})
	txt(card,{Text=tostring(data.body or ""),Size=UDim2.new(1,0,0,0),AutomaticSize=Enum.AutomaticSize.Y,TextWrapped=true,TextTruncate=Enum.TextTruncate.None,Font=Enum.Font.Gotham,TextSize=12,TextColor3=PARCHM,LayoutOrder=2})
	local btnRow = mk("Frame",{Size=UDim2.new(1,0,0,22),BackgroundTransparency=1,LayoutOrder=3,Parent=card})
	mk("UIListLayout",{FillDirection=Enum.FillDirection.Horizontal,Padding=UDim.new(0,4),SortOrder=Enum.SortOrder.LayoutOrder,Parent=btnRow})
	for _, b in ipairs(data.buttons or {}) do
		local btn = mk("TextButton",{Size=UDim2.new(0,0,1,0),AutomaticSize=Enum.AutomaticSize.X,BackgroundColor3=BTN_BASE,BorderSizePixel=0,Text="  "..b.label.."  ",TextColor3=PARCHM,Font=Enum.Font.GothamMedium,TextSize=11,AutoButtonColor=false,Parent=btnRow})
		addCorner(btn,2); addStroke(btn,1,BORDER)
		btn.MouseButton1Click:Connect(function()
			if b.cmd then fire(b.cmd, data.target, b.arg) end
			card:Destroy()
		end)
	end
	-- Safety net so an ignored card doesn't sit there forever
	task.delay(90, function() if card.Parent then card:Destroy() end end)
end

if Remotes.ModActionCard then
	Remotes.ModActionCard.OnClientEvent:Connect(function(data)
		if data then buildModActionCard(data) end
	end)
end

-- Window dragging.
--
-- Tracks movement on UserInputService, NOT on the drag handle's own InputChanged. The handle
-- is only a 26px-tall strip: listening on it means the moment the cursor outruns the window
-- (a fast flick, or dragging toward a screen edge) the events stop arriving and the window
-- is dropped mid-drag. That made it feel like windows were fenced into the middle of the
-- screen -- you simply could not throw one into a corner. Global tracking follows the cursor
-- anywhere, so a window goes exactly where it's dragged.
--
-- `target` is the frame that moves; `handle` is what you grab (usually its header).
-- Clamping keeps a grabbable sliver of the handle on screen so a window can be parked hard
-- against any edge but never flung somewhere it can't be retrieved from.
local DRAG_KEEP_X = 90 -- px of the handle that must stay horizontally on screen
local function dragWindow(target, handle)
	local dragging, startPos, startWin, moveConn, endConn = false, nil, nil, nil, nil

	local function stop()
		dragging = false
		if moveConn then moveConn:Disconnect(); moveConn = nil end
		if endConn then endConn:Disconnect(); endConn = nil end
	end

	handle.InputBegan:Connect(function(i)
		if i.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		dragging, startPos, startWin = true, i.Position, target.Position
		if moveConn then moveConn:Disconnect() end
		if endConn then endConn:Disconnect() end
		moveConn = UIS.InputChanged:Connect(function(m)
			if not dragging or m.UserInputType ~= Enum.UserInputType.MouseMovement then return end
			local d = m.Position - startPos
			local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920,1080)
			local w  = target.AbsoluteSize.X
			local hH = handle.AbsoluteSize.Y
			-- Resolve the drag start into pure pixels so the clamp math is in real screen units
			-- regardless of whatever Scale the window happened to be created with, then write back
			-- as a pure-offset position.
			local x = startWin.X.Scale*vp.X + startWin.X.Offset + d.X
			local y = startWin.Y.Scale*vp.Y + startWin.Y.Offset + d.Y
			x = math.clamp(x, -(w - DRAG_KEEP_X), vp.X - DRAG_KEEP_X)
			y = math.clamp(y, 0, math.max(0, vp.Y - hH))
			target.Position = UDim2.fromOffset(math.floor(x), math.floor(y))
		end)
		endConn = UIS.InputEnded:Connect(function(m)
			if m.UserInputType == Enum.UserInputType.MouseButton1 then stop() end
		end)
	end)
end

local function draggable(bar) dragWindow(mainFrame, bar) end

-- The panel's authored size is bigger than a windowed client's viewport, which used to push
-- its bottom edge (and the resize grip with it) clean off the screen with no way to get it
-- back. This clamps the panel to whatever actually fits.
--
-- It canNOT run at build time: the script builds during startup, when CurrentCamera.ViewportSize
-- is still (1,1), which would collapse the panel straight to its minimum. It runs on first
-- open and on any viewport change instead, when the real size is known.
local PANEL_W, PANEL_H = 740, 540      -- authored/preferred size
-- Height floor is derived, not guessed: the header (40) + search strip (18) + the fixed
-- Chronicle block (208 measured from rp's bottom) leaves the command list with
-- MIN_H - 46 - 208 px. At 300 that was 46px -- under two rows, effectively unusable. 360
-- keeps ~106px (3-4 command rows) while still fitting a short windowed client.
local PANEL_MIN_W, PANEL_MIN_H = 520, 360
local panelPlaced = false
function fitPanelToViewport(recentre)
	if not mainFrame then return end
	local cam = workspace.CurrentCamera
	local vp = cam and cam.ViewportSize
	if not vp or vp.X < 100 or vp.Y < 100 then return end -- viewport not real yet

	local w = math.clamp(mainFrame.AbsoluteSize.X, PANEL_MIN_W, math.max(PANEL_MIN_W, vp.X - 20))
	local h = math.clamp(mainFrame.AbsoluteSize.Y, PANEL_MIN_H, math.max(PANEL_MIN_H, vp.Y - 20))
	if not panelPlaced then
		-- First real placement: prefer the authored size, shrunk only as far as the screen forces.
		w = math.clamp(PANEL_W, PANEL_MIN_W, math.max(PANEL_MIN_W, vp.X - 20))
		h = math.clamp(PANEL_H, PANEL_MIN_H, math.max(PANEL_MIN_H, vp.Y - 20))
		panelPlaced = true
		recentre = true
	end
	mainFrame.Size = UDim2.fromOffset(math.floor(w), math.floor(h))

	if recentre then
		mainFrame.Position = UDim2.fromOffset(math.floor(math.max(0,(vp.X-w)/2)), math.floor(math.max(0,(vp.Y-h)/2)))
	else
		-- Keep it reachable without teleporting it away from where the mod parked it.
		local x = math.clamp(mainFrame.Position.X.Offset, -(w - DRAG_KEEP_X), math.max(0, vp.X - DRAG_KEEP_X))
		local y = math.clamp(mainFrame.Position.Y.Offset, 0, math.max(0, vp.Y - 38))
		mainFrame.Position = UDim2.fromOffset(math.floor(x), math.floor(y))
	end
end

-- Resize grip (bottom-right corner). Same global-tracking rule as dragWindow: the grip is a
-- 16px square, so listening on the grip's own InputChanged would drop the resize the instant
-- the cursor moved faster than the frame could follow.
--
-- Only Size is written -- Position is the frame's top-left with the default AnchorPoint, so
-- growing the window extends it right/down and leaves the corner the mod grabbed it by alone.
local function resizeWindow(target, minW, minH)
	local grip = mk("TextButton",{Name="ResizeGrip",Size=UDim2.new(0,16,0,16),Position=UDim2.new(1,-18,1,-18),
		BackgroundColor3=HDR_BG,BackgroundTransparency=0.2,BorderSizePixel=0,Text="",AutoButtonColor=false,ZIndex=50,Parent=target})
	addCorner(grip,3); addStroke(grip,1,BORDER)
	-- Two diagonal ticks so the corner reads as a grip rather than a stray button.
	for _, inset in ipairs({3,7}) do
		mk("Frame",{Size=UDim2.new(0,9,0,1),Position=UDim2.new(1,-12,1,-inset),BackgroundColor3=BORDER,
			BorderSizePixel=0,Rotation=-45,ZIndex=51,Parent=grip})
	end
	grip.MouseEnter:Connect(function() grip.BackgroundTransparency=0 end)
	grip.MouseLeave:Connect(function() grip.BackgroundTransparency=0.2 end)

	local sizing, startPos, startSize, moveConn, endConn = false, nil, nil, nil, nil
	local function stop()
		sizing = false
		if moveConn then moveConn:Disconnect(); moveConn = nil end
		if endConn then endConn:Disconnect(); endConn = nil end
	end

	grip.InputBegan:Connect(function(i)
		if i.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
		sizing, startPos, startSize = true, i.Position, target.AbsoluteSize
		if moveConn then moveConn:Disconnect() end
		if endConn then endConn:Disconnect() end
		moveConn = UIS.InputChanged:Connect(function(m)
			if not sizing or m.UserInputType ~= Enum.UserInputType.MouseMovement then return end
			local d = m.Position - startPos
			local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920,1080)
			target.Size = UDim2.fromOffset(
				math.floor(math.clamp(startSize.X + d.X, minW, vp.X)),
				math.floor(math.clamp(startSize.Y + d.Y, minH, vp.Y)))
		end)
		endConn = UIS.InputEnded:Connect(function(m)
			if m.UserInputType == Enum.UserInputType.MouseButton1 then stop() end
		end)
	end)
	return grip
end

-- Notifications -- Ghost of Tsushima style: a centered diamond icon flanked by chevron/
-- line flourishes, an all-caps tracked-out title, and a muted subtitle body. One at a
-- time (queued), not stacked -- unlike the old corner-toast style, several of these
-- overlapping dead-center would be unreadable.
local notifGui = nil
local notifDarken = nil
local notifQueue = {}
local notifPlaying = false
local NOTIF_CARD_W = 560
local NOTIF_DARKEN_TRANSPARENCY = 0.45 -- a frequent per-notice dim, not the big PDAnnounceClient world-event darken
local NOTIF_ACCENT = {
	info    = Color3.fromRGB(196,186,160),
	warning = Color3.fromRGB(198,156,55),
	pd      = Color3.fromRGB(176,60,48),
	lore    = Color3.fromRGB(150,120,190),
}
-- PLACEHOLDER_ICON: drop real asset ids in here. pd -> skull (perm-death notices, e.g.
-- "Reprieve" when PD deactivates), info -> book (arbitrary mod-to-player notifications).
-- warning/lore intentionally have no icon yet -- the diamond just renders empty for them.
local NOTIF_ICON = {
	pd   = "rbxassetid://0", -- skull
	info = "rbxassetid://0", -- book
}

local function buildNotifGui()
	notifGui=Instance.new("ScreenGui"); notifGui.Name="AbyssNotifications"; notifGui.ResetOnSpawn=false
	notifGui.ZIndexBehavior=Enum.ZIndexBehavior.Sibling; notifGui.IgnoreGuiInset=true; notifGui.DisplayOrder=30; notifGui.Parent=pgui
	notifDarken=Instance.new("Frame"); notifDarken.Name="Darken"; notifDarken.Size=UDim2.fromScale(1,1)
	notifDarken.BackgroundColor3=Color3.new(0,0,0); notifDarken.BackgroundTransparency=1
	notifDarken.BorderSizePixel=0; notifDarken.ZIndex=0; notifDarken.Parent=notifGui
end

-- Roblox TextLabels have no letter-spacing property -- widening the title by joining its
-- (uppercased) characters with a plain space is the standard UI-hack workaround and reads
-- close enough to the reference's tracked-out title style.
local function trackedUpper(s)
	local up = tostring(s):upper()
	local out = {}
	for i = 1, #up do out[#out+1] = up:sub(i,i) end
	return table.concat(out, " ")
end

local function notifLine(parent, xOffset, width, accent)
	local l=Instance.new("Frame"); l.AnchorPoint=Vector2.new(0,0.5); l.Position=UDim2.new(0,xOffset,0.5,0)
	l.Size=UDim2.new(0,width,0,1); l.BackgroundColor3=accent; l.BackgroundTransparency=0.25; l.BorderSizePixel=0; l.Parent=parent
	return l
end

local function notifChevron(parent, xOffset, text, accent)
	local c=Instance.new("TextLabel"); c.AnchorPoint=Vector2.new(0,0.5); c.Position=UDim2.new(0,xOffset,0.5,0)
	c.Size=UDim2.new(0,22,0,22); c.BackgroundTransparency=1; c.Text=text; c.TextColor3=accent
	c.Font=Enum.Font.GothamBold; c.TextSize=18; c.Parent=parent
	return c
end

-- Builds one notification card (diamond + flourish header, title, body) and returns it
-- plus its title/body labels so playNotification can fill in the text.
local function buildNotifCard(accent, iconId)
	local card=Instance.new("Frame"); card.Name="NotifCard"
	card.AnchorPoint=Vector2.new(0.5,0.5); card.Position=UDim2.fromScale(0.5,0.22)
	card.Size=UDim2.new(0,NOTIF_CARD_W,0,0); card.AutomaticSize=Enum.AutomaticSize.Y
	card.BackgroundTransparency=1; card.Parent=notifGui
	local layout=Instance.new("UIListLayout"); layout.SortOrder=Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment=Enum.HorizontalAlignment.Center; layout.Parent=card

	local flourish=Instance.new("Frame"); flourish.Size=UDim2.new(1,0,0,92)
	flourish.BackgroundTransparency=1; flourish.LayoutOrder=1; flourish.Parent=card
	notifLine(flourish,40,150,accent)
	notifLine(flourish,NOTIF_CARD_W-190,150,accent)
	notifChevron(flourish,196,"\u{00AB}",accent)
	notifChevron(flourish,NOTIF_CARD_W-218,"\u{00BB}",accent)

	local diamond=Instance.new("Frame"); diamond.Name="Diamond"
	diamond.AnchorPoint=Vector2.new(0.5,0.5); diamond.Position=UDim2.new(0.5,0,0.5,0)
	diamond.Size=UDim2.new(0,72,0,72); diamond.Rotation=45
	diamond.BackgroundColor3=Color3.fromRGB(10,9,6); diamond.BackgroundTransparency=0.1
	diamond.BorderSizePixel=0; diamond.Parent=flourish
	local dStroke=Instance.new("UIStroke"); dStroke.Thickness=1.5; dStroke.Color=accent; dStroke.Parent=diamond

	-- Icon is a sibling positioned over the diamond, not a child of it -- Rotation on a
	-- GuiObject visually rotates its whole subtree, so nesting the icon inside the
	-- (Rotation=45) diamond would tilt the icon too; keeping it unrotated and layered on
	-- top (higher ZIndex) avoids needing a counter-rotation.
	if iconId and iconId ~= "" and iconId ~= "rbxassetid://0" then
		local icon=Instance.new("ImageLabel"); icon.Name="Icon"
		icon.AnchorPoint=Vector2.new(0.5,0.5); icon.Position=UDim2.new(0.5,0,0.5,0)
		icon.Size=UDim2.new(0,38,0,38); icon.BackgroundTransparency=1
		icon.Image=iconId; icon.ImageColor3=accent; icon.ZIndex=2; icon.Parent=flourish
	end

	local divider=Instance.new("Frame"); divider.Size=UDim2.new(0,90,0,1)
	divider.BackgroundColor3=accent; divider.BackgroundTransparency=0.35; divider.BorderSizePixel=0
	divider.LayoutOrder=2; divider.Parent=card
	local dPad=Instance.new("UIPadding"); dPad.PaddingBottom=UDim.new(0,14); dPad.Parent=divider

	-- No background box behind the text (a visible rectangle read as "writing stuck in a
	-- square") -- legibility for the black text instead comes from a light TextStrokeColor3
	-- outline, same trick the reference image's own text uses.
	-- Parchment-light text with a DARK stroke: the old black-text/light-stroke combo was
	-- effectively invisible against the darkened night scene, which is why long list
	-- notifications (phrases, ships, talents) "never showed" -- they did, unreadably.
	local title=Instance.new("TextLabel"); title.Name="Title"
	title.Size=UDim2.new(1,-40,0,22); title.BackgroundTransparency=1
	title.Font=Enum.Font.Antique; title.TextColor3=Color3.fromRGB(232,224,202); title.TextSize=20
	title.TextStrokeColor3=Color3.new(0,0,0); title.TextStrokeTransparency=0.2
	title.TextWrapped=true; title.LayoutOrder=3; title.Parent=card

	-- Body is the part a mod actually writes (lore entries, custom notifications, etc.) --
	-- given its own distinct serif font and a bigger size than the system-generated title so
	-- written text reads clearly as its own thing.
	local body=Instance.new("TextLabel"); body.Name="Body"
	body.Size=UDim2.new(1,-80,0,0); body.AutomaticSize=Enum.AutomaticSize.Y
	body.BackgroundTransparency=1; body.Font=Enum.Font.Garamond; body.TextColor3=Color3.fromRGB(222,214,192); body.TextSize=18
	body.TextStrokeColor3=Color3.new(0,0,0); body.TextStrokeTransparency=0.3
	body.TextWrapped=true; body.LayoutOrder=4; body.Parent=card
	local bPad=Instance.new("UIPadding"); bPad.PaddingTop=UDim.new(0,8); bPad.Parent=body

	return card, title, body
end

-- Fades every descendant of card between invisible and its own authored transparency,
-- so this works generically no matter what's inside (Frame/TextLabel/UIStroke/ImageLabel)
-- without hand-listing each element.
local function notifCaptureBase(card)
	for _,d in ipairs(card:GetDescendants()) do
		if d:IsA("Frame") then d:SetAttribute("_baseTrans",d.BackgroundTransparency); d.BackgroundTransparency=1
		elseif d:IsA("TextLabel") then
			d:SetAttribute("_baseTrans",d.TextTransparency); d.TextTransparency=1
			d:SetAttribute("_baseStroke",d.TextStrokeTransparency); d.TextStrokeTransparency=1
		elseif d:IsA("UIStroke") then d:SetAttribute("_baseTrans",d.Transparency); d.Transparency=1
		elseif d:IsA("ImageLabel") then d:SetAttribute("_baseTrans",d.ImageTransparency); d.ImageTransparency=1
		end
	end
end

local function notifFade(card, toVisible, duration)
	for _,d in ipairs(card:GetDescendants()) do
		local base=d:GetAttribute("_baseTrans"); if base==nil then continue end
		local target=toVisible and base or 1
		local info=TweenInfo.new(duration,Enum.EasingStyle.Sine)
		if d:IsA("Frame") then TweenService:Create(d,info,{BackgroundTransparency=target}):Play()
		elseif d:IsA("TextLabel") then
			local strokeBase=d:GetAttribute("_baseStroke") or 1
			TweenService:Create(d,info,{TextTransparency=target, TextStrokeTransparency=toVisible and strokeBase or 1}):Play()
		elseif d:IsA("UIStroke") then TweenService:Create(d,info,{Transparency=target}):Play()
		elseif d:IsA("ImageLabel") then TweenService:Create(d,info,{ImageTransparency=target}):Play()
		end
	end
end

-- ── Lesser notification toasts ────────────────────────────────────────────────
-- Small stacked corner cards using the pre-built StarterGui.AbyssNotifGui shell
-- (Stack + Template + NotifSound). This is the "lesser broadcast" tier: routine
-- feedback lands here instead of taking over the whole screen with the big card.
local lesserCount = 0
local lesserToasts = {}
local function showLesserToast(data)
	local gui = pgui:FindFirstChild("AbyssNotifGui")
	local stack = gui and gui:FindFirstChild("Stack")
	local template = gui and gui:FindFirstChild("Template")
	if not (stack and template) then return false end
	template.Visible = false
	local card = template:Clone()
	card.Name = "Notif"
	lesserCount += 1
	card.LayoutOrder = lesserCount
	local titleLbl = card:FindFirstChild("TitleText")
	local msgLbl = card:FindFirstChild("MessageText")
	if titleLbl then titleLbl.Text = tostring(data.title or "Notice") end
	if msgLbl then
		msgLbl.Text = tostring(data.body or "")
		msgLbl.TextWrapped = true
	end
	-- Grow the card for multi-line bodies (phrase lists, logs) instead of clipping them.
	local _, lineCount = tostring(data.body or ""):gsub("\n", "")
	local extra = math.clamp(lineCount - 1, 0, 14) * 13
	if extra > 0 then
		card.Size = card.Size + UDim2.new(0, 0, 0, extra)
		if msgLbl then msgLbl.Size = msgLbl.Size + UDim2.new(0, 0, 0, extra) end
	end
	local accent = card:FindFirstChild("AccentLeft")
	if accent then accent.BackgroundColor3 = NOTIF_ACCENT[tostring(data.style or "info")] or NOTIF_ACCENT.info end
	local close = card:FindFirstChild("CloseBtn")
	if close and close:IsA("GuiButton") then
		close.MouseButton1Click:Connect(function() if card.Parent then card:Destroy() end end)
	end
	card.Visible = true
	card.Parent = stack
	local snd = gui:FindFirstChild("NotifSound")
	if snd and snd.SoundId ~= "" and snd.SoundId ~= "rbxassetid://0" then snd:Play() end
	table.insert(lesserToasts, card)
	if #lesserToasts > 6 then
		local old = table.remove(lesserToasts, 1)
		if old and old.Parent then old:Destroy() end
	end
	task.delay(math.max(3, tonumber(data.duration) or 5), function()
		if card.Parent then
			for _, d in ipairs(card:GetDescendants()) do
				if d:IsA("TextLabel") then TweenService:Create(d, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
				elseif d:IsA("Frame") then TweenService:Create(d, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play() end
			end
			TweenService:Create(card, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play()
			task.delay(0.45, function() if card.Parent then card:Destroy() end end)
		end
	end)
	return true
end

local function playNotification(data)
	if not notifGui then return end
	local title=tostring(data.title or "Notice"); local bodyText=tostring(data.body or "")
	local dur=tonumber(data.duration) or 5
	local style=tostring(data.style or "info")
	local accent=NOTIF_ACCENT[style] or NOTIF_ACCENT.info
	local iconId=NOTIF_ICON[style]

	local card,titleLbl,bodyLbl=buildNotifCard(accent,iconId)
	titleLbl.Text=trackedUpper(title)
	bodyLbl.Text=bodyText

	notifCaptureBase(card)
	local fadeIn=TweenInfo.new(0.5,Enum.EasingStyle.Sine)
	local fadeOut=TweenInfo.new(0.45,Enum.EasingStyle.Sine)
	TweenService:Create(notifDarken,fadeIn,{BackgroundTransparency=NOTIF_DARKEN_TRANSPARENCY}):Play()
	notifFade(card,true,0.5)
	task.wait(0.5+dur)
	TweenService:Create(notifDarken,fadeOut,{BackgroundTransparency=1}):Play()
	notifFade(card,false,0.45)
	task.wait(0.45)
	card:Destroy()
end

local function showNotification(data)
	-- Some legacy call sites fired bare strings -- normalize so they actually render.
	if type(data) ~= "table" then data = { title = "Notice", body = tostring(data) } end
	-- Tier routing: explicit tier wins; otherwise lore systems (pd/lore styles) keep the
	-- big full-screen card and everything else is a lesser corner toast.
	local style = tostring(data.style or "info")
	local tier = data.tier or ((style == "pd" or style == "lore") and "big" or "lesser")
	if tier ~= "big" then
		if showLesserToast(data) then return end
		-- toast shell missing: fall through to the big card rather than dropping the message
	end
	table.insert(notifQueue,data)
	if notifPlaying then return end
	notifPlaying=true
	task.spawn(function()
		while #notifQueue>0 do
			local d=table.remove(notifQueue,1)
			local ok,err=pcall(playNotification,d)
			if not ok then warn("[Notif] error: "..tostring(err)) end
		end
		notifPlaying=false
	end)
end

-- Fly
local function stopFly()
	if not flying then return end; flying=false
	if flyConn then flyConn:Disconnect(); flyConn=nil end
	if flyBody then flyBody:Destroy(); flyBody=nil end
	local hum=player.Character and player.Character:FindFirstChildOfClass("Humanoid"); if hum then hum.PlatformStand=false end
	if flyBtn then flyBtn.BackgroundColor3=BTN_BASE; flyBtn.Text="fly" end
end

local function startFly()
	if flying then return end
	local char=player.Character; if not char then return end
	local hrp=char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
	local hum=char:FindFirstChildOfClass("Humanoid"); if not hum then return end
	flying=true; hum.PlatformStand=true
	flyBody=Instance.new("BodyVelocity"); flyBody.Velocity=Vector3.zero; flyBody.MaxForce=Vector3.new(1e5,1e5,1e5); flyBody.P=1e5; flyBody.Parent=hrp
	if flyBtn then flyBtn.BackgroundColor3=BTN_FLY; flyBtn.Text="fly ON" end
	local cam=workspace.CurrentCamera
	flyConn=RunService.RenderStepped:Connect(function()
		if not flying or not flyBody then return end
		local spd=UIS:IsKeyDown(Enum.KeyCode.LeftShift) and 150 or 60
		local dir=Vector3.zero; local cf=cam.CFrame
		local fwd=Vector3.new(cf.LookVector.X,0,cf.LookVector.Z); local rgt=Vector3.new(cf.RightVector.X,0,cf.RightVector.Z)
		if UIS:IsKeyDown(Enum.KeyCode.W) then dir=dir+fwd end
		if UIS:IsKeyDown(Enum.KeyCode.S) then dir=dir-fwd end
		if UIS:IsKeyDown(Enum.KeyCode.A) then dir=dir-rgt end
		if UIS:IsKeyDown(Enum.KeyCode.D) then dir=dir+rgt end
		if UIS:IsKeyDown(Enum.KeyCode.Space)       then dir=dir+Vector3.new(0,1,0) end
		if UIS:IsKeyDown(Enum.KeyCode.LeftControl)  then dir=dir-Vector3.new(0,1,0) end
		flyBody.Velocity=(dir.Magnitude>0.01) and (dir.Unit*spd) or Vector3.zero
	end)
end

player.CharacterAdded:Connect(function()
	if flying then flying=false; flyBody=nil; flyConn=nil; if flyBtn then flyBtn.BackgroundColor3=BTN_BASE; flyBtn.Text="fly" end end
	if godmodeActive then
		local char=player.Character or player.CharacterAdded:Wait()
		local hum=char:WaitForChild("Humanoid",5)
		if hum then
			if godmodeConn then godmodeConn:Disconnect() end
			godmodeConn=hum.HealthChanged:Connect(function(hp)
				if godmodeActive and hp<hum.MaxHealth then hum.Health=hum.MaxHealth end
			end)
		end
	end
end)

-- Noclip
local function stopNoclip()
	noclipActive=false
	if noclipConn then noclipConn:Disconnect(); noclipConn=nil end
	local char=player.Character; if not char then return end
	for _,d in ipairs(char:GetDescendants()) do if d:IsA("BasePart") then d.CanCollide=true end end
end

local function startNoclip()
	if noclipActive then return end; noclipActive=true
	noclipConn=RunService.Stepped:Connect(function()
		local char=player.Character; if not char then return end
		for _,d in ipairs(char:GetDescendants()) do if d:IsA("BasePart") then d.CanCollide=false end end
	end)
end

-- Godmode
local function stopGodmode()
	godmodeActive=false
	if godmodeConn then godmodeConn:Disconnect(); godmodeConn=nil end
end

local function startGodmode()
	if godmodeActive then return end; godmodeActive=true
	local char=player.Character; if char then
		local hum=char:FindFirstChildOfClass("Humanoid")
		if hum then godmodeConn=hum.HealthChanged:Connect(function(hp) if godmodeActive and hp<hum.MaxHealth then hum.Health=hum.MaxHealth end end) end
	end
end

-- ESP
local function clearESP()
	for uid,bb in pairs(espBillboards) do if bb and bb.Parent then bb:Destroy() end end
	espBillboards={}
end

local function startESP()
	espActive=true
	task.spawn(function()
		while espActive do
			local current={}
			for _,p in ipairs(Players:GetPlayers()) do
				if p~=player and p.Character then
					local hrp=p.Character:FindFirstChild("HumanoidRootPart")
					if hrp then
						local uid=p.UserId; current[uid]=true
						local bb=espBillboards[uid]
						if not bb or not bb.Parent then
							bb=Instance.new("BillboardGui"); bb.Name="ESP_"..uid; bb.AlwaysOnTop=true
							bb.Size=UDim2.new(0,80,0,22); bb.StudsOffset=Vector3.new(0,3,0); bb.Parent=hrp
							local lbl=Instance.new("TextLabel"); lbl.Size=UDim2.new(1,0,1,0)
							lbl.BackgroundTransparency=1; lbl.Text=p.Name; lbl.TextColor3=Color3.fromRGB(255,80,80)
							lbl.Font=Enum.Font.GothamBold; lbl.TextSize=13; lbl.TextStrokeTransparency=0.5; lbl.Parent=bb
							espBillboards[uid]=bb
						end
					end
				end
			end
			for uid,bb in pairs(espBillboards) do
				if not current[uid] then if bb and bb.Parent then bb:Destroy() end; espBillboards[uid]=nil end
			end
			task.wait(0.5)
		end
		clearESP()
	end)
end

-- Spectate
local function startSpectate(targetName)
	local tgt=Players:FindFirstChild(targetName)
	if not tgt or not tgt.Character then log("spectate: player not found",Color3.fromRGB(200,72,62)); return end
	local hum=tgt.Character:FindFirstChildOfClass("Humanoid"); if not hum then return end
	workspace.CurrentCamera.CameraSubject=hum; spectating=true
	log("spectating "..targetName,Color3.fromRGB(100,160,220))
end

local function stopSpectate()
	local char=player.Character
	if char then local hum=char:FindFirstChildOfClass("Humanoid"); if hum then workspace.CurrentCamera.CameraSubject=hum end end
	spectating=false; log("unspectated",Color3.fromRGB(138,182,130))
end

-- View overlay helpers. viewRow/viewButton append into currentViewTarget so the SAME
-- populate functions can render either into the in-panel overlay or a pop-out window.
local currentViewTarget = nil
local lastViewTitle, lastViewPopulate = nil, nil

local function viewRow(text,order)
	local parent = currentViewTarget or viewContent
	local l=mk("TextLabel",{Size=UDim2.new(1,-8,0,18),BackgroundTransparency=1,Text=text,TextColor3=PARCHM,Font=Enum.Font.Gotham,TextSize=11,TextXAlignment=Enum.TextXAlignment.Left,TextWrapped=true,LayoutOrder=order or 0,Parent=parent})
	return l
end

local function viewButton(text,order,onClick)
	local parent = currentViewTarget or viewContent
	local b=mk("TextButton",{Size=UDim2.new(1,-8,0,20),BackgroundColor3=BTN_BASE,BorderSizePixel=0,Text="  "..text,TextColor3=PARCHM,Font=Enum.Font.Gotham,TextSize=11,TextXAlignment=Enum.TextXAlignment.Left,AutoButtonColor=false,LayoutOrder=order or 0,Parent=parent})
	addCorner(b,2)
	b.MouseEnter:Connect(function() b.BackgroundColor3=Color3.fromRGB(34,26,16) end)
	b.MouseLeave:Connect(function() b.BackgroundColor3=BTN_BASE end)
	if onClick then b.MouseButton1Click:Connect(onClick) end
	return b
end

local function openView(title, populateFn)
	if not viewOverlay then return end
	lastViewTitle, lastViewPopulate = title, populateFn
	viewOverlay.Visible=true; viewTitle.Text=title
	viewContent:ClearAllChildren(); mk("UIListLayout",{Padding=UDim.new(0,2),SortOrder=Enum.SortOrder.LayoutOrder,Parent=viewContent})
	addPad(viewContent,4,4,4,4)
	currentViewTarget = viewContent
	if populateFn then populateFn() end
	currentViewTarget = nil
end

-- Pop-out: the same view rendered in its own draggable window that stays on screen even
-- with the panel closed (user request: keep logs open while doing other things).
local popoutGui = nil
local popoutCount = 0
local function popOutView(title, populateFn)
	if not popoutGui or not popoutGui.Parent then
		popoutGui = mk("ScreenGui",{Name="AbyssModPopouts",ResetOnSpawn=false,ZIndexBehavior=Enum.ZIndexBehavior.Sibling,IgnoreGuiInset=true,DisplayOrder=20,Parent=pgui})
	end
	popoutCount += 1
	local offset = (popoutCount % 5) * 18
	local win = mk("Frame",{Size=UDim2.new(0,380,0,320),Position=UDim2.new(0.5,-190+offset,0.5,-160+offset),BackgroundColor3=BG,BorderSizePixel=0,Active=true,Parent=popoutGui})
	addCorner(win,4); addStroke(win,1,BORDER)
	local hdr = mk("Frame",{Size=UDim2.new(1,0,0,26),BackgroundColor3=HDR_BG,BorderSizePixel=0,Parent=win})
	addStroke(hdr,1,BORDER)
	txt(hdr,{Text=title,Size=UDim2.new(1,-116,1,0),Position=UDim2.new(0,8,0,0),TextColor3=GOLD,Font=Enum.Font.GothamBold,TextSize=12})
	local content = mk("ScrollingFrame",{Size=UDim2.new(1,-6,1,-32),Position=UDim2.new(0,3,0,29),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=2,ScrollBarImageColor3=BORDER,CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,Parent=win})
	local function populate()
		content:ClearAllChildren()
		mk("UIListLayout",{Padding=UDim.new(0,2),SortOrder=Enum.SortOrder.LayoutOrder,Parent=content})
		addPad(content,4,4,4,4)
		currentViewTarget = content
		if populateFn then populateFn() end
		currentViewTarget = nil
	end
	local rBtn=action(hdr,"refresh",UDim2.new(0,54,0,20),UDim2.new(1,-86,0,3)); rBtn.TextSize=10
	rBtn.MouseButton1Click:Connect(populate)
	local cBtn=action(hdr,"x",UDim2.new(0,24,0,20),UDim2.new(1,-28,0,3),true); cBtn.TextSize=10
	cBtn.MouseButton1Click:Connect(function() win:Destroy() end)
	dragWindow(win, hdr)
	resizeWindow(win, 260, 140)
	populate()
	return win
end

-- ================================================================================
-- PLAYER INFO VIEWER -- PLACEHOLDER_GUI: PlayerInfoViewerPanel
-- A read-only "everything about this character" window. Its own draggable window rather than
-- an openView page because the lore team's whole workflow is: keep this open on one character
-- while running commands against them in the panel behind it.
--
-- Deliberately shows username, display name AND in-game name together -- the lore team knows
-- people by their character name but has to grant things to a Roblox account, and nothing in
-- the game connected those two before.
-- ================================================================================
local viewerWindows = {} -- [targetName] = window, so V twice on one player refocuses instead of stacking

local function openPlayerInfoViewer(targetName)
	if not targetName or targetName=="" then log("no player to view",Color3.fromRGB(195,72,62)); return end
	local existing = viewerWindows[targetName]
	if existing and existing.Parent then existing.Visible=true; return existing end

	if not popoutGui or not popoutGui.Parent then
		popoutGui = mk("ScreenGui",{Name="AbyssModPopouts",ResetOnSpawn=false,ZIndexBehavior=Enum.ZIndexBehavior.Sibling,IgnoreGuiInset=true,DisplayOrder=20,Parent=pgui})
	end
	popoutCount += 1
	local offset = (popoutCount % 5) * 18
	-- Height is capped to the viewport: the full 540 is taller than a windowed Studio client,
	-- and a window taller than the screen can't be dragged anywhere useful. Content scrolls, so
	-- shrinking costs nothing.
	local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1920,1080)
	local winW = math.min(420, math.max(280, vp.X - 20))
	local winH = math.min(540, math.max(200, vp.Y - 20))
	local win = mk("Frame",{Size=UDim2.fromOffset(winW,winH),Position=UDim2.fromOffset(math.max(0,vp.X/2-winW/2)+offset,math.max(0,vp.Y/2-winH/2)+offset),BackgroundColor3=BG,BorderSizePixel=0,Active=true,Parent=popoutGui})
	addCorner(win,4); addStroke(win,1,BORDER)
	viewerWindows[targetName]=win

	local hdr = mk("Frame",{Size=UDim2.new(1,0,0,26),BackgroundColor3=HDR_BG,BorderSizePixel=0,Parent=win})
	addStroke(hdr,1,BORDER)
	txt(hdr,{Text="PLAYER INFO -- "..targetName,Size=UDim2.new(1,-150,1,0),Position=UDim2.new(0,8,0,0),TextColor3=GOLD,Font=Enum.Font.GothamBold,TextSize=12})
	local content = mk("ScrollingFrame",{Size=UDim2.new(1,-6,1,-58),Position=UDim2.new(0,3,0,29),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=2,ScrollBarImageColor3=BORDER,CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,Parent=win})
	mk("UIListLayout",{Padding=UDim.new(0,1),SortOrder=Enum.SortOrder.LayoutOrder,Parent=content})
	addPad(content,4,4,4,4)

	local order = 0
	local function row(text,col)
		order += 1
		return mk("TextLabel",{Size=UDim2.new(1,-8,0,16),BackgroundTransparency=1,Text=text,TextColor3=col or PARCHM,Font=Enum.Font.Code,TextSize=11,TextXAlignment=Enum.TextXAlignment.Left,TextWrapped=true,AutomaticSize=Enum.AutomaticSize.Y,LayoutOrder=order,Parent=content})
	end
	local function header(text)
		order += 1
		mk("TextLabel",{Size=UDim2.new(1,-8,0,20),BackgroundTransparency=1,Text="-- "..text.." --",TextColor3=GOLD,Font=Enum.Font.GothamBold,TextSize=11,TextXAlignment=Enum.TextXAlignment.Left,LayoutOrder=order,Parent=content})
	end

	local function render(info)
		for _,c in ipairs(content:GetChildren()) do
			if c:IsA("TextLabel") then c:Destroy() end
		end
		order = 0
		if not info then row("Player not found or data not loaded.",Color3.fromRGB(200,72,62)); return end

		local id=info.identity
		header("IDENTITY")
		row("Username:      @"..id.username)
		row("Display Name:  "..id.displayName)
		row("In-Game Name:  "..id.inGameName,GOLD)
		row("Gender:        "..id.gender.."   Race: "..id.race)
		row("UserID:        "..id.userId)

		local b=info.bloodline
		header("BLOODLINE (DNA)")
		row("Caste:         "..b.caste..(b.casteRank and ("  (rank "..b.casteRank..")") or ""))
		row("Purity:        "..b.purity)
		row("Clan:          "..b.clan)
		row("Titles:        "..(#b.titles>0 and table.concat(b.titles,", ") or "none"))
		for _,line in ipairs(b.activeBuffs) do row("   "..line,Color3.fromRGB(150,190,140)) end

		local s=info.stats
		local function statLine(label,pair)
			local base,eff=pair[1],pair[2]
			local extra = (eff~=base) and ("   (effective: "..string.format("%.0f",eff).." w/ DNA)") or ""
			row(label..string.format("%-5s",tostring(base))..extra)
		end
		header("STATS")
		statLine("Strength:      ",s.strength)
		statLine("Endurance:     ",s.endurance)
		statLine("Agility:       ",s.agility)
		row("Max Health:    "..string.format("%.0f",s.maxHealth))
		row("Max Stamina:   "..string.format("%.0f",s.maxStamina))
		row("Max Posture:   "..string.format("%.0f",s.maxPosture))

		local c=info.condition
		header("CONDITION")
		row("Health:        "..c.health.." / "..string.format("%.0f",s.maxHealth))
		row("Hunger/Water:  "..c.hunger.." / "..c.water)
		row("State:         "..c.state)
		row("Sanity:        "..string.format("%.0f",c.sanity).."  (hidden from player)",Color3.fromRGB(190,140,190))
		row("Rage State:    "..c.rage)
		row("Injuries:      "..(#c.injuries>0 and table.concat(c.injuries,", ") or "None"))
		row("Feelings:      "..(#c.feelings>0 and table.concat(c.feelings,", ") or "None active"))

		local pr=info.progression
		header("PROGRESSION")
		-- DataManager persists Talents as an ARRAY of talent-id strings, so the names are the
		-- values, not the keys (iterating keys renders "1, 2, 3" instead of the talents).
		local talentList={}
		for _,name in ipairs(pr.talents) do table.insert(talentList,tostring(name)) end
		table.sort(talentList)
		row("Talents:       "..(#talentList>0 and (table.concat(talentList,", ").."  ("..#talentList..")") or "none"))
		row("Fighting Style:"..pr.fightingStyle)
		row("Meditation:    "..pr.meditation.." QTEs    Pushups: "..pr.pushups)
		row("Faction Rep:   "..table.concat(pr.reputation,", "))

		local so=info.social
		header("SOCIAL")
		row("Allies:        "..(#so.allies>0 and table.concat(so.allies,", ") or "none"))
		row("Introduced To: "..so.introducedTo.." players")
		local knows={}
		for k,v in pairs(so.knownAboutSelf) do if v then table.insert(knows,k) end end
		table.sort(knows)
		row("Knows Of Self: "..(#knows>0 and table.concat(knows,", ") or "nothing"))

		header("ECONOMY")
		local e=info.economy
		row("Obol: "..(e.Obol or 0).."   Drachma: "..(e.Drachma or 0).."   Stater: "..(e.Stater or 0).."   Royal: "..(e.RoyalStater or 0))

		header("EQUIPMENT")
		local eq=info.equipment
		row("Weapon:        "..tostring(eq.weapon))
		row("Clothing:      "..tostring(eq.clothing))
		row("Face Gear:     "..tostring(eq.faceGear))
	end

	local function refresh()
		local ok,info=pcall(function() return Remotes.ModPlayerInfo:InvokeServer(targetName) end)
		render(ok and info or nil)
	end

	-- Action bar: the viewer itself is read-only (spec), so these only move the MOD, or hand
	-- the target off to the normal panel -- nothing here mutates the character.
	local bar = mk("Frame",{Size=UDim2.new(1,-6,0,24),Position=UDim2.new(0,3,1,-27),BackgroundTransparency=1,Parent=win})
	action(bar,"jump to",UDim2.new(0,64,0,20),UDim2.new(0,0,0,0)).MouseButton1Click:Connect(function()
		fire("tpSelf",targetName)
	end)
	action(bar,"bring here",UDim2.new(0,78,0,20),UDim2.new(0,68,0,0)).MouseButton1Click:Connect(function()
		fire("tpToMod",targetName)
	end)
	action(bar,"target in panel",UDim2.new(0,104,0,20),UDim2.new(0,150,0,0)).MouseButton1Click:Connect(function()
		allSelected=false; selectedName=targetName
		if infoLbl then infoLbl.Text="-> "..targetName end
		toggleMenu(true)
		log("panel now targeting "..targetName,GOLD)
	end)
	local rBtn=action(hdr,"refresh",UDim2.new(0,54,0,20),UDim2.new(1,-86,0,3)); rBtn.TextSize=10
	rBtn.MouseButton1Click:Connect(refresh)
	local cBtn=action(hdr,"x",UDim2.new(0,24,0,20),UDim2.new(1,-28,0,3),true); cBtn.TextSize=10
	cBtn.MouseButton1Click:Connect(function() viewerWindows[targetName]=nil; win:Destroy() end)

	-- Draggable anywhere on screen, including hard against an edge -- the viewer is meant to be
	-- parked to one side while the mod works the panel behind it -- and resizable, since how
	-- much of the readout you want visible at once is entirely down to what you're doing.
	dragWindow(win, hdr)
	resizeWindow(win, 300, 160)

	-- Live: everything updates while open (spec: poll every 1s). The loop ends with the window.
	task.spawn(function()
		while win.Parent do
			refresh()
			task.wait(1)
		end
		viewerWindows[targetName]=nil
	end)
	return win
end

-- ModSelfEffect handler
Remotes.ModSelfEffect.OnClientEvent:Connect(function(effect,arg,arg2,arg3)
	if effect=="fly" then
		if flying then stopFly(); log("fly OFF",MUTED) else startFly(); log("fly ON",Color3.fromRGB(100,160,220)) end
	elseif effect=="noclip" then
		if noclipActive then stopNoclip(); log("noclip OFF",MUTED) else startNoclip(); log("noclip ON",Color3.fromRGB(100,160,220)) end
		if noclipToggleSet then noclipToggleSet(noclipActive) end
	elseif effect=="godmode" then
		if godmodeActive then stopGodmode(); log("godmode OFF",MUTED) else startGodmode(); log("godmode ON",Color3.fromRGB(100,220,100)) end
		if godmodeToggleSet then godmodeToggleSet(godmodeActive) end
	elseif effect=="speed" then
		local mult=tonumber(arg) or 1
		local hum=player.Character and player.Character:FindFirstChildOfClass("Humanoid"); if hum then hum.WalkSpeed=16*mult end
		log("speed x"..mult,GOLD)
	elseif effect=="tpcoord" then
		local x,y,z=tonumber(arg),tonumber(arg2),tonumber(arg3)
		if x and y and z then
			local hrp=player.Character and player.Character:FindFirstChild("HumanoidRootPart"); if hrp then hrp.CFrame=CFrame.new(x,y,z) end
			log("tp to "..x.." "..y.." "..z,GOLD)
		end
	elseif effect=="spectate" then
		startSpectate(tostring(arg or ""))
	elseif effect=="unspectate" then
		stopSpectate()
	elseif effect=="esp" then
		if espActive then espActive=false; clearESP(); log("ESP OFF",MUTED) else startESP(); log("ESP ON",Color3.fromRGB(255,80,80)) end
		if espToggleSet then espToggleSet(espActive) end
	elseif effect=="modinvisible" then
		local char=player.Character; if not char then return end
		local hum=char:FindFirstChildOfClass("Humanoid")
		if hum then hum.NameDisplayDistance=0; hum.HealthDisplayDistance=0 end
		for _,d in ipairs(char:GetDescendants()) do
			if d:IsA("BasePart") and d.Name~="HumanoidRootPart" then d.LocalTransparencyModifier=1 end
		end
		log("self invisible",GOLD)
	end
end)

-- Blindness overlay (mod-applied, can target any player -- not just self)
local blindGui = nil
local function setBlind(state)
	if state then
		if not blindGui then
			blindGui=Instance.new("ScreenGui"); blindGui.Name="AbyssBlindGui"; blindGui.ResetOnSpawn=false
			-- Must render above every other GUI, including the mod panel itself — blindness
			-- should be total, not something a mod's own menu can poke through.
			blindGui.IgnoreGuiInset=true; blindGui.DisplayOrder=10000; blindGui.Parent=pgui
			local fr=Instance.new("Frame"); fr.Size=UDim2.new(1,0,1,0)
			fr.BackgroundColor3=Color3.new(0,0,0); fr.BackgroundTransparency=0
			fr.BorderSizePixel=0; fr.Parent=blindGui
		end
		blindGui.Enabled=true
		log("blinded",Color3.fromRGB(200,72,62))
	else
		if blindGui then blindGui.Enabled=false end
		log("blindness cleared",Color3.fromRGB(138,182,130))
	end
end

-- Forced spectate (mod event tool): camera is locked onto a named player until released.
-- A light enforcement loop re-applies the subject so respawns/manual camera fiddling
-- can't silently break out of it.
local forcedSpectateName = nil
local function applyForcedSpectate()
	if not forcedSpectateName then return end
	local tgt = Players:FindFirstChild(forcedSpectateName)
	local hum = tgt and tgt.Character and tgt.Character:FindFirstChildOfClass("Humanoid")
	if hum and workspace.CurrentCamera.CameraSubject ~= hum then
		workspace.CurrentCamera.CameraSubject = hum
	end
end
task.spawn(function()
	while true do
		task.wait(0.5)
		if forcedSpectateName then applyForcedSpectate() end
	end
end)

Remotes.ModTargetEffect.OnClientEvent:Connect(function(effect,state)
	if effect=="blind" then setBlind(state and true or false)
	elseif effect=="forcespectate" then
		if state then
			forcedSpectateName = tostring(state)
			applyForcedSpectate()
		else
			forcedSpectateName = nil
			local char=player.Character
			local hum=char and char:FindFirstChildOfClass("Humanoid")
			if hum then workspace.CurrentCamera.CameraSubject=hum end
		end
	end
end)

-- Commands panel
local noclipToggleSet, godmodeToggleSet, espToggleSet

local function buildCmds()
	cmdFrame:ClearAllChildren()
	mk("UIListLayout",{Padding=UDim.new(0,1),Parent=cmdFrame}); addPad(cmdFrame,0,4)

	sectionHdr(cmdFrame,"MOD TOOLS")
	do
		local r=cmdRow(cmdFrame,"Fly / Lock")
		flyBtn=mk("TextButton",{Size=UDim2.new(0,52,0,20),Position=UDim2.new(0,112,0,3),BackgroundColor3=flying and BTN_FLY or BTN_BASE,BorderSizePixel=0,Text=flying and "fly ON" or "fly",TextColor3=PARCHM,Font=Enum.Font.GothamMedium,TextSize=12,AutoButtonColor=false,Parent=r})
		addCorner(flyBtn,2); addStroke(flyBtn,1,BORDER)
		flyBtn.MouseButton1Click:Connect(function() fire("modFly",nil) end)
		action(r,"lock srv",UDim2.new(0,60,0,20),UDim2.new(0,170,0,3)).MouseButton1Click:Connect(function() fire("lockServer",nil) end)
		action(r,"unlock",UDim2.new(0,48,0,20),UDim2.new(0,236,0,3)).MouseButton1Click:Connect(function() fire("unlockServer",nil) end)
	end
	do local r=cmdRow(cmdFrame,"View Player Info")
		action(r,"open viewer",UDim2.new(0,80,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function()
			if selectedName then openPlayerInfoViewer(selectedName)
			else log("select a single player first (or hover one and press V)",Color3.fromRGB(195,72,62)) end
		end)
		txt(r,{Text="or hover a player and press V",Size=UDim2.new(0,220,0,20),Position=UDim2.new(0,198,0,3),TextColor3=FAINT,TextSize=11,TextXAlignment=Enum.TextXAlignment.Left})
	end
	do local r=cmdRow(cmdFrame,"Force Spectate")
		action(r,"all watch selected",UDim2.new(0,114,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function()
			if selectedName then fire("forceSpectateAll",selectedName)
			else log("select a single player to spectate",Color3.fromRGB(195,72,62)) end
		end)
		action(r,"release all",UDim2.new(0,72,0,20),UDim2.new(0,232,0,3)).MouseButton1Click:Connect(function() fire("clearSpectateAll",nil) end)
	end

	sectionHdr(cmdFrame,"LORE")
	do local r=cmdRow(cmdFrame,"PD Stage")
		local i=field(r,"0-5",UDim2.new(0,36,0,20),UDim2.new(0,112,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,154,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("setStage",getTarget(),tonumber(i.Text)) end end)
		action(r,"+1",UDim2.new(0,30,0,20),UDim2.new(0,196,0,3)).MouseButton1Click:Connect(function() if need() then fire("escalateStage",getTarget()) end end)
	end
	-- Global switch, not per-player -- affects every eligible player server-wide, so no
	-- roster target is needed (unlike every other row in this section).
	do local r=cmdRow(cmdFrame,"Global Perm Death")
		action(r,"activate",UDim2.new(0,58,0,20),UDim2.new(0,112,0,3),true).MouseButton1Click:Connect(function() fire("activatePDE",nil) end)
		action(r,"deactivate",UDim2.new(0,70,0,20),UDim2.new(0,174,0,3)).MouseButton1Click:Connect(function() fire("deactivatePDE",nil) end)
	end
	do local r=cmdRow(cmdFrame,"Lore Entry")
		local i=field(r,"entry text...",UDim2.new(0,200,0,20),UDim2.new(0,112,0,3))
		action(r,"add",UDim2.new(0,36,0,20),UDim2.new(0,318,0,3)).MouseButton1Click:Connect(function() if i.Text~="" then fire("loreEntry",nil,i.Text); i.Text="" end end)
		action(r,"broadcast",UDim2.new(0,66,0,20),UDim2.new(0,360,0,3)).MouseButton1Click:Connect(function() fire("announceBoard",nil) end)
	end
	do local r=cmdRow(cmdFrame,"Views")
		action(r,"view lore",UDim2.new(0,66,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function()
			openView("LORE BOARD",function()
				local ok,data=pcall(function() return Remotes.ModLoreBoard:InvokeServer() end)
				if ok and data then
					for i,entry in ipairs(data) do
						viewRow(os.date("%H:%M",entry.timestamp).." ["..entry.author.."]: "..entry.text, i)
					end
					if #data==0 then viewRow("Board is empty.",1) end
				else viewRow("Failed to load.",1) end
			end)
		end)
		action(r,"view logs",UDim2.new(0,62,0,20),UDim2.new(0,184,0,3)).MouseButton1Click:Connect(function()
			openView("ACTION LOG",function()
				local ok,data=pcall(function() return Remotes.ModFullLog:InvokeServer() end)
				if ok and data then
					for i,entry in ipairs(data) do
						viewRow(os.date("%H:%M",entry.timestamp).." "..entry.executer..": "..entry.command.." -> "..entry.result, i)
					end
					if #data==0 then viewRow("Log is empty.",1) end
				else viewRow("Failed to load.",1) end
			end)
		end)
		action(r,"discord",UDim2.new(0,54,0,20),UDim2.new(0,252,0,3)).MouseButton1Click:Connect(function()
			-- opens a small input; just fire the lore channel message
			log("use /discord cmd in next row",MUTED)
		end)
	end
	do local r=cmdRow(cmdFrame,"Discord Msg")
		local i=field(r,"message...",UDim2.new(0,200,0,20),UDim2.new(0,112,0,3))
		action(r,"send",UDim2.new(0,40,0,20),UDim2.new(0,318,0,3)).MouseButton1Click:Connect(function() if i.Text~="" then fire("discordMsg",nil,i.Text); i.Text="" end end)
	end

	sectionHdr(cmdFrame,"IDENTITY")
	do local r=cmdRow(cmdFrame,"Name")
		local fi=field(r,"first",UDim2.new(0,88,0,20),UDim2.new(0,112,0,3))
		local li=field(r,"last",UDim2.new(0,80,0,20),UDim2.new(0,206,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,292,0,3)).MouseButton1Click:Connect(function() if need() and fi.Text~="" then fire("setName",getTarget(),fi.Text,li.Text~="" and li.Text or nil) end end)
	end
	do local r=cmdRow(cmdFrame,"Title")
		local i=field(r,"title text",UDim2.new(0,140,0,20),UDim2.new(0,112,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,258,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("setTitle",getTarget(),i.Text) end end)
		action(r,"remove",UDim2.new(0,50,0,20),UDim2.new(0,300,0,3)).MouseButton1Click:Connect(function() if need() then fire("removeTitle",getTarget()) end end)
	end
	do local r=cmdRow(cmdFrame,"Scar")
		local i=field(r,"scar type",UDim2.new(0,112,0,20),UDim2.new(0,112,0,3))
		action(r,"assign",UDim2.new(0,48,0,20),UDim2.new(0,230,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("assignScar",getTarget(),i.Text) end end)
		action(r,"remove",UDim2.new(0,50,0,20),UDim2.new(0,284,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("removeScar",getTarget(),i.Text) end end)
	end
	do local r=cmdRow(cmdFrame,"Family")
		local i=field(r,"family name",UDim2.new(0,130,0,20),UDim2.new(0,112,0,3))
		action(r,"assign",UDim2.new(0,48,0,20),UDim2.new(0,248,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("assignFamily",getTarget(),i.Text) end end)
	end
	do local r=cmdRow(cmdFrame,"Relation")
		local i=field(r,"Brother/Sister/Twin...",UDim2.new(0,160,0,20),UDim2.new(0,112,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,278,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("setRelation",getTarget(),i.Text) end end)
	end
	do local r=cmdRow(cmdFrame,"View Talents")
		action(r,"view",UDim2.new(0,40,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function()
			if not selectedName then log("select a player first",Color3.fromRGB(200,72,62)); return end
			openView("TALENTS: "..selectedName,function()
				local ok,data=pcall(function() return Remotes.ModPlayerTalents:InvokeServer(selectedName) end)
				if ok and data then
					for i,t in ipairs(data) do viewRow(tostring(t),i) end
					if #data==0 then viewRow("No talents assigned.",1) end
				else viewRow("Failed to load.",1) end
			end)
		end)
	end

	sectionHdr(cmdFrame,"CHARACTER")
	do local r=cmdRow(cmdFrame,"Race")
		local i=field(r,"Human/Vampire/Dwarf...",UDim2.new(0,170,0,20),UDim2.new(0,112,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,288,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("setRace",getTarget(),i.Text) end end)
	end
	do local r=cmdRow(cmdFrame,"Hunger")
		local i=field(r,"0-100",UDim2.new(0,54,0,20),UDim2.new(0,112,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,172,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("setHunger",getTarget(),tonumber(i.Text)) end end)
	end
	do local r=cmdRow(cmdFrame,"Water")
		local i=field(r,"0-100",UDim2.new(0,54,0,20),UDim2.new(0,112,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,172,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("setWater",getTarget(),tonumber(i.Text)) end end)
	end
	do local r=cmdRow(cmdFrame,"Style")
		local i=field(r,"Ironwall/Duelist...",UDim2.new(0,148,0,20),UDim2.new(0,112,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,266,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("setFightingStyle",getTarget(),i.Text) end end)
	end
	do local r=cmdRow(cmdFrame,"Stat")
		local si=field(r,"Strength/Endurance/Agility",UDim2.new(0,154,0,20),UDim2.new(0,112,0,3))
		local vi=field(r,"val",UDim2.new(0,40,0,20),UDim2.new(0,272,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,318,0,3)).MouseButton1Click:Connect(function() if need() and si.Text~="" and vi.Text~="" then fire("setStat",getTarget(),si.Text,tonumber(vi.Text)) end end)
	end
	do local r=cmdRow(cmdFrame,"SP Add")
		local si=field(r,"Strength/End/Agi",UDim2.new(0,130,0,20),UDim2.new(0,112,0,3))
		local ai=field(r,"amt",UDim2.new(0,38,0,20),UDim2.new(0,248,0,3))
		action(r,"add",UDim2.new(0,32,0,20),UDim2.new(0,292,0,3)).MouseButton1Click:Connect(function()
			if need() and si.Text~="" and ai.Text~="" then fire("giveSP",getTarget(),si.Text,ai.Text) end
		end)
	end
	do local r=cmdRow(cmdFrame,"Stat Reveal")
		local i=field(r,"Strength/Endurance/Agility",UDim2.new(0,160,0,20),UDim2.new(0,112,0,3))
		action(r,"reveal",UDim2.new(0,46,0,20),UDim2.new(0,278,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("revealStat",getTarget(),i.Text) end end)
		action(r,"hide",UDim2.new(0,38,0,20),UDim2.new(0,330,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("hideStat",getTarget(),i.Text) end end)
	end
	do local r=cmdRow(cmdFrame,"Talent")
		local i=field(r,"talent name",UDim2.new(0,130,0,20),UDim2.new(0,112,0,3))
		action(r,"grant",UDim2.new(0,44,0,20),UDim2.new(0,248,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("grantTalent",getTarget(),i.Text) end end)
		action(r,"revoke",UDim2.new(0,48,0,20),UDim2.new(0,298,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("revokeTalent",getTarget(),i.Text) end end)
		action(r,"list all IDs",UDim2.new(0,80,0,20),UDim2.new(0,112,0,25)).MouseButton1Click:Connect(function() fire("listTalentIds",nil) end)
	end
	do local r=cmdRow(cmdFrame,"Quick Grant",26)
		action(r,"Riposte",UDim2.new(0,58,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function() if need() then fire("grantTalent",getTarget(),"Riposte") end end)
		action(r,"FeintMaster",UDim2.new(0,82,0,20),UDim2.new(0,174,0,3)).MouseButton1Click:Connect(function() if need() then fire("grantTalent",getTarget(),"FeintMaster") end end)
		action(r,"ReinforcedMuscles",UDim2.new(0,116,0,20),UDim2.new(0,260,0,3)).MouseButton1Click:Connect(function() if need() then fire("grantTalent",getTarget(),"ReinforcedMuscles") end end)
	end
	do local r=cmdRow(cmdFrame,"",26)
		action(r,"ColdBlood",UDim2.new(0,72,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function() if need() then fire("grantTalent",getTarget(),"ColdBlood") end end)
		action(r,"AwakenedEyes",UDim2.new(0,88,0,20),UDim2.new(0,188,0,3)).MouseButton1Click:Connect(function() if need() then fire("grantTalent",getTarget(),"AwakenedEyes") end end)
	end
	do local r=cmdRow(cmdFrame,"Posture Max")
		local i=field(r,"max value",UDim2.new(0,80,0,20),UDim2.new(0,112,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,198,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("setPostureMax",getTarget(),tonumber(i.Text)) end end)
	end

	sectionHdr(cmdFrame,"ECONOMY")
	do local r=cmdRow(cmdFrame,"Currency")
		local ti=field(r,"Obol/Drachma/Stater",UDim2.new(0,124,0,20),UDim2.new(0,112,0,3))
		local ai=field(r,"amt",UDim2.new(0,40,0,20),UDim2.new(0,242,0,3))
		action(r,"give",UDim2.new(0,36,0,20),UDim2.new(0,288,0,3)).MouseButton1Click:Connect(function() if need() and ti.Text~="" and ai.Text~="" then fire("grantCurrency",getTarget(),ti.Text,tonumber(ai.Text)) end end)
		action(r,"take",UDim2.new(0,36,0,20),UDim2.new(0,330,0,3)).MouseButton1Click:Connect(function() if need() and ti.Text~="" and ai.Text~="" then fire("revokeCurrency",getTarget(),ti.Text,tonumber(ai.Text)) end end)
	end
	do local r=cmdRow(cmdFrame,"Bounty")
		local i=field(r,"amount",UDim2.new(0,70,0,20),UDim2.new(0,112,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,188,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("setBounty",getTarget(),tonumber(i.Text)) end end)
		action(r,"clear",UDim2.new(0,40,0,20),UDim2.new(0,230,0,3)).MouseButton1Click:Connect(function() if need() then fire("clearBounty",getTarget()) end end)
	end
	do local r=cmdRow(cmdFrame,"Brand")
		action(r,"apply",UDim2.new(0,44,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function() if need() then fire("applyBrand",getTarget()) end end)
		action(r,"remove",UDim2.new(0,50,0,20),UDim2.new(0,162,0,3)).MouseButton1Click:Connect(function() if need() then fire("removeBrand",getTarget()) end end)
	end

	sectionHdr(cmdFrame,"INVENTORY")
	do local r=cmdRow(cmdFrame,"Give Item")
		local ni=field(r,"item name",UDim2.new(0,106,0,20),UDim2.new(0,112,0,3))
		local qi=field(r,"qual",UDim2.new(0,50,0,20),UDim2.new(0,224,0,3))
		action(r,"give",UDim2.new(0,36,0,20),UDim2.new(0,280,0,3)).MouseButton1Click:Connect(function()
			if need() and ni.Text~="" then fire("giveItem",getTarget(),ni.Text,qi.Text~="" and qi.Text or nil) end
		end)
	end
	do local r=cmdRow(cmdFrame,"Remove Item")
		local i=field(r,"item name",UDim2.new(0,150,0,20),UDim2.new(0,112,0,3))
		action(r,"remove",UDim2.new(0,50,0,20),UDim2.new(0,268,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("removeItem",getTarget(),i.Text) end end)
		action(r,"strip",UDim2.new(0,38,0,20),UDim2.new(0,324,0,3),true).MouseButton1Click:Connect(function() if need() then fire("strip",getTarget()) end end)
	end
	do local r=cmdRow(cmdFrame,"Weapon Qual")
		local ni=field(r,"item name",UDim2.new(0,100,0,20),UDim2.new(0,112,0,3))
		local qi=field(r,"Iron/Steel...",UDim2.new(0,90,0,20),UDim2.new(0,218,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,314,0,3)).MouseButton1Click:Connect(function() if need() and ni.Text~="" and qi.Text~="" then fire("setWeaponQuality",getTarget(),ni.Text,qi.Text) end end)
	end
	do local r=cmdRow(cmdFrame,"Give Food/Drink")
		local ni=field(r,"Bread/Apple/Orange/Stew Bowl/Grape Juice Bottle/Sweet Drink",UDim2.new(0,220,0,20),UDim2.new(0,112,0,3))
		action(r,"give",UDim2.new(0,36,0,20),UDim2.new(0,336,0,3)).MouseButton1Click:Connect(function()
			if need() and ni.Text~="" then fire("giveFood",getTarget(),ni.Text) end
		end)
	end

	sectionHdr(cmdFrame,"ACTION")
	do local r=cmdRow(cmdFrame,"Transport")
		action(r,"tp to",UDim2.new(0,44,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function() if need() then fire("tpSelf",getTarget()) end end)
		action(r,"pull here",UDim2.new(0,62,0,20),UDim2.new(0,162,0,3)).MouseButton1Click:Connect(function() if need() then fire("tpToMod",getTarget()) end end)
	end
	do local r=cmdRow(cmdFrame,"Send to XYZ")
		local xi=field(r,"x",UDim2.new(0,44,0,20),UDim2.new(0,112,0,3))
		local yi=field(r,"y",UDim2.new(0,44,0,20),UDim2.new(0,162,0,3))
		local zi=field(r,"z",UDim2.new(0,44,0,20),UDim2.new(0,212,0,3))
		action(r,"send",UDim2.new(0,40,0,20),UDim2.new(0,262,0,3)).MouseButton1Click:Connect(function()
			if need() and xi.Text~="" and yi.Text~="" and zi.Text~="" then fire("sendToCoords",getTarget(),xi.Text,yi.Text,zi.Text) end
		end)
		action(r,"set spawn",UDim2.new(0,60,0,20),UDim2.new(0,308,0,3)).MouseButton1Click:Connect(function() if need() then fire("setSpawn",getTarget()) end end)
	end
	do local r=cmdRow(cmdFrame,"Freeze")
		action(r,"freeze",UDim2.new(0,50,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function() if need() then fire("freezePlayer",getTarget()) end end)
		action(r,"unfreeze",UDim2.new(0,58,0,20),UDim2.new(0,168,0,3)).MouseButton1Click:Connect(function() if need() then fire("unfreezePlayer",getTarget()) end end)
	end
	do local r=cmdRow(cmdFrame,"Blindness")
		action(r,"blind",UDim2.new(0,42,0,20),UDim2.new(0,112,0,3),true).MouseButton1Click:Connect(function() if need() then fire("setBlind",getTarget()) end end)
		action(r,"unblind",UDim2.new(0,58,0,20),UDim2.new(0,158,0,3)).MouseButton1Click:Connect(function() if need() then fire("clearBlind",getTarget()) end end)
	end
	do local r=cmdRow(cmdFrame,"Visibility")
		action(r,"hide",UDim2.new(0,40,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function() if need() then fire("makeInvisible",getTarget()) end end)
		action(r,"show",UDim2.new(0,38,0,20),UDim2.new(0,158,0,3)).MouseButton1Click:Connect(function() if need() then fire("makeVisible",getTarget()) end end)
	end
	do local r=cmdRow(cmdFrame,"Life")
		action(r,"kill",UDim2.new(0,36,0,20),UDim2.new(0,112,0,3),true).MouseButton1Click:Connect(function() if need() then fire("killPlayer",getTarget()) end end)
		action(r,"respawn",UDim2.new(0,56,0,20),UDim2.new(0,154,0,3)).MouseButton1Click:Connect(function() if need() then fire("respawnPlayer",getTarget()) end end)
		action(r,"revive",UDim2.new(0,46,0,20),UDim2.new(0,216,0,3)).MouseButton1Click:Connect(function() if need() then fire("revivePlayer",getTarget()) end end)
		action(r,"alive",UDim2.new(0,40,0,20),UDim2.new(0,268,0,3)).MouseButton1Click:Connect(function() if need() then fire("setAlive",getTarget()) end end)
		action(r,"dead",UDim2.new(0,36,0,20),UDim2.new(0,314,0,3),true).MouseButton1Click:Connect(function() if need() then fire("setDead",getTarget()) end end)
	end
	do local r=cmdRow(cmdFrame,"Kick")
		local i=field(r,"reason",UDim2.new(0,134,0,20),UDim2.new(0,112,0,3))
		action(r,"kick",UDim2.new(0,36,0,20),UDim2.new(0,252,0,3),true).MouseButton1Click:Connect(function() if need() then fire("kick",getTarget(),i.Text~="" and i.Text or "Removed by a moderator.") end end)
	end
	do local r=cmdRow(cmdFrame,"Ban (selected)")
		local mi=field(r,"minutes",UDim2.new(0,54,0,20),UDim2.new(0,112,0,3))
		local ri=field(r,"reason",UDim2.new(0,130,0,20),UDim2.new(0,170,0,3))
		action(r,"ban",UDim2.new(0,38,0,20),UDim2.new(0,304,0,3),true).MouseButton1Click:Connect(function()
			if need() and mi.Text~="" then fire("banPlayer",getTarget(),mi.Text,ri.Text) end
		end)
	end
	do local r=cmdRow(cmdFrame,"Unban (name/id)")
		local i=field(r,"player name or userId",UDim2.new(0,166,0,20),UDim2.new(0,112,0,3))
		action(r,"unban",UDim2.new(0,50,0,20),UDim2.new(0,282,0,3)).MouseButton1Click:Connect(function()
			if i.Text~="" then fire("unbanPlayer",nil,i.Text) end
		end)
	end

	sectionHdr(cmdFrame,"NOTIFY")
	do local r=cmdRow(cmdFrame,"Notification")
		local ti=field(r,"title",UDim2.new(0,88,0,20),UDim2.new(0,112,0,3))
		local bi=field(r,"body",UDim2.new(0,110,0,20),UDim2.new(0,206,0,3))
		action(r,"-> player",UDim2.new(0,60,0,20),UDim2.new(0,322,0,3)).MouseButton1Click:Connect(function() if need() and ti.Text~="" then fire("sendNotification",getTarget(),ti.Text,bi.Text,12) end end)
		action(r,"-> all",UDim2.new(0,42,0,20),UDim2.new(0,388,0,3)).MouseButton1Click:Connect(function() if ti.Text~="" then fire("sendNotification",nil,ti.Text,bi.Text,12) end end)
	end

	sectionHdr(cmdFrame,"LANGUAGE")
	do local r=cmdRow(cmdFrame,"Language")
		local li=field(r,"None/Gaulish/Greek/Latin",UDim2.new(0,154,0,20),UDim2.new(0,112,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,272,0,3)).MouseButton1Click:Connect(function()
			if need() and li.Text~="" then fire("setLanguage",getTarget(),li.Text) end
		end)
		action(r,"clear",UDim2.new(0,42,0,20),UDim2.new(0,314,0,3)).MouseButton1Click:Connect(function()
			if need() then fire("setLanguage",getTarget(),"None") end
		end)
	end
	do local r=cmdRow(cmdFrame,"Comprehension")
		local li=field(r,"Gaulish/Greek/Latin",UDim2.new(0,120,0,20),UDim2.new(0,112,0,3))
		local pi=field(r,"0-100",UDim2.new(0,46,0,20),UDim2.new(0,238,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,290,0,3)).MouseButton1Click:Connect(function()
			if need() and li.Text~="" and pi.Text~="" then fire("setLanguageComprehension",getTarget(),li.Text,tonumber(pi.Text)) end
		end)
	end
	sectionHdr(cmdFrame,"LORE BROADCAST")
	do local r=cmdRow(cmdFrame,"[LORE TEAM]")
		local mi=field(r,"message...",UDim2.new(0,172,0,20),UDim2.new(0,112,0,3))
		action(r,"=> player",UDim2.new(0,58,0,20),UDim2.new(0,290,0,3)).MouseButton1Click:Connect(function()
			if mi.Text~="" then Remotes.ModBroadcast:FireServer(selectedName or nil,mi.Text); log("[LORE TEAM] => "..(selectedName or "all"),GOLD); mi.Text="" end
		end)
		action(r,"=> all",UDim2.new(0,40,0,20),UDim2.new(0,354,0,3)).MouseButton1Click:Connect(function()
			if mi.Text~="" then Remotes.ModBroadcast:FireServer(nil,mi.Text); log("[LORE TEAM] => all",GOLD); mi.Text="" end
		end)
	end
	sectionHdr(cmdFrame,"WORLD")
	-- Click-to-cycle instead of a free-text field: a mistyped/mis-cased weather name used
	-- to get silently accepted server-side and then do nothing visually (no valid profile
	-- matched it) -- this makes a typo structurally impossible.
	local WEATHER_LIST = {"Clear","Sunny","Cloudy","Foggy","Rain","HeavyRain","Thunderstorm","Snow","Hail","Sandstorm","BloodRain","RedMist","RedSky"}
	local weatherIdx = 1
	do local r=cmdRow(cmdFrame,"Weather",40)
		local picker=action(r,WEATHER_LIST[weatherIdx],UDim2.new(0,110,0,20),UDim2.new(0,112,0,3))
		picker.MouseButton1Click:Connect(function()
			weatherIdx = (weatherIdx % #WEATHER_LIST) + 1
			picker.Text = WEATHER_LIST[weatherIdx]
		end)
		local di=field(r,"sec (blank=permanent)",UDim2.new(0,110,0,20),UDim2.new(0,112,0,25))
		action(r,"set",UDim2.new(0,32,0,20),UDim2.new(0,226,0,3)).MouseButton1Click:Connect(function() fire("setWeather",nil,WEATHER_LIST[weatherIdx],di.Text~="" and tonumber(di.Text) or nil) end)
		action(r,"clr",UDim2.new(0,28,0,20),UDim2.new(0,262,0,3)).MouseButton1Click:Connect(function() fire("clearWeather",nil) end)
	end
	do local r=cmdRow(cmdFrame,"Lightning")
		action(r,"strike random",UDim2.new(0,86,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function() fire("strikeLightning",nil) end)
		action(r,"strike at me",UDim2.new(0,80,0,20),UDim2.new(0,202,0,3)).MouseButton1Click:Connect(function()
			local hrp=player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if hrp then fire("strikeLightning",nil,hrp.Position.X,hrp.Position.Y,hrp.Position.Z) end
		end)
		action(r,"strike player",UDim2.new(0,86,0,20),UDim2.new(0,286,0,3)).MouseButton1Click:Connect(function()
			if need() then fire("strikeLightningPlayer",getTarget()) end
		end)
	end
	do local r=cmdRow(cmdFrame,"Frost Stacks")
		local i=field(r,"amount",UDim2.new(0,60,0,20),UDim2.new(0,112,0,3))
		action(r,"force",UDim2.new(0,44,0,20),UDim2.new(0,176,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("forceFrostStacks",getTarget(),i.Text) end end)
		action(r,"clear",UDim2.new(0,44,0,20),UDim2.new(0,224,0,3)).MouseButton1Click:Connect(function() if need() then fire("clearFrostStacks",getTarget()) end end)
	end
	do local r=cmdRow(cmdFrame,"Clothing")
		local i=field(r,"None/LightCloth/Fur/HeavyFur",UDim2.new(0,166,0,20),UDim2.new(0,112,0,3))
		action(r,"grant",UDim2.new(0,44,0,20),UDim2.new(0,282,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("setClothing",getTarget(),i.Text) end end)
	end
	do local r=cmdRow(cmdFrame,"Face Gear")
		local i=field(r,"None/LightCloth/Mask/FullFaceCloth",UDim2.new(0,180,0,20),UDim2.new(0,112,0,3))
		action(r,"grant",UDim2.new(0,44,0,20),UDim2.new(0,296,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("setFaceGear",getTarget(),i.Text) end end)
	end
	do local r=cmdRow(cmdFrame,"Clock")
		local i=field(r,"0-24",UDim2.new(0,54,0,20),UDim2.new(0,112,0,3))
		action(r,"set",UDim2.new(0,32,0,20),UDim2.new(0,172,0,3)).MouseButton1Click:Connect(function() if i.Text~="" then fire("setClockTime",nil,tonumber(i.Text)) end end)
	end
	do local r=cmdRow(cmdFrame,"Zone Lock")
		local i=field(r,"zoneName",UDim2.new(0,120,0,20),UDim2.new(0,112,0,3))
		action(r,"lock",UDim2.new(0,36,0,20),UDim2.new(0,238,0,3)).MouseButton1Click:Connect(function() if i.Text~="" then fire("lockZone",nil,i.Text) end end)
		action(r,"unlock",UDim2.new(0,46,0,20),UDim2.new(0,280,0,3)).MouseButton1Click:Connect(function() if i.Text~="" then fire("unlockZone",nil,i.Text) end end)
	end
	do local r=cmdRow(cmdFrame,"Unlock Map")
		local i=field(r,"section id",UDim2.new(0,140,0,20),UDim2.new(0,112,0,3))
		action(r,"unlock",UDim2.new(0,46,0,20),UDim2.new(0,258,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("unlockMapSection",getTarget(),i.Text) end end)
	end
	-- (Trigger QTE moved to its own dedicated QTE section below)
	do local r=cmdRow(cmdFrame,"Eclipse")
		local i=field(r,"zone (blank=all)",UDim2.new(0,136,0,20),UDim2.new(0,112,0,3))
		action(r,"trigger",UDim2.new(0,50,0,20),UDim2.new(0,254,0,3)).MouseButton1Click:Connect(function() fire("triggerEclipse",nil,i.Text~="" and i.Text or nil) end)
	end
	do local r=cmdRow(cmdFrame,"Spawn Mob")
		-- Dropdown over Config.Mobs instead of hand-typing a template name. The field still
		-- accepts free text so an unlisted Workspace model can be spawned in a pinch, but the
		-- picker is the normal path and is the only way to get the right template spelling.
		local i=field(r,"pick a mob ->",UDim2.new(0,148,0,20),UDim2.new(0,112,0,3))
		action(r,"pick v",UDim2.new(0,46,0,20),UDim2.new(0,266,0,3)).MouseButton1Click:Connect(function()
			openView("SELECT MOB",function()
				local mobs = Config and Config.Mobs
				if not mobs or #mobs==0 then viewRow("Config.Mobs is empty.",1); return end
				for idx,m in ipairs(mobs) do
					local label = m.name
					if m.manager then label = label.."   [AI]" end
					if m.note then label = label.."   -- "..m.note end
					viewButton(label,idx,function()
						i.Text = m.template
						viewOverlay.Visible=false
						log("selected mob: "..m.name.." ("..m.template..")",GOLD)
					end)
				end
			end)
		end)
		action(r,"spawn",UDim2.new(0,46,0,20),UDim2.new(0,316,0,3)).MouseButton1Click:Connect(function()
			if i.Text~="" then fire("spawnMob",getTarget(),i.Text) end
		end)
	end
	do local r=cmdRow(cmdFrame,"Broadcast")
		local i=field(r,"message...",UDim2.new(0,200,0,20),UDim2.new(0,112,0,3))
		action(r,"send",UDim2.new(0,36,0,20),UDim2.new(0,318,0,3)).MouseButton1Click:Connect(function() if i.Text~="" then fire("globalMessage",nil,i.Text); i.Text="" end end)
	end

	sectionHdr(cmdFrame,"INJURY MANAGEMENT")
	local INJURY_TYPES = {"LostArm","Insanity","HalfBlind","FullBlind","BadVision","BrokenTissue","ConcussedMind","DeafEar"}
	local injuryIdx = 1
	local INJURY_SIDES = {"Random","Left","Right"}
	local injurySideIdx = 1
	do local r=cmdRow(cmdFrame,"Injury Type",47)
		local picker=action(r,INJURY_TYPES[injuryIdx],UDim2.new(0,110,0,20),UDim2.new(0,112,0,3))
		picker.MouseButton1Click:Connect(function() injuryIdx=(injuryIdx%#INJURY_TYPES)+1; picker.Text=INJURY_TYPES[injuryIdx] end)
		local sidePicker=action(r,INJURY_SIDES[injurySideIdx],UDim2.new(0,70,0,20),UDim2.new(0,228,0,3))
		sidePicker.MouseButton1Click:Connect(function() injurySideIdx=(injurySideIdx%#INJURY_SIDES)+1; sidePicker.Text=INJURY_SIDES[injurySideIdx] end)
		local sevI=field(r,"severity 0-100 (opt)",UDim2.new(0,150,0,20),UDim2.new(0,112,0,25))
		action(r,"apply",UDim2.new(0,46,0,20),UDim2.new(0,266,0,25)).MouseButton1Click:Connect(function()
			if need() then
				local side = INJURY_SIDES[injurySideIdx]~="Random" and INJURY_SIDES[injurySideIdx] or nil
				fire("applyInjury",getTarget(),INJURY_TYPES[injuryIdx],side,sevI.Text~="" and sevI.Text or nil)
			end
		end)
	end
	do local r=cmdRow(cmdFrame,"Remove Injury")
		action(r,"remove type above",UDim2.new(0,110,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function()
			if need() then fire("removeInjury",getTarget(),INJURY_TYPES[injuryIdx]) end
		end)
		action(r,"clear all",UDim2.new(0,58,0,20),UDim2.new(0,228,0,3)).MouseButton1Click:Connect(function()
			if need() then fire("clearAllInjuries",getTarget()) end
		end)
	end

	sectionHdr(cmdFrame,"DNA MANAGEMENT")
	local DNA_CLANS = {"None","Verkanos","Aeliana","Corvid"}
	local dnaClanIdx = 1
	do local r=cmdRow(cmdFrame,"DNA Clan/Purity",47)
		local picker=action(r,DNA_CLANS[dnaClanIdx],UDim2.new(0,90,0,20),UDim2.new(0,112,0,3))
		picker.MouseButton1Click:Connect(function() dnaClanIdx=(dnaClanIdx%#DNA_CLANS)+1; picker.Text=DNA_CLANS[dnaClanIdx] end)
		local purI=field(r,"purity 0-100",UDim2.new(0,100,0,20),UDim2.new(0,208,0,3))
		action(r,"apply",UDim2.new(0,46,0,20),UDim2.new(0,112,0,25)).MouseButton1Click:Connect(function()
			if need() then fire("setDNA",getTarget(),DNA_CLANS[dnaClanIdx],purI.Text~="" and purI.Text or nil) end
		end)
		action(r,"clear all DNA",UDim2.new(0,88,0,20),UDim2.new(0,164,0,25),true).MouseButton1Click:Connect(function()
			if need() then fire("clearDNA",getTarget()) end
		end)
	end
	-- Caste is a separate write from Clan/Purity on purpose: the lore team routinely changes one
	-- without touching the others, and a combined "apply" would force them to re-enter every
	-- field every time (and silently overwrite whatever they left blank).
	local CASTES = {"None","Celtae","Aedui","Aquitani","Belgae","Sequani","Parisii"}
	local casteIdx = 1
	do local r=cmdRow(cmdFrame,"Caste",47)
		local picker=action(r,CASTES[casteIdx],UDim2.new(0,90,0,20),UDim2.new(0,112,0,3))
		picker.MouseButton1Click:Connect(function() casteIdx=(casteIdx%#CASTES)+1; picker.Text=CASTES[casteIdx] end)
		action(r,"apply caste",UDim2.new(0,78,0,20),UDim2.new(0,208,0,3)).MouseButton1Click:Connect(function()
			if need() then fire("setCaste",getTarget(),CASTES[casteIdx]) end
		end)
		-- Purity gets its own apply so a purity tweak never disturbs the caste selection above.
		local purI=field(r,"purity 0-100",UDim2.new(0,100,0,20),UDim2.new(0,112,0,25))
		action(r,"apply purity",UDim2.new(0,82,0,20),UDim2.new(0,216,0,25)).MouseButton1Click:Connect(function()
			if need() and purI.Text~="" then fire("setPurity",getTarget(),purI.Text) end
		end)
		-- Read-back of the resolved numbers -- "Belgae at Purity 78" means nothing until you can
		-- see it is buying +6.24% damage. Pulled from the same viewer payload so the two can't drift.
		action(r,"view current",UDim2.new(0,84,0,20),UDim2.new(0,302,0,25)).MouseButton1Click:Connect(function()
			if not selectedName then log("select a player first",Color3.fromRGB(200,72,62)); return end
			local target=selectedName
			openView("DNA: "..target,function()
				local ok,info=pcall(function() return Remotes.ModPlayerInfo:InvokeServer(target) end)
				if not ok or not info then viewRow("Failed to load player info.",1); return end
				local b=info.bloodline
				viewRow("Caste:  "..b.caste..(b.casteRank and ("  (rank "..b.casteRank..")") or ""),1)
				viewRow("Purity: "..b.purity,2)
				viewRow("Clan:   "..b.clan,3)
				viewRow("Titles: "..(#b.titles>0 and table.concat(b.titles,", ") or "none"),4)
				viewRow("",5)
				viewRow("Active caste buffs at current purity:",6)
				if #b.activeBuffs==0 then viewRow("   (none -- no caste assigned)",7) end
				for i,line in ipairs(b.activeBuffs) do viewRow("   "..line,7+i) end
			end)
		end)
	end

	sectionHdr(cmdFrame,"TITLES")
	local TITLES = {"King","Chieftain","Druid","Champion","Outcast"}
	local titleIdx = 1
	do local r=cmdRow(cmdFrame,"Grant Title",47)
		local picker=action(r,TITLES[titleIdx],UDim2.new(0,96,0,20),UDim2.new(0,112,0,3))
		local warnLbl=txt(r,{Text="",Size=UDim2.new(0,250,0,20),Position=UDim2.new(0,112,0,25),TextColor3=Color3.fromRGB(200,120,60),TextSize=11,TextXAlignment=Enum.TextXAlignment.Left})
		-- King is the only title with a precondition, so the panel checks the target's caste up
		-- front rather than letting the mod click Grant and get a server-side rejection.
		local function refreshWarning()
			warnLbl.Text=""
			if TITLES[titleIdx]~="King" or not selectedName then return end
			task.spawn(function()
				local ok,info=pcall(function() return Remotes.ModPlayerInfo:InvokeServer(selectedName) end)
				if ok and info and info.bloodline.caste~="Celtae" then
					warnLbl.Text="! King requires Celtae (target is "..info.bloodline.caste..")"
				end
			end)
		end
		picker.MouseButton1Click:Connect(function()
			titleIdx=(titleIdx%#TITLES)+1; picker.Text=TITLES[titleIdx]; refreshWarning()
		end)
		action(r,"grant",UDim2.new(0,50,0,20),UDim2.new(0,214,0,3)).MouseButton1Click:Connect(function()
			if need() then fire("grantTitle",getTarget(),TITLES[titleIdx]) end
		end)
		action(r,"revoke",UDim2.new(0,56,0,20),UDim2.new(0,270,0,3),true).MouseButton1Click:Connect(function()
			if need() then fire("revokeTitle",getTarget(),TITLES[titleIdx]) end
		end)
		action(r,"check",UDim2.new(0,48,0,20),UDim2.new(0,332,0,3)).MouseButton1Click:Connect(refreshWarning)
	end

	sectionHdr(cmdFrame,"RITUAL MANAGEMENT")
	local ritualNameField
	do local r=cmdRow(cmdFrame,"Circle Name",40)
		ritualNameField=field(r,"Ritual_Name_1234 (see live feed)",UDim2.new(0,270,0,20),UDim2.new(0,112,0,3))
	end
	local function needRitual() if ritualNameField.Text~="" then return true end; log("no ritual circle name entered",Color3.fromRGB(195,72,62)); return false end
	do local r=cmdRow(cmdFrame,"View Location")
		action(r,"teleport to circle",UDim2.new(0,110,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function()
			if needRitual() then fire("viewRitualLocation",nil,ritualNameField.Text) end
		end)
	end
	do local r=cmdRow(cmdFrame,"Effect Text",47)
		local effectI=field(r,"what the ritual does...",UDim2.new(0,270,0,20),UDim2.new(0,112,0,3))
		action(r,"approve",UDim2.new(0,54,0,20),UDim2.new(0,112,0,25)).MouseButton1Click:Connect(function()
			if needRitual() and effectI.Text~="" then fire("approveRitual",nil,ritualNameField.Text,effectI.Text); effectI.Text="" end
		end)
	end
	do local r=cmdRow(cmdFrame,"Reject / Ignore")
		action(r,"reject",UDim2.new(0,50,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function()
			if needRitual() then fire("rejectRitual",nil,ritualNameField.Text) end
		end)
		action(r,"ignore",UDim2.new(0,50,0,20),UDim2.new(0,168,0,3)).MouseButton1Click:Connect(function()
			if needRitual() then fire("ignoreRitual",nil,ritualNameField.Text) end
		end)
	end

	sectionHdr(cmdFrame,"GIVE POTION")
	local POTION_IDS = {"MinorHealthPotion","MajorHealthPotion","StaminaPotion","Bandage","HealingSalve","ClarityElixir","RestorationDraught","CalmingTea"}
	local potionIdx = 1
	do local r=cmdRow(cmdFrame,"Give Potion")
		local picker=action(r,POTION_IDS[potionIdx],UDim2.new(0,130,0,20),UDim2.new(0,112,0,3))
		picker.MouseButton1Click:Connect(function() potionIdx=(potionIdx%#POTION_IDS)+1; picker.Text=POTION_IDS[potionIdx] end)
		local amtI=field(r,"amount",UDim2.new(0,60,0,20),UDim2.new(0,246,0,3))
		action(r,"give",UDim2.new(0,40,0,20),UDim2.new(0,310,0,3)).MouseButton1Click:Connect(function()
			if need() then fire("givePotion",getTarget(),POTION_IDS[potionIdx],amtI.Text~="" and amtI.Text or "1") end
		end)
	end

	sectionHdr(cmdFrame,"NPC MANAGEMENT")
	do local r=cmdRow(cmdFrame,"Spawn NPC",47)
		local nameI=field(r,"name",UDim2.new(0,120,0,20),UDim2.new(0,112,0,3))
		action(r,"spawn at me",UDim2.new(0,84,0,20),UDim2.new(0,236,0,3)).MouseButton1Click:Connect(function()
			if nameI.Text~="" then fire("spawnNPC",nil,nameI.Text) end
		end)
		local xi=field(r,"x",UDim2.new(0,50,0,20),UDim2.new(0,112,0,25))
		local yi=field(r,"y",UDim2.new(0,50,0,20),UDim2.new(0,166,0,25))
		local zi=field(r,"z",UDim2.new(0,50,0,20),UDim2.new(0,220,0,25))
		action(r,"spawn at xyz",UDim2.new(0,84,0,20),UDim2.new(0,276,0,25)).MouseButton1Click:Connect(function()
			if nameI.Text~="" and xi.Text~="" and yi.Text~="" and zi.Text~="" then
				fire("spawnNPC",nil,nameI.Text,xi.Text,yi.Text,zi.Text)
			end
		end)
	end
	local npcIdField
	do local r=cmdRow(cmdFrame,"Selected NPC")
		npcIdField=field(r,"NPC_Name_1234 (or pick from list)",UDim2.new(0,210,0,20),UDim2.new(0,112,0,3))
		-- Dropdown: lists live NPCs from the server so mods never have to hand-type the id.
		action(r,"pick v",UDim2.new(0,52,0,20),UDim2.new(0,328,0,3)).MouseButton1Click:Connect(function()
			openView("SELECT NPC",function()
				local folder=RepStorage:FindFirstChild("RemoteEvents")
				local rf=folder and folder:FindFirstChild("ModNPCList")
				local ok,data=pcall(function() return rf and rf:InvokeServer() end)
				if ok and data then
					if #data==0 then viewRow("No NPCs currently spawned.",1) end
					for i,e in ipairs(data) do
						viewButton(e.name.."   ("..e.id..")",i,function()
							npcIdField.Text=e.id
							viewOverlay.Visible=false
							log("selected NPC: "..e.id,GOLD)
						end)
					end
				else viewRow("Failed to load NPC list.",1) end
			end)
		end)
	end
	local function needNPC() if npcIdField.Text~="" then return true end; log("no NPC id entered",Color3.fromRGB(195,72,62)); return false end
	do local r=cmdRow(cmdFrame,"NPC Name")
		local nameI=field(r,"new name",UDim2.new(0,180,0,20),UDim2.new(0,112,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,296,0,3)).MouseButton1Click:Connect(function()
			if needNPC() and nameI.Text~="" then fire("setNPCName",nil,npcIdField.Text,nameI.Text) end
		end)
	end
	do local r=cmdRow(cmdFrame,"NPC Shirt/Pants")
		local si=field(r,"shirt id",UDim2.new(0,90,0,20),UDim2.new(0,112,0,3))
		local pi=field(r,"pants id",UDim2.new(0,90,0,20),UDim2.new(0,206,0,3))
		action(r,"apply",UDim2.new(0,46,0,20),UDim2.new(0,300,0,3)).MouseButton1Click:Connect(function()
			if needNPC() then fire("setNPCShirtPants",nil,npcIdField.Text,si.Text,pi.Text) end
		end)
	end
	do local r=cmdRow(cmdFrame,"NPC Skin/Face")
		local ski=field(r,"skin 1-6",UDim2.new(0,80,0,20),UDim2.new(0,112,0,3))
		local fai=field(r,"face 1-5",UDim2.new(0,80,0,20),UDim2.new(0,196,0,3))
		action(r,"apply",UDim2.new(0,46,0,20),UDim2.new(0,280,0,3)).MouseButton1Click:Connect(function()
			if needNPC() then
				if ski.Text~="" then fire("setNPCSkin",nil,npcIdField.Text,ski.Text) end
				if fai.Text~="" then fire("setNPCFace",nil,npcIdField.Text,fai.Text) end
			end
		end)
	end
	do local r=cmdRow(cmdFrame,"NPC Hair")
		local hi=field(r,"asset id (0=none)",UDim2.new(0,150,0,20),UDim2.new(0,112,0,3))
		action(r,"apply",UDim2.new(0,46,0,20),UDim2.new(0,266,0,3)).MouseButton1Click:Connect(function()
			if needNPC() then fire("setNPCHair",nil,npcIdField.Text,hi.Text) end
		end)
	end
	do local r=cmdRow(cmdFrame,"NPC Gear")
		local gi=field(r,"gear asset id",UDim2.new(0,150,0,20),UDim2.new(0,112,0,3))
		action(r,"add",UDim2.new(0,38,0,20),UDim2.new(0,266,0,3)).MouseButton1Click:Connect(function()
			if needNPC() and gi.Text~="" then fire("addNPCGear",nil,npcIdField.Text,gi.Text) end
		end)
		action(r,"clear all",UDim2.new(0,58,0,20),UDim2.new(0,308,0,3)).MouseButton1Click:Connect(function()
			if needNPC() then fire("clearNPCGear",nil,npcIdField.Text) end
		end)
	end
	local NPC_WEAPONS={"None","Sword","Axe","Spear","Dagger","Bow","Fists"}
	local npcWeaponIdx=1
	do local r=cmdRow(cmdFrame,"NPC Weapon")
		local picker=action(r,NPC_WEAPONS[npcWeaponIdx],UDim2.new(0,90,0,20),UDim2.new(0,112,0,3))
		picker.MouseButton1Click:Connect(function() npcWeaponIdx=(npcWeaponIdx%#NPC_WEAPONS)+1; picker.Text=NPC_WEAPONS[npcWeaponIdx] end)
		action(r,"equip",UDim2.new(0,46,0,20),UDim2.new(0,206,0,3)).MouseButton1Click:Connect(function()
			if needNPC() then fire("setNPCWeapon",nil,npcIdField.Text,NPC_WEAPONS[npcWeaponIdx]) end
		end)
	end
	local NPC_AGGRO={"None","OnSight","OnAttacked","PlayerLed"}
	local npcAggroIdx=1
	do local r=cmdRow(cmdFrame,"NPC Aggro Type")
		local picker=action(r,NPC_AGGRO[npcAggroIdx],UDim2.new(0,90,0,20),UDim2.new(0,112,0,3))
		picker.MouseButton1Click:Connect(function() npcAggroIdx=(npcAggroIdx%#NPC_AGGRO)+1; picker.Text=NPC_AGGRO[npcAggroIdx] end)
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,206,0,3)).MouseButton1Click:Connect(function()
			if needNPC() then fire("setNPCAggro",nil,npcIdField.Text,NPC_AGGRO[npcAggroIdx]) end
		end)
	end
	do local r=cmdRow(cmdFrame,"NPC Sight/Leash")
		local sgi=field(r,"sight 0-100",UDim2.new(0,90,0,20),UDim2.new(0,112,0,3))
		local lsi=field(r,"leash 0-200",UDim2.new(0,90,0,20),UDim2.new(0,206,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,300,0,3)).MouseButton1Click:Connect(function()
			if needNPC() then
				if sgi.Text~="" then fire("setNPCSightRange",nil,npcIdField.Text,sgi.Text) end
				if lsi.Text~="" then fire("setNPCLeashRange",nil,npcIdField.Text,lsi.Text) end
			end
		end)
	end
	do local r=cmdRow(cmdFrame,"NPC Leader")
		local pi=field(r,"leader player name",UDim2.new(0,150,0,20),UDim2.new(0,112,0,3))
		action(r,"set (PlayerLed)",UDim2.new(0,90,0,20),UDim2.new(0,266,0,3)).MouseButton1Click:Connect(function()
			if needNPC() and pi.Text~="" then fire("setNPCLeader",nil,npcIdField.Text,pi.Text) end
		end)
	end
	do local r=cmdRow(cmdFrame,"NPC Stats")
		local sti=field(r,"str",UDim2.new(0,50,0,20),UDim2.new(0,112,0,3))
		local eni=field(r,"end",UDim2.new(0,50,0,20),UDim2.new(0,166,0,3))
		local agi2=field(r,"agi",UDim2.new(0,50,0,20),UDim2.new(0,220,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,276,0,3)).MouseButton1Click:Connect(function()
			if needNPC() then fire("setNPCStats",nil,npcIdField.Text,sti.Text,eni.Text,agi2.Text) end
		end)
	end
	do local r=cmdRow(cmdFrame,"NPC Max HP")
		local hpi=field(r,"1-500",UDim2.new(0,80,0,20),UDim2.new(0,112,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,196,0,3)).MouseButton1Click:Connect(function()
			if needNPC() and hpi.Text~="" then fire("setNPCMaxHealth",nil,npcIdField.Text,hpi.Text) end
		end)
	end
	do local r=cmdRow(cmdFrame,"NPC Grip")
		action(r,"allow",UDim2.new(0,50,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function()
			if needNPC() then fire("setNPCGrip",nil,npcIdField.Text,"true") end
		end)
		action(r,"disallow",UDim2.new(0,60,0,20),UDim2.new(0,166,0,3),true).MouseButton1Click:Connect(function()
			if needNPC() then fire("setNPCGrip",nil,npcIdField.Text,"false") end
		end)
	end
	local NPC_TRIGGERS={"OnSpawn","OnAggro","OnDamage","OnKill","OnDeath","Idle","Custom"}
	local npcTriggerIdx=1
	do local r=cmdRow(cmdFrame,"NPC Phrase",40)
		local picker=action(r,NPC_TRIGGERS[npcTriggerIdx],UDim2.new(0,84,0,20),UDim2.new(0,112,0,3))
		picker.MouseButton1Click:Connect(function() npcTriggerIdx=(npcTriggerIdx%#NPC_TRIGGERS)+1; picker.Text=NPC_TRIGGERS[npcTriggerIdx] end)
		local txti=field(r,"phrase text",UDim2.new(0,270,0,20),UDim2.new(0,112,0,25))
		action(r,"add",UDim2.new(0,40,0,20),UDim2.new(0,202,0,3)).MouseButton1Click:Connect(function()
			if needNPC() and txti.Text~="" then fire("addNPCPhrase",nil,npcIdField.Text,NPC_TRIGGERS[npcTriggerIdx],txti.Text); txti.Text="" end
		end)
		action(r,"list",UDim2.new(0,40,0,20),UDim2.new(0,248,0,3)).MouseButton1Click:Connect(function()
			if needNPC() then fire("listNPCPhrases",nil,npcIdField.Text) end
		end)
		local idxi=field(r,"#",UDim2.new(0,34,0,20),UDim2.new(0,294,0,3))
		action(r,"remove #",UDim2.new(0,62,0,20),UDim2.new(0,332,0,3),true).MouseButton1Click:Connect(function()
			if needNPC() and idxi.Text~="" then fire("removeNPCPhrase",nil,npcIdField.Text,NPC_TRIGGERS[npcTriggerIdx],idxi.Text) end
		end)
	end
	-- Revealer config: turns the selected NPC into a stat-revealing oracle. Loads the NPC's
	-- CURRENT settings on demand so a mod editing an existing Revealer sees what it already is
	-- instead of blank fields they have to guess at.
	local REVEAL_TYPES = {"Caste","Purity","Clan","Stats","FullDNA","Sanity","Everything"}
	local revealTypeIdx = 1
	do local r=cmdRow(cmdFrame,"NPC Revealer",70)
		local picker=action(r,REVEAL_TYPES[revealTypeIdx],UDim2.new(0,94,0,20),UDim2.new(0,112,0,3))
		picker.MouseButton1Click:Connect(function() revealTypeIdx=(revealTypeIdx%#REVEAL_TYPES)+1; picker.Text=REVEAL_TYPES[revealTypeIdx] end)
		local costI=field(r,"cost (Obol)",UDim2.new(0,86,0,20),UDim2.new(0,212,0,3))
		local cdI=field(r,"cooldown s",UDim2.new(0,86,0,20),UDim2.new(0,304,0,3))
		local status=txt(r,{Text="",Size=UDim2.new(0,280,0,18),Position=UDim2.new(0,112,0,50),TextColor3=Color3.fromRGB(150,140,110),TextSize=11,TextXAlignment=Enum.TextXAlignment.Left})
		action(r,"load",UDim2.new(0,44,0,20),UDim2.new(0,112,0,26)).MouseButton1Click:Connect(function()
			if not needNPC() then return end
			local ok,cfg=pcall(function() return Remotes.ModRevealerConfig:InvokeServer(npcIdField.Text) end)
			if not ok or not cfg then status.Text="could not read that NPC"; return end
			local idx=table.find(REVEAL_TYPES,cfg.revealType)
			if idx then revealTypeIdx=idx; picker.Text=REVEAL_TYPES[idx] end
			costI.Text=tostring(cfg.cost); cdI.Text=tostring(cfg.cooldown)
			status.Text=cfg.isRevealer and ("currently a Revealer ("..cfg.revealType..")") or "not currently a Revealer"
		end)
		action(r,"enable",UDim2.new(0,56,0,20),UDim2.new(0,160,0,26)).MouseButton1Click:Connect(function()
			if needNPC() then
				fire("setNPCRevealer",nil,npcIdField.Text,"true",REVEAL_TYPES[revealTypeIdx],costI.Text~="" and costI.Text or "0",cdI.Text~="" and cdI.Text or "0")
				status.Text="enabled -> "..REVEAL_TYPES[revealTypeIdx]
			end
		end)
		action(r,"disable",UDim2.new(0,58,0,20),UDim2.new(0,220,0,26),true).MouseButton1Click:Connect(function()
			if needNPC() then
				fire("setNPCRevealer",nil,npcIdField.Text,"false")
				status.Text="disabled"
			end
		end)
	end
	do local r=cmdRow(cmdFrame,"Delete NPC")
		action(r,"delete",UDim2.new(0,50,0,20),UDim2.new(0,112,0,3),true).MouseButton1Click:Connect(function()
			if needNPC() then fire("deleteNPC",nil,npcIdField.Text) end
		end)
	end

	sectionHdr(cmdFrame,"SPIRIT TOOLS")
	local SPIRIT_FACTIONS = {"Flame","Wind","Water","Earth","Shadow","Blood"}
	local spiritFactionIdx = 1
	do local r=cmdRow(cmdFrame,"Spawn Spirit",40)
		local picker=action(r,SPIRIT_FACTIONS[spiritFactionIdx],UDim2.new(0,90,0,20),UDim2.new(0,112,0,3))
		picker.MouseButton1Click:Connect(function()
			spiritFactionIdx = (spiritFactionIdx % #SPIRIT_FACTIONS) + 1
			picker.Text = SPIRIT_FACTIONS[spiritFactionIdx]
		end)
		action(r,"spawn at me",UDim2.new(0,84,0,20),UDim2.new(0,206,0,3)).MouseButton1Click:Connect(function()
			fire("spawnSpirit",nil,SPIRIT_FACTIONS[spiritFactionIdx])
		end)
		local xi=field(r,"x",UDim2.new(0,50,0,20),UDim2.new(0,112,0,25))
		local yi=field(r,"y",UDim2.new(0,50,0,20),UDim2.new(0,166,0,25))
		local zi=field(r,"z",UDim2.new(0,50,0,20),UDim2.new(0,220,0,25))
		action(r,"spawn at xyz",UDim2.new(0,84,0,20),UDim2.new(0,276,0,25)).MouseButton1Click:Connect(function()
			if xi.Text~="" and yi.Text~="" and zi.Text~="" then
				fire("spawnSpirit",nil,SPIRIT_FACTIONS[spiritFactionIdx],xi.Text,yi.Text,zi.Text)
			end
		end)
	end
	do local r=cmdRow(cmdFrame,"Spirit Reputation",40)
		local picker2=action(r,SPIRIT_FACTIONS[1],UDim2.new(0,90,0,20),UDim2.new(0,112,0,3))
		local repFactionIdx=1
		picker2.MouseButton1Click:Connect(function()
			repFactionIdx = (repFactionIdx % #SPIRIT_FACTIONS) + 1
			picker2.Text = SPIRIT_FACTIONS[repFactionIdx]
		end)
		local ai=field(r,"-100 to 100",UDim2.new(0,90,0,20),UDim2.new(0,206,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,300,0,3)).MouseButton1Click:Connect(function()
			if need() and ai.Text~="" then fire("setSpiritRep",getTarget(),SPIRIT_FACTIONS[repFactionIdx],ai.Text) end
		end)
	end
	local spiritNameField
	do local r=cmdRow(cmdFrame,"Spirit Name")
		spiritNameField=field(r,"e.g. Spirit_Flame",UDim2.new(0,220,0,20),UDim2.new(0,112,0,3))
	end
	local function needSpirit() if spiritNameField.Text~="" then return true end; log("no spirit name entered",Color3.fromRGB(195,72,62)); return false end
	do local r=cmdRow(cmdFrame,"Spirit Phrase",40)
		local txti=field(r,"phrase text",UDim2.new(0,270,0,20),UDim2.new(0,112,0,3))
		action(r,"add",UDim2.new(0,40,0,20),UDim2.new(0,112,0,25)).MouseButton1Click:Connect(function()
			if needSpirit() and txti.Text~="" then fire("addSpiritPhrase",nil,spiritNameField.Text,txti.Text); txti.Text="" end
		end)
		action(r,"list",UDim2.new(0,40,0,20),UDim2.new(0,158,0,25)).MouseButton1Click:Connect(function()
			if needSpirit() then fire("listSpiritPhrases",nil,spiritNameField.Text) end
		end)
		local idxi=field(r,"#",UDim2.new(0,40,0,20),UDim2.new(0,204,0,25))
		action(r,"remove #",UDim2.new(0,60,0,20),UDim2.new(0,250,0,25),true).MouseButton1Click:Connect(function()
			if needSpirit() and idxi.Text~="" then fire("removeSpiritPhrase",nil,spiritNameField.Text,idxi.Text) end
		end)
	end

	sectionHdr(cmdFrame,"INTERACTABLES")
	local INTERACT_TIERS = {"Tier1","Tier2","Tier3","Tier4","Tier5"}
	local INTERACT_REWARDS = {"None","Item","Currency","LoreNotify"}
	do local r=cmdRow(cmdFrame,"Spawn Interactable",62)
		local tierIdx=1
		local tierPicker=action(r,INTERACT_TIERS[tierIdx],UDim2.new(0,60,0,20),UDim2.new(0,112,0,3))
		tierPicker.MouseButton1Click:Connect(function() tierIdx=(tierIdx%#INTERACT_TIERS)+1; tierPicker.Text=INTERACT_TIERS[tierIdx] end)
		local rewardIdx=1
		local rewardPicker=action(r,INTERACT_REWARDS[rewardIdx],UDim2.new(0,74,0,20),UDim2.new(0,178,0,3))
		rewardPicker.MouseButton1Click:Connect(function() rewardIdx=(rewardIdx%#INTERACT_REWARDS)+1; rewardPicker.Text=INTERACT_REWARDS[rewardIdx] end)
		local promptI=field(r,"prompt text",UDim2.new(0,110,0,20),UDim2.new(0,258,0,3))
		local valueI=field(r,"reward value (Item / Type:Amt)",UDim2.new(0,196,0,20),UDim2.new(0,112,0,25))
		local cdI=field(r,"cooldown sec",UDim2.new(0,76,0,20),UDim2.new(0,312,0,25))
		action(r,"spawn at me",UDim2.new(0,84,0,20),UDim2.new(0,112,0,47)).MouseButton1Click:Connect(function()
			fire("spawnInteractable",nil,INTERACT_TIERS[tierIdx],promptI.Text,INTERACT_REWARDS[rewardIdx],valueI.Text,cdI.Text)
		end)
	end
	do local r=cmdRow(cmdFrame,"Edit Interactable",62)
		local nameI=field(r,"interactable name",UDim2.new(0,140,0,20),UDim2.new(0,112,0,3))
		local tierIdx2=1
		local tierPicker2=action(r,INTERACT_TIERS[tierIdx2],UDim2.new(0,60,0,20),UDim2.new(0,256,0,3))
		tierPicker2.MouseButton1Click:Connect(function() tierIdx2=(tierIdx2%#INTERACT_TIERS)+1; tierPicker2.Text=INTERACT_TIERS[tierIdx2] end)
		local rewardIdx2=1
		local rewardPicker2=action(r,INTERACT_REWARDS[rewardIdx2],UDim2.new(0,74,0,20),UDim2.new(0,320,0,3))
		rewardPicker2.MouseButton1Click:Connect(function() rewardIdx2=(rewardIdx2%#INTERACT_REWARDS)+1; rewardPicker2.Text=INTERACT_REWARDS[rewardIdx2] end)
		local promptI2=field(r,"prompt text",UDim2.new(0,110,0,20),UDim2.new(0,112,0,25))
		local valueI2=field(r,"reward value",UDim2.new(0,130,0,20),UDim2.new(0,226,0,25))
		local cdI2=field(r,"cooldown sec",UDim2.new(0,76,0,20),UDim2.new(0,360,0,25))
		action(r,"save",UDim2.new(0,60,0,20),UDim2.new(0,112,0,47)).MouseButton1Click:Connect(function()
			if nameI.Text~="" then
				fire("editInteractable",nil,nameI.Text,tierPicker2.Text,promptI2.Text,rewardPicker2.Text,valueI2.Text,cdI2.Text)
			end
		end)
	end

	sectionHdr(cmdFrame,"QTE")
	local QTE_TIERS = {"Tier1","Tier2","Tier3","Tier4","Tier5"}
	local qteTierIdx = 1
	do local r=cmdRow(cmdFrame,"Trigger QTE",47)
		local picker=action(r,QTE_TIERS[qteTierIdx],UDim2.new(0,70,0,20),UDim2.new(0,112,0,3))
		picker.MouseButton1Click:Connect(function() qteTierIdx=(qteTierIdx%#QTE_TIERS)+1; picker.Text=QTE_TIERS[qteTierIdx] end)
		action(r,"on selected",UDim2.new(0,80,0,20),UDim2.new(0,188,0,3)).MouseButton1Click:Connect(function()
			if need() then fire("triggerQTE",getTarget(),QTE_TIERS[qteTierIdx]) end
		end)
		action(r,"on ALL",UDim2.new(0,54,0,20),UDim2.new(0,274,0,3)).MouseButton1Click:Connect(function()
			fire("triggerQTE","ALL",QTE_TIERS[qteTierIdx])
		end)
		txt(r,{Text="pass/fail results come back as notifications",Size=UDim2.new(0,260,0,16),Position=UDim2.new(0,112,0,26),TextColor3=FAINT,TextSize=10})
	end

	sectionHdr(cmdFrame,"SERVER")
	do local r=cmdRow(cmdFrame,"Server")
		action(r,"shutdown",UDim2.new(0,60,0,20),UDim2.new(0,112,0,3),true).MouseButton1Click:Connect(function() fire("shutdownServer",nil) end)
		action(r,"restart",UDim2.new(0,54,0,20),UDim2.new(0,178,0,3),true).MouseButton1Click:Connect(function() fire("restartServer",nil) end)
	end

	sectionHdr(cmdFrame,"MOD SELF")
	-- Noclip/Godmode/ESP only fire the remote here -- the server's reply on ModSelfEffect
	-- (handled above) is the single place that flips the real flag, runs the actual
	-- start/stop logic, and now also calls these ToggleSet functions to sync the button.
	-- Previously the buttons ALSO pre-toggled the flag+visuals themselves on click, which
	-- raced the round-trip reply: by the time the reply arrived the flag already looked
	-- "on", so the reply's own if-active-then-stop-else-start logic called stop instead of
	-- start -- the real noclip/godmode/ESP implementation never actually ran.
	do
		local r=cmdRow(cmdFrame,"Noclip / Godmode")
		local nBtn; nBtn,noclipToggleSet=toggle(r,"noclip",UDim2.new(0,56,0,20),UDim2.new(0,112,0,3))
		local gBtn; gBtn,godmodeToggleSet=toggle(r,"godmode",UDim2.new(0,66,0,20),UDim2.new(0,174,0,3))
		nBtn.MouseButton1Click:Connect(function() fire("modNoclip",nil) end)
		gBtn.MouseButton1Click:Connect(function() fire("modGodmode",nil) end)
	end
	do
		local r=cmdRow(cmdFrame,"Invisible / ESP")
		local iBtn=mk("TextButton",{Size=UDim2.new(0,62,0,20),Position=UDim2.new(0,112,0,3),BackgroundColor3=BTN_BASE,BorderSizePixel=0,Text="invis (self)",TextColor3=PARCHM,Font=Enum.Font.GothamMedium,TextSize=12,AutoButtonColor=false,Parent=r})
		addCorner(iBtn,2); addStroke(iBtn,1,BORDER)
		local eBtn; eBtn,espToggleSet=toggle(r,"ESP",UDim2.new(0,42,0,20),UDim2.new(0,180,0,3),Color3.fromRGB(120,0,0))
		iBtn.MouseButton1Click:Connect(function() fire("modInvisible",nil) end)
		eBtn.MouseButton1Click:Connect(function() fire("modESP",nil) end)
	end
	do local r=cmdRow(cmdFrame,"Speed")
		local i=field(r,"mult (1=normal)",UDim2.new(0,108,0,20),UDim2.new(0,112,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,226,0,3)).MouseButton1Click:Connect(function() if i.Text~="" then fire("modSpeed",nil,i.Text) end end)
		action(r,"reset",UDim2.new(0,42,0,20),UDim2.new(0,268,0,3)).MouseButton1Click:Connect(function() fire("modSpeed",nil,"1") end)
	end
	do local r=cmdRow(cmdFrame,"TP to XYZ")
		local xi=field(r,"x",UDim2.new(0,44,0,20),UDim2.new(0,112,0,3))
		local yi=field(r,"y",UDim2.new(0,44,0,20),UDim2.new(0,162,0,3))
		local zi=field(r,"z",UDim2.new(0,44,0,20),UDim2.new(0,212,0,3))
		action(r,"go",UDim2.new(0,32,0,20),UDim2.new(0,262,0,3)).MouseButton1Click:Connect(function()
			if xi.Text~="" and yi.Text~="" and zi.Text~="" then fire("modTpCoord",nil,xi.Text,yi.Text,zi.Text) end
		end)
	end
	do local r=cmdRow(cmdFrame,"Spectate")
		local i=field(r,"player name",UDim2.new(0,120,0,20),UDim2.new(0,112,0,3))
		action(r,"spectate",UDim2.new(0,58,0,20),UDim2.new(0,238,0,3)).MouseButton1Click:Connect(function() if i.Text~="" then fire("modSpectate",nil,i.Text) end end)
		action(r,"stop",UDim2.new(0,38,0,20),UDim2.new(0,302,0,3)).MouseButton1Click:Connect(function() fire("modUnspectate",nil) end)
	end

	sectionHdr(cmdFrame,"APPEARANCE")
	do local r=cmdRow(cmdFrame,"Skin Tone")
		local i=field(r,"1-6",UDim2.new(0,50,0,20),UDim2.new(0,112,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,168,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("setSkinTone",getTarget(),i.Text) end end)
	end
	do local r=cmdRow(cmdFrame,"Face")
		local i=field(r,"1-5",UDim2.new(0,50,0,20),UDim2.new(0,112,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,168,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("setFace",getTarget(),i.Text) end end)
	end
	do local r=cmdRow(cmdFrame,"Hair Override")
		local i=field(r,"asset id",UDim2.new(0,110,0,20),UDim2.new(0,112,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,228,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("setHairOverride",getTarget(),i.Text) end end)
		action(r,"clear",UDim2.new(0,46,0,20),UDim2.new(0,270,0,3)).MouseButton1Click:Connect(function() if need() then fire("clearHairOverride",getTarget()) end end)
	end

	sectionHdr(cmdFrame,"OUTFIT SLOTS")
	do local r=cmdRow(cmdFrame,"Slot 1 Shirt/Pants")
		local si=field(r,"shirt id",UDim2.new(0,86,0,20),UDim2.new(0,112,0,3))
		local pi=field(r,"pants id",UDim2.new(0,86,0,20),UDim2.new(0,202,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,292,0,3)).MouseButton1Click:Connect(function()
			if need() and si.Text~="" and pi.Text~="" then fire("setOutfitSlot1",getTarget(),si.Text,pi.Text) end
		end)
	end
	do local r=cmdRow(cmdFrame,"Slot 2 Shirt/Pants")
		local si=field(r,"shirt id",UDim2.new(0,86,0,20),UDim2.new(0,112,0,3))
		local pi=field(r,"pants id",UDim2.new(0,86,0,20),UDim2.new(0,202,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,292,0,3)).MouseButton1Click:Connect(function()
			if need() and si.Text~="" and pi.Text~="" then fire("setOutfitSlot2",getTarget(),si.Text,pi.Text) end
		end)
	end
	do local r=cmdRow(cmdFrame,"Active Slot")
		action(r,"1",UDim2.new(0,32,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function() if need() then fire("setActiveOutfit",getTarget(),"1") end end)
		action(r,"2",UDim2.new(0,32,0,20),UDim2.new(0,150,0,3)).MouseButton1Click:Connect(function() if need() then fire("setActiveOutfit",getTarget(),"2") end end)
	end

	sectionHdr(cmdFrame,"IDENTITY (NAME)")
	do local r=cmdRow(cmdFrame,"First Name")
		local i=field(r,"first name",UDim2.new(0,140,0,20),UDim2.new(0,112,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,258,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("setFirstName",getTarget(),i.Text) end end)
	end
	do local r=cmdRow(cmdFrame,"Family Name")
		local i=field(r,"family name",UDim2.new(0,140,0,20),UDim2.new(0,112,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,258,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("setFamilyName",getTarget(),i.Text) end end)
	end

	sectionHdr(cmdFrame,"PLAYER MANAGEMENT")
	do local r=cmdRow(cmdFrame,"Blood Bar")
		action(r,"check",UDim2.new(0,48,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function() if need() then fire("checkBloodBar",getTarget()) end end)
		action(r,"clear bleeds",UDim2.new(0,86,0,20),UDim2.new(0,166,0,3)).MouseButton1Click:Connect(function() if need() then fire("clearBleeds",getTarget()) end end)
	end

	sectionHdr(cmdFrame,"SANITY MANAGEMENT")
	do local r=cmdRow(cmdFrame,"Sanity")
		action(r,"check",UDim2.new(0,48,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function() if need() then fire("checkSanity",getTarget()) end end)
		local i=field(r,"0-100",UDim2.new(0,60,0,20),UDim2.new(0,166,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,230,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("setSanity",getTarget(),i.Text) end end)
	end
	do local r=cmdRow(cmdFrame,"Sanity +/-")
		local i=field(r,"amount",UDim2.new(0,60,0,20),UDim2.new(0,112,0,3))
		action(r,"reduce",UDim2.new(0,50,0,20),UDim2.new(0,176,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("reduceSanity",getTarget(),i.Text) end end)
		action(r,"increase",UDim2.new(0,58,0,20),UDim2.new(0,230,0,3)).MouseButton1Click:Connect(function() if need() and i.Text~="" then fire("increaseSanity",getTarget(),i.Text) end end)
	end

	sectionHdr(cmdFrame,"FEELING TRIGGER")
	local FEELING_IDS = {"Anxiety","Fear","Rage","Paranoia","Soothing"}
	local feelingIdx = 1
	do local r=cmdRow(cmdFrame,"Feeling")
		local picker=action(r,FEELING_IDS[feelingIdx],UDim2.new(0,90,0,20),UDim2.new(0,112,0,3))
		picker.MouseButton1Click:Connect(function() feelingIdx=(feelingIdx%#FEELING_IDS)+1; picker.Text=FEELING_IDS[feelingIdx] end)
		action(r,"trigger on player",UDim2.new(0,110,0,20),UDim2.new(0,208,0,3)).MouseButton1Click:Connect(function() if need() then fire("triggerFeeling",getTarget(),FEELING_IDS[feelingIdx]) end end)
	end

	sectionHdr(cmdFrame,"RAGE MANAGEMENT")
	do local r=cmdRow(cmdFrame,"Force Rage")
		action(r,"force enter",UDim2.new(0,80,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function() if need() then fire("forceEnterRage",getTarget()) end end)
		action(r,"force exit",UDim2.new(0,76,0,20),UDim2.new(0,196,0,3)).MouseButton1Click:Connect(function() if need() then fire("forceExitRage",getTarget()) end end)
	end
	local RAGE_DEBUFF_TYPES = {"None","Injury","ReduceSanityRecovery","Curse"}
	local rageDebuffIdx = 1
	do local r=cmdRow(cmdFrame,"Rage Exit Debuff",47)
		local picker=action(r,RAGE_DEBUFF_TYPES[rageDebuffIdx],UDim2.new(0,140,0,20),UDim2.new(0,112,0,3))
		picker.MouseButton1Click:Connect(function() rageDebuffIdx=(rageDebuffIdx%#RAGE_DEBUFF_TYPES)+1; picker.Text=RAGE_DEBUFF_TYPES[rageDebuffIdx] end)
		-- Injury sub-type reuses the same INJURY_TYPES picker/index from INJURY MANAGEMENT above
		-- (only relevant when the debuff type above is "Injury"); Curse instead uses free text.
		local curseI=field(r,"curse text (if Curse)",UDim2.new(0,270,0,20),UDim2.new(0,112,0,25))
		action(r,"assign",UDim2.new(0,54,0,20),UDim2.new(0,258,0,3)).MouseButton1Click:Connect(function()
			if need() then
				local dtype=RAGE_DEBUFF_TYPES[rageDebuffIdx]
				local arg = (dtype=="Injury") and INJURY_TYPES[injuryIdx] or (dtype=="Curse") and curseI.Text or nil
				fire("assignRageDebuff",getTarget(),dtype,arg)
			end
		end)
	end

	sectionHdr(cmdFrame,"ALLY MANAGEMENT")
	do local r=cmdRow(cmdFrame,"Ally Progress")
		action(r,"check",UDim2.new(0,58,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function() if need() then fire("checkAllyProgress",getTarget()) end end)
	end
	do local r=cmdRow(cmdFrame,"Ally Bond",47)
		local otherI=field(r,"second player name",UDim2.new(0,150,0,20),UDim2.new(0,112,0,3))
		action(r,"force bond",UDim2.new(0,72,0,20),UDim2.new(0,112,0,25)).MouseButton1Click:Connect(function() if need() and otherI.Text~="" then fire("forceAllyBond",getTarget(),otherI.Text) end end)
		action(r,"remove bond",UDim2.new(0,78,0,20),UDim2.new(0,188,0,25)).MouseButton1Click:Connect(function() if need() and otherI.Text~="" then fire("removeAllyBond",getTarget(),otherI.Text) end end)
	end

	sectionHdr(cmdFrame,"INTERACTABLE MANAGEMENT")
	local interactNameField
	do local r=cmdRow(cmdFrame,"Object Name",40)
		interactNameField=field(r,"exact part name (see SessionPlacements)",UDim2.new(0,270,0,20),UDim2.new(0,112,0,3))
	end
	local function needInteract() if interactNameField.Text~="" then return true end; log("no object name entered",Color3.fromRGB(195,72,62)); return false end
	do local r=cmdRow(cmdFrame,"Get Info")
		action(r,"fetch attributes",UDim2.new(0,110,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function()
			if needInteract() then fire("getInteractableInfo",nil,interactNameField.Text) end
		end)
	end
	do local r=cmdRow(cmdFrame,"Set Attribute",47)
		local attrI=field(r,"attribute name",UDim2.new(0,130,0,20),UDim2.new(0,112,0,3))
		local valI=field(r,"value",UDim2.new(0,130,0,20),UDim2.new(0,112,0,25))
		action(r,"apply",UDim2.new(0,50,0,20),UDim2.new(0,246,0,25)).MouseButton1Click:Connect(function()
			if needInteract() and attrI.Text~="" then fire("setInteractableAttr",nil,interactNameField.Text,attrI.Text,valI.Text) end
		end)
	end

	sectionHdr(cmdFrame,"INVENTORY EXTRAS")
	do local r=cmdRow(cmdFrame,"Clear Inventory")
		action(r,"wipe all",UDim2.new(0,70,0,20),UDim2.new(0,112,0,3),true).MouseButton1Click:Connect(function() if need() then fire("clearInventory",getTarget()) end end)
	end
	do local r=cmdRow(cmdFrame,"Quick Give: Food",26)
		action(r,"Bread",UDim2.new(0,60,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function() if need() then fire("giveFood",getTarget(),"Bread") end end)
		action(r,"Water Skin",UDim2.new(0,72,0,20),UDim2.new(0,176,0,3)).MouseButton1Click:Connect(function() if need() then fire("giveFood",getTarget(),"Water_Skin") end end)
		action(r,"Wine",UDim2.new(0,50,0,20),UDim2.new(0,252,0,3)).MouseButton1Click:Connect(function() if need() then fire("giveFood",getTarget(),"Wine") end end)
	end
	do local r=cmdRow(cmdFrame,"Quick Give: Items",26)
		action(r,"Iron Ingot",UDim2.new(0,74,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function() if need() then fire("giveItem",getTarget(),"Iron_Ingot","Iron") end end)
		action(r,"Iron Longsword",UDim2.new(0,96,0,20),UDim2.new(0,190,0,3)).MouseButton1Click:Connect(function() if need() then fire("giveItem",getTarget(),"Iron_Longsword","Iron") end end)
		action(r,"Coin Pouch",UDim2.new(0,76,0,20),UDim2.new(0,290,0,3)).MouseButton1Click:Connect(function() if need() then fire("giveItem",getTarget(),"Coin_Pouch") end end)
	end

	sectionHdr(cmdFrame,"SHIP MANAGEMENT")
	do local r=cmdRow(cmdFrame,"Ships")
		action(r,"list all",UDim2.new(0,70,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function() fire("listShips",nil) end)
	end
	local shipNameField
	do local r=cmdRow(cmdFrame,"Ship Name")
		shipNameField=field(r,"exact ShipName (see list all)",UDim2.new(0,220,0,20),UDim2.new(0,112,0,3))
	end
	local function needShip() if shipNameField.Text~="" then return true end; log("no ship name entered",Color3.fromRGB(195,72,62)); return false end
	do local r=cmdRow(cmdFrame,"Set Ship HP")
		local hpI=field(r,"hp",UDim2.new(0,60,0,20),UDim2.new(0,112,0,3))
		action(r,"apply",UDim2.new(0,44,0,20),UDim2.new(0,176,0,3)).MouseButton1Click:Connect(function()
			if needShip() and hpI.Text~="" then fire("setShipHP",nil,shipNameField.Text,hpI.Text) end
		end)
	end
	do local r=cmdRow(cmdFrame,"Anchor / Sailing")
		action(r,"toggle",UDim2.new(0,60,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function() if needShip() then fire("toggleShipAnchor",nil,shipNameField.Text) end end)
		action(r,"force sink",UDim2.new(0,74,0,20),UDim2.new(0,178,0,3),true).MouseButton1Click:Connect(function() if needShip() then fire("forceSinkShip",nil,shipNameField.Text) end end)
	end
	do local r=cmdRow(cmdFrame,"Assign Owner")
		action(r,"assign to selected",UDim2.new(0,120,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function()
			if needShip() and need() then fire("assignShipOwner",getTarget(),shipNameField.Text) end
		end)
	end

	sectionHdr(cmdFrame,"SHADOW BOXING")
	do local r=cmdRow(cmdFrame,"Shadow Practice",48)
		action(r,"force end for selected",UDim2.new(0,140,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function() if need() then fire("forceEndShadowPractice",getTarget()) end end)
		action(r,"force start for selected",UDim2.new(0,150,0,20),UDim2.new(0,112,0,25)).MouseButton1Click:Connect(function() if need() then fire("forceStartShadowPractice",getTarget()) end end)
	end
	do local r=cmdRow(cmdFrame,"Shadow Box Hits")
		local hi=field(r,"# hits to defeat",UDim2.new(0,90,0,20),UDim2.new(0,112,0,3))
		action(r,"set",UDim2.new(0,36,0,20),UDim2.new(0,206,0,3)).MouseButton1Click:Connect(function()
			if need() and hi.Text~="" then fire("setShadowBoxHits",getTarget(),hi.Text) end
		end)
	end

	-- VELOCITY TEST -- Studio-only feel tests for the VelocityManager (movement rehaul
	-- phase 1). The `vmtest` command itself is registered at runtime by VM_TestHarness,
	-- which never runs on a live server -- so the section is hidden there too, and even a
	-- hand-fired "vmtest" would just come back "Unknown command".
	if RunService:IsStudio() then
		sectionHdr(cmdFrame,"VELOCITY TEST (STUDIO)")
		do local r=cmdRow(cmdFrame,"Push Self",48)
			action(r,"wind",UDim2.new(0,42,0,20),UDim2.new(0,112,0,3)).MouseButton1Click:Connect(function() fire("vmtest",nil,"wind") end)
			action(r,"knockback",UDim2.new(0,70,0,20),UDim2.new(0,160,0,3)).MouseButton1Click:Connect(function() fire("vmtest",nil,"kb") end)
			action(r,"sum",UDim2.new(0,38,0,20),UDim2.new(0,236,0,3)).MouseButton1Click:Connect(function() fire("vmtest",nil,"sum") end)
			action(r,"launch",UDim2.new(0,50,0,20),UDim2.new(0,280,0,3)).MouseButton1Click:Connect(function() fire("vmtest",nil,"launch") end)
			action(r,"mob hit",UDim2.new(0,56,0,20),UDim2.new(0,112,0,25)).MouseButton1Click:Connect(function() fire("vmtest",nil,"hit") end)
			action(r,"npc push",UDim2.new(0,60,0,20),UDim2.new(0,174,0,25)).MouseButton1Click:Connect(function() fire("vmtest",nil,"npc") end)
		end
	end
end

-- Roster
local function buildRoster(list)
	for _,b in ipairs(playerBtns) do if b.Parent then b:Destroy() end end; playerBtns={}
	for _,info in ipairs(list) do
		local b=mk("TextButton",{Size=UDim2.new(1,-4,0,22),BackgroundColor3=Color3.fromRGB(16,12,8),BorderSizePixel=0,Text="  "..info.name,TextColor3=PARCHM,Font=Enum.Font.Gotham,TextSize=12,TextXAlignment=Enum.TextXAlignment.Left,TextTruncate=Enum.TextTruncate.AtEnd,ClipsDescendants=true,AutoButtonColor=false,Parent=rosterFrame})
		addCorner(b,2); addPad(b,4)
		local cap=info
		b.MouseEnter:Connect(function() if selectedName~=cap.name then b.BackgroundColor3=Color3.fromRGB(28,22,14) end end)
		b.MouseLeave:Connect(function() if selectedName~=cap.name and not allSelected then b.BackgroundColor3=Color3.fromRGB(16,12,8) end end)
		b.MouseButton1Click:Connect(function()
			allSelected=false; selectedName=cap.name
			infoLbl.Text=cap.name.."  race: "..(cap.race or "?").."  style: "..(cap.fightingStyle or "?").."  state: "..(cap.playerState or "?").."  title: "..(cap.title or "")
			for _,ob in ipairs(playerBtns) do ob.BackgroundColor3=Color3.fromRGB(16,12,8); ob.TextColor3=PARCHM end
			b.BackgroundColor3=Color3.fromRGB(42,32,14); b.TextColor3=GOLD
		end)
		table.insert(playerBtns,b)
	end
end

local function fallback()
	local t={}; for _,p in ipairs(Players:GetPlayers()) do t[#t+1]={name=p.Name,displayName=p.DisplayName,fightingStyle="?",playerState="?",stage=0,race="?",title=""} end; return t
end

-- Build GUI
local function build()
	screenGui=mk("ScreenGui",{Name="AbyssModMenu",ResetOnSpawn=false,ZIndexBehavior=Enum.ZIndexBehavior.Sibling,IgnoreGuiInset=true,Enabled=false,DisplayOrder=0,Parent=pgui})
	mainFrame=mk("Frame",{Name="Main",Size=UDim2.fromOffset(740,540),Position=UDim2.fromOffset(0,0),BackgroundColor3=BG,BorderSizePixel=0,Parent=screenGui})
	addCorner(mainFrame,4); addStroke(mainFrame,1,BORDER); bgImg(mainFrame,IMG_BG)

	local hdr=mk("Frame",{Size=UDim2.new(1,0,0,38),BackgroundColor3=HDR_BG,BorderSizePixel=0,Parent=mainFrame})
	addStroke(hdr,1,BORDER); bgImg(hdr,IMG_HDR)
	txt(hdr,{Text="ABYSS   .   COUNCIL",Size=UDim2.new(1,-82,1,0),Position=UDim2.new(0,12,0,0),Font=Enum.Font.Antique,TextSize=16,TextColor3=GOLD})
	feedBtn=action(hdr,"feed",UDim2.new(0,40,0,26),UDim2.new(1,-74,0,6)); feedBtn.TextSize=10
	feedBtn.MouseButton1Click:Connect(function()
		liveFeedOpen=not liveFeedOpen
		if liveFeedOverlay then liveFeedOverlay.Visible=liveFeedOpen end
		feedBtn.BackgroundColor3=liveFeedOpen and BTN_ON or BTN_BASE
		if liveFeedOpen and liveFeedContent and #liveFeedEntries>0 then
			task.defer(function() liveFeedContent.CanvasPosition=Vector2.new(0,math.huge) end)
		end
	end)
	local xBtn=action(hdr,"x",UDim2.new(0,26,0,26),UDim2.new(1,-30,0,6),true); xBtn.TextSize=11
	xBtn.MouseButton1Click:Connect(function() toggleMenu(false) end); draggable(hdr)
	-- Minimum is the point below which the fixed-height log strip + header would start eating
	-- the command list entirely; width floor keeps the roster and the widest command rows legible.
	resizeWindow(mainFrame, PANEL_MIN_W, PANEL_MIN_H)
	fitPanelToViewport(true)
	-- Resizing the client window (or entering/leaving fullscreen) must not strand the panel or
	-- its resize grip off-screen. Re-clamp size, then let the drag clamp pull it back in view.
	local cam = workspace.CurrentCamera
	if cam then cam:GetPropertyChangedSignal("ViewportSize"):Connect(function() fitPanelToViewport(false) end) end

	-- Panel interior is sized relative to mainFrame so the resize grip actually reflows it.
	-- Roster keeps its fixed 172px width (name buttons don't benefit from being wider) and
	-- takes all the extra height; the command side absorbs both extra width and height.
	local lp=mk("Frame",{Size=UDim2.new(0,172,1,-46),Position=UDim2.new(0,6,0,40),BackgroundColor3=PANEL,BorderSizePixel=0,Parent=mainFrame})
	addCorner(lp,3); addStroke(lp,1,BORDER); bgImg(lp,IMG_LEFT)
	txt(lp,{Text="ROSTER",Size=UDim2.new(0,70,0,18),Position=UDim2.new(0,8,0,5),Font=Enum.Font.GothamBold,TextSize=10,TextColor3=FAINT})

	local selAll=mk("TextButton",{Size=UDim2.new(0,30,0,16),Position=UDim2.new(0,80,0,6),BackgroundColor3=BTN_BASE,BorderSizePixel=0,Text="all",TextColor3=GOLD,Font=Enum.Font.GothamMedium,TextSize=10,AutoButtonColor=false,Parent=lp})
	addCorner(selAll,2); addStroke(selAll,1,BORDER)
	selAll.MouseButton1Click:Connect(function()
		allSelected=true; selectedName=nil; infoLbl.Text="-> ALL PLAYERS"
		for _,ob in ipairs(playerBtns) do ob.BackgroundColor3=Color3.fromRGB(32,24,10); ob.TextColor3=GOLD end
		log("selected: ALL",GOLD)
	end)

	local refBtn=action(lp,"r",UDim2.new(0,20,0,16),UDim2.new(1,-24,0,6)); refBtn.TextColor3=MUTED; refBtn.TextSize=10
	refBtn.MouseButton1Click:Connect(function()
		buildRoster(fallback())
		task.spawn(function() local ok,data=pcall(function() return Remotes.ModMenuData:InvokeServer() end); if ok and data and data.players then buildRoster(data.players) end end)
		log("refreshed")
	end)
	mk("Frame",{Size=UDim2.new(1,-10,0,1),Position=UDim2.new(0,5,0,26),BackgroundColor3=BORDER,BorderSizePixel=0,Parent=lp})
	rosterFrame=mk("ScrollingFrame",{Size=UDim2.new(1,-4,1,-32),Position=UDim2.new(0,2,0,30),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=2,ScrollBarImageColor3=BORDER,CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,Parent=lp})
	mk("UIListLayout",{Padding=UDim.new(0,2),Parent=rosterFrame}); addPad(rosterFrame,2,2)

	local rp=mk("Frame",{Size=UDim2.new(1,-186,1,-46),Position=UDim2.new(0,184,0,40),BackgroundColor3=PANEL,BorderSizePixel=0,Parent=mainFrame})
	addCorner(rp,3); addStroke(rp,1,BORDER); bgImg(rp,IMG_RIGHT)
	infoLbl=txt(rp,{Text="--",Size=UDim2.new(1,-8,0,22),Position=UDim2.new(0,8,0,4),TextColor3=MUTED,TextSize=11})
	mk("Frame",{Size=UDim2.new(1,-10,0,1),Position=UDim2.new(0,5,0,28),BackgroundColor3=BORDER,BorderSizePixel=0,Parent=rp})
	-- Search bar sits in the strip above the command list; cmdFrame drops from y=32 to y=58
	-- and loses the same 26px of height, so the divider/log below it are untouched.
	local searchWrap=mk("Frame",{Size=UDim2.new(1,-6,0,22),Position=UDim2.new(0,3,0,32),BackgroundColor3=INPUT_BG,BorderSizePixel=0,Parent=rp})
	addCorner(searchWrap,2); addStroke(searchWrap,1,BORDER)
	local searchBox=mk("TextBox",{Size=UDim2.new(1,-46,1,0),Position=UDim2.new(0,8,0,0),BackgroundTransparency=1,Text="",PlaceholderText="Search commands...",PlaceholderColor3=MUTED,TextColor3=PARCHM,Font=Enum.Font.Gotham,TextSize=11,TextXAlignment=Enum.TextXAlignment.Left,ClearTextOnFocus=false,ClipsDescendants=true,Parent=searchWrap})
	local searchCount=txt(searchWrap,{Text="",Size=UDim2.new(0,34,1,0),Position=UDim2.new(1,-56,0,0),TextColor3=FAINT,TextSize=10,TextXAlignment=Enum.TextXAlignment.Right})
	local searchClear=mk("TextButton",{Size=UDim2.new(0,18,1,0),Position=UDim2.new(1,-20,0,0),BackgroundTransparency=1,Text="x",TextColor3=MUTED,Font=Enum.Font.GothamBold,TextSize=12,AutoButtonColor=false,Parent=searchWrap})
	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		applyCmdFilter(searchBox.Text)
		if searchBox.Text == "" then
			searchCount.Text = ""
		else
			local n = 0
			for _, c in ipairs(cmdFrame:GetChildren()) do
				if c:IsA("GuiObject") and c.Visible and not c:GetAttribute(SECTION_MARKER) then n += 1 end
			end
			searchCount.Text = tostring(n)
		end
	end)
	searchClear.MouseButton1Click:Connect(function() searchBox.Text="" end)

	-- The Chronicle log stays a fixed 120px strip pinned to the bottom; the command list gets
	-- every pixel of extra height, since that's the part worth enlarging (~130 rows of it).
	-- Offsets below are all measured back from rp's bottom edge, not down from its top.
	cmdFrame=mk("ScrollingFrame",{Name="Cmds",Size=UDim2.new(1,-6,1,-208),Position=UDim2.new(0,3,0,58),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=2,ScrollBarImageColor3=BORDER,CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,Parent=rp})
	mk("Frame",{Size=UDim2.new(1,-10,0,1),Position=UDim2.new(0,5,1,-146),BackgroundColor3=BORDER,BorderSizePixel=0,Parent=rp})
	txt(rp,{Text="CHRONICLE",Size=UDim2.new(1,0,0,14),Position=UDim2.new(0,8,1,-143),Font=Enum.Font.GothamBold,TextSize=9,TextColor3=FAINT})
	logFrame=mk("ScrollingFrame",{Size=UDim2.new(1,-6,0,120),Position=UDim2.new(0,3,1,-127),BackgroundColor3=INPUT_BG,BorderSizePixel=0,ScrollBarThickness=2,ScrollBarImageColor3=BORDER,CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,Parent=rp})
	addCorner(logFrame,2); addStroke(logFrame,1,BORDER); mk("UIListLayout",{SortOrder=Enum.SortOrder.LayoutOrder,Parent=logFrame})

	-- View overlay (overlays the cmdFrame + log area)
	viewOverlay=mk("Frame",{Name="ViewOverlay",Size=UDim2.new(1,-6,1,-32),Position=UDim2.new(0,3,0,32),BackgroundColor3=PANEL,BorderSizePixel=0,Visible=false,ZIndex=8,Parent=rp})
	addCorner(viewOverlay,2); addStroke(viewOverlay,1,BORDER)
	local ovHdr=mk("Frame",{Size=UDim2.new(1,0,0,28),BackgroundColor3=HDR_BG,BorderSizePixel=0,ZIndex=9,Parent=viewOverlay})
	addStroke(ovHdr,1,BORDER)
	viewTitle=txt(ovHdr,{Text="VIEW",Size=UDim2.new(1,-124,1,0),Position=UDim2.new(0,8,0,0),TextColor3=GOLD,Font=Enum.Font.GothamBold,TextSize=13,ZIndex=9})
	-- Pop the current view (logs, lore board, talents, NPC list) into its own draggable
	-- window that survives closing the panel -- mods can keep logs open while working.
	local vpo=action(ovHdr,"pop out",UDim2.new(0,58,0,22),UDim2.new(1,-90,0,3)); vpo.TextSize=10; vpo.ZIndex=9
	vpo.MouseButton1Click:Connect(function()
		if lastViewTitle then
			popOutView(lastViewTitle,lastViewPopulate)
			viewOverlay.Visible=false
		end
	end)
	local vcx=action(ovHdr,"x",UDim2.new(0,24,0,22),UDim2.new(1,-26,0,3),true); vcx.TextSize=10; vcx.ZIndex=9
	vcx.MouseButton1Click:Connect(function() viewOverlay.Visible=false end)
	viewContent=mk("ScrollingFrame",{Name="ViewContent",Size=UDim2.new(1,-4,1,-32),Position=UDim2.new(0,2,0,30),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=2,ScrollBarImageColor3=BORDER,CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=9,Parent=viewOverlay})

	-- Live feed overlay
	liveFeedOverlay=mk("Frame",{Name="LiveFeedOverlay",Size=UDim2.new(1,-6,1,-32),Position=UDim2.new(0,3,0,32),BackgroundColor3=PANEL,BorderSizePixel=0,Visible=false,ZIndex=10,Parent=rp})
	addCorner(liveFeedOverlay,2); addStroke(liveFeedOverlay,1,BORDER)
	local feedHdr=mk("Frame",{Size=UDim2.new(1,0,0,28),BackgroundColor3=HDR_BG,BorderSizePixel=0,ZIndex=11,Parent=liveFeedOverlay})
	addStroke(feedHdr,1,BORDER)
	txt(feedHdr,{Text="LIVE FEED",Size=UDim2.new(0,66,1,0),Position=UDim2.new(0,8,0,0),TextColor3=GOLD,Font=Enum.Font.GothamBold,TextSize=13,ZIndex=11})
	local filterBtn=action(feedHdr,"All",UDim2.new(0,64,0,22),UDim2.new(0,76,0,3)); filterBtn.ZIndex=11; filterBtn.TextSize=10
	filterBtn.MouseButton1Click:Connect(function()
		feedFilterIdx=(feedFilterIdx%#FEED_FILTERS)+1; filterBtn.Text=FEED_FILTERS[feedFilterIdx]
		applyFeedFilter()
	end)
	local clrBtn=action(feedHdr,"clear",UDim2.new(0,42,0,22),UDim2.new(1,-50,0,3)); clrBtn.ZIndex=11
	clrBtn.MouseButton1Click:Connect(function()
		for _,e in ipairs(liveFeedEntries) do if e.Parent then e:Destroy() end end; liveFeedEntries={}
	end)
	local fcx=action(feedHdr,"x",UDim2.new(0,24,0,22),UDim2.new(0,4,0,3),true); fcx.TextSize=10; fcx.ZIndex=11
	fcx.MouseButton1Click:Connect(function() liveFeedOpen=false; liveFeedOverlay.Visible=false; if feedBtn then feedBtn.BackgroundColor3=BTN_BASE end end)
	liveFeedContent=mk("ScrollingFrame",{Name="LiveFeedContent",Size=UDim2.new(1,-4,1,-32),Position=UDim2.new(0,2,0,30),BackgroundTransparency=1,BorderSizePixel=0,ScrollBarThickness=2,ScrollBarImageColor3=BORDER,CanvasSize=UDim2.new(0,0,0,0),AutomaticCanvasSize=Enum.AutomaticSize.Y,ZIndex=11,Parent=liveFeedOverlay})
	mk("UIListLayout",{Padding=UDim.new(0,1),SortOrder=Enum.SortOrder.LayoutOrder,Parent=liveFeedContent})
	-- Auto-scroll-to-bottom detection: only snap to bottom on a new entry if the mod was
	-- ALREADY at the bottom (within 30px) -- preserves scroll position while reading history.
	liveFeedContent:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		local maxScroll = liveFeedContent.AbsoluteCanvasSize.Y - liveFeedContent.AbsoluteWindowSize.Y
		feedScrolledToBottom = (maxScroll - liveFeedContent.CanvasPosition.Y) < 30
	end)
	log("ready"); print("[ModMenuClient] built")
end

function toggleMenu(open)
	-- "Cannot open journal or mod panel" during rage -- the player isn't in control mentally
	-- (design doc PART THREE). Own RageActive is mirrored onto the character as an Attribute
	-- by RageManager, same replication convention as CombatState/Talent_<id>.
	if open then
		local char = player.Character
		if char and char:GetAttribute("RageActive") == true then
			log("cannot open the council panel while raging",Color3.fromRGB(200,72,62))
			return
		end
	end
	menuOpen=open; screenGui.Enabled=open; if not open then if viewOverlay then viewOverlay.Visible=false end; return end
	-- Belt-and-braces: build() runs before the viewport is real, so if the ViewportSize signal
	-- somehow never fired, this is the first moment we're guaranteed a genuine screen size.
	fitPanelToViewport(false)
	allSelected=false; selectedName=nil; infoLbl.Text="--"
	for _,b in ipairs(playerBtns) do b.BackgroundColor3=Color3.fromRGB(16,12,8); b.TextColor3=PARCHM end
	buildCmds(); buildRoster(fallback())
	task.spawn(function() local ok,data=pcall(function() return Remotes.ModMenuData:InvokeServer() end); if ok and data and data.players then buildRoster(data.players) end end)
end

-- notifGui is used by ShowNotification for every player (revive/PDE/etc. messages),
-- so it must build unconditionally. Only the panel itself and its toggle are mod-only.
buildNotifGui()

-- Server is authoritative on mod status (ModMenuData returns nil for non-mods) --
-- was previously built unconditionally, so the toggle button and full panel were
-- visible (though not functional, since every command still checks isMod server-side)
-- to every player.
local isModPlayer = false
do
	local ok, data = pcall(function() return Remotes.ModMenuData:InvokeServer() end)
	isModPlayer = ok and data ~= nil
end

if isModPlayer then
	build()

	local _cg=mk("ScreenGui",{Name="AbyssModToggle",ResetOnSpawn=false,ZIndexBehavior=Enum.ZIndexBehavior.Sibling,IgnoreGuiInset=false,DisplayOrder=0,Parent=pgui})
	local _cb=mk("TextButton",{Size=UDim2.new(0,28,0,18),Position=UDim2.new(0,6,0,6),BackgroundColor3=Color3.fromRGB(17,13,8),BorderSizePixel=0,Text="*",TextColor3=GOLD,Font=Enum.Font.GothamBold,TextSize=14,AutoButtonColor=false,Parent=_cg})
	addCorner(_cb,2); addStroke(_cb,1,BORDER)
	_cb.MouseButton1Click:Connect(function() toggleMenu(not menuOpen) end)

	UIS.InputBegan:Connect(function(input,gpe)
		if input.KeyCode==Enum.KeyCode.RightBracket then toggleMenu(not menuOpen) end
		-- V opens the Player Info Viewer on whoever the mod is looking at, falling back to the
		-- currently selected roster entry. Suppressed while typing in a panel field (gpe), or
		-- pressing V to type a word would fire this from any TextBox.
		if input.KeyCode==Enum.KeyCode.V and not gpe then
			local target=nil
			local hit=mouse and mouse.Target
			if hit then
				local model=hit:FindFirstAncestorOfClass("Model")
				local hovered=model and Players:GetPlayerFromCharacter(model)
				if hovered then target=hovered.Name end
			end
			target=target or selectedName
			if target then openPlayerInfoViewer(target)
			else log("V: no player under cursor and none selected",Color3.fromRGB(195,72,62)) end
		end
	end)
end

Remotes.ModCommand.OnClientEvent:Connect(function(ok,msg)
	if msg then log(tostring(msg),ok and Color3.fromRGB(138,195,128) or Color3.fromRGB(200,72,62)) end
end)

do
	local rageDebuffRE=RepStorage:WaitForChild("RemoteEvents",10)
	rageDebuffRE=rageDebuffRE and rageDebuffRE:WaitForChild("RageDebuffPrompt",5)
	if rageDebuffRE then
		rageDebuffRE.OnClientEvent:Connect(function(payload)
			if not payload then return end
			log("[RAGE] "..tostring(payload.charName).." entered rage -- assign an exit debuff (RAGE MANAGEMENT)",Color3.fromRGB(200,72,62))
		end)
	end
end

local remF=RepStorage:WaitForChild("RemoteEvents",10)
if remF then
	local flyAck=remF:WaitForChild("ModFlyToggle",5)
	if flyAck then
		flyAck.OnClientEvent:Connect(function()
			if flying then stopFly(); log("fly OFF",MUTED) else startFly(); log("fly ON",Color3.fromRGB(100,160,220)) end
		end)
	end
	local nRE=remF:WaitForChild("ShowNotification",5)
	if nRE then nRE.OnClientEvent:Connect(showNotification) end
	local pdSnd=remF:WaitForChild("PDSoundEvent",5)
	if pdSnd then
		pdSnd.OnClientEvent:Connect(function(stage)
			-- PLACEHOLDER_SOUND: PDStageSound -- replace with actual atmospheric PD sound per stage
			local ss=game:GetService("SoundService"); local snd=Instance.new("Sound")
			snd.SoundId="rbxassetid://0"; snd.Volume=1; snd.RollOffMaxDistance=0; snd.Parent=ss; snd:Play()
			game:GetService("Debris"):AddItem(snd,10)
		end)
	end
end

-- Live feed handler
if Remotes.LiveFeedUpdate then
	Remotes.LiveFeedUpdate.OnClientEvent:Connect(function(entry)
		if not liveFeedContent then return end
		local typeStr=tostring(entry.type or "?")
		local col=FEED_COLORS[typeStr] or Color3.fromRGB(140,140,140)
		local ts=string.format("%02d:%02d",entry.h or 0,entry.m or 0)
		local zone=tostring(entry.zone or "?")
		local charName=tostring(entry.charName or "?")
		local msg=tostring(entry.message or "")
		local line=string.format("[%s][%s][%s] %s: %s",ts,typeStr,zone,charName,msg)
		local lbl=mk("TextLabel",{Size=UDim2.new(1,-6,0,13),BackgroundTransparency=1,Text="  "..line,TextColor3=col,Font=Enum.Font.Code,TextSize=10,TextXAlignment=Enum.TextXAlignment.Left,TextTruncate=Enum.TextTruncate.AtEnd,ClipsDescendants=true,LayoutOrder=#liveFeedEntries+1,ZIndex=12,Parent=liveFeedContent})
		lbl:SetAttribute("FeedType",typeStr)
		local want=FEED_FILTERS[feedFilterIdx]
		lbl.Visible = (want=="All") or (typeStr==want)
		table.insert(liveFeedEntries,lbl)
		-- Cap at 200 visible entries (spec) -- full history still lives in Discord + the
		-- server-side chat DataStore log (ChatManager's own AbyssChatLog_v1), this is only
		-- the mod panel's live render buffer.
		if #liveFeedEntries>200 then
			liveFeedEntries[1]:Destroy(); table.remove(liveFeedEntries,1)
			for i,v in ipairs(liveFeedEntries) do v.LayoutOrder=i end
		end
		if liveFeedOpen and feedScrolledToBottom then
			task.defer(function() if liveFeedContent then liveFeedContent.CanvasPosition=Vector2.new(0,math.huge) end end)
		end
	end)
end
print("[ModMenuClient] ready")
