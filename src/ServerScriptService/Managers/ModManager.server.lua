-- ModManager
local Players    = game:GetService("Players")
local RepStorage = game:GetService("ReplicatedStorage")
local Config     = require(RepStorage:WaitForChild("Shared"):WaitForChild("Config"))

local OWNERS       = require(RepStorage.Shared.Config).Owners
local MOD_GROUP_ID = 3015509993
local MOD_RANK_MIN = 200
-- Lore Team is a smaller, higher-trust subset of mods (design doc: "for less notifications
-- make it lore team only") -- same group, just a higher rank threshold, so promoting someone
-- to Lore Team is just a rank change in the existing mod group rather than a whole new one.
-- Owners always qualify, same as isMod.
local LORE_RANK_MIN = 240

local function getOrCreate(name, isFunc)
	local folder = RepStorage:FindFirstChild("RemoteEvents") or (function()
		local f=Instance.new("Folder"); f.Name="RemoteEvents"; f.Parent=RepStorage; return f
	end)()
	local r=folder:FindFirstChild(name); if r then return r end
	r=Instance.new(isFunc and "RemoteFunction" or "RemoteEvent"); r.Name=name; r.Parent=folder; return r
end

local modCommandRE  = getOrCreate("ModCommand")
local modMenuDataRF = getOrCreate("ModMenuData", true)
local notifRE       = getOrCreate("ShowNotification")
local pdSndRE       = getOrCreate("PDSoundEvent")
local flyAckRE      = getOrCreate("ModFlyToggle")
local reqFlyRE        = getOrCreate("RequestModFly")
local modSelfEffectRE = getOrCreate("ModSelfEffect")
local modTargetEffectRE = getOrCreate("ModTargetEffect")
local modFullLogRF    = getOrCreate("ModFullLog", true)
local modPlayerTalsRF = getOrCreate("ModPlayerTalents", true)
local modLoreBoardRF  = getOrCreate("ModLoreBoard", true)
local loreTeamMsgRE   = getOrCreate("LoreTeamMessage") -- server -> all clients: {title, subtitle} (design doc: new lore-team-only broadcast banner)
_G._notifRE = notifRE

local serverLocked     = false
local frozenPlayers    = {}
local invisiblePlayers = {}
local invinciblePlayers= {} -- godmode: real server-side damage immunity, not just the client's cosmetic HP-snap-back
local loreBoard        = {}
local RACE_MAP    = {human="Human",vampire="Vampire",dwarf="Dwarf",apostle="Apostle",godhand="GodHand"}
local RELATION_MAP= {brother="Brother",sister="Sister",twin="Twin",cousin="Cousin",distantrelative="DistantRelative",none="None"}

local function applyFreeze(target)
	local char=target.Character; if not char then return end
	local hrp=char:FindFirstChild("HumanoidRootPart"); if not hrp then return end
	hrp.Anchored=true
	local hum=char:FindFirstChildOfClass("Humanoid")
	if hum then hum.WalkSpeed=0; hum.JumpHeight=0 end
end

local function isOwner(p) return table.find(OWNERS, p.Name) ~= nil end
local function isMod(p)
	if isOwner(p) then return true end
	local ok,rank=pcall(function() return p:GetRankInGroup(MOD_GROUP_ID) end)
	return ok and rank >= MOD_RANK_MIN
end
local function isLoreTeam(p)
	if isOwner(p) then return true end
	local ok,rank=pcall(function() return p:GetRankInGroup(MOD_GROUP_ID) end)
	return ok and rank >= LORE_RANK_MIN
end

local cooldowns = {}
local function checkRateLimit(p, cd)
	local uid=p.UserId; cooldowns[uid]=cooldowns[uid] or {}
	local last=cooldowns[uid]["ModCommand"] or 0
	if tick()-last < cd then return false end
	cooldowns[uid]["ModCommand"]=tick(); return true
end

local actionLog = {}
local function logAction(exec, cmd, result)
	local e={timestamp=os.time(),executer=exec and exec.Name or "SYSTEM",command=cmd,result=tostring(result)}
	table.insert(actionLog,e); if #actionLog>200 then table.remove(actionLog,1) end
	print(string.format("[ModManager] %s -> %s: %s",e.executer,cmd,e.result))
	local disc=_G.DiscordManager; if disc then disc.logModAction(exec,cmd,result) end
end

local STAGE_NAMES={[0]="Inert",[1]="Awakened",[2]="Scarred",[3]="Burning",[4]="Condemned",[5]="The Abyss"}

-- tier: "lesser" (small corner toast) vs "big" (full-screen centered card). When omitted
-- the client decides by style: pd/lore stay big (lore systems keep the big treatment),
-- everything else renders as a lesser toast (design doc: "when we have lesser broadcasts
-- don't put the bigger one").
local function fireNotif(target, title, body, duration, style, tier)
	local d={title=title,body=body,duration=duration or 5,style=style or "info",tier=tier}
	if target then notifRE:FireClient(target,d) else notifRE:FireAllClients(d) end
end

-- Never surface a player's raw Roblox account name in immersive/lore-flavored broadcast
-- text -- fall back to a generic label if they haven't set an in-game FirstName yet.
-- (IdentityManager sets this during normal character creation; only test/Studio
-- characters that skipped that flow would otherwise leak the bare account name.)
local function firstNameOr(player, fallback)
	local dm=_G.DataManager; local fn=(dm and dm.getValue(player,"FirstName")) or ""
	return (#fn>0) and fn or fallback
end

local commands = {}

commands.reviveDowned = function(exec, target)
	assert(target,"target player required")
	local cm = _G.CombatManager; assert(cm,"CombatManager not ready")
	local cs = cm.getCombatState(target)
	assert(cs=="Downed","target is not currently Downed (use drop first if BeingCarried)")
	cm.setCombatState(target,"Idle")
	cm.setSpeed(target,1)
	cm.clearHitstun(target)
	cm.removeBloodPool(target)
	local char = target.Character
	if char then
		local rm=_G.RagdollManager; if rm then rm.unragdoll(char) end
		local hum=char:FindFirstChildOfClass("Humanoid")
		if hum then hum.Health=hum.MaxHealth; hum.WalkSpeed=16; hum.JumpPower=50; hum.PlatformStand=false end
	end
	fireNotif(target,"Revived","You have been revived by the lore team.",6,"info")
end

commands.checkBloodBar = function(exec, target)
	assert(target,"target player required")
	local bm = _G.BleedManager; assert(bm,"BleedManager not ready")
	local val = bm.getBloodBar(target)
	local stacks = bm.getActiveBleedCount(target)
	fireNotif(exec,"Blood Bar",target.Name..": "..math.floor(val).."/100 ("..stacks.." active bleed(s))",6,"info")
end

commands.clearBleeds = function(exec, target)
	assert(target,"target player required")
	local bm = _G.BleedManager; assert(bm,"BleedManager not ready")
	bm.ClearBleeds(target)
	fireNotif(exec,"Bleeds Cleared",target.Name.."'s active bleeds were cleared.",5,"info")
end

commands.setStage = function(exec, target, stage)
	assert(target,"target player required"); assert(_G.LoreManager,"LoreManager not ready")
	local s=assert(tonumber(stage),"stage must be number")
	_G.LoreManager.setStage(target, s)
	local label=firstNameOr(target,"An unnamed soul")
	fireNotif(nil,"The Eclipse Stirs",label.." — Stage "..s.." ("..(STAGE_NAMES[s] or "?")..")",10,"pd")
	pdSndRE:FireAllClients(s)
end

commands.escalateStage = function(exec, target)
	assert(target,"target player required"); assert(_G.LoreManager,"LoreManager not ready")
	local next=_G.LoreManager.escalateStage(target)
	local label=firstNameOr(target,"An unnamed soul")
	fireNotif(nil,"The Eclipse Stirs",label.." — Stage "..(next or "?").." ("..(STAGE_NAMES[next] or "?")..")",10,"pd")
	pdSndRE:FireAllClients(next or 0)
end

-- Global, not per-player: turning Permanent Death on/off is a whole-server switch (see
-- LoreManager.activatePDE/deactivatePDE) -- every player at Stage 3+ is affected, not just
-- one target. The activation cinematic (screen darken + letter-reveal message) fires from
-- LoreManager itself via PDGlobalAnnounce, not from here.
commands.activatePDE = function(exec, _)
	assert(_G.LoreManager,"LoreManager not ready")
	_G.LoreManager.activatePDE()
end

commands.deactivatePDE = function(exec, _)
	assert(_G.LoreManager,"LoreManager not ready")
	_G.LoreManager.deactivatePDE()
	fireNotif(nil,"Reprieve","Permanent death has receded... for now.",8,"pd")
end

commands.grantTalent = function(exec, target, talentName)
	assert(target,"target player required"); assert(type(talentName)=="string" and #talentName>0,"talent name required")
	assert(_G.TalentManager,"TalentManager not ready"); _G.TalentManager.assignTalent(target,talentName)
end

commands.revokeTalent = function(exec, target, talentName)
	assert(target,"target player required"); assert(type(talentName)=="string" and #talentName>0,"talent name required")
	assert(_G.TalentManager,"TalentManager not ready"); _G.TalentManager.revokeTalent(target,talentName)
end
commands.listTalentIds = function(exec)
	local tm=assert(_G.TalentManager,"TalentManager not ready")
	local ids=tm.getAllTalentIds()
	fireNotif(exec,"All Talent IDs ("..#ids..")",table.concat(ids,", "),12,"info")
end

commands.setWeather = function(exec, _, wt, dur)
	assert(type(wt)=="string","weatherType required"); assert(_G.WeatherManager,"WeatherManager not ready")
	_G.WeatherManager.setWeather(wt, dur and tonumber(dur) or nil)
end
commands.clearWeather = function(exec,_) assert(_G.WeatherManager,"WeatherManager not ready"); _G.WeatherManager.clearWeather() end
commands.setClockTime = function(exec,_,t) assert(_G.WeatherManager,"WeatherManager not ready"); _G.WeatherManager.setClockTime(assert(tonumber(t),"time must be number")) end
commands.strikeLightning = function(exec,_,x,y,z)
	assert(_G.WeatherManager,"WeatherManager not ready")
	local px,py,pz = tonumber(x),tonumber(y),tonumber(z)
	if px and py and pz then
		_G.WeatherManager.triggerLightningStrike(Vector3.new(px,py,pz))
	else
		_G.WeatherManager.triggerLightningStrike()
	end
end
commands.strikeLightningPlayer = function(exec,target)
	assert(target,"target player required"); assert(_G.WeatherManager,"WeatherManager not ready")
	local char = target.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	assert(hrp,"target has no character")
	_G.WeatherManager.triggerLightningStrike(hrp.Position)
end
commands.forceFrostStacks = function(exec,target,amount)
	assert(target,"target player required"); assert(_G.WeatherManager,"WeatherManager not ready")
	local v = assert(tonumber(amount),"amount must be number")
	_G.WeatherManager.forceFrostStacks(target, v)
end
commands.clearFrostStacks = function(exec,target)
	assert(target,"target player required"); assert(_G.WeatherManager,"WeatherManager not ready")
	_G.WeatherManager.clearFrostStacks(target)
end
commands.setClothing = function(exec,target,tier)
	assert(target,"target player required")
	local valid={None=true,LightCloth=true,Fur=true,HeavyFur=true}
	assert(valid[tier],"tier must be: None LightCloth Fur HeavyFur")
	local dm=assert(_G.DataManager,"DataManager not ready"); dm.setValue(target,"EquippedClothing",tier)
	if _G.WeatherManager then _G.WeatherManager.syncMitigation(target) end
end
commands.setFaceGear = function(exec,target,tier)
	assert(target,"target player required")
	local valid={None=true,LightCloth=true,Mask=true,FullFaceCloth=true}
	assert(valid[tier],"tier must be: None LightCloth Mask FullFaceCloth")
	local dm=assert(_G.DataManager,"DataManager not ready"); dm.setValue(target,"EquippedFaceGear",tier)
	if _G.WeatherManager then _G.WeatherManager.syncMitigation(target) end
end

commands.lockZone = function(exec,_,zoneName)
	assert(type(zoneName)=="string" and #zoneName>0,"zoneName required"); assert(_G.ZoneManager,"ZoneManager not ready")
	assert(_G.ZoneManager.setZoneLocked(zoneName,true),"Zone not found: "..zoneName)
end
commands.unlockZone = function(exec,_,zoneName)
	assert(type(zoneName)=="string" and #zoneName>0,"zoneName required"); assert(_G.ZoneManager,"ZoneManager not ready")
	assert(_G.ZoneManager.setZoneLocked(zoneName,false),"Zone not found: "..zoneName)
end

commands.setHunger = function(exec,target,amount)
	assert(target,"target player required"); local v=assert(tonumber(amount),"amount must be number")
	assert(v>=0 and v<=100,"hunger 0-100"); assert(_G.DataManager,"DataManager not ready")
	_G.DataManager.setValue(target,"Hunger",v)
end
commands.setWater = function(exec,target,amount)
	assert(target,"target player required"); local v=assert(tonumber(amount),"amount must be number")
	assert(v>=0 and v<=100,"water 0-100"); assert(_G.DataManager,"DataManager not ready")
	_G.DataManager.setValue(target,"Water",v)
end
commands.setTitle = function(exec,target,title)
	assert(target,"target player required"); assert(type(title)=="string" and #title>0,"title required")
	assert(_G.DataManager,"DataManager not ready"); _G.DataManager.setValue(target,"Title",title)
end
commands.setFightingStyle = function(exec,target,style)
	assert(target,"target player required")
	local valid={None=true,Ironwall=true,Duelist=true,Berserker=true,Unarmed=true,Spear=true,Dagger=true}
	assert(valid[style],"style must be: None Ironwall Duelist Berserker Unarmed Spear Dagger")
	local dm=assert(_G.DataManager,"DataManager not ready"); dm.setValue(target,"FightingStyle",style)
end
-- IDENTITY / APPEARANCE
commands.setFirstName = function(exec,target,name)
	assert(target,"target player required"); assert(type(name)=="string" and #name>0,"name required")
	local dm=assert(_G.DataManager,"DataManager not ready"); dm.setValue(target,"FirstName",name)
	local im=_G.IdentityManager
	if im then
		if target.Character then im.applyAppearance(target,target.Character) end
		im.refreshKnownObservers(target)
	end
end
commands.setFamilyName = function(exec,target,name)
	assert(target,"target player required"); assert(type(name)=="string" and #name>0,"name required")
	local dm=assert(_G.DataManager,"DataManager not ready"); dm.setValue(target,"FamilyName",name)
	local im=_G.IdentityManager
	if im then
		if target.Character then im.applyAppearance(target,target.Character) end
		im.refreshKnownObservers(target)
	end
end
commands.setSkinTone = function(exec,target,idx)
	assert(target,"target player required"); local v=assert(tonumber(idx),"index must be number")
	local im=assert(_G.IdentityManager,"IdentityManager not ready")
	assert(v>=1 and v<=#im.SkinTones,"index out of range 1-"..#im.SkinTones)
	local dm=assert(_G.DataManager,"DataManager not ready"); dm.setValue(target,"SkinToneIndex",v)
	if target.Character then im.applyAppearance(target,target.Character) end
end
commands.setFace = function(exec,target,idx)
	assert(target,"target player required"); local v=assert(tonumber(idx),"index must be number")
	local im=assert(_G.IdentityManager,"IdentityManager not ready")
	assert(v>=1 and v<=#im.FacePool,"index out of range 1-"..#im.FacePool)
	local dm=assert(_G.DataManager,"DataManager not ready"); dm.setValue(target,"FaceIndex",v)
	if target.Character then im.applyAppearance(target,target.Character) end
end
commands.setHairOverride = function(exec,target,assetId)
	assert(target,"target player required"); local v=assert(tonumber(assetId),"assetId must be number")
	local dm=assert(_G.DataManager,"DataManager not ready"); dm.setValue(target,"HairOverrideId",v)
	local im=assert(_G.IdentityManager,"IdentityManager not ready")
	if target.Character then im.applyAppearance(target,target.Character) end
end
commands.clearHairOverride = function(exec,target)
	assert(target,"target player required")
	local dm=assert(_G.DataManager,"DataManager not ready"); dm.setValue(target,"HairOverrideId",0)
	local im=assert(_G.IdentityManager,"IdentityManager not ready")
	if target.Character then im.restoreNaturalHair(target,target.Character) end
end
commands.setOutfitSlot1 = function(exec,target,shirtId,pantsId)
	assert(target,"target player required")
	local s,p=tonumber(shirtId),tonumber(pantsId); assert(s and p,"shirtId and pantsId must be numbers")
	local im=assert(_G.IdentityManager,"IdentityManager not ready")
	local shirtTemplate=im.resolveShirtId(math.floor(s)) or ("rbxassetid://"..tostring(math.floor(s)))
	local pantsTemplate=im.resolvePantsId(math.floor(p)) or ("rbxassetid://"..tostring(math.floor(p)))
	local dm=assert(_G.DataManager,"DataManager not ready")
	dm.setValue(target,"OutfitSlot1",{shirt=shirtTemplate,pants=pantsTemplate})
	if target.Character and (dm.getValue(target,"ActiveOutfitSlot") or 1)==1 then im.applyAppearance(target,target.Character) end
end
commands.setOutfitSlot2 = function(exec,target,shirtId,pantsId)
	assert(target,"target player required")
	local s,p=tonumber(shirtId),tonumber(pantsId); assert(s and p,"shirtId and pantsId must be numbers")
	local im=assert(_G.IdentityManager,"IdentityManager not ready")
	local shirtTemplate=im.resolveShirtId(math.floor(s)) or ("rbxassetid://"..tostring(math.floor(s)))
	local pantsTemplate=im.resolvePantsId(math.floor(p)) or ("rbxassetid://"..tostring(math.floor(p)))
	local dm=assert(_G.DataManager,"DataManager not ready")
	dm.setValue(target,"OutfitSlot2",{shirt=shirtTemplate,pants=pantsTemplate})
	if target.Character and (dm.getValue(target,"ActiveOutfitSlot") or 1)==2 then im.applyAppearance(target,target.Character) end
end
commands.setActiveOutfit = function(exec,target,slot)
	assert(target,"target player required"); local v=assert(tonumber(slot),"slot must be number")
	assert(v==1 or v==2,"slot must be 1 or 2")
	local dm=assert(_G.DataManager,"DataManager not ready"); dm.setValue(target,"ActiveOutfitSlot",v)
	local im=_G.IdentityManager
	if im and target.Character then im.applyAppearance(target,target.Character) end
end

commands.setStat = function(exec,target,statName,amount)
	assert(target,"target player required"); local v=assert(tonumber(amount),"amount must be number"); assert(v>=0,"must be non-negative")
	local valid={Strength=true,Endurance=true,Agility=true}; assert(valid[statName],"statName must be Strength/Endurance/Agility")
	local dm=assert(_G.DataManager,"DataManager not ready"); local stats=dm.getValue(target,"Stats") or {}
	stats[statName]=v; dm.setValue(target,"Stats",stats)
	if statName=="Endurance" then local pm=_G.PostureManager; if pm and pm.recalculateMax then pm.recalculateMax(target) end end
end
commands.grantCurrency = function(exec,target,ct,amount)
	assert(target,"target player required"); local v=assert(tonumber(amount),"amount must be number"); assert(v>0,"must be positive")
	local dm=assert(_G.DataManager,"DataManager not ready"); local cur=dm.getValue(target,"Currency") or {}
	cur[ct]=(cur[ct] or 0)+v; dm.setValue(target,"Currency",cur)
end
commands.revokeCurrency = function(exec,target,ct,amount)
	assert(target,"target player required"); local v=assert(tonumber(amount),"amount must be number"); assert(v>0,"must be positive")
	local dm=assert(_G.DataManager,"DataManager not ready"); local cur=dm.getValue(target,"Currency") or {}
	cur[ct]=math.max(0,(cur[ct] or 0)-v); dm.setValue(target,"Currency",cur)
end
commands.globalMessage = function(exec,_,message)
	assert(type(message)=="string" and #message>0,"message required"); assert(_G.HUDManager,"HUDManager not ready")
	_G.HUDManager.showGlobalMessage(message)
end
commands.killPlayer = function(exec,target)
	assert(target,"target player required"); local dm=assert(_G.DataManager,"DataManager not ready")
	dm.setValue(target,"PlayerState","Dead"); local char=target.Character
	local hum=char and char:FindFirstChildWhichIsA("Humanoid"); if hum then hum.Health=0 end
end
commands.revivePlayer = function(exec,target)
	assert(target,"target player required"); local dm=assert(_G.DataManager,"DataManager not ready")
	dm.setValue(target,"PlayerState","Alive"); local char=target.Character
	local hum=char and char:FindFirstChildWhichIsA("Humanoid"); if hum then hum.Health=hum.MaxHealth end
end
commands.kick = function(exec,target,reason)
	assert(target,"target player required"); target:Kick(reason or "Removed by a moderator.")
end
commands.banPlayer = function(exec,target,durationMinutes,reason)
	assert(target,"target player required")
	local dur=tonumber(durationMinutes); assert(dur and dur>0,"duration (minutes) must be a positive number")
	local bm=assert(_G.BanManager,"BanManager not ready")
	bm.banPlayer(target,dur,reason,exec and exec.Name)
end
-- Unban targets a player who by definition isn't online, so it can't go through the
-- roster's online-target lookup like every other command -- the name/UserId to unban is
-- passed as a plain string arg instead (targetName itself is unused, hence the `_`).
commands.unbanPlayer = function(exec,_,userIdOrName)
	assert(type(userIdOrName)=="string" and #userIdOrName>0,"player name or userId required")
	local bm=assert(_G.BanManager,"BanManager not ready")
	local uid=tonumber(userIdOrName)
	if not uid then
		local ok,id=pcall(function() return Players:GetUserIdFromNameAsync(userIdOrName) end)
		assert(ok and id,"Could not resolve username: "..userIdOrName)
		uid=id
	end
	bm.unbanUserId(uid)
end
commands.tpToMod = function(exec,target)
	assert(exec and target,"mod and target required")
	local mHRP=exec.Character and exec.Character:FindFirstChild("HumanoidRootPart"); assert(mHRP,"Mod no HRP")
	local tHRP=target.Character and target.Character:FindFirstChild("HumanoidRootPart"); assert(tHRP,"Target no HRP")
	tHRP.CFrame=mHRP.CFrame*CFrame.new(3,0,0)
end
commands.tpSelf = function(exec,target)
	assert(exec and target,"mod and target required")
	local tHRP=target.Character and target.Character:FindFirstChild("HumanoidRootPart"); assert(tHRP,"Target no HRP")
	local mHRP=exec.Character and exec.Character:FindFirstChild("HumanoidRootPart"); assert(mHRP,"Mod no HRP")
	mHRP.CFrame=tHRP.CFrame*CFrame.new(3,0,0)
end
commands.freezePlayer = function(exec,target)
	assert(target,"target player required")
	local uid=target.UserId
	if frozenPlayers[uid] then frozenPlayers[uid].conn:Disconnect() end
	applyFreeze(target)
	local conn=target.CharacterAdded:Connect(function()
		task.wait()
		if frozenPlayers[uid] then applyFreeze(target) end
	end)
	frozenPlayers[uid]={conn=conn}
end
commands.unfreezePlayer = function(exec,target)
	assert(target,"target player required")
	local uid=target.UserId
	if frozenPlayers[uid] then frozenPlayers[uid].conn:Disconnect(); frozenPlayers[uid]=nil end
	local char=target.Character; local hrp=char and char:FindFirstChild("HumanoidRootPart")
	if hrp then hrp.Anchored=false end
	local hum=char and char:FindFirstChildOfClass("Humanoid")
	if hum then hum.WalkSpeed=16; hum.JumpHeight=7.2 end
end
commands.respawnPlayer = function(exec,target)
	assert(target,"target player required")
	local hum=target.Character and target.Character:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health>0 then hum.Health=0 end
	task.wait(1); if target and target.Parent then target:LoadCharacter() end
end
commands.sendNotification = function(exec,target,title,body,duration)
	fireNotif(target, title or "Notice", body or "", tonumber(duration) or 10, "info")
end
commands.giveItem = function(exec,target,itemName,quality)
	assert(target,"target player required"); assert(type(itemName)=="string" and #itemName>0,"itemName required")
	local dm=assert(_G.DataManager,"DataManager not ready"); local inv=dm.getValue(target,"Inventory") or {}
	table.insert(inv,{itemName=itemName,quality=quality or "Iron"}); dm.setValue(target,"Inventory",inv)
	local im=_G.InventoryManager; if im then im.refresh(target) end
	fireNotif(exec,"Item Given",itemName.." ("..(quality or "Iron")..") → "..target.Name,8,"info")
end
-- SHADOW BOXING (design doc PART ONE)
commands.forceEndShadowPractice = function(exec,target)
	assert(target,"target player required")
	local sb=assert(_G.ShadowBoxManager,"ShadowBoxManager not ready")
	sb.stopPractice(target,"mod ended it")
	-- Force end deliberately keeps the BIG notification (user request: everything else is
	-- a lesser toast, force end still does the big one).
	fireNotif(exec,"Shadow Practice Ended",target.Name.." was pulled out of shadow practice.",6,"info")
end
-- LORE TEAM BROADCAST (design doc: side banner, lore-team-only, non-blocking -- see
-- LoreBroadcastClient for the actual display).
commands.loreBroadcast = function(exec,_,title,subtitle)
	assert(exec and isLoreTeam(exec), "Lore team only")
	assert(type(title)=="string" and #title>0, "title required")
	loreTeamMsgRE:FireAllClients({ title = title, subtitle = (type(subtitle)=="string" and subtitle) or "" })
	fireNotif(exec,"Lore Broadcast Sent","\""..title.."\""..((subtitle~="" and subtitle) and (" -- "..subtitle) or ""),6,"info")
end
commands.forceStartShadowPractice = function(exec,target)
	assert(target,"target player required")
	local sb=assert(_G.ShadowBoxManager,"ShadowBoxManager not ready")
	local ok,err=sb.startPractice(target)
	assert(ok, err or "could not start shadow practice")
	fireNotif(exec,"Shadow Practice Started",target.Name.." was placed into shadow practice.",6,"info")
end
commands.setShadowBoxHits = function(exec,target,hits)
	assert(target,"target player required")
	local n=tonumber(hits); assert(n and n>=1 and n==math.floor(n),"hits must be a whole number, 1 or more")
	target:SetAttribute("ShadowBoxMaxHits", n)
	fireNotif(exec,"Shadow Box Hits Set",target.Name.."'s shadow now takes "..n.." hit"..(n==1 and "" or "s").." to defeat (applies next time they start practice).",6,"info")
end

-- SPIRIT PHRASES (design doc: spirits can have phrases to tell people)
commands.addSpiritPhrase = function(exec,_,spiritName,text)
	local sm=assert(_G.SpiritManager,"SpiritManager not ready")
	local part=sm.findSpiritByName(spiritName); assert(part,"Spirit not found: "..tostring(spiritName))
	assert(sm.addPhrase(part,text),"Failed to add phrase")
	fireNotif(exec,"Phrase Added",spiritName..": \""..tostring(text).."\"",6,"info")
end
commands.removeSpiritPhrase = function(exec,_,spiritName,index)
	local sm=assert(_G.SpiritManager,"SpiritManager not ready")
	local part=sm.findSpiritByName(spiritName); assert(part,"Spirit not found: "..tostring(spiritName))
	assert(sm.removePhrase(part,index),"Failed to remove phrase (bad index?)")
	fireNotif(exec,"Phrase Removed",spiritName.." phrase #"..tostring(index).." removed",6,"info")
end
commands.listSpiritPhrases = function(exec,_,spiritName)
	local sm=assert(_G.SpiritManager,"SpiritManager not ready")
	local part=sm.findSpiritByName(spiritName); assert(part,"Spirit not found: "..tostring(spiritName))
	local list=sm.getPhrases(part)
	if #list==0 then fireNotif(exec,"Phrases",spiritName.." has no phrases yet.",6,"info"); return end
	local lines={}
	for i,text in ipairs(list) do table.insert(lines,i..". "..text) end
	fireNotif(exec,"Phrases -- "..spiritName,table.concat(lines,"\n"),10,"info")
end
commands.giveFood = function(exec,target,itemName)
	assert(target,"target player required"); assert(type(itemName)=="string" and #itemName>0,"itemName required (Bread/Apple/Orange/Stew Bowl/Grape Juice Bottle/Sweet Drink)")
	local em=assert(_G.EdibleManager,"EdibleManager not ready")
	local ok,reason=em.grant(target,itemName)
	assert(ok,reason or "failed to grant edible")
	fireNotif(exec,"Edible Given",itemName.." → "..target.Name,8,"info")
end
commands.setRace = function(exec,target,race)
	assert(target,"target player required")
	local norm=RACE_MAP[race:lower()] or race
	local valid={Human=true,Vampire=true,Dwarf=true,Apostle=true,GodHand=true}
	assert(valid[norm],"race must be: Human Vampire Dwarf Apostle GodHand")
	local dm=assert(_G.DataManager,"DataManager not ready"); dm.setValue(target,"Race",norm)
end
commands.assignRace = commands.setRace
commands.giveSP = function(exec,target,statName,amount)
	assert(target,"target player required")
	local validStats={Strength=true,Endurance=true,Agility=true}
	assert(validStats[statName],"stat must be Strength, Endurance, or Agility")
	local v=assert(tonumber(amount),"amount must be number"); assert(v>0,"must be positive")
	local dm=assert(_G.DataManager,"DataManager not ready")
	local stats=dm.getValue(target,"Stats") or {Strength=0,Endurance=0,Agility=0}
	stats[statName]=(stats[statName] or 0)+v
	dm.setValue(target,"Stats",stats)
	fireNotif(exec,"SP Added","+"..v.." "..statName.." → "..target.Name,8,"info")
end
commands.makeInvisible = function(exec,target)
	assert(target,"target player required")
	local char=target.Character; if not char then return end
	if invisiblePlayers[target.UserId] then return end
	local saved={}
	for _,d in ipairs(char:GetDescendants()) do
		if d:IsA("BasePart") and d.Name~="HumanoidRootPart" then
			saved[d]=d.Transparency; d.Transparency=1
		end
	end
	invisiblePlayers[target.UserId]=saved
end
commands.makeVisible = function(exec,target)
	assert(target,"target player required")
	local saved=invisiblePlayers[target.UserId]; if not saved then return end
	invisiblePlayers[target.UserId]=nil
	for part,trans in pairs(saved) do if part and part.Parent then part.Transparency=trans end end
end
commands.lockServer = function(exec,_)
	serverLocked=true; fireNotif(nil,"Server Locked","No new players may join",6,"warning")
end
commands.unlockServer = function(exec,_)
	serverLocked=false; fireNotif(nil,"Server Unlocked","Players may now join",5,"info")
end

-- LORE BOARD
commands.loreEntry = function(exec,_,text)
	assert(type(text)=="string" and #text>0,"text required")
	local entry={timestamp=os.time(),author=exec and firstNameOr(exec,"The Council") or "SYSTEM",text=text}
	table.insert(loreBoard,entry)
	if #loreBoard>200 then table.remove(loreBoard,1) end
	-- Broadcast notification is just the text -- no author prefix (entry.author is still
	-- recorded for the mod-only "view lore" history log, just not shown in the popup).
	fireNotif(nil,"Lore Board",text,10,"lore")
end
commands.announceBoard = function(exec,_)
	if #loreBoard==0 then fireNotif(exec,"Lore Board","Board is empty.",5,"info"); return end
	local last=loreBoard[#loreBoard]
	fireNotif(nil,"Lore Board",last.text,12,"lore")
end
commands.discordMsg = function(exec,_,msg)
	assert(type(msg)=="string" and #msg>0,"msg required")
	local disc=_G.DiscordManager
	if disc and disc.sendToDiscord then disc.sendToDiscord("Mod Message","["..exec.Name.."] "..msg) end
	logAction(exec,"discordMsg",msg)
	fireNotif(exec,"Discord","Message queued.",5,"info")
end
-- IDENTITY
commands.removeTitle = function(exec,target)
	assert(target,"target player required")
	assert(_G.DataManager,"DataManager not ready"); _G.DataManager.setValue(target,"Title","")
end
commands.assignScar = function(exec,target,scarType)
	assert(target,"target player required"); assert(type(scarType)=="string" and #scarType>0,"scarType required")
	local dm=assert(_G.DataManager,"DataManager not ready")
	local scars=dm.getValue(target,"Scars") or {}
	if not table.find(scars,scarType) then table.insert(scars,scarType) end
	dm.setValue(target,"Scars",scars)
end
commands.removeScar = function(exec,target,scarType)
	assert(target,"target player required"); assert(type(scarType)=="string" and #scarType>0,"scarType required")
	local dm=assert(_G.DataManager,"DataManager not ready")
	local scars=dm.getValue(target,"Scars") or {}
	local idx=table.find(scars,scarType); if idx then table.remove(scars,idx) end
	dm.setValue(target,"Scars",scars)
end
commands.assignFamily = function(exec,target,familyName)
	assert(target,"target player required"); assert(type(familyName)=="string" and #familyName>0,"familyName required")
	assert(_G.DataManager,"DataManager not ready"); _G.DataManager.setValue(target,"FamilyAssigned",familyName)
end
commands.setRelation = function(exec,target,relation)
	assert(target,"target player required"); assert(type(relation)=="string","relation required")
	local norm=RELATION_MAP[relation:lower()] or relation
	local valid={Brother=true,Sister=true,Twin=true,Cousin=true,DistantRelative=true,None=true}
	assert(valid[norm],"relation must be: Brother Sister Twin Cousin DistantRelative None")
	assert(_G.DataManager,"DataManager not ready"); _G.DataManager.setValue(target,"Relation",norm)
end
commands.setName = function(exec,target,firstName,lastName)
	assert(target,"target player required"); assert(type(firstName)=="string" and #firstName>0,"firstName required")
	local dm=assert(_G.DataManager,"DataManager not ready")
	dm.setValue(target,"FirstName",firstName)
	if type(lastName)=="string" and #lastName>0 then dm.setValue(target,"FamilyName",lastName) end
end
-- ECONOMY
commands.setBounty = function(exec,target,amount)
	assert(target,"target player required"); local v=assert(tonumber(amount),"amount must be number"); assert(v>=0,"must be non-negative")
	local dm=assert(_G.DataManager,"DataManager not ready")
	dm.setValue(target,"BountyAmount",v); dm.setValue(target,"BountyActive",v>0)
	if v>0 then fireNotif(nil,"Bounty Posted","Bounty of "..v.." placed on "..target.Name,10,"warning") end
end
commands.clearBounty = function(exec,target)
	assert(target,"target player required")
	local dm=assert(_G.DataManager,"DataManager not ready")
	dm.setValue(target,"BountyAmount",0); dm.setValue(target,"BountyActive",false)
end
commands.applyBrand = function(exec,target)
	assert(target,"target player required")
	assert(_G.DataManager,"DataManager not ready"); _G.DataManager.setValue(target,"BrandActive",true)
	fireNotif(target,"The Brand","You have been branded. You are visible on the map.",12,"pd")
end
commands.removeBrand = function(exec,target)
	assert(target,"target player required")
	assert(_G.DataManager,"DataManager not ready"); _G.DataManager.setValue(target,"BrandActive",false)
	fireNotif(target,"Brand Lifted","The brand has been removed.",10,"info")
end
-- INVENTORY
commands.removeItem = function(exec,target,itemName)
	assert(target,"target player required"); assert(type(itemName)=="string" and #itemName>0,"itemName required")
	local dm=assert(_G.DataManager,"DataManager not ready")
	local inv=dm.getValue(target,"Inventory") or {}
	for i,item in ipairs(inv) do
		if item.itemName==itemName or item.itemID==itemName then
			table.remove(inv,i); dm.setValue(target,"Inventory",inv)
			-- table.remove shifts every later index down by one, so EquippedSlot (a raw
			-- Inventory array index) must shift with it or it'll silently point at the wrong item.
			local eqSlot=dm.getValue(target,"EquippedSlot")
			if eqSlot==i then
				dm.setValue(target,"EquippedWeapon",nil); dm.setValue(target,"EquippedSlot",nil)
			elseif eqSlot and eqSlot>i then
				dm.setValue(target,"EquippedSlot",eqSlot-1)
			end
			local im=_G.InventoryManager; if im then im.refresh(target) end
			return
		end
	end
	error("Item not found: "..itemName)
end
commands.clearInventory = function(exec,target)
	assert(target,"target player required")
	local dm=assert(_G.DataManager,"DataManager not ready")
	dm.setValue(target,"Inventory",{})
	dm.setValue(target,"EquippedWeapon",nil); dm.setValue(target,"EquippedSlot",nil)
	local em=_G.EdibleManager; if em then em.unequipHeld(target) end
	local im=_G.InventoryManager; if im then im.refresh(target) end
	fireNotif(exec,"Inventory Cleared",target.Name.."'s inventory was wiped.",6,"info")
end

-- SHIP MANAGEMENT (design doc PART TWO/FIVE) -- ships aren't tracked in ModManager's own
-- state; found by ShipName each call directly off the live workspace models BoatManager
-- itself maintains (same "read the real Instance, don't duplicate state" approach as
-- INTERACTABLE_EDITOR above).
local function findShipHull(shipName)
	for _, inst in ipairs(workspace:GetChildren()) do
		if inst:IsA("Model") then
			local hull = inst:FindFirstChild("Hull")
			if hull and hull:GetAttribute("ShipName") == shipName then return hull end
		end
	end
	return nil
end
commands.listShips = function(exec)
	local names = {}
	for _, inst in ipairs(workspace:GetChildren()) do
		if inst:IsA("Model") then
			local hull = inst:FindFirstChild("Hull")
			if hull and hull:GetAttribute("HullHP") ~= nil then
				table.insert(names, hull:GetAttribute("ShipName") .. " (HP " .. hull:GetAttribute("HullHP") .. "/" .. hull:GetAttribute("HullMaxHP") .. ", " .. hull:GetAttribute("AnchorState") .. ")")
			end
		end
	end
	if #names==0 then fireNotif(exec,"Ships","No ships placed.",6,"info"); return end
	fireNotif(exec,"Ships",table.concat(names,"\n"),10,"info")
end
commands.setShipHP = function(exec,_,shipName,hp)
	local hull = findShipHull(shipName); assert(hull,"Ship not found: "..tostring(shipName))
	local v = assert(tonumber(hp),"hp must be a number")
	v = math.clamp(v, 0, hull:GetAttribute("HullMaxHP") or 500)
	hull:SetAttribute("HullHP", v)
	if v <= 0 then
		local bm=_G.BoatManager; if bm then bm.sinkShip(hull) end
	end
	fireNotif(exec,"Ship Updated",shipName.." HP set to "..v,6,"info")
end
commands.toggleShipAnchor = function(exec,_,shipName)
	local hull = findShipHull(shipName); assert(hull,"Ship not found: "..tostring(shipName))
	assert(hull:GetAttribute("AnchorState")~="Sinking","Ship is sinking")
	local newState = (hull:GetAttribute("AnchorState")=="Sailing") and "Anchored" or "Sailing"
	hull:SetAttribute("AnchorState", newState)
	fireNotif(exec,"Ship Updated",shipName.." is now "..newState,6,"info")
end
commands.forceSinkShip = function(exec,_,shipName)
	local hull = findShipHull(shipName); assert(hull,"Ship not found: "..tostring(shipName))
	local bm=assert(_G.BoatManager,"BoatManager not ready")
	bm.sinkShip(hull)
	fireNotif(exec,"Ship Sinking",shipName.." is going down.",6,"info")
end
commands.assignShipOwner = function(exec,target,shipName)
	assert(target,"target player required")
	local hull = findShipHull(shipName); assert(hull,"Ship not found: "..tostring(shipName))
	hull:SetAttribute("OwnerUserId", target.UserId)
	fireNotif(exec,"Ship Updated",shipName.." is now owned by "..target.Name,6,"info")
end

commands.strip = function(exec,target)
	assert(target,"target player required")
	local dm=assert(_G.DataManager,"DataManager not ready")
	dm.setValue(target,"Inventory",{}); dm.setValue(target,"EquippedWeapon",nil); dm.setValue(target,"EquippedSlot",nil)
	local im=_G.InventoryManager; if im then im.refresh(target) end
end
commands.setWeaponQuality = function(exec,target,itemName,quality)
	assert(target,"target player required"); assert(type(itemName)=="string" and #itemName>0,"itemName required")
	assert(type(quality)=="string" and #quality>0,"quality required")
	local dm=assert(_G.DataManager,"DataManager not ready")
	local inv=dm.getValue(target,"Inventory") or {}
	for _,item in ipairs(inv) do
		if item.itemName==itemName or item.itemID==itemName then
			item.quality=quality; dm.setValue(target,"Inventory",inv)
			local im=_G.InventoryManager; if im then im.refresh(target) end
			return
		end
	end
	error("Item not found: "..itemName)
end
-- ACTION
commands.setAlive = function(exec,target)
	assert(target,"target player required"); local dm=assert(_G.DataManager,"DataManager not ready")
	dm.setValue(target,"PlayerState","Alive")
	local hum=target.Character and target.Character:FindFirstChildOfClass("Humanoid"); if hum then hum.Health=hum.MaxHealth end
end
commands.setDead = function(exec,target)
	assert(target,"target player required"); local dm=assert(_G.DataManager,"DataManager not ready")
	dm.setValue(target,"PlayerState","Dead")
	local hum=target.Character and target.Character:FindFirstChildOfClass("Humanoid"); if hum then hum.Health=0 end
end
commands.sendToCoords = function(exec,target,x,y,z)
	assert(target,"target player required")
	local px,py,pz=tonumber(x),tonumber(y),tonumber(z)
	assert(px and py and pz,"x y z must be numbers")
	local hrp=target.Character and target.Character:FindFirstChild("HumanoidRootPart"); assert(hrp,"Target no HRP")
	hrp.CFrame=CFrame.new(px,py,pz)
end
commands.setSpawn = function(exec,target,x,y,z)
	assert(target,"target player required")
	local dm=assert(_G.DataManager,"DataManager not ready")
	local px,py,pz=tonumber(x),tonumber(y),tonumber(z)
	if px and py and pz then
		dm.setValue(target,"SpawnOverride",{X=px,Y=py,Z=pz})
	else
		local hrp=exec.Character and exec.Character:FindFirstChild("HumanoidRootPart")
		assert(hrp,"Mod has no HRP -- provide x y z coords")
		dm.setValue(target,"SpawnOverride",{X=hrp.Position.X,Y=hrp.Position.Y,Z=hrp.Position.Z})
	end
end
commands.revealStat = function(exec,target,statName)
	assert(target,"target player required"); assert(type(statName)=="string" and #statName>0,"statName required")
	local valid={Strength=true,Endurance=true,Agility=true}; assert(valid[statName],"stat must be Strength/Endurance/Agility")
	local dm=assert(_G.DataManager,"DataManager not ready")
	local revealed=dm.getValue(target,"RevealedStats") or {}
	if not table.find(revealed,statName) then table.insert(revealed,statName) end
	dm.setValue(target,"RevealedStats",revealed)
	-- Combat polish 4D: weapons scale with stats, so show what the target is wielding
	-- alongside the reveal (Config.Weapons -- see its comment for why every entry currently
	-- says Strength, that's the real scaling behavior, not a guess).
	local weaponName = dm.getValue(target,"EquippedWeapon")
	local wCfg = weaponName and Config.Weapons[weaponName]
	local wielding = weaponName and (wCfg and wCfg.name or weaponName) or "Bare hands"
	local scalesWith = wCfg and wCfg.scalesWith or "Strength"
	fireNotif(exec,"Stat Revealed",statName.." revealed for "..target.Name.."\nWielding: "..wielding.."\nScales with: "..scalesWith,8,"info")
end
commands.hideStat = function(exec,target,statName)
	assert(target,"target player required"); assert(type(statName)=="string" and #statName>0,"statName required")
	local dm=assert(_G.DataManager,"DataManager not ready")
	local revealed=dm.getValue(target,"RevealedStats") or {}
	local idx=table.find(revealed,statName); if idx then table.remove(revealed,idx) end
	dm.setValue(target,"RevealedStats",revealed)
end
commands.setPostureMax = function(exec,target,max)
	assert(target,"target player required"); local v=assert(tonumber(max),"max must be number"); assert(v>0,"must be positive")
	local pm=assert(_G.PostureManager,"PostureManager not ready")
	if pm.setPlayerMax then pm.setPlayerMax(target,v) else error("PostureManager.setPlayerMax not found") end
end
-- LANGUAGE
commands.setLanguage = function(exec,target,lang)
	assert(target,"target player required")
	local lm=assert(_G.LanguageManager,"LanguageManager not ready")
	local result=lm.setLanguage(target,lang or "None")
	-- Was firing a bare string payload -- the client renderer expects {title, body, ...},
	-- so the notification came through with an empty body and never actually read.
	fireNotif(target,"Language","Language set: "..result,5,"info")
end
commands.setLanguageComprehension = function(exec,target,lang,pct)
	assert(target,"target player required")
	local v=assert(tonumber(pct),"percent must be number"); assert(v>=0 and v<=100,"percent 0-100")
	local lm=assert(_G.LanguageManager,"LanguageManager not ready")
	local normLang,result=lm.setComprehension(target,lang,v)
	assert(normLang,"lang must be Gaulish/Greek/Latin")
	fireNotif(target,"Language",normLang.." comprehension set: "..result.."%",5,"info")
end
-- WORLD
commands.unlockMapSection = function(exec,target,sectionId)
	assert(target,"target player required"); assert(type(sectionId)=="string" and #sectionId>0,"sectionId required")
	local dm=assert(_G.DataManager,"DataManager not ready")
	local sections=dm.getValue(target,"UnlockedMapSections") or {}
	if not table.find(sections,sectionId) then table.insert(sections,sectionId) end
	dm.setValue(target,"UnlockedMapSections",sections)
end
commands.triggerQTE = function(exec,target,qteId)
	assert(target,"target player required"); assert(type(qteId)=="string" and #qteId>0,"qteId required")
	local qm=assert(_G.QTEManager,"QTEManager not ready")
	local instanceId=qm.startQTE(target,qteId,{source="ModTriggered",triggeredBy=exec and exec.Name or "SYSTEM"},function(p,success)
		if exec then fireNotif(exec,"QTE Result",p.Name.." "..(success and "PASSED" or "FAILED").." the "..qteId.." QTE",5,"info") end
	end)
	assert(instanceId,"Unknown QTE tier: "..qteId.." (use Tier1-Tier5)")
end
commands.triggerEclipse = function(exec,_,zone)
	local folder=RepStorage:FindFirstChild("RemoteEvents")
	local eclipseRE=folder and folder:FindFirstChild("UpdateEclipseMoon")
	if eclipseRE then eclipseRE:FireAllClients(zone or "ALL") end
	fireNotif(nil,"Eclipse","The Eclipse Moon rises over "..(zone or "the world"),12,"pd")
end
commands.spawnMob = function(exec,target,mobName)
	assert(type(mobName)=="string" and #mobName>0,"mobName required")
	local pos
	if target and target.Character then
		-- Spawn ON the target (owner request), not 4 studs to the side. A small up-offset keeps it
		-- from clipping into the floor; the mob managers set HipHeight so it settles correctly.
		local hrp=target.Character:FindFirstChild("HumanoidRootPart"); if hrp then pos=hrp.Position+Vector3.new(0,3,0) end
	end
	pos=pos or Vector3.new(0,10,0)

	-- If this template is registered in Config.Mobs with a manager, hand the spawn to that
	-- manager instead of bare-cloning it. A raw clone has no AI, no corrected HipHeight and no
	-- loot -- picking "Shroom" from the dropdown used to give a statue standing in the floor.
	local Config = require(RepStorage.Shared.Config)
	for _,entry in ipairs(Config.Mobs or {}) do
		if entry.template == mobName and entry.manager then
			local mgr = _G[entry.manager]
			if mgr and mgr.spawn then
				local model = mgr.spawn(pos)
				assert(model, entry.manager.." failed to spawn "..entry.name)
				fireNotif(exec,"Mob Spawned",entry.name.." spawned with full AI.",5,"info")
				return
			end
			-- Manager registered but not loaded -- say so rather than silently dropping to a
			-- dumb clone the mod would assume was the real thing.
			error(entry.manager.." is not running; cannot spawn "..entry.name.." with AI")
		end
	end

	local template=workspace:FindFirstChild(mobName) or RepStorage:FindFirstChild(mobName)
	assert(template,"Mob template not found: "..mobName)
	local wasArch=template.Archivable; template.Archivable=true
	local mob=template:Clone(); template.Archivable=wasArch
	assert(mob,"Clone failed for "..mobName)
	mob.Parent=workspace
	local mHRP=mob.PrimaryPart or mob:FindFirstChild("HumanoidRootPart")
	if mHRP then mHRP.CFrame=CFrame.new(pos)
	elseif mob:IsA("BasePart") then mob.CFrame=CFrame.new(pos) end
end
-- SPIRITS
commands.spawnSpirit = function(exec,_,factionName,x,y,z)
	assert(type(factionName)=="string" and #factionName>0,"factionName required")
	local sm=assert(_G.SpiritManager,"SpiritManager not ready")
	local px,py,pz=tonumber(x),tonumber(y),tonumber(z)
	local pos
	if px and py and pz then
		pos=Vector3.new(px,py,pz)
	else
		local hrp=exec.Character and exec.Character:FindFirstChild("HumanoidRootPart")
		assert(hrp,"Mod has no HRP -- provide x y z coords")
		pos=hrp.Position+Vector3.new(0,3,0)
	end
	assert(sm.spawnSpirit(factionName,pos),"Unknown faction: "..factionName)
end
commands.setSpiritRep = function(exec,target,factionName,amount)
	assert(target,"target player required")
	local sm=assert(_G.SpiritManager,"SpiritManager not ready")
	assert(sm.setReputation(target,factionName,amount),"Invalid faction or reputation set failed")
end
commands.spiritBless = function(exec,target,factionName)
	assert(target,"target player required")
	local sm=assert(_G.SpiritManager,"SpiritManager not ready")
	local dm=assert(_G.DataManager,"DataManager not ready")
	local rep=dm.getValue(target,"SpiritReputation") or {}
	sm.setReputation(target,factionName,(rep[factionName] or 0)+15)
	fireNotif(target,"Spirit Blessing","The "..tostring(factionName).." spirits favor you.",6,"lore")
end
commands.spiritWarn = function(exec,target,factionName)
	assert(target,"target player required")
	local sm=assert(_G.SpiritManager,"SpiritManager not ready")
	local dm=assert(_G.DataManager,"DataManager not ready")
	local rep=dm.getValue(target,"SpiritReputation") or {}
	sm.setReputation(target,factionName,(rep[factionName] or 0)-15)
	fireNotif(target,"Spirit Warning","The "..tostring(factionName).." spirits are wary of you.",6,"warning")
end
-- PROGRESSION (meditation/pushups milestone cards -- lore team's manual bookkeeping tool,
-- distinct from grantTalent: no mechanical effect, just logged for the lore team's own record)
commands.grantProgress = function(exec,target,category)
	assert(target,"target player required"); assert(type(category)=="string" and #category>0,"category required")
	logAction(exec,"grantProgress",target.Name..": "..category)
end
-- INTERACTABLES
commands.spawnInteractable = function(exec,_,tier,prompt,rewardType,rewardValue,cooldown)
	local im=assert(_G.InteractableManager,"InteractableManager not ready")
	local hrp=exec.Character and exec.Character:FindFirstChild("HumanoidRootPart")
	assert(hrp,"Mod has no HRP")
	im.create(hrp.Position+hrp.CFrame.LookVector*3, {
		tier=(tier~="" and tier) or nil, prompt=(prompt~="" and prompt) or nil,
		rewardType=(rewardType~="" and rewardType) or nil, rewardValue=rewardValue,
		cooldown=tonumber(cooldown),
	})
end
commands.editInteractable = function(exec,_,name,tier,prompt,rewardType,rewardValue,cooldown)
	assert(type(name)=="string" and #name>0,"interactable name required")
	local im=assert(_G.InteractableManager,"InteractableManager not ready")
	local part=im.findByName(name)
	assert(part,"Interactable not found: "..name)
	im.configure(part, {
		tier=(tier~="" and tier) or nil, prompt=(prompt~="" and prompt) or nil,
		rewardType=(rewardType~="" and rewardType) or nil, rewardValue=rewardValue,
		cooldown=tonumber(cooldown),
	})
end
-- NPCs
local function resolveNPC(npcId)
	local npcM=assert(_G.NPCManager,"NPCManager not ready")
	assert(type(npcId)=="string" and #npcId>0,"npc name/id required")
	local model=npcM.getByName(npcId)
	assert(model,"NPC not found: "..tostring(npcId))
	return model, npcM
end
commands.spawnNPC = function(exec,_,name,x,y,z)
	local px,py,pz=tonumber(x),tonumber(y),tonumber(z)
	local pos
	if px and py and pz then
		pos=Vector3.new(px,py,pz)
	else
		local hrp=exec.Character and exec.Character:FindFirstChild("HumanoidRootPart")
		assert(hrp,"Mod has no HRP -- provide x y z coords")
		pos=hrp.Position+hrp.CFrame.LookVector*4
	end
	local npcM=assert(_G.NPCManager,"NPCManager not ready")
	assert(npcM.spawnNPC(pos,name),"Failed to spawn NPC -- is Workspace.CombatDummy present?")
end
commands.deleteNPC = function(exec,_,npcId)
	local model,npcM=resolveNPC(npcId)
	npcM.deleteNPC(model)
end
commands.setNPCName = function(exec,_,npcId,name)
	local model,npcM=resolveNPC(npcId)
	npcM.setName(model,name)
end
commands.setNPCShirtPants = function(exec,_,npcId,shirtId,pantsId)
	local model,npcM=resolveNPC(npcId)
	npcM.setShirtPants(model,shirtId,pantsId)
end
commands.setNPCSkin = function(exec,_,npcId,index)
	local model,npcM=resolveNPC(npcId)
	npcM.setSkinTone(model,index)
end
commands.setNPCFace = function(exec,_,npcId,index)
	local model,npcM=resolveNPC(npcId)
	npcM.setFace(model,index)
end
commands.setNPCHair = function(exec,_,npcId,assetId)
	local model,npcM=resolveNPC(npcId)
	npcM.setHair(model,assetId)
end
commands.addNPCGear = function(exec,_,npcId,assetId)
	local model,npcM=resolveNPC(npcId)
	assert(npcM.addGear(model,assetId),"Failed to add gear -- invalid asset id or no Accessory found in it")
end
commands.clearNPCGear = function(exec,_,npcId)
	local model,npcM=resolveNPC(npcId)
	npcM.clearGear(model)
end
commands.setNPCWeapon = function(exec,_,npcId,weaponType)
	local model,npcM=resolveNPC(npcId)
	assert(npcM.setWeapon(model,weaponType),"Invalid weapon type")
end
commands.setNPCAggro = function(exec,_,npcId,aggroType)
	local model,npcM=resolveNPC(npcId)
	assert(npcM.setAggroType(model,aggroType),"Invalid aggro type")
end
commands.setNPCSightRange = function(exec,_,npcId,range)
	local model,npcM=resolveNPC(npcId)
	npcM.setSightRange(model,range)
end
commands.setNPCLeashRange = function(exec,_,npcId,range)
	local model,npcM=resolveNPC(npcId)
	npcM.setLeashRange(model,range)
end
commands.setNPCLeader = function(exec,_,npcId,playerName)
	local model,npcM=resolveNPC(npcId)
	local leader=playerName and Players:FindFirstChild(tostring(playerName))
	assert(leader,"Leader player not found: "..tostring(playerName))
	npcM.setLeader(model,leader)
	npcM.setAggroType(model,"PlayerLed")
end
commands.setNPCStats = function(exec,_,npcId,str,endur,agi)
	local model,npcM=resolveNPC(npcId)
	npcM.setStats(model,str,endur,agi)
end
commands.setNPCMaxHealth = function(exec,_,npcId,hp)
	local model,npcM=resolveNPC(npcId)
	npcM.setMaxHealth(model,hp)
end
commands.setNPCGrip = function(exec,_,npcId,allowed)
	local model,npcM=resolveNPC(npcId)
	npcM.setGripAllowed(model,allowed==true or allowed=="true")
end
commands.addNPCPhrase = function(exec,_,npcId,trigger,text)
	local model,npcM=resolveNPC(npcId)
	assert(npcM.addPhrase(model,trigger,text),"Invalid trigger or empty text")
	fireNotif(exec,"NPC Phrase Added",(model:GetAttribute("NPCName") or npcId).." ["..tostring(trigger).."]: \""..tostring(text).."\"",6,"info")
end
commands.removeNPCPhrase = function(exec,_,npcId,trigger,index)
	local model,npcM=resolveNPC(npcId)
	assert(npcM.removePhrase(model,trigger,index),"Invalid trigger/index")
	fireNotif(exec,"NPC Phrase Removed",(model:GetAttribute("NPCName") or npcId).." ["..tostring(trigger).."] #"..tostring(index).." removed",6,"info")
end
-- Phrases were previously write-only from the panel (add existed, but nothing ever showed
-- what an NPC currently has) -- this is the read side.
commands.listNPCPhrases = function(exec,_,npcId)
	local model,npcM=resolveNPC(npcId)
	local phrases=npcM.getPhrases(model)
	local lines={}
	for trigger,list in pairs(phrases) do
		for i,text in ipairs(list) do
			table.insert(lines,"["..trigger.."] "..i..". "..text)
		end
	end
	local name=model:GetAttribute("NPCName") or npcId
	if #lines==0 then fireNotif(exec,"NPC Phrases",name.." has no phrases yet.",6,"info"); return end
	table.sort(lines)
	fireNotif(exec,"Phrases -- "..name,table.concat(lines,"\n"),12,"info")
end
-- INJURIES
commands.applyInjury = function(exec,target,injuryType,side,severity)
	assert(target,"target player required")
	local im=assert(_G.InjuryManager,"InjuryManager not ready")
	local ok,err=im.applyInjury(target,injuryType,exec and exec.Name,side,severity)
	assert(ok,err)
end
commands.removeInjury = function(exec,target,injuryType)
	assert(target,"target player required")
	local im=assert(_G.InjuryManager,"InjuryManager not ready")
	assert(im.removeInjury(target,injuryType),"Injury not present: "..tostring(injuryType))
end
commands.clearAllInjuries = function(exec,target)
	assert(target,"target player required")
	local im=assert(_G.InjuryManager,"InjuryManager not ready")
	im.clearAllInjuries(target)
end
-- DNA
commands.setDNA = function(exec,target,clanName,purity)
	assert(target,"target player required")
	local dnaM=assert(_G.DNAManager,"DNAManager not ready")
	assert(dnaM.setDNA(target,clanName,purity),"Unknown clan: "..tostring(clanName))
end
commands.clearDNA = function(exec,target)
	assert(target,"target player required")
	local dnaM=assert(_G.DNAManager,"DNAManager not ready")
	dnaM.clearDNA(target)
end
-- CASTES
commands.setCaste = function(exec,target,casteId)
	assert(target,"target player required")
	local cm=assert(_G.CasteManager,"CasteManager not ready")
	local ok,err=cm.setCaste(target,casteId)
	assert(ok,err)
end
commands.setPurity = function(exec,target,purity)
	assert(target,"target player required")
	assert(tonumber(purity),"purity must be a number 0-100")
	local cm=assert(_G.CasteManager,"CasteManager not ready")
	local ok,err=cm.setPurity(target,purity)
	assert(ok,err)
end
-- TITLES
commands.grantTitle = function(exec,target,title)
	assert(target,"target player required")
	local cm=assert(_G.CasteManager,"CasteManager not ready")
	local ok,err=cm.grantTitle(target,title)
	assert(ok,err)
	fireNotif(exec,"Title Granted",target.Name.." is now "..tostring(title),6,"info")
end
commands.revokeTitle = function(exec,target,title)
	assert(target,"target player required")
	local cm=assert(_G.CasteManager,"CasteManager not ready")
	local ok,err=cm.revokeTitle(target,title)
	assert(ok,err)
end
-- NPC REVEALER CONFIG
commands.setNPCRevealer = function(exec,_,npcId,isRevealer,revealType,cost,cooldown)
	local model=resolveNPC(npcId)
	local rm=assert(_G.RevealManager,"RevealManager not ready")
	local on=(isRevealer==true or isRevealer=="true")
	local ok,err=rm.setRevealer(model,on,revealType,cost,cooldown)
	assert(ok,err)
	fireNotif(exec,"Revealer Updated",
		(model:GetAttribute("NPCName") or npcId)..(on and (" reveals "..tostring(revealType)) or " is no longer a Revealer"),6,"info")
end
-- POTIONS
commands.givePotion = function(exec,target,potionId,amount)
	assert(target,"target player required")
	local pm=assert(_G.PotionManager,"PotionManager not ready")
	assert(pm.give(target,potionId,tonumber(amount) or 1),"Unknown potion: "..tostring(potionId))
end
-- RITUALS
local function resolveRitual(circleName)
	local rm=assert(_G.RitualManager,"RitualManager not ready")
	assert(type(circleName)=="string" and #circleName>0,"ritual circle name required")
	local part=rm.getByName(circleName)
	assert(part,"Ritual circle not found: "..tostring(circleName))
	return part, rm
end
commands.viewRitualLocation = function(exec,_,circleName)
	local part=resolveRitual(circleName)
	if exec and exec.Character then
		local hrp=exec.Character:FindFirstChild("HumanoidRootPart")
		if hrp then hrp.CFrame=CFrame.new(part.Position+Vector3.new(0,6,10),part.Position) end
	end
end
commands.approveRitual = function(exec,_,circleName,effectText)
	local part,rm=resolveRitual(circleName)
	assert(type(effectText)=="string" and #effectText>0,"effect text required for approval")
	assert(rm.approve(part,effectText),"Failed to approve ritual")
end
commands.rejectRitual = function(exec,_,circleName)
	local part,rm=resolveRitual(circleName)
	assert(rm.reject(part),"Failed to reject ritual")
end
commands.ignoreRitual = function(exec,_,circleName)
	local part,rm=resolveRitual(circleName)
	rm.ignore(part)
end
-- SERVER
commands.shutdownServer = function(exec,_)
	fireNotif(nil,"Server Shutdown","The server is shutting down in 5 seconds.",8,"warning")
	task.delay(5,function()
		for _,p in ipairs(Players:GetPlayers()) do p:Kick("Server shut down by a moderator.") end
	end)
end
commands.restartServer = function(exec,_)
	fireNotif(nil,"Server Restart","The server is restarting in 5 seconds.",8,"warning")
	task.delay(5,function()
		for _,p in ipairs(Players:GetPlayers()) do p:Kick("Server is restarting. Please rejoin.") end
	end)
end
-- MOD SELF-EFFECTS
local function selfEffect(exec,effect,...)
	assert(exec,"exec required for self-effects")
	modSelfEffectRE:FireClient(exec,effect,...)
end
commands.modFly        = function(exec,_)        selfEffect(exec,"fly") end
commands.modNoclip     = function(exec,_)        selfEffect(exec,"noclip") end
commands.modGodmode    = function(exec,_)
	invinciblePlayers[exec.UserId] = not invinciblePlayers[exec.UserId]
	selfEffect(exec,"godmode")
end
commands.modSpeed      = function(exec,_,mult)   selfEffect(exec,"speed",mult) end
commands.modTpCoord    = function(exec,_,x,y,z) selfEffect(exec,"tpcoord",x,y,z) end
commands.modSpectate   = function(exec,_,tName)  selfEffect(exec,"spectate",tName) end
commands.modUnspectate = function(exec,_)        selfEffect(exec,"unspectate") end
-- Force EVERY (non-mod) player's camera onto the target -- event tool ("all eyes on X").
-- Mods are exempt so they keep control of their own view while running the event.
commands.forceSpectateAll = function(exec,target)
	assert(target,"target player required (who everyone should watch)")
	local count=0
	for _,p in ipairs(Players:GetPlayers()) do
		if p~=target and not isMod(p) then
			modTargetEffectRE:FireClient(p,"forcespectate",target.Name)
			count+=1
		end
	end
	fireNotif(exec,"Force Spectate",count.." player(s) now watching "..target.Name..".",6,"info")
end
commands.clearSpectateAll = function(exec,_)
	for _,p in ipairs(Players:GetPlayers()) do
		modTargetEffectRE:FireClient(p,"forcespectate",false)
	end
	fireNotif(exec,"Force Spectate","All players released from forced spectate.",5,"info")
end
commands.modESP        = function(exec,_)        selfEffect(exec,"esp") end
commands.modInvisible  = function(exec,_)        selfEffect(exec,"modinvisible") end

-- MOD TARGET-EFFECTS (applied to a chosen target player, not the executing mod)
commands.setBlind = function(exec,target)
	assert(target,"target player required")
	modTargetEffectRE:FireClient(target,"blind",true)
end
commands.clearBlind = function(exec,target)
	assert(target,"target player required")
	modTargetEffectRE:FireClient(target,"blind",false)
end

-- SANITY MANAGEMENT
commands.checkSanity = function(exec,target)
	assert(target,"target player required")
	local sanM=assert(_G.SanityManager,"SanityManager not ready")
	fireNotif(exec,"Sanity",target.Name..": "..sanM.getSanity(target).."/100",6,"info")
end
commands.setSanity = function(exec,target,value)
	assert(target,"target player required")
	local sanM=assert(_G.SanityManager,"SanityManager not ready")
	sanM.setSanity(target,tonumber(value) or 0,"LoreTeamAction")
end
commands.reduceSanity = function(exec,target,amount)
	assert(target,"target player required")
	local sanM=assert(_G.SanityManager,"SanityManager not ready")
	sanM.adjustSanity(target,-(tonumber(amount) or 20),"LoreTeamAction")
end
commands.increaseSanity = function(exec,target,amount)
	assert(target,"target player required")
	local sanM=assert(_G.SanityManager,"SanityManager not ready")
	sanM.adjustSanity(target,tonumber(amount) or 20,"LoreTeamAction")
end

-- FEELING TRIGGER
commands.triggerFeeling = function(exec,target,feelingId)
	assert(target,"target player required")
	local fm=assert(_G.FeelingsManager,"FeelingsManager not ready")
	assert(fm.trigger(target,feelingId),"Feeling not triggered (unknown id, or blocked by a talent)")
end

-- RAGE MANAGEMENT
commands.forceEnterRage = function(exec,target)
	assert(target,"target player required")
	local rm=assert(_G.RageManager,"RageManager not ready")
	assert(rm.forceEnter(target),"Could not force rage entry (already raging?)")
end
commands.forceExitRage = function(exec,target)
	assert(target,"target player required")
	local rm=assert(_G.RageManager,"RageManager not ready")
	assert(rm.forceExit(target),"Could not force rage exit (not currently raging?)")
end
commands.assignRageDebuff = function(exec,target,debuffType,arg)
	assert(target,"target player required")
	local rm=assert(_G.RageManager,"RageManager not ready")
	rm.assignExitDebuff(exec,target,debuffType,arg)
end

-- ALLY MANAGEMENT
commands.checkAllyProgress = function(exec,target)
	assert(target,"target player required")
	local am=assert(_G.AllyManager,"AllyManager not ready")
	local list=am.getProgressSummary(target)
	if #list==0 then fireNotif(exec,"Ally Progress",target.Name.." has no tracked ally progress.",6,"info"); return end
	local lines={}
	for _,e in ipairs(list) do
		table.insert(lines,string.format("%s: %d/%ds (Introduced: %s)%s",e.name,math.floor(e.timeAccumulated),e.required,e.bothIntroduced and "Yes" or "No",e.isAlly and " [ALLY]" or ""))
	end
	fireNotif(exec,"Ally Progress -- "..target.Name,table.concat(lines,"\n"),10,"info")
end
commands.forceAllyBond = function(exec,target,otherName)
	assert(target,"target player required")
	local other=otherName and Players:FindFirstChild(tostring(otherName))
	assert(other,"second player not found: "..tostring(otherName))
	local am=assert(_G.AllyManager,"AllyManager not ready")
	assert(am.forceAllyBond(target,other),"Already allies")
end
commands.removeAllyBond = function(exec,target,otherName)
	assert(target,"target player required")
	local other=otherName and Players:FindFirstChild(tostring(otherName))
	assert(other,"second player not found: "..tostring(otherName))
	local am=assert(_G.AllyManager,"AllyManager not ready")
	assert(am.removeAllyBond(target,other),"Not currently allies")
end

-- INTERACTABLE EDITOR (design doc PART ONE/SEVEN: mod-only ExtraKey editor, exposed here
-- through the existing mod-panel-command convention rather than a bespoke floating panel --
-- every other mod tool in this codebase works this way). All BTools-placed objects
-- (interactables/ore nodes/smelters/tailoring stations/forges/farming plots) live under
-- workspace.SessionPlacements regardless of which manager owns them, so that's the one
-- place this needs to search.
local INTERACTABLE_EDITABLE_ATTRS = {
	InteractType=true, InteractPrompt=true, InteractRange=true, InteractCooldown=true,
	LootPool=true, QTETier=true, RewardType=true, RewardValue=true, JournalContent=true,
	ExtraKey=true, OreType=true, OreRarity=true, OreQuantity=true, RespawnAfterMining=true,
	SmelterTier=true, TailoringTier=true, RespawnTime=true,
	-- Farming attributes -- missing from this whitelist originally (caught live: the mod
	-- panel's "apply" click reported an error via ModCommand's ok/msg callback, which the
	-- test script simply wasn't listening for, so the failure looked like a silent no-op).
	PlantedSeed=true, GrowthDuration=true, Harvestable=true,
}
local function findPlacement(partName)
	local folder = workspace:FindFirstChild("SessionPlacements")
	return folder and folder:FindFirstChild(partName)
end
commands.setInteractableAttr = function(exec,_,partName,attrName,value)
	assert(INTERACTABLE_EDITABLE_ATTRS[attrName], "Not an editable attribute: "..tostring(attrName))
	local part = findPlacement(partName)
	assert(part, "Placement not found: "..tostring(partName))
	local num = tonumber(value)
	part:SetAttribute(attrName, num or value)
	fireNotif(exec, "Interactable Updated", partName.."."..attrName.." = "..tostring(value), 6, "info")
end
commands.getInteractableInfo = function(exec,_,partName)
	local part = findPlacement(partName)
	assert(part, "Placement not found: "..tostring(partName))
	local im = _G.InteractableManager
	local lines = {}
	if im then
		local summary = im.getAttributesSummary(part)
		for k,v in pairs(summary) do table.insert(lines, k..": "..tostring(v)) end
	else
		for attrName,v in pairs(part:GetAttributes()) do table.insert(lines, attrName..": "..tostring(v)) end
	end
	fireNotif(exec, partName, table.concat(lines, "\n"), 10, "info")
end

local function dispatch(exec,cmdName,target,...)
	local handler=commands[cmdName]
	if not handler then logAction(exec,cmdName,"ERROR: unknown command"); return false,"Unknown command: "..tostring(cmdName) end
	local ok,err=pcall(handler,exec,target,...); logAction(exec,cmdName,ok and "OK" or ("ERROR: "..tostring(err))); return ok,err
end

local ModManager = {}
function ModManager.isOwner(p) return isOwner(p) end
function ModManager.isMod(p)   return isMod(p)   end
function ModManager.isInvincible(p) return p ~= nil and invinciblePlayers[p.UserId] == true end
function ModManager.executeCommand(exec,cmdName,targetName,...)
	if not isMod(exec) then warn("[ModManager] Permission denied: "..(exec and exec.Name or "?")); return false,"Permission denied" end
	if targetName=="ALL" then
		local allOk=true
		for _,p in ipairs(Players:GetPlayers()) do local ok=dispatch(exec,cmdName,p,...); if not ok then allOk=false end end
		return allOk, allOk and "OK: ALL" or "Some failed"
	end
	local target=targetName and Players:FindFirstChild(tostring(targetName)) or nil
	return dispatch(exec,cmdName,target,...)
end
function ModManager.directExecute(cmdName,exec,target,...) return dispatch(exec,cmdName,target,...) end
ModManager.isLoreTeam = isLoreTeam
function ModManager.getLastLog()  return actionLog[#actionLog] end
function ModManager.getLogCount() return #actionLog end
_G.ModManager = ModManager

modMenuDataRF.OnServerInvoke = function(sender)
	if not isMod(sender) then return nil end
	local dm=_G.DataManager; local players={}
	for _,p in ipairs(Players:GetPlayers()) do
		players[#players+1]={
			name=p.Name,displayName=p.DisplayName,
			fightingStyle=dm and dm.getValue(p,"FightingStyle") or "None",
			playerState=dm and dm.getValue(p,"PlayerState") or "?",
			hunger=dm and dm.getValue(p,"Hunger") or 0,
			water=dm and dm.getValue(p,"Water") or 0,
			stage=dm and dm.getValue(p,"PDStage") or 0,
			race=dm and dm.getValue(p,"Race") or "Human",
			title=dm and dm.getValue(p,"Title") or "",
		}
	end
	return {
		players=players, serverLocked=serverLocked,
		talents={"Riposte","Executioner","Counter","Warrior","Guardian","Swift","Endurance","IronWill","Bloodbound","Herald","AwakenedEyes","ReinforcedMind","ReinforcedMuscles","BlindSight","BloodInsight","ColdBlood","IronNerve","Stoicism"},
		fightingStyles={"None","Ironwall","Duelist","Berserker","Unarmed","Spear","Dagger"},
	}
end

modFullLogRF.OnServerInvoke = function(sender)
	if not isMod(sender) then return nil end
	return actionLog
end

modPlayerTalsRF.OnServerInvoke = function(sender,targetName)
	if not isMod(sender) then return nil end
	local dm=_G.DataManager; if not dm then return {} end
	local target=targetName and Players:FindFirstChild(tostring(targetName))
	if not target then return {} end
	return dm.getValue(target,"Talents") or {}
end

modLoreBoardRF.OnServerInvoke = function(sender)
	if not isMod(sender) then return nil end
	return loreBoard
end

-- ================================================================================
-- PLAYER INFO VIEWER -- one read-only snapshot of everything the lore team needs to set a
-- character up. Polled ~1s by the panel while open, so it is assembled fresh each call and
-- nothing here writes.
--
-- The username/display-name/in-game-name split is the whole point: the lore team knows
-- characters by their in-game name ("Brennus Verkanos") but has to grant things to a Roblox
-- account, and nothing in the game showed both side by side before this.
-- ================================================================================
local modPlayerInfoRF = getOrCreate("ModPlayerInfo", true)
local modRevealerCfgRF = getOrCreate("ModRevealerConfig", true)

local function countKeys(t)
	if type(t)~="table" then return 0 end
	local n=0; for _ in pairs(t) do n+=1 end; return n
end

modPlayerInfoRF.OnServerInvoke = function(sender,targetName)
	if not isMod(sender) then return nil end
	local dm=_G.DataManager; if not dm then return nil end
	local t=targetName and Players:FindFirstChild(tostring(targetName))
	if not t or not dm.isLoaded(t) then return nil end

	local casteM = _G.CasteManager
	local dnaM   = _G.DNAManager
	local char   = t.Character
	local hum    = char and char:FindFirstChildOfClass("Humanoid")

	local stats = dm.getValue(t,"Stats") or {}
	local function effStat(name)
		local base = stats[name] or 0
		return base, (dnaM and dnaM.getEffectiveStat(t,name,base) or base)
	end
	local strBase,strEff = effStat("Strength")
	local endBase,endEff = effStat("Endurance")
	local agiBase,agiEff = effStat("Agility")

	local dna = dnaM and dnaM.getDNA(t) or {Clan="",Purity=0,Caste=""}
	local casteId = dna.Caste or ""
	local casteInfo = casteId~="" and Config.Castes[casteId] or nil
	local clanInfo = (dna.Clan or "")~="" and Config.LoreClans[dna.Clan] or nil

	-- Max stamina/posture come from the managers that own the formula rather than being
	-- re-derived here, so the viewer can never drift from what the player actually has.
	local maxStamina = Config.Stamina.Max
		+ (dnaM and dnaM.getStaminaMaxBonus(t) or 0)
		+ (_G.TalentManager and _G.TalentManager.getModifier(t,"MaxStaminaAdd") or 0)
		+ (casteM and casteM.getMaxStaminaBonus(t) or 0)
	local pm = _G.PostureManager
	local maxPosture = (pm and pm.getMax and pm.getMax(t)) or Config.Posture.Max

	local injuries = {}
	local im = _G.InjuryManager
	if im then
		-- getAllInjuries returns an ARRAY of {type,side,severity,appliedBy,appliedAt} records --
		-- not a table keyed by injury type. The display name lives in Config.Injuries[entry.type].
		for _,entry in ipairs(im.getAllInjuries(t) or {}) do
			if type(entry)=="table" and entry.type then
				local cfg = Config.Injuries[entry.type]
				local label = (cfg and cfg.name) or entry.type
				if entry.side then label = label.." ("..entry.side..")" end
				if entry.severity then label = label.." ["..entry.severity.."]" end
				table.insert(injuries,label)
			end
		end
		table.sort(injuries)
	end

	local allies = {}
	local am = _G.AllyManager
	if am and am.getJournalAllies then
		for _,a in ipairs(am.getJournalAllies(t) or {}) do
			table.insert(allies, a.name.." ("..tostring(a.hoursTogether).."h)")
		end
	end

	local rage = "Inactive"
	local rm = _G.RageManager
	if rm then
		if rm.isRaging(t) then rage="RAGING" elseif rm.isExhausted(t) then rage="Exhausted" end
	end

	local rep = dm.getValue(t,"Reputation") or {}
	local repLines = {}
	for _,faction in ipairs({"Gauls","Greeks","Military"}) do
		local base = rep[faction] or 0
		local eff = casteM and casteM.getEffectiveReputation(t,faction) or base
		table.insert(repLines, faction.." "..(eff>=0 and "+" or "")..string.format("%.0f",eff)
			..(eff~=base and (" (base "..base..")") or ""))
	end

	local fm = _G.FeelingsManager
	local feelings = (fm and fm.getActiveFeelings and fm.getActiveFeelings(t)) or {}

	local first = dm.getValue(t,"FirstName") or ""
	local family = dm.getValue(t,"FamilyName") or ""
	local inGameName = (first.." "..family):match("^%s*(.-)%s*$")

	return {
		identity = {
			username    = t.Name,
			displayName = t.DisplayName,
			inGameName  = inGameName~="" and inGameName or "(not introduced)",
			gender      = dm.getValue(t,"Gender") or "?",
			race        = dm.getValue(t,"Race") or "Human",
			userId      = t.UserId,
		},
		bloodline = {
			caste     = casteInfo and casteInfo.name or "None",
			casteRank = casteInfo and casteInfo.rank or nil,
			purity    = dna.Purity or 0,
			clan      = clanInfo and clanInfo.name or "None",
			titles    = casteM and casteM.getTitles(t) or {},
			activeBuffs = casteM and casteM.describeActiveBuffs(t) or {},
		},
		stats = {
			strength={strBase,strEff}, endurance={endBase,endEff}, agility={agiBase,agiEff},
			maxHealth = hum and hum.MaxHealth or 0,
			maxStamina = maxStamina,
			maxPosture = maxPosture,
		},
		condition = {
			health   = hum and math.floor(hum.Health) or 0,
			sanity   = _G.SanityManager and _G.SanityManager.getSanity(t) or 0,
			rage     = rage,
			injuries = injuries,
			feelings = feelings,
			hunger   = math.floor(dm.getValue(t,"Hunger") or 0),
			water    = math.floor(dm.getValue(t,"Water") or 0),
			state    = dm.getValue(t,"PlayerState") or "?",
		},
		progression = {
			talents      = dm.getValue(t,"Talents") or {},
			fightingStyle= dm.getValue(t,"FightingStyle") or "None",
			meditation   = dm.getValue(t,"MeditationQTEsPassed") or 0,
			pushups      = dm.getValue(t,"PushupsQTEsPassed") or 0,
			reputation   = repLines,
		},
		social = {
			allies       = allies,
			introducedTo = countKeys(dm.getValue(t,"KnownNames")),
			knownAboutSelf = dm.getValue(t,"KnownAboutSelf") or {},
		},
		economy = dm.getValue(t,"Currency") or {},
		equipment = {
			weapon   = dm.getValue(t,"EquippedWeapon") or "None",
			clothing = dm.getValue(t,"EquippedClothing") or "None",
			faceGear = dm.getValue(t,"EquippedFaceGear") or "None",
		},
	}
end

-- Read side for the panel's Revealer config box, so it opens showing what the NPC already is
-- rather than blank fields the mod has to guess at.
modRevealerCfgRF.OnServerInvoke = function(sender,npcId)
	if not isMod(sender) then return nil end
	local rm=_G.RevealManager; if not rm then return nil end
	local npcM=_G.NPCManager; if not npcM then return nil end
	local model=npcM.getByName(tostring(npcId))
	if not model then return nil end
	return rm.getConfig(model)
end

-- Live NPC roster for the mod panel's NPC dropdown (unique model name + display name).
local modNPCListRF = getOrCreate("ModNPCList", true)
modNPCListRF.OnServerInvoke = function(sender)
	if not isMod(sender) then return nil end
	local npcM=_G.NPCManager; if not npcM or not npcM.getAll then return {} end
	local out={}
	for _,model in ipairs(npcM.getAll()) do
		if model.Parent then
			table.insert(out,{ id=model.Name, name=model:GetAttribute("NPCName") or "Unnamed" })
		end
	end
	table.sort(out,function(a,b) return a.id<b.id end)
	return out
end

modCommandRE.OnServerEvent:Connect(function(sender,cmdName,targetName,...)
	if not checkRateLimit(sender,0.5) then modCommandRE:FireClient(sender,false,"Rate limited."); return end
	local ok,err=ModManager.executeCommand(sender,cmdName,targetName,...)
	modCommandRE:FireClient(sender,ok,ok and ("OK: "..tostring(cmdName)) or ("Error: "..tostring(err)))
end)

reqFlyRE.OnServerEvent:Connect(function(sender)
	if not isMod(sender) then return end
	flyAckRE:FireClient(sender); logAction(sender,"fly","toggled")
end)

Players.PlayerAdded:Connect(function(p)
	if serverLocked and not isMod(p) then task.wait(1); p:Kick("The server is currently locked.") end
end)
Players.PlayerRemoving:Connect(function(p)
	cooldowns[p.UserId]=nil
	local uid=p.UserId
	if frozenPlayers[uid] then frozenPlayers[uid].conn:Disconnect(); frozenPlayers[uid]=nil end
	invisiblePlayers[uid]=nil
	invinciblePlayers[uid]=nil
end)

local n=0; for _ in pairs(commands) do n+=1 end
print("[ModManager] Init: "..n.." commands registered")
