-- ChatManager
-- Intercepts all player chat server-side, routes by command type,
-- applies language garbling (if LanguageManager exists), fires display remotes.
-- Commands: /a (action), /t (thought), /w (whisper 20s), /s (shout 60s), plain (quoted)

if _G._ChatManagerInit then return else _G._ChatManagerInit = true end

local Players            = game:GetService("Players")
local RepStorage         = game:GetService("ReplicatedStorage")
local DataStoreService   = game:GetService("DataStoreService")

local Remotes = require(RepStorage.Shared.RemoteEvents)

local chatEventRE      = Remotes.ChatEvent
local shoutBroadcastRE = Remotes.ShoutBroadcast
local thoughtNotifRE   = Remotes.ThoughtNotif
local liveFeedRE       = Remotes.LiveFeedUpdate
local broadcastMsgRE   = Remotes.BroadcastMsg
local modBroadcastRE   = Remotes.ModBroadcast
local sendChatMsgRE    = Remotes.SendChatMessage
local chatBubbleRE     = Remotes.ChatBubble

local Config       = require(RepStorage.Shared.Config)
local OWNERS       = Config.Owners
local MOD_GROUP_ID = 3015509993
local MOD_RANK_MIN = 200

local function isMod(p)
	if table.find(OWNERS, p.Name) then return true end
	local ok, rank = pcall(function() return p:GetRankInGroup(MOD_GROUP_ID) end)
	return ok and rank >= MOD_RANK_MIN
end

local function getCharName(player)
	local dm = _G.DataManager
	if dm then
		local fn = dm.getValue(player, "FirstName") or ""
		local ln = dm.getValue(player, "FamilyName") or ""
		if #fn > 0 then return (#ln > 0) and (fn .. " " .. ln) or fn end
	end
	return player.Name
end

local function getPlayerZone(player)
	local zm = _G.ZoneManager
	if zm and zm.getPlayerZone then return zm.getPlayerZone(player) or "Unknown" end
	return "Unknown"
end

-- Insanity's "chat text occasionally distorts" hallucination -- like language garbling but
-- temporary and per-receiver (the RECEIVER's insanity, not the sender's, since this is
-- something the afflicted player perceives, not something they broadcast).
local GLITCH_CHARS = {"#","%","~","?","$"}
local function distortForInsanity(text)
	local out = {}
	for i = 1, #text do
		local c = text:sub(i,i)
		if c ~= " " and math.random() < 0.3 then
			c = GLITCH_CHARS[math.random(#GLITCH_CHARS)]
		end
		out[i] = c
	end
	return table.concat(out)
end

local function applyLanguage(text, sender, receiver)
	local lm = _G.LanguageManager
	if lm and lm.process then text = lm.process(text, sender, receiver) end
	local im = _G.InjuryManager
	if im and receiver and im.isInsane(receiver) then
		local inj = im.getInjury(receiver, "Insanity")
		local scale = (inj and inj.severity or 0) / 100
		if math.random() < (0.10 * scale) then -- matches Config.InsanityHallucinations.ChatDistortion.chance
			text = distortForInsanity(text)
		end
	end
	return text
end

local function getPlayersInRange(sender, range)
	local sHRP = sender.Character and sender.Character:FindFirstChild("HumanoidRootPart")
	if not sHRP then return {} end
	local out = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p ~= sender and p.Character then
			local hrp = p.Character:FindFirstChild("HumanoidRootPart")
			if hrp and (hrp.Position - sHRP.Position).Magnitude <= range then
				table.insert(out, p)
			end
		end
	end
	return out
end

local C = {
	CHAT      = Color3.fromRGB( 20,  20,  20),
	ACTION    = Color3.fromRGB(201, 168,  76),
	WHISPER   = Color3.fromRGB( 20,  20,  20),
	THOUGHT   = Color3.fromRGB(155,  89, 182),
	SHOUT     = Color3.fromRGB(163,  21,  21),
	INTRODUCE = Color3.fromRGB(200, 184, 154),
}

local chatLogStore = DataStoreService:GetDataStore("AbyssChatLog_v1")
local SESSION_KEY  = "ChatLog_" .. tostring(math.floor(os.time() / 300) * 300)
local logBuffer    = {}

local function pushFeed(type, charName, zone, message)
	local ts = os.date("*t")
	local entry = { type=type, charName=charName, zone=zone, message=message,
	                h=ts.hour, m=ts.min }
	for _, p in ipairs(Players:GetPlayers()) do
		if isMod(p) then liveFeedRE:FireClient(p, entry) end
	end
end

local function writeLog(type, charName, zone, message, userId)
	local entry = { timestamp=os.time(), type=type, charName=charName,
	                zone=zone, message=message, userId=userId }
	table.insert(logBuffer, entry)
	if #logBuffer >= 20 then
		local buf = logBuffer; logBuffer = {}
		task.spawn(function()
			pcall(function()
				chatLogStore:UpdateAsync(SESSION_KEY, function(existing)
					local log = existing or {}
					for _, e in ipairs(buf) do table.insert(log, e) end
					if #log > 2000 then
						local t = {}
						for i = #log-1999, #log do t[#t+1]=log[i] end
						return t
					end
					return log
				end)
			end)
		end)
	end
end

local function handleRegular(sender, rawMsg)
	local charName = getCharName(sender)
	local zone     = getPlayerZone(sender)
	local display  = '"' .. rawMsg .. '"'
	for _, p in ipairs(Players:GetPlayers()) do
		chatBubbleRE:FireClient(p, sender.Name, applyLanguage(display, sender, p), C.CHAT, 5)
	end
	pushFeed("CHAT", charName, zone, rawMsg)
	writeLog("CHAT", charName, zone, rawMsg, sender.UserId)
end

local function handleAction(sender, text)
	local charName = getCharName(sender)
	local zone     = getPlayerZone(sender)
	local display  = "[Action] " .. text
	for _, p in ipairs(Players:GetPlayers()) do
		chatBubbleRE:FireClient(p, sender.Name, display, C.ACTION, 7)
	end
	-- Actions now raise the same persistent mod-facing panel thoughts do (5th arg tags the
	-- kind so ChatClient styles/labels it [ACTION] instead of [THOUGHT]).
	for _, p in ipairs(Players:GetPlayers()) do
		if isMod(p) then thoughtNotifRE:FireClient(p, charName, zone, text, sender.Name, "ACTION") end
	end
	pushFeed("ACTION", charName, zone, text)
	writeLog("ACTION", charName, zone, text, sender.UserId)
end

local function handleThought(sender, text)
	local charName = getCharName(sender)
	local zone     = getPlayerZone(sender)
	chatBubbleRE:FireClient(sender, sender.Name, "{Thought} " .. text, C.THOUGHT, 6)
	for _, p in ipairs(Players:GetPlayers()) do
		if isMod(p) then thoughtNotifRE:FireClient(p, charName, zone, text, sender.Name) end
	end
	pushFeed("THOUGHT", charName, zone, text)
	writeLog("THOUGHT", charName, zone, text, sender.UserId)
end

local function handleWhisper(sender, text)
	local charName = getCharName(sender)
	local zone     = getPlayerZone(sender)
	local tag      = "[Whispers] "
	chatBubbleRE:FireClient(sender, sender.Name, tag..text, C.WHISPER, 4)
	for _, p in ipairs(getPlayersInRange(sender, 20)) do
		chatBubbleRE:FireClient(p, sender.Name, applyLanguage(tag..text, sender, p), C.WHISPER, 4)
	end
	pushFeed("WHISPER", charName, zone, text)
	writeLog("WHISPER", charName, zone, text, sender.UserId)
end

local function handleIntroduce(sender, full)
	local dm = _G.DataManager
	local im = _G.IdentityManager
	local fn = (dm and dm.getValue(sender, "FirstName")) or sender.Name
	local ln = (dm and dm.getValue(sender, "FamilyName")) or ""
	local recipients = getPlayersInRange(sender, 20)

	for _, p in ipairs(recipients) do
		if im then im.learnName(p, sender, full) end
	end

	local displayText = full and ("I am " .. fn .. ((#ln > 0) and (" " .. ln) or "") .. ".")
		or ("I am " .. fn .. ".")
	for _, p in ipairs(recipients) do
		chatBubbleRE:FireClient(p, sender.Name, displayText, C.INTRODUCE, 6, true)
	end

	local zone = getPlayerZone(sender)
	local tag  = full and "INTRODUCE FULL" or "INTRODUCE"
	local note = string.format("-> revealed %s name to %d player%s nearby",
		full and "full" or "first", #recipients, (#recipients == 1) and "" or "s")
	pushFeed(tag, fn, zone, note)
	writeLog(tag, fn, zone, displayText, sender.UserId)
	local disc = _G.DiscordManager
	if disc and disc.logModAction then disc.logModAction(sender, tag, note) end
end

local function handleSubmitRitual(sender)
	local rm = _G.RitualManager; if not rm then return end
	local ok, err = rm.trySubmitNearest(sender)
	if not ok then
		chatEventRE:FireClient(sender, "SYSTEM", "Server", "", tostring(err), Color3.fromRGB(180,60,60))
	end
end

-- Data wipe (design doc PART ONE) -- owner-only, requires the exact confirm phrase typed
-- in chat so it can never fire by accident. See DataManager.wipeAll for what actually
-- happens (DataStore version bump, not a destructive delete -- old data stays recoverable).
local function handleWipeAll(sender)
	if not table.find(OWNERS, sender.Name) then
		chatEventRE:FireClient(sender, "SYSTEM", "Server", "", "[Permission denied]", Color3.fromRGB(180,60,60))
		return
	end
	local dm = _G.DataManager
	if not dm or not dm.wipeAll then
		chatEventRE:FireClient(sender, "SYSTEM", "Server", "", "[DataManager not ready]", Color3.fromRGB(180,60,60))
		return
	end
	local ok, msg = dm.wipeAll(sender)
	chatEventRE:FireClient(sender, "SYSTEM", "Server", "", "["..tostring(msg).."]", ok and Color3.fromRGB(138,195,128) or Color3.fromRGB(180,60,60))
	pushFeed("MOD_ACTION", getCharName(sender), getPlayerZone(sender), "ran /wipeall: "..tostring(msg))
	writeLog("MOD_ACTION", getCharName(sender), getPlayerZone(sender), "/wipeall: "..tostring(msg), sender.UserId)
end

local function handleOutfit(sender)
	local dm = _G.DataManager
	local im = _G.IdentityManager
	if not dm or not im then return end
	local active  = dm.getValue(sender, "ActiveOutfitSlot") or 1
	local newSlot = (active == 1) and 2 or 1
	local outfit  = dm.getValue(sender, newSlot == 2 and "OutfitSlot2" or "OutfitSlot1")
	if newSlot == 2 and not outfit then
		chatEventRE:FireClient(sender, "SYSTEM", "Server", "",
			"Your second outfit has not been set.", Color3.fromRGB(180,60,60))
		return
	end
	dm.setValue(sender, "ActiveOutfitSlot", newSlot)
	local char = sender.Character
	if char then im.applyAppearance(sender, char) end
	local charName = getCharName(sender)
	local zone     = getPlayerZone(sender)
	local note     = "switched to outfit slot " .. newSlot
	pushFeed("OUTFIT", charName, zone, note)
	writeLog("OUTFIT", charName, zone, note, sender.UserId)
end

local function handleShout(sender, text)
	local charName = getCharName(sender)
	local zone     = getPlayerZone(sender)
	local tag      = "[Shouts] "
	local broadMsg = charName .. " shouts: " .. text
	chatBubbleRE:FireClient(sender, sender.Name, tag..text, C.SHOUT, 5)
	for _, p in ipairs(getPlayersInRange(sender, 60)) do
		chatBubbleRE:FireClient(p, sender.Name, applyLanguage(tag..text, sender, p), C.SHOUT, 5)
		shoutBroadcastRE:FireClient(p, applyLanguage(broadMsg, sender, p))
	end
	pushFeed("SHOUT", charName, zone, text)
	writeLog("SHOUT", charName, zone, text, sender.UserId)
end

-- Slur list — blocked regardless of context. Regular swearing is allowed.
local BLOCKED = {
	"nigger","nigga","faggot","chink","spic","kike","wetback","gook",
	"beaner","coon","jigaboo","sambo","raghead","towelhead","zipperhead",
	"retard","tranny","shemale","cracker","honky",
}

local function normalizeForFilter(text)
	local s = text:lower()
	s = s:gsub("1","i"):gsub("0","o"):gsub("3","e"):gsub("4","a"):gsub("5","s")
	s = s:gsub("@","a"):gsub("%$","s"):gsub("!","i")
	s = s:gsub("[^%a]"," ")
	return " " .. s .. " "
end

local function containsSlur(text)
	local norm = normalizeForFilter(text)
	for _, slur in ipairs(BLOCKED) do
		if norm:find(" " .. slur .. " ", 1, true) then return true end
	end
	return false
end

local chatCooldowns = {}
local CHAT_COOLDOWN = 0.7

-- /decree -- the King's server-wide proclamation (Config.KingTitle's CommandAuthority perk).
-- Rate limited on its own timer, separate from normal chat: a decree is meant to be rare and
-- weighty, and an unlimited server-wide banner would just be a spam tool.
local decreeCooldowns = {}
local function handleDecree(sender, text)
	local cm = _G.CasteManager
	if not cm or not cm.hasTitle(sender, "King") then
		chatEventRE:FireClient(sender, "SYSTEM", "Server", "", "[You are not the King.]", Color3.fromRGB(180,60,60))
		return
	end
	text = text:match("^%s*(.-)%s*$") or ""
	if #text == 0 then
		chatEventRE:FireClient(sender, "SYSTEM", "Server", "", "[Usage: /decree <message>]", Color3.fromRGB(180,60,60))
		return
	end
	local cd = (Config.KingTitle and Config.KingTitle.DecreeCooldown) or 300
	local nextAt = decreeCooldowns[sender.UserId] or 0
	if os.clock() < nextAt then
		chatEventRE:FireClient(sender, "SYSTEM", "Server", "",
			"[The crown has spoken recently. Wait " .. math.ceil(nextAt - os.clock()) .. "s.]", Color3.fromRGB(180,60,60))
		return
	end
	decreeCooldowns[sender.UserId] = os.clock() + cd

	local charName = getCharName(sender)
	broadcastMsgRE:FireAllClients("BY DECREE OF KING " .. string.upper(charName) .. ": " .. text)
	pushFeed("BROADCAST", charName, "-", "[DECREE] " .. text)
	writeLog("BROADCAST", charName, "-", "[DECREE] " .. text, sender.UserId)
	local disc = _G.DiscordManager
	if disc and disc.logDNA then disc.logDNA(charName, "issued a royal decree: " .. text) end
end

sendChatMsgRE.OnServerEvent:Connect(function(sender, msg)
	if type(msg) ~= "string" then return end
	msg = msg:match("^%s*(.-)%s*$") or ""
	if #msg == 0 or #msg > 200 then return end

	local uid = sender.UserId
	local now = os.clock()
	if (chatCooldowns[uid] or 0) + CHAT_COOLDOWN > now then return end
	chatCooldowns[uid] = now

	if containsSlur(msg) then
		chatEventRE:FireClient(sender, "SYSTEM", "Server", "",
			"[Message blocked]", Color3.fromRGB(180,60,60))
		return
	end

	if     msg:sub(1,3) == "/a " then handleAction(sender, msg:sub(4))
	elseif msg:sub(1,3) == "/t " then handleThought(sender, msg:sub(4))
	elseif msg:sub(1,3) == "/w " then handleWhisper(sender, msg:sub(4))
	elseif msg:sub(1,3) == "/s " then handleShout(sender, msg:sub(4))
	elseif msg:lower() == "/introduce full" then handleIntroduce(sender, true)
	elseif msg == "/introduce"   then handleIntroduce(sender, false)
	elseif msg == "/outfit"      then handleOutfit(sender)
	elseif msg == "/submitritual" then handleSubmitRitual(sender)
	elseif msg:lower() == "/wipeall confirm delete everything" then handleWipeAll(sender)
	elseif msg:lower() == "/shadowbox" or msg:lower() == "/spar" then
		local sb = _G.ShadowBoxManager
		if sb then sb.startPractice(sender) end
	elseif msg:lower() == "/shadowbox stop" or msg:lower() == "/spar stop" then
		local sb = _G.ShadowBoxManager
		if sb then sb.stopPractice(sender, "manual") end
	elseif msg:sub(1,11):lower() == "/dropcoins " then
		local tm = _G.TradeManager
		if tm then
			local currencyType, amountStr = msg:sub(12):match("^(%a+)%s+(%d+)$")
			if currencyType then
				local ok, err = tm.dropCoins(sender, currencyType, tonumber(amountStr))
				if not ok then
					chatEventRE:FireClient(sender, "SYSTEM", "Server", "", "["..tostring(err).."]", Color3.fromRGB(180,60,60))
				end
			else
				chatEventRE:FireClient(sender, "SYSTEM", "Server", "", "[Usage: /dropcoins <Obol|Drachma|Stater|RoyalStater> <amount>]", Color3.fromRGB(180,60,60))
			end
		end
	elseif msg:sub(1,8):lower() == "/decree " then handleDecree(sender, msg:sub(9))
	elseif msg:sub(1,1) ~= "/"   then handleRegular(sender, msg)
	end
end)

Players.PlayerRemoving:Connect(function(p) chatCooldowns[p.UserId] = nil end)

modBroadcastRE.OnServerEvent:Connect(function(sender, targetName, message)
	if not isMod(sender) then return end
	if type(message) ~= "string" or #message == 0 then return end
	local charName = getCharName(sender)
	local target   = targetName and Players:FindFirstChild(tostring(targetName))
	if target then broadcastMsgRE:FireClient(target, message)
	else           broadcastMsgRE:FireAllClients(message) end
	local dest = target and target.Name or "ALL"
	pushFeed("BROADCAST", charName, "—", "→ " .. dest .. ": " .. message)
	writeLog("BROADCAST", charName, "—", "→ "..dest..": "..message, sender.UserId)
end)

game:BindToClose(function()
	if #logBuffer > 0 then
		local buf = logBuffer; logBuffer = {}
		pcall(function()
			chatLogStore:UpdateAsync(SESSION_KEY, function(existing)
				local log = existing or {}
				for _, e in ipairs(buf) do table.insert(log, e) end
				return log
			end)
		end)
	end
end)

print("[ChatManager] Init — /a /t /w(20s) /s(60s) + quoted regular chat hooked")